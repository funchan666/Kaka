import Foundation

#if canImport(NIMSDK)
@preconcurrency import NIMSDK
#endif

@MainActor
final class KakaRoomChat {
    struct AudienceMember: Identifiable, Sendable {
        let id: String
        let name: String
        let portrait: URL?
    }

    struct AudiencePage: Sendable {
        let members: [AudienceMember]
        let nextPageToken: String?
    }

    private struct Visit: Equatable {
        let session: UUID
        let id: UUID
        let kind: String
        let serverID: Int64

        init(publicFeed id: UUID, session: UUID) {
            self.id = id
            self.session = session
            kind = "public"
            serverID = 0
        }

        init(input: [String: Any], session: UUID, sending: Bool) throws {
            let fields: Set<String> = sending ? ["kind", "serverID", "visit", "text"] : ["kind", "serverID", "visit"]
            guard Set(input.keys) == fields, let kind = input["kind"] as? String,
                  ["live", "voice"].contains(kind), let raw = input["serverID"] as? String,
                  let visit = (input["visit"] as? String).flatMap({ UUID(uuidString: $0) }),
                  let serverID = Int64(raw), serverID > 0, String(serverID) == raw else {
                throw KakaAccountStore.Failure.invalidInput
            }
            self.session = session
            id = visit
            self.kind = kind
            self.serverID = serverID
        }
    }

    enum RoomNotice: Equatable {
        case voiceClosed(String)
        case gift(label: String, artwork: URL?, time: TimeInterval)
        case expression(VoiceExpression, user: Int64, seat: Int64)
    }

    struct PublicGift: Sendable, Identifiable {
        let id: String
        let label: String
        let artwork: URL?
    }

    struct VoiceExpression: Identifiable, Equatable, Sendable {
        let name: String
        let artwork: URL
        let animation: URL

        var id: URL { animation }
    }

    struct VoiceExpressionGroup: Identifiable, Sendable {
        let id: Int
        let name: String
        let choices: [VoiceExpression]
    }

    private let voiceRoom: (UUID, Int64) -> String?
    private let verifySeat: (Int64, UUID, Int64, String, Int64) -> Bool
    var onRoomNotice: ((UUID, RoomNotice) -> Void)?

    init(verifySeat: @escaping (Int64, UUID, Int64, String, Int64) -> Bool = { _, _, _, _, _ in false },
         voiceRoom: @escaping (UUID, Int64) -> String?) {
        self.verifySeat = verifySeat
        self.voiceRoom = voiceRoom
    }

    #if canImport(NIMSDK)
    private var visit: Visit?
    private var generation = UUID()
    private var client: V2NIMChatroomClient?
    private var listener: RoomListener?
    private var provider: RoomLinks?
    private var account: String?
    private var chatID: String?
    private var sender: (name: String, userID: Int64)?
    private var connected = false
    private var revision = 0
    private var transcript: [ChatLine] = []
    private var direct: DirectChannel?
    private var endRoomNotice: (@MainActor () -> Void)?
    private var expressionCatalog: [VoiceExpressionGroup]?
    private var expressionCatalogLoad: Task<[VoiceExpressionGroup], Error>?
    private var recentExpressions: [String: TimeInterval] = [:]
    private var sendingExpression = false
    private var publicFeedSender: String?
    private var recentPublicGifts: [String] = []
    private var onPublicGift: (@MainActor (PublicGift) -> Void)?
    private var publicWatchID: UUID?

    private struct Snapshot: Encodable {
        let connected: Bool
        let revision: Int
        let messages: [ChatLine]
    }
    #endif

    func watchPublicGifts(session: UUID, receive: @escaping @MainActor (PublicGift) -> Void) async {
        #if canImport(NIMSDK)
        let target = Visit(publicFeed: UUID(), session: session)
        guard let publisher = try? await KakaAccountStore.shared.messagingNoticeAccount(session: session),
              !Task.isCancelled else { return }
        publicWatchID = target.id
        onPublicGift = receive
        defer {
            if publicWatchID == target.id { close() }
        }
        while !Task.isCancelled, publicWatchID == target.id {
            do {
                if visit != target || !connected { try await enter(target, publicFeedSender: publisher) }
                try await Task.sleep(nanoseconds: 25_000_000_000)
            } catch {
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
            }
        }
        #endif
    }

    func perform(operation: String, input: [String: Any], session: UUID) async throws -> Data {
        let target = try Visit(input: input, session: session, sending: operation == "roomChat.send")
        #if canImport(NIMSDK)
        _ = try await KakaAccountStore.shared.remoteUserID(session: session)
        switch operation {
        case "roomChat.open":
            if target != visit || client == nil || !connected { try await enter(target) }
        case "roomChat.snapshot":
            guard target == visit else { throw KakaAccountStore.Failure.unavailable }
            if target.kind == "voice", voiceRoom(session, target.serverID) != chatID { closeRoom() }
        case "roomChat.send":
            guard target == visit, let text = input["text"] as? String else {
                throw KakaAccountStore.Failure.unavailable
            }
            try await send(text, visit: target)
        case "roomChat.close":
            if target == visit { closeRoom() }
        default:
            throw KakaAccountStore.Failure.invalidInput
        }
        let blocked = ChatSignIn.shared.blockedAccounts(session: session)
        let visible = transcript.filter { !blocked.contains($0.author) }
        return try JSONEncoder().encode(Snapshot(connected: connected, revision: revision + ChatSignIn.shared.blockRevision,
                                                 messages: visible))
        #else
        throw KakaAccountStore.Failure.unavailable
        #endif
    }

    func audience(kind: String, serverID: Int64, session: UUID, pageToken: String? = nil) async throws -> AudiencePage {
        #if canImport(NIMSDK)
        let lease = generation
        _ = try await KakaAccountStore.shared.remoteUserID(session: session)
        try check(lease)
        guard connected, let client, let chatID, let account, let visit,
              visit.session == session, visit.kind == kind, visit.serverID == serverID,
              kind != "voice" || voiceRoom(session, serverID) == chatID,
              ChatSignIn.shared.isSignedIn(session: session, account: account) else {
            throw KakaAccountStore.Failure.unavailable
        }

        let query = V2NIMChatroomMemberQueryOption()
        query.onlyOnline = true
        query.limit = 30
        query.pageToken = pageToken ?? ""
        let page: AudiencePage = try await SDKCallback.perform { completion in
            client.getChatroomService().getMemberList(by: query, success: { result in
                let members: [AudienceMember] = result.memberList.compactMap { value in
                    // NIM roles 4 and 5 are anonymous and virtual members.
                    guard let member = value as? V2NIMChatroomMember,
                          (0...3).contains(member.memberRole.rawValue), !member.blocked,
                          member.roomId == nil || member.roomId == chatID,
                          let id = member.accountId, !id.isEmpty,
                          let name = member.roomNick?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !name.isEmpty else { return nil }
                    let url = member.roomAvatar.flatMap { URL(string: $0) }
                    let portrait = url.flatMap { url in
                        url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil ? url : nil
                    }
                    return AudienceMember(id: id, name: String(name.prefix(64)), portrait: portrait)
                }
                let token = result.finished || result.pageToken.isEmpty || result.pageToken == pageToken ? nil : result.pageToken
                completion(.success(AudiencePage(members: members, nextPageToken: token)))
            }, failure: { _ in completion(.failure(.network)) })
        }
        _ = try await KakaAccountStore.shared.remoteUserID(session: session)
        try check(lease)
        guard connected, kind != "voice" || voiceRoom(session, serverID) == chatID,
              ChatSignIn.shared.isSignedIn(session: session, account: account) else {
            throw KakaAccountStore.Failure.unavailable
        }
        let blocked = ChatSignIn.shared.blockedAccounts(session: session)
        var seen = Set<String>()
        return AudiencePage(members: page.members.filter { !blocked.contains($0.id) && seen.insert($0.id).inserted },
                            nextPageToken: page.nextPageToken)
        #else
        throw KakaAccountStore.Failure.unavailable
        #endif
    }

