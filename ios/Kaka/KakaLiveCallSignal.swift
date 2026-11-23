import Foundation

#if canImport(AgoraRtmKit)
@preconcurrency import AgoraRtmKit
#endif

@MainActor
final class KakaLiveCallSignal: NSObject {
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

        var errorDescription: String? {
            switch self {
            case .unavailable: return "Live call signaling is unavailable."
            case .disconnected: return "The call invitation could not be confirmed."
            case .invalidCall: return "The call details changed. Open the live room again."
            }
        }
    }

    #if canImport(AgoraRtmKit)
    private struct Target {
        let id = UUID()
        let callID: String
        let channel: String
        let peerID: Int64
        let onResponse: @MainActor (Action) -> Void
    }

    private var client: AgoraRtmClientKit?
    private var connecting = false
    private var ready = false
    private var generation = UUID()
    private var session: UUID?
    private var localUserID: Int64 = 0
    private var target: Target?
    private var receivedActions: Set<Action> = []
    private var renewal: Task<Void, Never>?
    #endif

    func connect(session: UUID) async throws {
        #if canImport(AgoraRtmKit)
        guard !connecting else { throw Failure.unavailable }
        close()
        connecting = true
        let attempt = generation
        let accounts = KakaAccountStore.shared
        do {
            let userID = try await accounts.remoteUserID(session: session)
            let appID = try await accounts.rtcAppID(session: session)
            let token = try await Self.token(session: session)
            guard attempt == generation, userID > 0 else { throw CancellationError() }
            try Task.checkCancellation()
            let configuration = AgoraRtmClientConfig(appId: appID, userId: String(userID))
            let newClient = try AgoraRtmClientKit(configuration, delegate: self)
            client = newClient
            try await Self.waitForSDK { complete in
                newClient.login(token) { @Sendable _, error in complete(error == nil) }
            }
            let signedInUser = try await accounts.remoteUserID(session: session)
            guard attempt == generation, signedInUser == userID else { throw CancellationError() }
            self.session = session
            localUserID = userID
            ready = true
            connecting = false
        } catch {
            if attempt == generation { close() }
            throw error
        }
        #else
        throw Failure.unavailable
        #endif
    }

    func bind(callID: String, channel: String, peerID: Int64,
              onResponse: @escaping @MainActor (Action) -> Void) throws {
        #if canImport(AgoraRtmKit)
        guard ready, peerID > 0, peerID != localUserID, !callID.isEmpty, callID.utf8.count <= 128,
              !channel.isEmpty, channel.utf8.count <= 128 else { throw Failure.invalidCall }
        target = Target(callID: callID, channel: channel, peerID: peerID, onResponse: onResponse)
        receivedActions = []
        #else
        throw Failure.unavailable
        #endif
    }

    func publish(_ action: Action) async throws {
        #if canImport(AgoraRtmKit)
        guard ready, let client, let session, let target else { throw Failure.unavailable }
        let user = try await KakaAccountStore.shared.remoteUserID(session: session)
        guard ready, self.client === client, self.target?.id == target.id, user == localUserID else {
            throw CancellationError()
        }
        try Task.checkCancellation()
        var fields: [String: Any] = [
            "message_version": "1.0",
            "message_timestamp": Int64(Date().timeIntervalSince1970 * 1000),
            "callId": target.callID,
            "fromRoomId": target.channel,
            "message_action": action.rawValue,
            "fromUserId": user,
            "remoteUserId": target.peerID,
        ]
        switch action {
        case .invite: fields["callType"] = 4
        case .cancelled: fields["cancelCallByInternal"] = 0
        case .declined: fields["rejectByInternal"] = 0
        default: break
        }
        let payload = String(decoding: try KakaRemoteClient.json(fields), as: UTF8.self)
        let options = AgoraRtmPublishOptions()
        options.channelType = .user
        try await Self.waitForSDK { complete in
            client.publish(channelName: String(target.peerID), message: payload, option: options) { @Sendable _, error in
                complete(error == nil)
            }
        }
        #else
        throw Failure.unavailable
        #endif
    }

    func close() {
        #if canImport(AgoraRtmKit)
        generation = UUID()
        ready = false
        connecting = false
        renewal?.cancel()
        renewal = nil
        target = nil
        receivedActions = []
        session = nil
        localUserID = 0
        let signedIn = client
        client = nil
        signedIn?.logout(nil)
        signedIn?.destroy()
        #endif
    }

    #if canImport(AgoraRtmKit)
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
        guard ready, let client, ObjectIdentifier(client) == clientID, let target, let session,
              publisher == String(target.peerID), payload.utf8.count <= 4096,
              let body = try? KakaRemoteClient.object(Data(payload.utf8)), body["message_version"] as? String == "1.0",
              body["callId"] as? String == target.callID, KakaRemoteClient.userID(body["fromUserId"]) == target.peerID,
              KakaRemoteClient.userID(body["remoteUserId"]) == localUserID,
              let rawAction = KakaRemoteClient.userID(body["message_action"]), let number = Int(exactly: rawAction),
              let action = Action(rawValue: number), action != .invite,
              let timestamp = KakaRemoteClient.userID(body["message_timestamp"]), timestamp > 0,
              abs(Date().timeIntervalSince1970 - Double(timestamp) / 1000) <= 60 else { return }
        if let channel = body["fromRoomId"] as? String, !channel.isEmpty, channel != target.channel { return }
        let userID = try? await KakaAccountStore.shared.remoteUserID(session: session)
        guard ready, self.client === client, self.target?.id == target.id, userID == localUserID,
              receivedActions.insert(action).inserted else { return }
        target.onResponse(action)
    }

    private func renew(clientID: ObjectIdentifier) {
        guard ready, renewal == nil, let session, let client, ObjectIdentifier(client) == clientID else { return }
        let attempt = generation
        renewal = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if generation == attempt { renewal = nil } }
            guard let token = try? await Self.token(session: session), !Task.isCancelled,
                  generation == attempt, self.client === client else { return }
            client.renewToken(token, completion: nil)
        }
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
}
#endif
