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

    private let voiceRoom: (UUID, Int64) -> String?

    init(voiceRoom: @escaping (UUID, Int64) -> String?) {
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

    private struct Snapshot: Encodable {
        let connected: Bool
        let revision: Int
        let messages: [ChatLine]
    }
    #endif

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

    func close() {
        #if canImport(NIMSDK)
        closeRoom()
        closeDirect()
        #endif
    }

    #if canImport(NIMSDK)
    private func closeRoom() {
        generation = UUID()
        visit = nil
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

        init?(_ source: V2NIMMessage, membership: Membership) {
            guard source.messageType.rawValue == 0, source.conversationId == membership.conversation,
                  let from = source.senderId, let to = source.receiverId,
                  let key = source.messageClientId, !key.isEmpty, key.utf8.count <= 128,
                  let value = source.text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
                  source.createTime.isFinite else { return nil }
            own = from == membership.viewer && to == membership.account
            if own {
                guard source.sendingState.rawValue == 1, source.messageStatus.errorCode == 0 else { return nil }
            } else {
                guard from == membership.account, to == membership.viewer else { return nil }
            }
            id = key
            name = own ? "You" : membership.nickname
            text = String(value.prefix(500))
            timestamp = source.createTime
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
            history.messageTypes = [NSNumber(value: 0)]
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

    private static func publicText(_ raw: String, limit: Int) throws -> String {
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

    private func enter(_ target: Visit) async throws {
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
            let observer = RoomListener(owner: self, generation: lease)
            let linkProvider = RoomLinks(links)
            let params = V2NIMChatroomEnterParams()
            params.accountId = identity.account
            params.token = identity.token
            params.roomNick = identity.name
            params.linkProvider = linkProvider
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

            self.client = instance
            account = identity.account
            listener = observer
            provider = linkProvider
            chatID = room
            sender = (identity.name, identity.userID)
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

private final class RoomListener: NSObject, V2NIMChatroomClientListener, V2NIMChatroomListener {
    private weak var owner: KakaRoomChat?
    private let generation: UUID

    init(owner: KakaRoomChat, generation: UUID) {
        self.owner = owner
        self.generation = generation
    }

    func receive(_ messages: [V2NIMChatroomMessage]) {
        let lines = messages.suffix(80).compactMap(ChatLine.init)
        let lease = generation
        Task { @MainActor [weak owner] in owner?.ingest(lines, lease: lease) }
    }

    func onReceiveMessages(_ messages: [Any]) {
        receive(messages.suffix(80).compactMap { $0 as? V2NIMChatroomMessage })
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

@MainActor
private final class ChatSignIn {
    static let shared = ChatSignIn()
    private var appKey: String?
    private var owner: UUID?
    private var pending: (session: UUID, attempt: UUID, task: Task<Bool, Error>)?
    private var blocked: Set<String> = []
    private(set) var blockRevision = 0

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
        replaceBlocks([])
        pending?.task.cancel()
        pending = nil
        let sdk = NIMSDK.shared()
        let _: Bool? = try? await SDKCallback.perform { completion in
            sdk.v2LoginService.logout({ completion(.success(true)) }, failure: { _ in completion(.failure(.rejected)) })
        }
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