    func canShowLiveViewer(account: String, session: UUID) -> Bool {
        #if canImport(NIMSDK)
        let blocked = ChatSignIn.shared.blockedAccounts(session: session)
        return account.isEmpty ? blocked.isEmpty : !blocked.contains(account)
        #else
        return true
        #endif
    }

    func voiceExpressions(roomID: Int64, session: UUID, visit: UUID, seat: Int64) async throws -> [VoiceExpressionGroup] {
        #if canImport(NIMSDK)
        let target = try expressionVisit(roomID: roomID, session: session, visit: visit, seat: seat)
        let groups = try await loadExpressions(target)
        _ = try expressionVisit(roomID: roomID, session: session, visit: visit, seat: seat)
        return groups
        #else
        throw KakaAccountStore.Failure.unavailable
        #endif
    }

    func sendVoiceExpression(_ choice: VoiceExpression, roomID: Int64, session: UUID, visit: UUID, seat: Int64) async throws {
        #if canImport(NIMSDK)
        guard !sendingExpression else { throw KakaAccountStore.Failure.unavailable }
        let target = try expressionVisit(roomID: roomID, session: session, visit: visit, seat: seat)
        let lease = generation
        sendingExpression = true
        defer { if generation == lease { sendingExpression = false } }
        let groups = try await loadExpressions(target)
        let user = try await KakaAccountStore.shared.remoteUserID(session: session)
        try check(lease)
        _ = try expressionVisit(roomID: roomID, session: session, visit: visit, seat: seat)
        guard let client, sender?.userID == user, groups.contains(where: { $0.choices.contains(choice) }) else {
            throw KakaAccountStore.Failure.unavailable
        }
        let fields: [String: Any] = ["attachType": -10, "data": ["sendUserId": user, "seatIndex": seat,
                                     "playUrl": choice.animation.absoluteString, "minImage": choice.artwork.absoluteString]]
        let raw = String(decoding: try KakaRemoteClient.json(fields), as: UTF8.self)
        let packet: RoomExpressionPacket = try await SDKCallback.perform { completion in
            client.getChatroomService().send(V2NIMChatroomMessageCreator.createCustomMessage(raw),
                params: V2NIMSendChatroomMessageParams(), success: { result in
                    guard let sent = result.message, let packet = RoomExpressionPacket(sent) else {
                        completion(.failure(.rejected))
                        return
                    }
                    completion(.success(packet))
                }, failure: { _ in completion(.failure(.rejected)) }, progress: nil)
        }
        await ingestExpression(packet, lease: lease)
        #else
        throw KakaAccountStore.Failure.unavailable
        #endif
    }

    func performDirect(operation: String, input: [String: Any], session: UUID) async throws -> Data {
        #if canImport(NIMSDK)
        let fields: Set<String> = operation == "directChat.send" ? ["userID", "visit", "text"] : ["userID", "visit"]
        guard Set(input.keys) == fields,
              let userID = KakaRemoteClient.userID(input["userID"]), userID > 0,
              let id = (input["visit"] as? String).flatMap({ UUID(uuidString: $0) }) else {
            throw KakaAccountStore.Failure.invalidInput
        }
        let viewer = try await KakaAccountStore.shared.remoteUserID(session: session)
        guard viewer != userID else { throw KakaAccountStore.Failure.invalidInput }
        let target = DirectVisit(session: session, userID: userID, id: id)
        switch operation {
        case "directChat.open":
            if direct?.visit != target || direct?.membership == nil { try await openDirect(target) }
        case "directChat.snapshot":
            guard direct?.visit == target else { throw KakaAccountStore.Failure.unavailable }
        case "directChat.send":
            guard let direct, direct.visit == target, let text = input["text"] as? String else {
                throw KakaAccountStore.Failure.unavailable
            }
            try await sendDirect(text, channel: direct)
        case "directChat.close":
            if direct?.visit == target { closeDirect() }
        default:
            throw KakaAccountStore.Failure.invalidInput
        }
        let channel = direct?.visit == target ? direct : nil
        let auth = ChatSignIn.shared
        let membership = channel?.membership
        let active = membership.map { auth.isSignedIn(session: session, account: $0.viewer) } ?? false
        let blocked = membership.map { auth.blockedAccounts(session: session).contains($0.account) } ?? false
        return try JSONEncoder().encode(DirectSnapshot(connected: active, canSend: active && !blocked && channel?.eligible == true,
                                                       blocked: blocked, revision: (channel?.revision ?? 0) + auth.blockRevision,
                                                       messages: blocked ? [] : channel?.messages ?? []))
        #else
        throw KakaAccountStore.Failure.unavailable
        #endif
    }

    func directGiftCatalog(hostID: Int64, visit: UUID, session: UUID) async throws -> KakaPeerGifts.Catalog {
        #if canImport(NIMSDK)
        let (channel, peer) = try await directGiftContext(hostID: hostID, visit: visit, session: session)
        return try await KakaPeerGifts.catalog(scene: "IM", peerID: hostID, session: session) {
            self.directGiftAllowed(channel, peer: peer)
        }
        #else
        throw KakaLiveGifts.Failure.unavailable
        #endif
    }

    func sendDirectGift(_ gift: KakaPeerGifts.Gift, quantity: Int, hostID: Int64, visit: UUID,
                        session: UUID) async throws -> KakaVoiceGifts.Delivery {
        #if canImport(NIMSDK)
        guard quantity == 1 else { throw KakaAccountStore.Failure.invalidInput }
        let (channel, peer) = try await directGiftContext(hostID: hostID, visit: visit, session: session)
        return try await KakaPeerGifts.send(gift, quantity: quantity, destination: .message(account: peer.account),
                                            peerID: hostID, session: session) {
            self.directGiftAllowed(channel, peer: peer)
        }
        #else
        throw KakaLiveGifts.Failure.unavailable
        #endif
    }

    func close() {
        #if canImport(NIMSDK)
        closeRoom()
        closeDirect()
        onPublicGift = nil
        publicWatchID = nil
        #endif
    }

    #if canImport(NIMSDK)
    private func closeRoom() {
        generation = UUID()
        visit = nil
        endRoomNotice?()
        endRoomNotice = nil
        publicFeedSender = nil
        recentPublicGifts = []
        expressionCatalogLoad?.cancel()
        expressionCatalogLoad = nil
        expressionCatalog = nil
        recentExpressions = [:]
        sendingExpression = false
        if let client {
            if let listener {
                client.remove(listener)
                client.getChatroomService().remove(listener)
            }
            client.exit()
            V2NIMChatroomClient.destroyInstance(client.getInstanceId())
        }
        client = nil
        listener = nil
        provider = nil
        account = nil
        chatID = nil
        sender = nil
        transcript.removeAll()
        connected = false
        revision += 1
    }
    #endif

    static func signOut(session: UUID) async {
        #if canImport(NIMSDK)
        await ChatSignIn.shared.end(session)
        #endif
    }

    static func setBlocked(userID: Int64, blocked: Bool, session: UUID) async throws {
        #if canImport(NIMSDK)
        let person = try await resolvePeer(userID, session: session)
        try await ChatSignIn.shared.setBlocked(person.account, blocked: blocked, session: session)
        _ = try await KakaAccountStore.shared.remoteUserID(session: session)
        #else
        throw KakaAccountStore.Failure.unavailable
        #endif
    }

