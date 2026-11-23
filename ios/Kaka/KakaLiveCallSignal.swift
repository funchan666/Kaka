import Foundation

#if canImport(AgoraRtmKit)
@preconcurrency import AgoraRtmKit
#endif

@MainActor
final class KakaLiveCallSignal: NSObject {
    static let shared = KakaLiveCallSignal()

    enum Action: Int, Hashable, Sendable {
        case invite = 0
        case cancelled = 1
        case accepted = 2
        case declined = 3
        case ended = 4
    }

    enum Failure: LocalizedError {
        case unavailable
        case disconnected
        case invalidCall
        case busy

        var errorDescription: String? {
            switch self {
            case .unavailable: return "Live call signaling is unavailable."
            case .disconnected: return "The call invitation could not be confirmed."
            case .invalidCall: return "The call details changed. Open the live room again."
            case .busy: return "Another call is already in progress."
            }
        }
    }

    struct Invitation: Equatable, Sendable {
        let callID: String
        let channel: String
        let peerID: Int64
        let callType: Int
        let receivedAt: Date
        fileprivate let receipt: UUID
        fileprivate let receivedUptime: TimeInterval
    }

    var onInvitation: (@MainActor (Invitation) -> Void)?

    #if canImport(AgoraRtmKit)
    private struct Address: Equatable {
        let callID: String
        let channel: String
        let peerID: Int64
    }

    private struct InvitationIdentity: Hashable {
        let callID: String
        let peerID: Int64
    }

    private struct Target {
        let owner: UUID
        let address: Address
        let incoming: Bool
        let onResponse: @MainActor (Action) -> Void
    }

    private var client: AgoraRtmClientKit?
    private var connection: (session: UUID, task: Task<Void, Error>)?
    private var ready = false
    private var generation = UUID()
    private var session: UUID?
    private var localUserID: Int64 = 0
    private var callOwner: UUID?
    private var target: Target?
    private var pendingInvitation: Invitation?
    private var seenInvitations: [InvitationIdentity: TimeInterval] = [:]
    private var receivedActions: Set<Action> = []
    private var renewal: Task<Void, Never>?
    #endif

    func connect(session: UUID) async throws {
        #if canImport(AgoraRtmKit)
        try Task.checkCancellation()
        let observedGeneration = generation
        _ = try await KakaAccountStore.shared.remoteUserID(session: session)
        try Task.checkCancellation()
        guard observedGeneration == generation || self.session == session || connection?.session == session else {
            throw CancellationError()
        }
        if ready, self.session == session, client != nil { return }
        if let connection, connection.session == session {
            try await connection.task.value
            try Task.checkCancellation()
            return
        }
        if self.session != session {
            onInvitation = nil
            close()
        }
        let attempt = generation
        let task = Task { @MainActor in
            defer { if attempt == generation { connection = nil } }
            try await authenticate(session: session, attempt: attempt)
        }
        connection = (session, task)
        try await task.value
        try Task.checkCancellation()
        #else
        throw Failure.unavailable
        #endif
    }

    func reserveCall(owner: UUID, session: UUID) throws {
        #if canImport(AgoraRtmKit)
        guard ready, self.session == session else { throw Failure.unavailable }
        guard callOwner == nil else { throw Failure.busy }
        callOwner = owner
        #else
        throw Failure.unavailable
        #endif
    }

    func bind(callID: String, channel: String, peerID: Int64, owner: UUID,
              onResponse: @escaping @MainActor (Action) -> Void) throws {
        #if canImport(AgoraRtmKit)
        guard ready, callOwner == owner, target == nil, validPendingInvitation() == nil,
              let address = address(callID: callID, channel: channel, peerID: peerID) else { throw Failure.invalidCall }
        target = Target(owner: owner, address: address, incoming: false, onResponse: onResponse)
        receivedActions = []
        #else
        throw Failure.unavailable
        #endif
    }

    func bind(_ invitation: Invitation, owner: UUID,
              onResponse: @escaping @MainActor (Action) -> Void) throws {
        #if canImport(AgoraRtmKit)
        guard ready, callOwner == owner, target == nil, validPendingInvitation() == invitation,
              let address = address(callID: invitation.callID, channel: invitation.channel,
                                    peerID: invitation.peerID) else { throw Failure.invalidCall }
        pendingInvitation = nil
        target = Target(owner: owner, address: address, incoming: true, onResponse: onResponse)
        receivedActions = []
        #else
        throw Failure.unavailable
        #endif
    }

