import Foundation
import Security

actor KakaAccountStore {
    static let shared = KakaAccountStore()

    enum Request: Sendable {
        case session
        case register(name: String, email: String, password: String)
        case login(email: String, password: String)
        case signOut(UUID)
        case delete(UUID)
        case read(UUID)
        case write(UUID, revision: Int, record: String)
    }

    struct Session: Sendable {
        let token: UUID
        let name: String
        let email: String
    }

    struct RoomMessagingIdentity: Sendable {
        let appKey: String
        let account: String
        let token: String
        let userID: Int64
        let name: String
    }

    enum Response: Sendable {
        case session(Session?)
        case record(KakaRecordStore.Snapshot)
    }

    enum Failure: String, Error {
        case invalidInput = "auth-input"
        case duplicate = "auth-duplicate"
        case authRejected = "auth-rejected"
        case sessionChanged = "session-changed"
        case storage = "storage-error"
        case unavailable = "service-unavailable"
        case unconfigured = "service-unconfigured"
        case network = "service-network"
        case rejected = "service-rejected"
        case expired = "service-session-expired"

        var code: String { rawValue }
    }

    private struct Credentials: Codable, Sendable {
        let userID: Int64
        let access: String
        let refresh: String
        let relay: String?
        let messagingToken: String?
        let messagingAccount: String?

        init(_ document: [String: Any], replacing previous: Self? = nil) throws {
            guard let access = document["encorePass"] as? String, !access.isEmpty,
                  let refresh = document["renewalPass"] as? String ?? previous?.refresh, !refresh.isEmpty,
                  let user = KakaRemoteClient.userID(document["voyagerBadge"]) ?? previous?.userID, user > 0 else {
                throw KakaRemoteClient.Fault.response
            }
            if let previous, previous.userID != user { throw Failure.sessionChanged }
            self.userID = user
            self.access = access
            self.refresh = refresh
            self.relay = document["relicPass"] as? String ?? previous?.relay
            messagingToken = document["transitPass"] as? String ?? previous?.messagingToken
            messagingAccount = document["relayCode"] as? String ?? previous?.messagingAccount
        }
    }

    private struct Workspace: Codable, Sendable {
        let scope: String
        let token: UUID
        let email: String
        var name: String
        var credentials: Credentials

        var session: Session { Session(token: token, name: name, email: email) }
    }

    private struct Pending<Value: Sendable> {
        let session: UUID
        let attempt = UUID()
        let task: Task<Value, Error>
    }

    private struct PartyAccess: Sendable {
        let value: String
        let expires: Date
    }

    private static let keychainService = "kaka.service-auth.v1"
    private var client: KakaRemoteClient?
    private var runtime: KakaRemoteClient.Runtime?
    private var verifiedSession: UUID?
    private var opening = false
    private var renewal: Pending<Credentials>?
    private var exchange: Pending<PartyAccess>?
    private var partyAccess: (session: UUID, credential: PartyAccess)?

    func perform(_ request: Request) async throws -> Response {
        do {
            switch request {
            case .session:
                return .session(try await restore())
            case .register(let name, let email, let password):
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard (1...24).contains(trimmed.utf16.count), password.count >= 8 else { throw Failure.invalidInput }
                return .session(try await signIn(email: email, password: password, proposedName: trimmed))
            case .login(let email, let password):
                return .session(try await signIn(email: email, password: password))
            case .signOut(let session):
                try await signOut(session)
                return .session(nil)
            case .delete(let session):
                _ = try active(session)
                throw Failure.unavailable
            case .read(let session):
                let account = try localID(session)
                return .record(try KakaRecordStore.read(accountID: account))
            case .write(let session, let revision, let record):
                let account = try localID(session)
                return .record(try KakaRecordStore.write(record, ifRevision: revision, accountID: account))
            }
        } catch {
            throw failure(for: error)
        }
    }

    func call(path: String, body: Data, session: UUID) async throws -> Data {
        // Dedicated methods own the exchange/bootstrapping routes. Business callers only receive their result.
        guard body.count <= 512 * 1024, (try? KakaRemoteClient.object(body)) != nil,
              path != "/console/unseal", !path.hasPrefix("/cipher/"),
              !path.hasPrefix("/sapi/auth/") else { throw Failure.invalidInput }
        do {
            _ = try active(session)
            let client = try transport()
            let data: Data
            if path.hasPrefix("/sapi/") {
                guard let runtime else { throw Failure.unavailable }
                data = try await callParty(path, body: body, session: session, client: client, runtime: runtime)
            } else {
                data = try await authenticated(path, body: body, session: session, client: client)
            }
            _ = try active(session)
            return try client.normalizedMedia(data, runtime: runtime)
        } catch {
            throw failure(for: error)
        }
    }

    func remoteUserID(session: UUID) throws -> Int64 {
        try active(session).credentials.userID
    }

    func remoteCommerceScope(session: UUID) throws -> String {
        try active(session).scope
    }

    func rtcAppID(session: UUID) throws -> String {
        _ = try active(session)
        guard let runtime else { throw Failure.unavailable }
        return runtime.rtcAppID
    }

    func roomMessagingIdentity(session: UUID) throws -> RoomMessagingIdentity {
        let workspace = try active(session)
        guard let key = runtime?.messagingAppKey, !key.isEmpty,
              let account = workspace.credentials.messagingAccount, !account.isEmpty,
              let token = workspace.credentials.messagingToken, !token.isEmpty else { throw Failure.unavailable }
        return RoomMessagingIdentity(appKey: key, account: account, token: token,
                                     userID: workspace.credentials.userID, name: workspace.name)
    }

    func messagingNoticeAccount(session: UUID) throws -> String {
        _ = try active(session)
        guard let account = runtime?.messagingNoticeAccount else { throw Failure.unavailable }
        return account
    }

    func voiceHeartbeatURL(session: UUID) throws -> URL {
        let workspace = try active(session)
        guard let runtime else { throw Failure.unavailable }
        do {
            let credential = workspace.credentials
            return try transport().heartbeatURL(token: credential.relay ?? credential.access, runtime: runtime)
        } catch {
            throw failure(for: error)
        }
    }

    private func signIn(email: String, password: String, proposedName: String? = nil) async throws -> Session {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.utf8.count <= 254,
              email.range(of: #"^[^@\s]+@[^@\s.]+(?:\.[^@\s.]+)+$"#, options: .regularExpression) != nil,
              (6...64).contains(password.count), !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.invalidInput
        }
        guard !opening else { throw Failure.sessionChanged }
        let client = try transport()
        guard try loadWorkspace()?.scope != client.configuration.scope else { throw Failure.sessionChanged }
        opening = true
        defer { opening = false }

        let runtime = try await bootstrap(client).runtime
        let body = try KakaRemoteClient.json(["fanAddress": email, "cipherKey": password])
        let login: Data
        do {
            login = try await client.gateway("/cipher/signal/launch", body: body)
        } catch let fault as KakaRemoteClient.Fault {
            if case .rejected(let code) = fault, code != 429 && code < 500 {
                throw Failure.authRejected
            }
            throw fault
        }
        let account = try KakaRemoteClient.object(login)
        let credentials = try Credentials(account)
        let existingAccount = account["onboarded"] as? Bool
        let empty = try KakaRemoteClient.json([String: String]())
        var profile = try KakaRemoteClient.object(await client.gateway("/r2/voyager/brief", body: empty, bearer: credentials.access))
        try verifyProfile(profile, expectedUser: credentials.userID)
        if let proposedName, existingAccount == false || (existingAccount == nil && profileName(profile) == nil) {
            let changes = try KakaRemoteClient.json(["nickname": proposedName])
            _ = try await client.gateway("/r2/voyager/refresh", body: changes, bearer: credentials.access)
            profile = try KakaRemoteClient.object(await client.gateway("/r2/voyager/brief", body: empty, bearer: credentials.access))
            try verifyProfile(profile, expectedUser: credentials.userID)
        }
        let workspace = Workspace(scope: client.configuration.scope, token: UUID(), email: email,
                                  name: profileName(profile) ?? "New artist", credentials: credentials)
        try saveWorkspace(workspace)
        self.runtime = runtime
        verifiedSession = workspace.token
        return workspace.session
    }

    private func restore() async throws -> Session? {
        guard let stored = try loadWorkspace() else { return nil }
        let client = try transport()
        guard stored.scope == client.configuration.scope else { return nil }
        if stored.token == verifiedSession { return stored.session }
        guard !opening else { throw Failure.sessionChanged }
        opening = true
        defer { opening = false }

        do {
            let boot = try await bootstrap(client, previous: stored.credentials)
            var workspace = try matchingWorkspace(stored.token, client: client)
            if let rotated = boot.credentials {
                workspace.credentials = rotated
                try saveWorkspace(workspace)
            }
            let empty = try KakaRemoteClient.json([String: String]())
            let profile = try KakaRemoteClient.object(
                await authenticated("/r2/voyager/brief", body: empty, session: stored.token, client: client)
            )
            workspace = try matchingWorkspace(stored.token, client: client)
            try verifyProfile(profile, expectedUser: workspace.credentials.userID)
            workspace.name = profileName(profile) ?? "New artist"
            try saveWorkspace(workspace)
            runtime = boot.runtime
            verifiedSession = workspace.token
            return workspace.session
        } catch let fault as KakaRemoteClient.Fault where fault.isExpired {
            try expire(stored.token)
            return nil
        } catch Failure.expired {
            return nil
        }
    }

    private func bootstrap(_ client: KakaRemoteClient, previous: Credentials? = nil) async throws
        -> (runtime: KakaRemoteClient.Runtime, credentials: Credentials?) {
        let settings: [String: Any] = ["consoleDialect": ["en"], "orbitZone": TimeZone.current.identifier]
        let body = try KakaRemoteClient.json(settings)
        let result = try KakaRemoteClient.object(await client.gateway("/console/unseal", body: body, renewalHint: previous?.refresh))
        let updated: Credentials?
        if let previous, let access = result["encorePass"] as? String, !access.isEmpty {
            updated = try Credentials(result, replacing: previous)
        } else {
            updated = nil
        }
        return (try KakaRemoteClient.Runtime(startup: result, fallbackSocketKey: client.configuration.socketAesKey), updated)
    }

    private func signOut(_ session: UUID) async throws {
        guard !opening else { throw Failure.sessionChanged }
        let workspace = try active(session)
        let client = try transport()
        opening = true
        defer { opening = false }

        try expire(session)
        let body = try KakaRemoteClient.json([String: String]())
        // The device still signs out if it loses connectivity during server revocation.
        _ = try? await client.gateway("/cipher/exit", body: body, bearer: workspace.credentials.access)
    }

    private func authenticated(_ path: String, body: Data, session: UUID, client: KakaRemoteClient) async throws -> Data {
        let workspace = try matchingWorkspace(session, client: client)
        do {
            let result = try await client.gateway(path, body: body, bearer: workspace.credentials.access)
            _ = try matchingWorkspace(session, client: client)
            return result
        } catch let fault as KakaRemoteClient.Fault where fault.isExpired {
            let updated = try await renew(workspace, client: client)
            do {
                let result = try await client.gateway(path, body: body, bearer: updated.access)
                _ = try matchingWorkspace(session, client: client)
                return result
            } catch let retryFault as KakaRemoteClient.Fault where retryFault.isExpired {
                // A concurrent refresh may have already installed a newer credential.
                let current = try matchingWorkspace(session, client: client)
                if current.credentials.access == updated.access { try expire(session) }
                throw Failure.expired
            }
        }
    }

    private func renew(_ rejected: Workspace, client: KakaRemoteClient) async throws -> Credentials {
        let current = try matchingWorkspace(rejected.token, client: client)
        guard current.credentials.access == rejected.credentials.access else { return current.credentials }

        let pending: Pending<Credentials>
        if let renewal, renewal.session == current.token {
            pending = renewal
        } else {
            let original = current.credentials
            let body = try KakaRemoteClient.json(["renewalPass": original.refresh])
            let task = Task {
                let content = try await client.gateway("/cipher/pass/renew", body: body)
                return try Credentials(KakaRemoteClient.object(content), replacing: original)
            }
            pending = Pending(session: current.token, task: task)
            renewal = pending
        }
        defer { if renewal?.attempt == pending.attempt { renewal = nil } }
        let updated: Credentials
        do {
            updated = try await pending.task.value
        } catch let fault as KakaRemoteClient.Fault where fault.isExpired {
            let latest = try matchingWorkspace(current.token, client: client)
            if latest.credentials.access == current.credentials.access { try expire(current.token) }
            throw Failure.expired
        }
        var latest = try matchingWorkspace(current.token, client: client)
        guard latest.credentials.access == current.credentials.access else { return latest.credentials }
        latest.credentials = updated
        try saveWorkspace(latest)
        return updated
    }

    private func callParty(_ path: String, body: Data, session: UUID,
                           client: KakaRemoteClient, runtime: KakaRemoteClient.Runtime) async throws -> Data {
        let token = try await partyCredential(session, client: client, runtime: runtime)
        do {
            return try await client.party(path, body: body, runtime: runtime, token: token)
        } catch KakaRemoteClient.Fault.rejected(401) {
            if partyAccess?.session == session, partyAccess?.credential.value == token { partyAccess = nil }
            let renewed = try await partyCredential(session, client: client, runtime: runtime)
            return try await client.party(path, body: body, runtime: runtime, token: renewed)
        }
    }

    private func partyCredential(_ session: UUID, client: KakaRemoteClient,
                                 runtime: KakaRemoteClient.Runtime) async throws -> String {
        let workspace = try active(session)
        if let partyAccess, partyAccess.session == session,
           partyAccess.credential.expires.timeIntervalSinceNow > 45 {
            return partyAccess.credential.value
        }

        let pending: Pending<PartyAccess>
        if let exchange, exchange.session == session {
            pending = exchange
        } else {
            let credentials = workspace.credentials
            let body = try KakaRemoteClient.json(["token": credentials.relay ?? credentials.access])
            let task = Task {
                let path = "/sapi/auth/v1/client/auth/exchangeToken"
                let result = try KakaRemoteClient.object(await client.party(path, body: body, runtime: runtime))
                guard let token = result["tokenValue"] as? String, !token.isEmpty else {
                    throw KakaRemoteClient.Fault.response
                }
                let duration = KakaRemoteClient.userID(result["tokenTimeout"]) ?? 1800
                return PartyAccess(value: token, expires: Date().addingTimeInterval(Double(duration > 0 ? duration : 1800)))
            }
            pending = Pending(session: session, task: task)
            exchange = pending
        }
        defer { if exchange?.attempt == pending.attempt { exchange = nil } }
        let credential = try await pending.task.value
        _ = try active(session)
        partyAccess = (session, credential)
        return credential.value
    }

    private func profileName(_ profile: [String: Any]) -> String? {
        for field in ["nickname", "castMoniker"] {
            if let value = profile[field] as? String {
                let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
                var available = 24
                let prefix = name.prefix { character in
                    let size = String(character).utf16.count
                    guard size <= available else { return false }
                    available -= size
                    return true
                }
                if !prefix.isEmpty { return String(prefix) }
            }
        }
        return nil
    }

    private func verifyProfile(_ profile: [String: Any], expectedUser: Int64) throws {
        if let marker = profile["voyagerBadge"], !(marker is NSNull) {
            guard let identifier = KakaRemoteClient.userID(marker), identifier == 0 || identifier == expectedUser else {
                throw Failure.sessionChanged
            }
        }
    }

    private func matchingWorkspace(_ token: UUID, client: KakaRemoteClient) throws -> Workspace {
        guard let workspace = try loadWorkspace(), workspace.token == token,
              workspace.scope == client.configuration.scope else { throw Failure.sessionChanged }
        return workspace
    }

    private func active(_ token: UUID) throws -> Workspace {
        guard token == verifiedSession else { throw Failure.sessionChanged }
        return try matchingWorkspace(token, client: transport())
    }

    private func localID(_ token: UUID) throws -> UUID {
        let workspace = try active(token)
        return try transport().configuration.workspaceID(for: workspace.credentials.userID)
    }

    private func transport() throws -> KakaRemoteClient {
        if let client { return client }
        let device: UUID
        if let stored = try readKeychain("device") {
            guard let value = UUID(uuidString: String(decoding: stored, as: UTF8.self)) else {
                throw Failure.storage
            }
            device = value
        } else {
            device = UUID()
            try writeKeychain(Data(device.uuidString.utf8), account: "device")
        }
        let service = try KakaRemoteClient(device: device)
        client = service
        return service
    }

    private func expire(_ token: UUID) throws {
        guard try loadWorkspace()?.token == token else { return }
        try writeKeychain(nil, account: "session")
        verifiedSession = nil
        runtime = nil
        renewal?.task.cancel()
        renewal = nil
        exchange?.task.cancel()
        exchange = nil
        partyAccess = nil
    }

    private func failure(for error: Error) -> Error {
        guard let fault = error as? KakaRemoteClient.Fault else { return error }
        switch fault {
        case .configuration: return Failure.unconfigured
        case .invalidBody: return Failure.invalidInput
        case .network: return Failure.network
        case .response: return Failure.rejected
        case .rejected: return fault.isExpired ? Failure.expired : Failure.rejected
        }
    }

    private func loadWorkspace() throws -> Workspace? {
        guard let data = try readKeychain("session") else { return nil }
        guard let stored = try? JSONDecoder().decode(Workspace.self, from: data),
              stored.credentials.userID > 0 else { throw Failure.storage }
        return stored
    }

    private func saveWorkspace(_ workspace: Workspace) throws {
        try writeKeychain(JSONEncoder().encode(workspace), account: "session")
    }

    private func keychainQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.keychainService,
         kSecAttrAccount as String: account]
    }

    private func readKeychain(_ account: String) throws -> Data? {
        var query = keychainQuery(account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw Failure.storage }
        return data
    }

    private func writeKeychain(_ data: Data?, account: String) throws {
        let query = keychainQuery(account)
        guard let data else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.storage }
            return
        }
        let updates = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw Failure.storage }
        } else if status != errSecSuccess {
            throw Failure.storage
        }
    }
}