    static func isBlocked(userID: Int64, session: UUID) async throws -> Bool {
        #if canImport(NIMSDK)
        let person = try await resolvePeer(userID, session: session)
        try await ChatSignIn.shared.refreshBlocks(session: session)
        _ = try await KakaAccountStore.shared.remoteUserID(session: session)
        return ChatSignIn.shared.blockedAccounts(session: session).contains(person.account)
        #else
        throw KakaAccountStore.Failure.unavailable
        #endif
    }

    static func observeCallRecharge(session: UUID, channel: String, since: Date,
                                    onRecharge: @escaping @MainActor () -> Void) async throws -> @MainActor () -> Void {
        #if canImport(NIMSDK)
        let accounts = KakaAccountStore.shared
        let identity = try await accounts.roomMessagingIdentity(session: session)
        let noticeAccount = try await accounts.messagingNoticeAccount(session: session)
        try await ChatSignIn.shared.prepare(session: session, identity: identity)
        _ = try await accounts.remoteUserID(session: session)
        try Task.checkCancellation()
        guard ChatSignIn.shared.isSignedIn(session: session, account: identity.account) else {
            throw KakaAccountStore.Failure.unavailable
        }
        return ChatSignIn.shared.observeRecharge(session: session, recipient: identity.account,
                                                 sender: noticeAccount, channel: channel, since: since,
                                                 onRecharge: onRecharge)
        #else
        throw KakaAccountStore.Failure.unavailable
        #endif
    }

    static func observeCallText(session: UUID, peerID: Int64, account: String, channel: String, since: Date,
                                onText: @escaping @MainActor (String) -> Void) async throws -> @MainActor () -> Void {
        #if canImport(NIMSDK)
        let peer = try await resolvePeer(peerID, session: session)
        try Task.checkCancellation()
        guard peer.account == account, !channel.isEmpty,
              !ChatSignIn.shared.blockedAccounts(session: session).contains(account),
              ChatSignIn.shared.isSignedIn(session: session, account: peer.viewer) else {
            throw KakaAccountStore.Failure.unavailable
        }
        return ChatSignIn.shared.observeCallText(session: session, recipient: peer.viewer, sender: account,
                                                peerID: peerID, channel: channel, since: since, onText: onText)
        #else
        throw KakaAccountStore.Failure.unavailable
        #endif
    }

    static func sendCallText(_ raw: String, session: UUID, peerID: Int64, account: String, channel: String,
                             stillInCall: () -> Bool) async throws -> String {
        #if canImport(NIMSDK)
        let text = try publicText(raw, limit: 280)
        let identity = try await KakaAccountStore.shared.roomMessagingIdentity(session: session)
        try Task.checkCancellation()
        guard let conversation = V2NIMConversationIdUtil.p2pConversationId(account) else {
            throw KakaAccountStore.Failure.unavailable
        }
        let sender: [String: Any] = ["userId": identity.userID,
            "fromNickName": identity.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""]
        let encoded = try KakaRemoteClient.json([
            "attachType": -1, "content": text, "channelId": channel, "ext": sender,
        ])
        let params = V2NIMSendCustomNotificationParams()
        let notification = V2NIMNotificationConfig()
        notification.offlineEnabled = false
        notification.unreadEnabled = false
        params.notificationConfig = notification
        let push = V2NIMNotificationPushConfig()
        push.pushEnabled = false
        params.pushConfig = push
        let _: Bool = try await SDKCallback.perform { completion in
            guard !Task.isCancelled, stillInCall(),
                  ChatSignIn.shared.ownsCallText(session: session, recipient: identity.account,
                                                 sender: account, peerID: peerID, channel: channel) else {
                completion(.failure(.unavailable))
                return
            }
            NIMSDK.shared().v2NotificationService.sendCustomNotification(conversation,
                content: String(decoding: encoded, as: UTF8.self), params: params,
                success: { completion(.success(true)) }, failure: { _ in completion(.failure(.rejected)) })
        }
        return text
        #else
        throw KakaAccountStore.Failure.unavailable
        #endif
    }

    #if canImport(NIMSDK)
    private struct Peer {
        let account: String
        let nickname: String
        let viewer: String
    }

    private struct DirectVisit: Equatable {
        let session: UUID
        let userID: Int64
        let id: UUID
    }

    private struct Membership: Sendable {
        let conversation: String
        let account: String
        let viewer: String
        let nickname: String
    }

    private struct DirectRecord: Encodable, Equatable, Sendable {
        let id: String
        let name: String
        let text: String
        let timestamp: Double
        let own: Bool
        let giftQuantity: Int?
        let giftImage: URL?

        init?(_ source: V2NIMMessage, membership: Membership) {
            guard source.conversationId == membership.conversation,
                  let from = source.senderId, let to = source.receiverId,
                  let key = source.messageClientId, !key.isEmpty, key.utf8.count <= 128,
                  source.createTime.isFinite else { return nil }
            own = from == membership.viewer && to == membership.account
            if own {
                guard source.sendingState.rawValue == 1, source.messageStatus.errorCode == 0 else { return nil }
            } else {
                guard from == membership.account, to == membership.viewer else { return nil }
            }
            id = key
            name = own ? "You" : membership.nickname
            timestamp = source.createTime
            switch source.messageType.rawValue {
            case 0:
                guard let value = source.text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
                text = String(value.prefix(500))
                giftQuantity = nil
                giftImage = nil
            case 100:
                guard let document = Self.document(source.attachment?.raw) ?? Self.document(source.serverExtension) else { return nil }
                let data = (document["data"] as? [String: Any]) ?? Self.document(document["data"] as? String) ?? document
                let type = KakaRemoteClient.userID(document["attachType"])
                guard type.map({ [50, 66, 88, 89].contains($0) }) == true
                        || document["type"] as? String == "im_gift" || document["attachType"] as? String == "SEND_GIFT"
                        || (KakaRemoteClient.userID(document["giftId"]) ?? 0) > 0,
                      let label = (data["giftName"] ?? data["name"]) as? String else { return nil }
                let clean = label.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty, clean.utf8.count <= 240, clean.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
                let count = KakaRemoteClient.userID(data["giftNum"]) ?? 1
                guard (1...9_999).contains(count) else { return nil }
                text = clean
                giftQuantity = Int(count)
                giftImage = ((data["giftIcon"] ?? data["giftImg"] ?? data["icon"]) as? String).flatMap(URL.init(string:)).flatMap {
                    $0.scheme?.lowercased() == "https" && $0.host != nil && $0.user == nil && $0.password == nil ? $0 : nil
                }
            default:
                return nil
            }
        }

        private static func document(_ raw: String?) -> [String: Any]? {
            guard let raw, raw.utf8.count <= 16_384 else { return nil }
            return try? KakaRemoteClient.object(Data(raw.utf8))
        }
    }

    private struct DirectSnapshot: Encodable {
        let connected: Bool
        let canSend: Bool
        let blocked: Bool
        let revision: Int
        let messages: [DirectRecord]
    }

    private final class DirectListener: NSObject, V2NIMMessageListener {
        private let membership: Membership
        private let accept: @Sendable ([DirectRecord]) -> Void

        init(membership: Membership, accept: @escaping @Sendable ([DirectRecord]) -> Void) {
            self.membership = membership
            self.accept = accept
        }

        func onReceive(_ values: [V2NIMMessage]) {
            accept(values.suffix(80).compactMap { DirectRecord($0, membership: membership) })
        }

        func onSend(_ value: V2NIMMessage) {
            if let message = DirectRecord(value, membership: membership) { accept([message]) }
        }
    }

    private final class DirectChannel {
        let visit: DirectVisit
        let generation = UUID()
        var membership: Membership?
        var listener: DirectListener?
        var messages: [DirectRecord] = []
        var revision = 0
        var eligible = false
        var sending = false

        init(_ visit: DirectVisit) { self.visit = visit }
    }