    func decline(_ invitation: Invitation) async throws {
        #if canImport(AgoraRtmKit)
        guard validPendingInvitation() == invitation else { throw Failure.invalidCall }
        pendingInvitation = nil
        let address = Address(callID: invitation.callID, channel: invitation.channel, peerID: invitation.peerID)
        try await send(.declined, to: address, internalRejection: true)
        #else
        throw Failure.unavailable
        #endif
    }

    func releaseCall(owner: UUID) {
        #if canImport(AgoraRtmKit)
        guard callOwner == owner else { return }
        callOwner = nil
        target = nil
        receivedActions = []
        #endif
    }

    func publish(_ action: Action, owner: UUID) async throws {
        #if canImport(AgoraRtmKit)
        guard callOwner == owner, let target, target.owner == owner else { throw Failure.unavailable }
        guard !target.incoming || (action != .invite && action != .cancelled) else { throw Failure.invalidCall }
        guard target.incoming || (action != .accepted && action != .declined) else { throw Failure.invalidCall }
        try await send(action, to: target.address, owner: owner)
        #else
        throw Failure.unavailable
        #endif
    }

    func close() {
        #if canImport(AgoraRtmKit)
        generation = UUID()
        ready = false
        connection?.task.cancel()
        connection = nil
        renewal?.cancel()
        renewal = nil
        callOwner = nil
        target = nil
        pendingInvitation = nil
        seenInvitations = [:]
        receivedActions = []
        session = nil
        localUserID = 0
        let signedIn = client
        client = nil
        signedIn?.logout(nil)
        signedIn?.destroy()
        #endif
    }

    func disconnect(session: UUID) {
        #if canImport(AgoraRtmKit)
        if self.session == session || connection?.session == session {
            onInvitation = nil
            close()
        }
        #endif
    }

    #if canImport(AgoraRtmKit)
    private func authenticate(session: UUID, attempt: UUID) async throws {
        let accounts = KakaAccountStore.shared
        do {
            let userID = try await accounts.remoteUserID(session: session)
            let appID = try await accounts.rtcAppID(session: session)
            let token = try await Self.token(session: session)
            guard attempt == generation, userID > 0 else { throw CancellationError() }
            try Task.checkCancellation()
            let signingClient: AgoraRtmClientKit
            if let existing = client {
                guard self.session == session, localUserID == userID else { throw CancellationError() }
                try await Self.waitForSDK { complete in
                    existing.logout { @Sendable _, _ in complete(true) }
                }
                guard attempt == generation, self.client === existing else { throw CancellationError() }
                signingClient = existing
            } else {
                let configuration = AgoraRtmClientConfig(appId: appID, userId: String(userID))
                let newClient = try AgoraRtmClientKit(configuration, delegate: self)
                client = newClient
                signingClient = newClient
            }
            try Task.checkCancellation()
            try await Self.waitForSDK { complete in
                signingClient.login(token) { @Sendable _, error in complete(error == nil) }
            }
            let signedInUser = try await accounts.remoteUserID(session: session)
            guard attempt == generation, client === signingClient, signedInUser == userID else {
                throw CancellationError()
            }
            self.session = session
            localUserID = userID
            ready = true
        } catch {
            if attempt == generation, self.session == nil { close() }
            throw error
        }
    }

