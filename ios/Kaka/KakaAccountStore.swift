import CommonCrypto
import Foundation
import Security

actor KakaAccountStore {
    static let shared = KakaAccountStore()

    enum Request: Sendable {
        case session
        case register(name: String, email: String, password: String)
        case login(email: String, password: String)
        case guest
        case signOut(UUID)
        case delete(UUID)
        case read(UUID?)
        case write(UUID?, revision: Int, record: String)
    }

    struct Session: Sendable {
        let token: UUID
        let name: String?
        let email: String?
    }

    enum Response: Sendable {
        case session(Session?)
        case record(KakaRecordStore.Snapshot)
    }

    enum Failure: String, Error {
        case invalidInput = "auth-input"
        case duplicate = "auth-duplicate"
        case credentials = "auth-credentials"
        case accountLimit = "auth-limit"
        case sessionChanged = "session-changed"
        case storage = "storage-error"
    }

    private struct Account: Codable {
        let id: UUID
        let name: String
        let email: String
        let salt: Data
        let verifier: Data
    }

    private struct Workspace: Codable {
        let token: UUID
        let accountID: UUID?
    }

    private struct Directory: Codable {
        var accounts: [Account] = []
        var active: Workspace?
        var pendingRemoval: [UUID] = []
    }

    func perform(_ request: Request) throws -> Response {
        switch request {
        case .read(let token):
            let accountID = try token.map { try workspace($0, in: load()).accountID } ?? nil
            return .record(try KakaRecordStore.read(accountID: accountID))
        case .write(let token, let revision, let record):
            let accountID = try token.map { try workspace($0, in: load()).accountID } ?? nil
            return .record(try KakaRecordStore.write(record, ifRevision: revision, accountID: accountID))
        default:
            break
        }

        var directory = try load()
        switch request {
        case .session:
            purgeDeletedRecords(&directory)
            return .session(session(in: directory))
        case .register(let name, let email, let password):
            guard directory.active == nil else { throw Failure.sessionChanged }
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let email = try normalizedEmail(email)
            try validatePassword(password)
            guard (1...24).contains(name.utf16.count) else { throw Failure.invalidInput }
            guard !directory.accounts.contains(where: { $0.email == email }) else { throw Failure.duplicate }
            guard directory.accounts.count < 24 else { throw Failure.accountLimit }
            var salt = Data(count: 16)
            let status = salt.withUnsafeMutableBytes { bytes in
                SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
            }
            guard status == errSecSuccess else { throw Failure.storage }
            let account = Account(id: UUID(), name: name, email: email, salt: salt,
                                  verifier: try verifier(password, salt: salt))
            directory.accounts.append(account)
            directory.active = Workspace(token: UUID(), accountID: account.id)
        case .login(let email, let password):
            guard directory.active == nil else { throw Failure.sessionChanged }
            let email = try normalizedEmail(email)
            try validatePassword(password)
            guard let account = directory.accounts.first(where: { $0.email == email }),
                  Self.equal(try verifier(password, salt: account.salt), account.verifier) else {
                throw Failure.credentials
            }
            directory.active = Workspace(token: UUID(), accountID: account.id)
        case .guest:
            guard directory.active == nil else { throw Failure.sessionChanged }
            directory.active = Workspace(token: UUID(), accountID: nil)
        case .signOut(let token):
            _ = try workspace(token, in: directory)
            directory.active = nil
        case .delete(let token):
            guard let accountID = try workspace(token, in: directory).accountID else {
                throw Failure.sessionChanged
            }
            directory.accounts.removeAll { $0.id == accountID }
            directory.pendingRemoval.append(accountID)
            directory.active = nil
        case .read, .write:
            preconditionFailure("Record requests have already returned.")
        }

        try save(directory)
        purgeDeletedRecords(&directory)
        return .session(session(in: directory))
    }

    private func workspace(_ token: UUID, in directory: Directory) throws -> Workspace {
        guard let active = directory.active, active.token == token else { throw Failure.sessionChanged }
        return active
    }

    private func session(in directory: Directory) -> Session? {
        guard let active = directory.active else { return nil }
        let account = directory.accounts.first { $0.id == active.accountID }
        return Session(token: active.token, name: account?.name, email: account?.email)
    }

    private func normalizedEmail(_ email: String) throws -> String {
        let value = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.utf8.count <= 254,
              value.range(of: #"^[^@\s]+@[^@\s.]+(?:\.[^@\s.]+)+$"#, options: .regularExpression) != nil else {
            throw Failure.invalidInput
        }
        return value
    }

    private func validatePassword(_ password: String) throws {
        guard (8...128).contains(password.utf16.count),
              !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.invalidInput
        }
    }

    private func verifier(_ password: String, salt: Data) throws -> Data {
        var output = Data(count: 32)
        let status = password.withCString { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                output.withUnsafeMutableBytes { result in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes, password.utf8.count,
                                         saltBytes.bindMemory(to: UInt8.self).baseAddress, saltBytes.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 600_000,
                                         result.bindMemory(to: UInt8.self).baseAddress, result.count)
                }
            }
        }
        guard Int(status) == kCCSuccess else { throw Failure.storage }
        return output
    }

    private static func equal(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { result, pair in result | (pair.0 ^ pair.1) } == 0
    }

    private var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "kaka.account-directory.v1",
         kSecAttrAccount as String: "directory"]
    }

    private func load() throws -> Directory {
        var query = keychainQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return Directory() }
        guard status == errSecSuccess, let data = value as? Data else { throw Failure.storage }
        let directory = try JSONDecoder().decode(Directory.self, from: data)
        if let accountID = directory.active?.accountID,
           !directory.accounts.contains(where: { $0.id == accountID }) {
            throw Failure.storage
        }
        return directory
    }

    private func save(_ directory: Directory) throws {
        let data = try JSONEncoder().encode(directory)
        let query = keychainQuery
        let values = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw Failure.storage }
        } else if status != errSecSuccess {
            throw Failure.storage
        }
    }

    private func purgeDeletedRecords(_ directory: inout Directory) {
        guard !directory.pendingRemoval.isEmpty else { return }
        var updated = directory
        updated.pendingRemoval = directory.pendingRemoval.filter { accountID in
            do {
                try KakaRecordStore.remove(accountID: accountID)
                return false
            } catch {
                return true
            }
        }
        if updated.pendingRemoval != directory.pendingRemoval, (try? save(updated)) != nil {
            directory = updated
        }
    }
}