    private func openDirect(_ target: DirectVisit) async throws {
        closeDirect()
        let channel = DirectChannel(target)
        direct = channel
        do {
            let person = try await Self.resolvePeer(target.userID, session: target.session)
            try await ChatSignIn.shared.refreshBlocks(session: target.session)
            guard direct === channel, let key = V2NIMConversationIdUtil.p2pConversationId(person.account) else {
                throw KakaAccountStore.Failure.unavailable
            }
            let membership = Membership(conversation: key, account: person.account, viewer: person.viewer, nickname: person.nickname)
            channel.membership = membership
            let generation = channel.generation
            let listener = DirectListener(membership: membership) { [weak self] values in
                Task { @MainActor in self?.recordDirect(values, generation: generation) }
            }
            let service = NIMSDK.shared().v2MessageService
            channel.listener = listener
            service.add(listener)
            let history = V2NIMMessageListOption()
            history.conversationId = key
            history.limit = 50
            history.messageTypes = [NSNumber(value: 0), NSNumber(value: 100)]
            history.onlyQueryLocal = false
            let fetched: [DirectRecord] = try await SDKCallback.perform { completion in
                service.getMessageList(history, success: { rows in
                    completion(.success(rows.suffix(50).compactMap { DirectRecord($0, membership: membership) }))
                }, failure: { _ in completion(.failure(.network)) })
            }
            channel.eligible = try await directEligibility(membership, session: target.session)
            _ = try await KakaAccountStore.shared.remoteUserID(session: target.session)
            guard direct === channel else { throw KakaAccountStore.Failure.unavailable }
            recordDirect(fetched, generation: generation)
        } catch {
            if direct === channel { closeDirect() }
            throw error
        }
    }

    private func closeDirect() {
        if let listener = direct?.listener { NIMSDK.shared().v2MessageService.remove(listener) }
        direct = nil
    }

    private func directEligibility(_ peer: Membership, session: UUID) async throws -> Bool {
        let signIn = ChatSignIn.shared
        guard signIn.isSignedIn(session: session, account: peer.viewer),
              !signIn.blockedAccounts(session: session).contains(peer.account) else { return false }
        let payload = try JSONSerialization.data(withJSONObject: ["relayCode": peer.account])
        async let theirs = KakaAccountStore.shared.call(path: "/r2/voyager/veil/beacon-scan", body: payload, session: session)
        async let ours = KakaAccountStore.shared.call(path: "/r2/voyager/veil/self-scan", body: payload, session: session)
        let (fromPeer, fromUser) = try await (theirs, ours)
        guard let peerLocked = try KakaRemoteClient.object(fromPeer)["curtainLocked"] as? Bool,
              let userLocked = try KakaRemoteClient.object(fromUser)["curtainLocked"] as? Bool else {
            throw KakaAccountStore.Failure.rejected
        }
        return !peerLocked && !userLocked
    }

    private func directGiftContext(hostID: Int64, visit: UUID, session: UUID) async throws -> (DirectChannel, Membership) {
        guard let channel = direct, channel.visit == DirectVisit(session: session, userID: hostID, id: visit),
              let peer = channel.membership else { throw KakaLiveGifts.Failure.unavailable }
        try await ChatSignIn.shared.refreshBlocks(session: session)
        channel.eligible = try await directEligibility(peer, session: session)
        _ = try await KakaAccountStore.shared.remoteUserID(session: session)
        guard directGiftAllowed(channel, peer: peer) else { throw KakaLiveGifts.Failure.unavailable }
        return (channel, peer)
    }

    private func directGiftAllowed(_ channel: DirectChannel, peer: Membership) -> Bool {
        let signIn = ChatSignIn.shared
        let session = channel.visit.session
        return direct === channel && channel.eligible && signIn.isSignedIn(session: session, account: peer.viewer)
            && !signIn.blockedAccounts(session: session).contains(peer.account)
    }

    private func sendDirect(_ raw: String, channel: DirectChannel) async throws {
        guard let membership = channel.membership, !channel.sending else { throw KakaAccountStore.Failure.unavailable }
        let text = try Self.publicText(raw, limit: 500)
        channel.sending = true
        defer { channel.sending = false }
        let session = channel.visit.session
        channel.eligible = try await directEligibility(membership, session: session)
        _ = try await KakaAccountStore.shared.remoteUserID(session: session)
        let auth = ChatSignIn.shared
        guard direct === channel, channel.eligible, auth.isSignedIn(session: session, account: membership.viewer),
              !auth.blockedAccounts(session: session).contains(membership.account) else {
            throw KakaAccountStore.Failure.unavailable
        }
        let message = V2NIMMessageCreator.createTextMessage(text)
        let parameters = V2NIMSendMessageParams()
        let durability = V2NIMMessageConfig()
        durability.historyEnabled = true
        durability.offlineEnabled = true
        durability.roamingEnabled = true
        durability.onlineSyncEnabled = true
        durability.unreadEnabled = true
        durability.lastMessageUpdateEnabled = true
        parameters.messageConfig = durability
        let accepted: DirectRecord = try await SDKCallback.perform { completion in
            NIMSDK.shared().v2MessageService.send(message, conversationId: membership.conversation, params: parameters,
                                                  success: { result in
                guard let sent = result.message, let line = DirectRecord(sent, membership: membership), line.own else {
                    completion(.failure(.rejected))
                    return
                }
                completion(.success(line))
            }, failure: { _ in completion(.failure(.rejected)) }, progress: nil)
        }
        _ = try await KakaAccountStore.shared.remoteUserID(session: session)
        guard direct === channel else { throw KakaAccountStore.Failure.unavailable }
        recordDirect([accepted], generation: channel.generation)
    }

    private func recordDirect(_ values: [DirectRecord], generation: UUID) {
        guard let channel = direct, channel.generation == generation, !values.isEmpty else { return }
        var indexed = Dictionary(uniqueKeysWithValues: channel.messages.map { ($0.id, $0) })
        for value in values { indexed[value.id] = value }
        let sorted = indexed.values.sorted { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }
        let next = Array(sorted.suffix(50))
        if channel.messages != next {
            channel.messages = next
            channel.revision += 1
        }
    }

    private static let publicSafetyTerms = [
        "casino", "cashapp", "whatsapp", "telegram", "underage", "nudity", "nude", "sexual",
        "escort", "minor", "hookup", "crypto", "betting", "gambling", "lottery", "withdraw",
        "porn", "onlyfans", "adult only",
    ]