    private func send(_ action: Action, to address: Address, owner: UUID? = nil,
                      internalRejection: Bool = false) async throws {
        guard ready, let client, let session else { throw Failure.unavailable }
        let attempt = generation
        let user = try await KakaAccountStore.shared.remoteUserID(session: session)
        guard ready, attempt == generation, self.client === client, self.session == session, user == localUserID else {
            throw CancellationError()
        }
        if let owner {
            guard callOwner == owner, target?.address == address else { throw CancellationError() }
            if action == .invite || action == .accepted {
                guard receivedActions.isDisjoint(with: [.cancelled, .declined, .ended]) else { throw Failure.invalidCall }
            }
        }
        try Task.checkCancellation()
        var fields: [String: Any] = [
            "message_version": "1.0",
            "message_timestamp": Int64(Date().timeIntervalSince1970 * 1000),
            "callId": address.callID,
            "fromRoomId": address.channel,
            "message_action": action.rawValue,
            "fromUserId": user,
            "remoteUserId": address.peerID,
        ]
        switch action {
        case .invite: fields["callType"] = 4
        case .cancelled: fields["cancelCallByInternal"] = 0
        case .declined: fields["rejectByInternal"] = internalRejection ? 1 : 0
        default: break
        }
        let payload = String(decoding: try KakaRemoteClient.json(fields), as: UTF8.self)
        let options = AgoraRtmPublishOptions()
        options.channelType = .user
        try await Self.waitForSDK { complete in
            client.publish(channelName: String(address.peerID), message: payload, option: options) { @Sendable _, error in
                complete(error == nil)
            }
        }
    }

    private static func token(session: UUID) async throws -> String {
        let result = try await KakaAccountStore.shared.call(path: "/voyager/relay/pass", body: Data("{}".utf8), session: session)
        let fields = try KakaRemoteClient.object(result)
        guard let token = fields["signalPass"] as? String, !token.isEmpty, token.utf8.count <= 16384 else {
            throw Failure.unavailable
        }
        return token
    }