    fileprivate static func publicText(_ raw: String, limit: Int) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet.controlCharacters.subtracting(.newlines).subtracting(CharacterSet(charactersIn: "\t"))
        guard (1...limit).contains(text.utf16.count), text.rangeOfCharacter(from: forbidden) == nil else {
            throw KakaAccountStore.Failure.invalidInput
        }
        let plain = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let formatControls = CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{FEFF}")
        let visible = plain.unicodeScalars.filter { !formatControls.contains($0) }
        let searchable = String(String.UnicodeScalarView(visible)).lowercased()
        guard !publicSafetyTerms.contains(where: searchable.contains) else { throw KakaAccountStore.Failure.rejected }
        return text
    }

    private static func resolvePeer(_ userID: Int64, session: UUID) async throws -> Peer {
        let identity = try await KakaAccountStore.shared.roomMessagingIdentity(session: session)
        guard userID > 0, userID != identity.userID else { throw KakaAccountStore.Failure.invalidInput }
        let body = try JSONSerialization.data(withJSONObject: ["voyagerBadge": userID])
        let data = try await KakaAccountStore.shared.call(path: "/r2/voyager/identity-slate", body: body, session: session)
        let profile = try KakaRemoteClient.object(data)
        guard let account = profile["relayCode"] as? String, !account.isEmpty, account != identity.account else {
            throw KakaAccountStore.Failure.unavailable
        }
        if let marker = profile["voyagerBadge"], KakaRemoteClient.userID(marker) != userID {
            throw KakaAccountStore.Failure.rejected
        }
        try await ChatSignIn.shared.prepare(session: session, identity: identity)
        _ = try await KakaAccountStore.shared.remoteUserID(session: session)
        let name = (profile["castMoniker"] as? String ?? profile["nickname"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Peer(account: account, nickname: name.isEmpty ? "Artist" : String(name.prefix(48)), viewer: identity.account)
    }

    private func enter(_ target: Visit, publicFeedSender: String? = nil) async throws {
        closeRoom()
        visit = target
        let lease = generation
        do {
            let identity = try await KakaAccountStore.shared.roomMessagingIdentity(session: target.session)
            let room = try await destination(target)
            try check(lease)
            try await ChatSignIn.shared.prepare(session: target.session, identity: identity)
            try check(lease)
            try await ChatSignIn.shared.refreshBlocks(session: target.session)
            try check(lease)
            let links: [String] = try await SDKCallback.perform { completion in
                NIMSDK.shared().v2LoginService.getChatroomLinkAddress(room, success: { values in
                    completion(.success(values))
                }, failure: { _ in completion(.failure(.network)) })
            }
            try check(lease)
            guard !links.isEmpty else { throw KakaAccountStore.Failure.unavailable }

            let instance = V2NIMChatroomClient.newInstance()
            let isPublicFeed = target.kind == "public"
            let observer = RoomListener(owner: self, generation: lease, isPublicFeed: isPublicFeed)
            let linkProvider = RoomLinks(links)
            let params = V2NIMChatroomEnterParams()
            params.accountId = identity.account
            params.token = identity.token
            params.linkProvider = linkProvider
            if !isPublicFeed {
                params.roomNick = identity.name
                let metadata = String(decoding: try JSONSerialization.data(withJSONObject: [
                    "nickname": identity.name, "yxAccid": identity.account, "userId": identity.userID
                ] as [String: Any]), as: UTF8.self)
                params.notificationExtension = metadata
                if target.kind == "voice" {
                    let tags = V2NIMChatroomTagConfig()
                    tags.tags = ["party_room"]
                    params.tagConfig = tags
                } else {
                    params.serverExtension = metadata
                }
            }

            self.client = instance
            account = identity.account
            listener = observer
            provider = linkProvider
            chatID = room
            sender = (identity.name, identity.userID)
            self.publicFeedSender = publicFeedSender
            instance.add(observer)
            instance.getChatroomService().add(observer)
            let _: Bool = try await SDKCallback.perform { completion in
                instance.enter(room, enterParams: params, success: { _ in
                    completion(.success(true))
                }, failure: { _ in completion(.failure(.rejected)) })
            }
            try check(lease)
            _ = try await KakaAccountStore.shared.remoteUserID(session: target.session)
            try check(lease)
            guard target.kind != "voice" || voiceRoom(target.session, target.serverID) == room else {
                throw KakaAccountStore.Failure.unavailable
            }
            updateConnection(true, lease: lease)
            if isPublicFeed { return }
            if let notice = try? await KakaAccountStore.shared.messagingNoticeAccount(session: target.session) {
                try check(lease)
                endRoomNotice = ChatSignIn.shared.observeRoomNotice(session: target.session, identity: identity,
                    sender: notice, roomID: target.serverID, isVoice: target.kind == "voice") { [weak self] event in
                    guard let self, self.generation == lease else { return }
                    self.onRoomNotice?(target.id, event)
                }
            }
            try check(lease)

            let history = V2NIMChatroomMessageListOption()
            if let direction = V2NIMQueryDirection(rawValue: 0) {
                history.direction = direction
                history.beginTime = 0
                history.limit = 30
                history.messageTypes = [NSNumber(value: 0)]
                instance.getChatroomService().getMessageList(history, success: { [weak observer] messages in
                    observer?.receive(messages)
                }, failure: { _ in })
            }
        } catch {
            if generation == lease { closeRoom() }
            throw error
        }
    }

    private func destination(_ visit: Visit) async throws -> String {
        let identifier: String?
        if visit.kind == "voice" {
            identifier = voiceRoom(visit.session, visit.serverID)
        } else if visit.kind == "public" {
            let data = try await KakaAccountStore.shared.call(path: "/signal/public/forum-key", body: Data("{}".utf8), session: visit.session)
            let fields = try KakaRemoteClient.object(data)
            identifier = fields["habitatTag"] as? String
                ?? KakaRemoteClient.userID(fields["habitatTag"]).map(String.init)
        } else {
            let body = try JSONSerialization.data(withJSONObject: ["habitatTag": visit.serverID])
            let data = try await KakaAccountStore.shared.call(path: "/nebula/studio/retrieve", body: body, session: visit.session)
            let detail = try KakaRemoteClient.object(data)
            let field = detail["chamberGlyph"]
            identifier = field as? String ?? KakaRemoteClient.userID(field).map(String.init)
        }
        guard let identifier, identifier.utf8.count <= 128,
              identifier.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
            throw KakaAccountStore.Failure.unavailable
        }
        return identifier
    }

    fileprivate func ingestPublicGift(_ packet: PublicGiftPacket, lease: UUID) {
        guard generation == lease, connected, let visit, visit.kind == "public", packet.room == chatID,
              packet.sender == publicFeedSender, let account,
              ChatSignIn.shared.isSignedIn(session: visit.session, account: account),
              !recentPublicGifts.contains(packet.gift.id) else { return }
        let age = Date().timeIntervalSince1970 - packet.sentAt
        guard (-5...15).contains(age) else { return }
        recentPublicGifts.append(packet.gift.id)
        if recentPublicGifts.count > 64 { recentPublicGifts.removeFirst() }
        onPublicGift?(packet.gift)
    }

    private func send(_ raw: String, visit: Visit) async throws {
        let text = try Self.publicText(raw, limit: 280)
        guard connected, let client, let sender,
              visit.kind != "voice" || voiceRoom(visit.session, visit.serverID) == chatID else {
            throw KakaAccountStore.Failure.unavailable
        }

        let lease = generation
        let message = V2NIMChatroomMessageCreator.createTextMessage(text)
        let identity: [String: Any] = ["nickname": sender.name, "userId": sender.userID]
        message.serverExtension = String(decoding: try JSONSerialization.data(withJSONObject: identity), as: UTF8.self)
        let row: ChatLine = try await SDKCallback.perform { completion in
            client.getChatroomService().send(message, params: V2NIMSendChatroomMessageParams(), success: { result in
                guard let sent = result.message, let row = ChatLine(sent) else {
                    completion(.failure(.rejected))
                    return
                }
                completion(.success(row))
            }, failure: { _ in completion(.failure(.rejected)) }, progress: nil)
        }
        _ = try await KakaAccountStore.shared.remoteUserID(session: visit.session)
        try check(lease)
        ingest([row], lease: lease)
    }

    private func expressionVisit(roomID: Int64, session: UUID, visit: UUID, seat: Int64) throws -> Visit {
        guard connected, let target = self.visit, target.kind == "voice", target.id == visit,
              target.session == session, target.serverID == roomID, let chatID, let account, let sender,
              voiceRoom(session, roomID) == chatID, ChatSignIn.shared.isSignedIn(session: session, account: account),
              verifySeat(roomID, session, sender.userID, account, seat), !Task.isCancelled else {
            throw KakaAccountStore.Failure.unavailable
        }
        return target
    }

    private func loadExpressions(_ target: Visit) async throws -> [VoiceExpressionGroup] {
        if let expressionCatalog { return expressionCatalog }
        if let expressionCatalogLoad { return try await expressionCatalogLoad.value }
        let lease = generation
        let task = Task<[VoiceExpressionGroup], Error> {
            let response = try await KakaAccountStore.shared.call(path: "/sapi/weidou/v1/client/party/room/getPartyRoomEmojis",
                body: KakaRemoteClient.json(["roomId": target.serverID]), session: target.session)
            let data = try JSONSerialization.jsonObject(with: response, options: [.fragmentsAllowed])
            guard let groups = data as? [[String: Any]] else { throw KakaAccountStore.Failure.rejected }
            return groups.prefix(24).enumerated().compactMap { index, group in
                var seen = Set<URL>()
                let choices = (group["emojisList"] as? [[String: Any]] ?? []).prefix(100).compactMap { row -> VoiceExpression? in
                    guard let artwork = RoomExpressionPacket.url(row["minImage"]),
                          let animation = RoomExpressionPacket.url(row["gifImage"]), seen.insert(animation).inserted else { return nil }
                    let label = (row["emojiName"] as? String ?? row["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    return VoiceExpression(name: String(label.prefix(56)), artwork: artwork, animation: animation)
                }
                guard !choices.isEmpty else { return nil }
                let title = (group["classType"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return VoiceExpressionGroup(id: index, name: String(title.prefix(56)), choices: choices)
            }
        }
        expressionCatalogLoad = task
        defer { if generation == lease { expressionCatalogLoad = nil } }
        let result = try await task.value
        try check(lease)
        expressionCatalog = result
        return result
    }

    fileprivate func ingestExpression(_ packet: RoomExpressionPacket, lease: UUID) async {
        guard generation == lease, let target = visit, acceptsExpression(packet, visit: target) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        recentExpressions = recentExpressions.filter { $0.value > now }
        let event = "event:\(packet.sender):\(packet.id)"
        let source = "sender:\(packet.sender)"
        guard recentExpressions.count < 96, recentExpressions[event] == nil, recentExpressions[source] == nil else { return }
        recentExpressions[event] = now + 12
        recentExpressions[source] = now + 1
        guard let userID = try? await KakaAccountStore.shared.remoteUserID(session: target.session), userID == sender?.userID,
              generation == lease, let groups = try? await loadExpressions(target), generation == lease,
              acceptsExpression(packet, visit: target),
              let choice = groups.lazy.flatMap(\.choices).first(where: { $0.animation == packet.animation && $0.artwork == packet.artwork })
        else { return }
        onRoomNotice?(target.id, .expression(choice, user: packet.userID, seat: packet.seat))
    }

    private func acceptsExpression(_ packet: RoomExpressionPacket, visit: Visit) -> Bool {
        guard connected, visit.kind == "voice", self.visit == visit, packet.room == chatID, let account,
              voiceRoom(visit.session, visit.serverID) == packet.room,
              abs(Date().timeIntervalSince1970 - packet.time) <= 12,
              ChatSignIn.shared.isSignedIn(session: visit.session, account: account),
              !ChatSignIn.shared.blockedAccounts(session: visit.session).contains(packet.sender) else { return false }
        return verifySeat(visit.serverID, visit.session, packet.userID, packet.sender, packet.seat)
    }

    private func check(_ lease: UUID) throws {
        guard generation == lease, !Task.isCancelled else { throw KakaAccountStore.Failure.unavailable }
    }

    fileprivate func ingest(_ values: [ChatLine], lease: UUID) {
        guard generation == lease, let chatID, let account else { return }
        var indexed = Dictionary(uniqueKeysWithValues: transcript.map { ($0.id, $0) })
        for var row in values where row.room == chatID {
            row.own = row.author == account
            indexed[row.id] = row
        }
        let ordered = indexed.values.sorted { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }
        let result = Array(ordered.suffix(50))
        if result != transcript {
            transcript = result
            revision += 1
        }
    }

    fileprivate func updateConnection(_ value: Bool, lease: UUID) {
        guard generation == lease, connected != value else { return }
        connected = value
        revision += 1
    }

    fileprivate func endVisit(_ lease: UUID) {
        if generation == lease { closeRoom() }
    }
    #endif
}

#if canImport(NIMSDK)
fileprivate struct ChatLine: Encodable, Equatable, Sendable {
    let room: String
    let author: String
    let id: String
    let name: String
    let text: String
    let timestamp: Double
    var own = false

    private enum CodingKeys: String, CodingKey { case id, name, text, timestamp, own }

    init?(_ message: V2NIMChatroomMessage) {
        guard message.messageType.rawValue == 0, let room = message.roomId, let author = message.senderId,
              let id = message.messageClientId, !id.isEmpty, id.utf8.count <= 128,
              let value = message.text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              message.createTime.isFinite else { return nil }
        self.room = room
        self.author = author
        self.id = id
        let nickname = message.userInfoConfig?.senderNick?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        name = nickname.isEmpty ? "Listener" : String(nickname.prefix(48))
        text = String(value.prefix(280))
        timestamp = message.createTime
    }
}

private final class RoomLinks: NSObject, V2NIMChatroomLinkProvider {
    private let urls: [String]

    init(_ urls: [String]) { self.urls = urls }

    func getLinkAddress(_ roomId: String, accountId: String) -> [String]? { urls }
}

fileprivate struct PublicGiftPacket: Sendable {
    let room: String
    let sender: String
    let sentAt: TimeInterval
    let gift: KakaRoomChat.PublicGift

    init?(_ message: V2NIMChatroomMessage) {
        guard let room = message.roomId, let sender = message.senderId,
              let id = message.messageClientId, !id.isEmpty, id.utf8.count <= 128,
              message.createTime.isFinite else { return nil }
        let values = [message.attachment?.raw, message.serverExtension, message.text].compactMap { $0 }
        let fields = values.lazy.filter { $0.utf8.count <= 4096 }.compactMap {
            try? KakaRemoteClient.object(Data($0.utf8))
        }.first { KakaRemoteClient.userID($0["attachType"]) != nil }
        guard let fields, let type = KakaRemoteClient.userID(fields["attachType"]),
              [50, 66, 80, 88, 89, 1004, 1007].contains(type) else { return nil }
        let data = fields["data"] as? [String: Any] ?? (fields["data"] as? String).flatMap {
            try? KakaRemoteClient.object(Data($0.utf8))
        } ?? fields
        let name = KakaRoomFields.text(data, "giftName", "giftLabel")
        let rawArt = KakaRoomFields.text(data, "giftImg")
        let art = rawArt.utf8.count <= 1024 ? KakaRoomFields.url(rawArt) : nil
        guard !name.isEmpty || art != nil else { return nil }
        self.room = room
        self.sender = sender
        sentAt = message.createTime > 100_000_000_000 ? message.createTime / 1_000 : message.createTime
        gift = KakaRoomChat.PublicGift(id: id, label: name.isEmpty ? "A gift was sent" : "Gift sent · \(name.prefix(72))", artwork: art)
    }
}

fileprivate struct RoomExpressionPacket: Sendable {
    let room: String
    let id: String
    let sender: String
    let userID: Int64
    let seat: Int64
    let artwork: URL
    let animation: URL
    let time: TimeInterval

    init?(_ message: V2NIMChatroomMessage) {
        guard message.messageType.rawValue == 100,
              let room = message.roomId, !room.isEmpty, room.utf8.count <= 128,
              let id = message.messageClientId, !id.isEmpty, id.utf8.count <= 128,
              let sender = message.senderId, !sender.isEmpty, sender.utf8.count <= 128,
              let raw = message.attachment?.raw, raw.utf8.count <= 4096,
              let fields = try? KakaRemoteClient.object(Data(raw.utf8)), KakaRemoteClient.userID(fields["attachType"]) == -10,
              let data = fields["data"] as? [String: Any], let user = KakaRemoteClient.userID(data["sendUserId"]), user > 0,
              let seat = KakaRemoteClient.userID(data["seatIndex"]), seat > 0,
              let artwork = Self.url(data["minImage"]), let animation = Self.url(data["playUrl"]),
              message.createTime.isFinite else { return nil }
        self.room = room
        self.id = id
        self.sender = sender
        self.userID = user
        self.seat = seat
        self.artwork = artwork
        self.animation = animation
        time = message.createTime
    }

    static func url(_ raw: Any?) -> URL? {
        guard let text = raw as? String, text.utf8.count <= 1536, let url = URL(string: text),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil else { return nil }
        return url
    }
}

private final class RoomListener: NSObject, V2NIMChatroomClientListener, V2NIMChatroomListener {
    private weak var owner: KakaRoomChat?
    private let generation: UUID
    private let isPublicFeed: Bool

    init(owner: KakaRoomChat, generation: UUID, isPublicFeed: Bool) {
        self.owner = owner
        self.generation = generation
        self.isPublicFeed = isPublicFeed
    }

    func receive(_ messages: [V2NIMChatroomMessage]) {
        let lines = messages.suffix(80).compactMap(ChatLine.init)
        let lease = generation
        Task { @MainActor [weak owner] in owner?.ingest(lines, lease: lease) }
    }

    func onReceiveMessages(_ messages: [Any]) {
        let live = messages.suffix(80).compactMap { $0 as? V2NIMChatroomMessage }
        let lease = generation
        if isPublicFeed {
            let gifts = live.suffix(20).compactMap(PublicGiftPacket.init)
            guard !gifts.isEmpty else { return }
            Task { @MainActor [weak owner] in
                for gift in gifts { owner?.ingestPublicGift(gift, lease: lease) }
            }
            return
        }
        receive(live)
        let expressions = live.suffix(20).compactMap(RoomExpressionPacket.init)
        guard !expressions.isEmpty else { return }
        Task { @MainActor [weak owner] in
            for expression in expressions { await owner?.ingestExpression(expression, lease: lease) }
        }
    }

    func onChatroomStatus(_ status: V2NIMChatroomStatus, error: V2NIMError?) {
        let entered = status.rawValue == 5
        let lease = generation
        Task { @MainActor [weak owner] in owner?.updateConnection(entered, lease: lease) }
    }

    func onChatroomKicked(_ info: V2NIMChatroomKickedInfo) {
        let lease = generation
        Task { @MainActor [weak owner] in owner?.endVisit(lease) }
    }
}

/// SDK callbacks may finish off-main, arrive after logout, or fail to arrive when offline.
@MainActor
private final class SDKCallback<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var deadline: Task<Void, Never>?

    private init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    static func perform(_ start: (@escaping @Sendable (Result<Value, KakaAccountStore.Failure>) -> Void) -> Void) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let callback = SDKCallback(continuation)
            callback.deadline = Task {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                if !Task.isCancelled { callback.finish(.failure(.network)) }
            }
            start { result in Task { @MainActor in callback.finish(result) } }
        }
    }

    private func finish(_ result: Result<Value, KakaAccountStore.Failure>) {
        guard let continuation else { return }
        self.continuation = nil
        deadline?.cancel()
        deadline = nil
        continuation.resume(with: result.mapError { $0 as Error })
    }
}

private final class CallNotificationListener: NSObject, V2NIMNotificationListener {
    struct Notice: Sendable {
        let sender: String
        let recipient: String?
        let timestamp: TimeInterval
        let content: String

        func isCurrent(recipient account: String, since: TimeInterval) -> Bool {
            let seconds = timestamp > 100_000_000_000 ? timestamp / 1000 : timestamp
            return (recipient == nil || recipient == account) && seconds.isFinite
                && seconds >= since - 1 && seconds <= Date().timeIntervalSince1970 + 5
        }
    }

    private let accept: @Sendable (Notice) -> Void

    init(accept: @escaping @Sendable (Notice) -> Void) { self.accept = accept }

    nonisolated func onReceive(_ notifications: [V2NIMCustomNotification]) {
        for message in notifications where message.conversationType.rawValue == 1 {
            guard let sender = message.senderId, let content = message.content,
                  content.utf8.count <= 4096 else { continue }
            accept(Notice(sender: sender, recipient: message.receiverId, timestamp: message.timestamp, content: content))
        }
    }

    nonisolated func onReceive(_ notifications: [V2NIMBroadcastNotification]) {}
}

@MainActor
private final class ChatSignIn {
    static let shared = ChatSignIn()
    private var appKey: String?
    private var owner: UUID?
    private var pending: (session: UUID, attempt: UUID, task: Task<Bool, Error>)?
    private var blocked: Set<String> = []
    private(set) var blockRevision = 0
    private var callNotificationListener: CallNotificationListener?
    private var rechargeObserver: RechargeObserver?
    private var callTextObserver: CallTextObserver?
    private var roomNoticeObserver: RoomNoticeObserver?

    private struct RoomNoticeObserver {
        let id = UUID()
        let session: UUID
        let account: String
        let userID: Int64
        let sender: String
        let roomID: Int64
        let isVoice: Bool
        let since: TimeInterval
        let receive: @MainActor (KakaRoomChat.RoomNotice) -> Void
    }

    private struct RechargeObserver {
        let id = UUID()
        let session: UUID
        let recipient: String
        let sender: String
        let channel: String
        let since: TimeInterval
        let onRecharge: @MainActor () -> Void
    }

    private struct CallTextObserver {
        let id = UUID()
        let session: UUID
        let recipient: String
        let sender: String
        let peerID: Int64
        let channel: String
        let since: TimeInterval
        let onText: @MainActor (String) -> Void
    }

    func prepare(session: UUID, identity: KakaAccountStore.RoomMessagingIdentity) async throws {
        let sdk = NIMSDK.shared()
        if appKey == nil {
            let settings = NIMSDKOption(appKey: identity.appKey)
            settings.v2 = true
            let conversations = V2NIMSDKOption()
            conversations.enableV2CloudConversation = true
            sdk.register(withOptionV2: settings, v2Option: conversations)
            appKey = identity.appKey
        }
        guard appKey == identity.appKey else { throw KakaAccountStore.Failure.unavailable }
        if isSignedIn(session: session, account: identity.account) { return }
        if let owner, owner != session { await end(owner) }
        let operation: (session: UUID, attempt: UUID, task: Task<Bool, Error>)
        if let pending, pending.session == session {
            operation = pending
        } else {
            let task = Task {
                try await SDKCallback<Bool>.perform { completion in
                    sdk.v2LoginService.login(identity.account, token: identity.token, option: nil,
                                             success: { completion(.success(true)) },
                                             failure: { _ in completion(.failure(.rejected)) })
                }
            }
            operation = (session, UUID(), task)
            pending = operation
            owner = session
        }
        defer { if pending?.attempt == operation.attempt { pending = nil } }
        _ = try await operation.task.value
        guard owner == session, sdk.v2LoginService.getLoginUser() == identity.account else {
            throw KakaAccountStore.Failure.unavailable
        }
    }

    func isSignedIn(session: UUID, account: String) -> Bool {
        let login = NIMSDK.shared().v2LoginService
        return owner == session && login.getLoginUser() == account && login.getLoginStatus().rawValue == 1
    }

    func end(_ session: UUID) async {
        guard owner == session else { return }
        owner = nil
        if rechargeObserver?.session == session { rechargeObserver = nil }
        if callTextObserver?.session == session { callTextObserver = nil }
        if roomNoticeObserver?.session == session { roomNoticeObserver = nil }
        replaceBlocks([])
        pending?.task.cancel()
        pending = nil
        let sdk = NIMSDK.shared()
        let _: Bool? = try? await SDKCallback.perform { completion in
            sdk.v2LoginService.logout({ completion(.success(true)) }, failure: { _ in completion(.failure(.rejected)) })
        }
    }

    func observeRecharge(session: UUID, recipient: String, sender: String, channel: String, since: Date,
                         onRecharge: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        installCallNotificationListener()
        let observer = RechargeObserver(session: session, recipient: recipient, sender: sender, channel: channel,
                                        since: since.timeIntervalSince1970, onRecharge: onRecharge)
        rechargeObserver = observer
        let id = observer.id
        return { [weak self] in
            if self?.rechargeObserver?.id == id { self?.rechargeObserver = nil }
        }
    }

    func observeCallText(session: UUID, recipient: String, sender: String, peerID: Int64, channel: String, since: Date,
                         onText: @escaping @MainActor (String) -> Void) -> @MainActor () -> Void {
        installCallNotificationListener()
        let observer = CallTextObserver(session: session, recipient: recipient, sender: sender, peerID: peerID,
                                        channel: channel, since: since.timeIntervalSince1970, onText: onText)
        callTextObserver = observer
        let id = observer.id
        return { [weak self] in
            if self?.callTextObserver?.id == id { self?.callTextObserver = nil }
        }
    }

    func ownsCallText(session: UUID, recipient: String, sender: String, peerID: Int64, channel: String) -> Bool {
        guard let observer = callTextObserver else { return false }
        return observer.session == session && observer.recipient == recipient && observer.sender == sender
            && observer.peerID == peerID && observer.channel == channel && !blocked.contains(sender)
            && isSignedIn(session: session, account: recipient)
    }

    func observeRoomNotice(session: UUID, identity: KakaAccountStore.RoomMessagingIdentity, sender: String,
                           roomID: Int64, isVoice: Bool,
                           receive: @escaping @MainActor (KakaRoomChat.RoomNotice) -> Void) -> @MainActor () -> Void {
        installCallNotificationListener()
        let observer = RoomNoticeObserver(session: session, account: identity.account, userID: identity.userID,
                                          sender: sender, roomID: roomID, isVoice: isVoice,
                                          since: Date().timeIntervalSince1970, receive: receive)
        roomNoticeObserver = observer
        let id = observer.id
        return { [weak self] in
            if self?.roomNoticeObserver?.id == id { self?.roomNoticeObserver = nil }
        }
    }

    private func installCallNotificationListener() {
        guard callNotificationListener == nil else { return }
        let listener = CallNotificationListener { [weak self] message in
            Task { @MainActor [weak self] in self?.receiveCallNotification(message) }
        }
        callNotificationListener = listener
        NIMSDK.shared().v2NotificationService.addNoticationListener(listener)
    }

    private func receiveCallNotification(_ message: CallNotificationListener.Notice) {
        guard rechargeObserver != nil || callTextObserver != nil || roomNoticeObserver != nil,
              let document = try? KakaRemoteClient.object(Data(message.content.utf8)) else { return }
        let data = document["data"] as? [String: Any] ?? (document["data"] as? String).flatMap {
            try? KakaRemoteClient.object(Data($0.utf8))
        } ?? document
        guard let type = KakaRemoteClient.userID(document["attachType"]) else { return }
        switch type {
        case 6: receiveRecharge(message, document: document, data: data)
        case -1: receiveCallText(message, document: document, data: data)
        case 50, 66, 80, 88, 89, 1003, 1004, 1007, 1009: receiveRoomNotice(message, data: data, type: type)
        default: break
        }
    }

    private func receiveRoomNotice(_ message: CallNotificationListener.Notice, data: [String: Any], type: Int64) {
        guard let observer = roomNoticeObserver, message.sender == observer.sender,
              isSignedIn(session: observer.session, account: observer.account),
              message.isCurrent(recipient: observer.account, since: observer.since) else { return }
        let roomIDs = ["roomId", "partyRoomId", "habitatTag"].compactMap { KakaRemoteClient.userID(data[$0]) }.filter { $0 > 0 }
        guard !roomIDs.isEmpty, roomIDs.allSatisfy({ $0 == observer.roomID }) else { return }
        if type == 1003 || type == 1009 {
            guard observer.isVoice, type != 1003 || KakaRemoteClient.userID(data["userId"]) == observer.userID else { return }
            roomNoticeObserver = nil
            observer.receive(.voiceClosed(type == 1003 ? "You were removed from this room." : "This voice room has ended."))
            return
        }
        let name = KakaRoomFields.text(data, "giftName", "giftLabel")
        let rawArt = KakaRoomFields.text(data, "giftImg")
        let art = rawArt.utf8.count <= 1024 ? KakaRoomFields.url(rawArt) : nil
        guard !name.isEmpty || art != nil else { return }
        let label = name.isEmpty ? "A gift was sent" : "Gift sent · \(name.prefix(72))"
        observer.receive(.gift(label: label, artwork: art, time: message.timestamp))
    }

    private func receiveRecharge(_ message: CallNotificationListener.Notice, document: [String: Any], data: [String: Any]) {
        guard let observer = rechargeObserver, isSignedIn(session: observer.session, account: observer.recipient),
              message.sender == observer.sender, message.isCurrent(recipient: observer.recipient, since: observer.since),
              matchesCallChannel(observer.channel, document: document, data: data) else { return }
        observer.onRecharge()
    }

    private func receiveCallText(_ message: CallNotificationListener.Notice, document: [String: Any], data: [String: Any]) {
        guard let observer = callTextObserver,
              ownsCallText(session: observer.session, recipient: observer.recipient, sender: message.sender,
                           peerID: observer.peerID, channel: observer.channel),
              message.isCurrent(recipient: observer.recipient, since: observer.since),
              matchesCallChannel(observer.channel, document: document, data: data),
              let raw = (data["content"] ?? data["text"]) as? String,
              let text = try? KakaRoomChat.publicText(raw, limit: 280) else { return }
        if let ext = (data["ext"] ?? document["ext"]) as? [String: Any], let userID = ext["userId"],
           KakaRemoteClient.userID(userID) != observer.peerID { return }
        observer.onText(text)
    }

    private func matchesCallChannel(_ channel: String, document: [String: Any], data: [String: Any]) -> Bool {
        // Legacy notifications omit the channel and only reach the current, authenticated observer.
        for fields in [document, data] {
            for key in ["channelId", "venueKey"] {
                if let raw = fields[key], !(raw is NSNull) {
                    guard let value = raw as? String, value.isEmpty || value == channel else { return false }
                }
            }
        }
        return true
    }

    func blockedAccounts(session: UUID) -> Set<String> { owner == session ? blocked : [] }

    func refreshBlocks(session: UUID) async throws {
        guard owner == session else { throw KakaAccountStore.Failure.unavailable }
        let observed = blockRevision
        let accounts: [String] = try await SDKCallback.perform { completion in
            NIMSDK.shared().v2UserService.getBlockList({ completion(.success($0)) },
                                                       failure: { _ in completion(.failure(.rejected)) })
        }
        guard owner == session else { throw KakaAccountStore.Failure.unavailable }
        if observed == blockRevision { replaceBlocks(Set(accounts)) }
    }

    func setBlocked(_ account: String, blocked value: Bool, session: UUID) async throws {
        guard owner == session else { throw KakaAccountStore.Failure.unavailable }
        let _: Bool = try await SDKCallback.perform { completion in
            let service = NIMSDK.shared().v2UserService
            if value {
                service.addUser(toBlockList: account, success: { completion(.success(true)) },
                                failure: { _ in completion(.failure(.rejected)) })
            } else {
                service.removeUser(fromBlockList: account, success: { completion(.success(true)) },
                                   failure: { _ in completion(.failure(.rejected)) })
            }
        }
        guard owner == session else { throw KakaAccountStore.Failure.unavailable }
        replaceBlocks(value ? blocked.union([account]) : blocked.subtracting([account]))
    }

    private func replaceBlocks(_ values: Set<String>) {
        guard values != blocked else { return }
        blocked = values
        blockRevision += 1
    }
}
#endif