    private static func waitForSDK(_ execute: (@escaping @Sendable (Bool) -> Void) -> Void) async throws {
        let response = AsyncStream<Bool>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let deadline = Task {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if !Task.isCancelled { continuation.finish() }
            }
            continuation.onTermination = { _ in deadline.cancel() }
            execute { completed in
                continuation.yield(completed)
                continuation.finish()
            }
        }
        var iterator = response.makeAsyncIterator()
        let completed = await iterator.next()
        try Task.checkCancellation()
        guard completed == true else { throw Failure.disconnected }
    }

    private func deliver(_ payload: String, publisher: String, clientID: ObjectIdentifier) async {
        guard ready, let client, ObjectIdentifier(client) == clientID, let session,
              payload.utf8.count <= 4096,
              let body = try? KakaRemoteClient.object(Data(payload.utf8)), body["message_version"] as? String == "1.0",
              let peerID = KakaRemoteClient.userID(body["fromUserId"]), peerID > 0,
              peerID <= Int64(UInt32.max), peerID != localUserID, publisher == String(peerID),
              KakaRemoteClient.userID(body["remoteUserId"]) == localUserID,
              let callID = Self.identifier(body["callId"], maxBytes: 128),
              let rawAction = KakaRemoteClient.userID(body["message_action"]), let number = Int(exactly: rawAction),
              let action = Action(rawValue: number),
              let timestamp = KakaRemoteClient.userID(body["message_timestamp"]), timestamp > 0,
              Self.isFresh(timestamp) else { return }
        let rawRoom = body["fromRoomId"] ?? body["channelId"]
        let channel = Self.identifier(rawRoom, maxBytes: 64)
        if rawRoom != nil, channel == nil { return }
        if let fromRoom = body["fromRoomId"], let channelID = body["channelId"],
           Self.identifier(fromRoom, maxBytes: 64) != Self.identifier(channelID, maxBytes: 64) { return }
        let attempt = generation
        let receivingOwner = callOwner
        let userID = try? await KakaAccountStore.shared.remoteUserID(session: session)
        guard ready, attempt == generation, self.client === client, self.session == session,
              userID == localUserID, Self.isFresh(timestamp) else { return }
        if action == .invite {
            guard let channel, let rawType = KakaRemoteClient.userID(body["callType"]), (1...5).contains(rawType) else { return }
            await receiveInvitation(Address(callID: callID, channel: channel, peerID: peerID),
                                    callType: Int(rawType))
            return
        }
        guard let target, receivingOwner == target.owner, target.address.callID == callID,
              target.address.peerID == peerID,
              channel == target.address.channel || (channel == nil && action == .declined && !target.incoming),
              !target.incoming || (action == .cancelled || action == .ended),
              receivedActions.insert(action).inserted else { return }
        target.onResponse(action)
    }

    private func receiveInvitation(_ address: Address, callType: Int) async {
        let now = ProcessInfo.processInfo.systemUptime
        seenInvitations = seenInvitations.filter { $0.value > now }
        let key = InvitationIdentity(callID: address.callID, peerID: address.peerID)
        guard seenInvitations[key] == nil, seenInvitations.count < 256 else { return }
        if target?.address.callID == address.callID && target?.address.peerID == address.peerID { return }
        seenInvitations[key] = now + 120
        guard callOwner == nil, validPendingInvitation() == nil, let onInvitation else {
            try? await send(.declined, to: address, internalRejection: true)
            return
        }
        let invitation = Invitation(callID: address.callID, channel: address.channel, peerID: address.peerID,
                                    callType: callType, receivedAt: Date(), receipt: UUID(), receivedUptime: now)
        pendingInvitation = invitation
        onInvitation(invitation)
    }

    private func validPendingInvitation() -> Invitation? {
        guard let pendingInvitation, ProcessInfo.processInfo.systemUptime - pendingInvitation.receivedUptime <= 30 else {
            pendingInvitation = nil
            return nil
        }
        return pendingInvitation
    }

    private func address(callID: String, channel: String, peerID: Int64) -> Address? {
        guard peerID > 0, peerID <= Int64(UInt32.max), peerID != localUserID,
              Self.identifier(callID, maxBytes: 128) != nil,
              Self.identifier(channel, maxBytes: 64) != nil else { return nil }
        return Address(callID: callID, channel: channel, peerID: peerID)
    }

    private static func identifier(_ value: Any?, maxBytes: Int) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= maxBytes,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return value
    }

    private static func isFresh(_ timestamp: Int64) -> Bool {
        abs(Date().timeIntervalSince1970 - Double(timestamp) / 1000) <= 60
    }

    private func renew(clientID: ObjectIdentifier) {
        guard ready, renewal == nil, let session, let client, ObjectIdentifier(client) == clientID else { return }
        let attempt = generation
        renewal = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if generation == attempt { renewal = nil } }
            guard let token = try? await Self.token(session: session), !Task.isCancelled,
                  generation == attempt, self.client === client, ready else { return }
            let currentUser = try? await KakaAccountStore.shared.remoteUserID(session: session)
            guard !Task.isCancelled, generation == attempt, self.session == session, self.client === client,
                  ready, currentUser == localUserID else { return }
            try? await Self.waitForSDK { complete in
                client.renewToken(token) { @Sendable _, error in complete(error == nil) }
            }
        }
    }

    private func linkFailed(clientID: ObjectIdentifier, tokenExpired: Bool) async {
        guard let session, let client, ObjectIdentifier(client) == clientID, connection == nil else { return }
        ready = false
        if tokenExpired { try? await connect(session: session) }
    }
    #endif
}

#if canImport(AgoraRtmKit)
extension KakaLiveCallSignal: AgoraRtmClientDelegate {
    nonisolated func rtmKit(_ rtmKit: AgoraRtmClientKit, didReceiveMessageEvent event: AgoraRtmMessageEvent) {
        guard event.channelType == .user, let payload = event.message.stringData else { return }
        let publisher = event.publisher
        let clientID = ObjectIdentifier(rtmKit)
        Task { @MainActor [weak self] in await self?.deliver(payload, publisher: publisher, clientID: clientID) }
    }

    nonisolated func rtmKit(_ rtmKit: AgoraRtmClientKit, tokenPrivilegeWillExpire channel: String?) {
        let clientID = ObjectIdentifier(rtmKit)
        Task { @MainActor [weak self] in self?.renew(clientID: clientID) }
    }

    nonisolated func rtmKit(_ rtmKit: AgoraRtmClientKit, didReceiveLinkStateEvent event: AgoraRtmLinkStateEvent) {
        guard event.serviceType.contains(.message), event.currentState == .failed else { return }
        let clientID = ObjectIdentifier(rtmKit)
        let tokenExpired = event.reasonCode == .tokenExpired
        Task { @MainActor [weak self] in await self?.linkFailed(clientID: clientID, tokenExpired: tokenExpired) }
    }
}
#endif
