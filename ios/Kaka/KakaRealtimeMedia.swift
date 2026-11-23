import UIKit
import AVFoundation
import Combine

#if canImport(AgoraRtcKit)
@preconcurrency import AgoraRtcKit
#endif

@MainActor
final class KakaRealtimeMedia: ObservableObject {
    enum Failure: String, Error {
        case unavailable = "media-unavailable"
        case invalidRoom = "media-invalid-room"
        case busy = "media-busy"
        case connection = "media-connection"
        case timeout = "media-timeout"
        case cancelled = "media-cancelled"
        case permission = "media-permission"
        case seat = "media-seat"
        case heartbeat = "media-heartbeat"
    }

    let videoView = UIView()
    @Published private(set) var hasReceivedLiveFrame = false

    struct VoiceStageSeat: Identifiable {
        let index: Int64
        let occupant: Int64?
        let name: String
        let portrait: URL?
        let locked: Bool
        let microphoneEnabled: Bool?

        var id: Int64 { index }
    }

    #if canImport(AgoraRtcKit)
    private enum Mode: String {
        case live, voice
    }

    private struct VoiceExit {
        let session: UUID
        let roomID: Int64
        let seat: Int64
        let messagingRoom: String
    }

    private struct Admission {
        let mode: Mode
        let roomID: Int64
        let session: UUID
        let channel: String
        let credential: String
        let listener: UInt
        let host: UInt?
    }

    private struct Seat {
        let index: Int64
        let user: Int64
        let locked: Bool
        let permitted: Bool
        let microphone: Bool
        let template: Int64
        let name: String
        let portrait: URL?
        let microphoneEnabled: Bool?
    }

    private static weak var engineOwner: KakaRealtimeMedia?
    private var lease = UUID()
    private var joining = false
    private var releasing = false
    private var pendingExit: VoiceExit?
    private var admission: Admission?
    private var engine: AgoraRtcEngineKit?
    private var callbacks: EventReceiver?
    private var joinReply: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?
    private var renewal: Task<Void, Never>?
    private var presence: Task<Void, Never>?
    private var seatWatch: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var presenceReady = false
    private var seatAction: UUID?
    private var seatWrite: (id: UUID, task: Task<Void, Error>)?
    private var ownedSeat: Seat?
    private var voiceStageSeats: [VoiceStageSeat] = []
    private var microphone = false
    private var publicationRequested = false
    private var roomTemplate: Int64 = 0
    private var voiceUser: Int64 = 0
    private var voiceMessagingRoom = ""
    private var publishReply: CheckedContinuation<Void, Error>?
    private var publishTimeout: Task<Void, Never>?
    private var frame: CGRect?
    private var connected = false
    #endif

    init() {
        videoView.backgroundColor = .black
        videoView.clipsToBounds = true
        videoView.isUserInteractionEnabled = false
        videoView.accessibilityElementsHidden = true
        videoView.isHidden = true
    }

    func setVideoFrame(_ frame: CGRect?) {
        #if canImport(AgoraRtcKit)
        self.frame = frame
        updateVideoVisibility()
        #endif
    }

    func chatroomID(session: UUID, serverID: Int64) -> String? {
        #if canImport(AgoraRtcKit)
        guard connected, admission?.mode == .voice, admission?.session == session,
              admission?.roomID == serverID, let room = pendingExit?.messagingRoom, !room.isEmpty else { return nil }
        return room
        #else
        return nil
        #endif
    }

    func isLiveAudience(roomID: Int64, session: UUID, hostID: Int64?, channel: String?) -> Bool {
        #if canImport(AgoraRtcKit)
        guard connected, engine != nil, let admission, admission.mode == .live,
              admission.roomID == roomID, admission.session == session else { return false }
        if let hostID {
            guard let expectedHost = UInt(exactly: hostID), expectedHost > 0,
                  admission.host == expectedHost else { return false }
        }
        if let channel, channel != admission.channel { return false }
        return true
        #else
        return false
        #endif
    }

    func join(kind: String, roomID: Int64, password: String?, session: UUID) async throws {
        #if canImport(AgoraRtcKit)
        guard let mode = Mode(rawValue: kind), roomID > 0,
              (password?.utf8.count ?? 0) <= 128 else { throw Failure.invalidRoom }
        guard !joining, !releasing, engine == nil,
              Self.engineOwner == nil || Self.engineOwner === self else { throw Failure.busy }
        Self.engineOwner = self
        joining = true
        let attempt = UUID()
        lease = attempt
        defer {
            joining = false
            releaseOwnershipIfIdle()
        }
        do {
            try await settlePreviousRoom(for: session)
            try verify(attempt)
            let appID = try await KakaAccountStore.shared.rtcAppID(session: session)
            guard !appID.isEmpty else { throw Failure.unavailable }
            let authorization = try await admit(mode, roomID: roomID, password: password, session: session, attempt: attempt)
            try verify(attempt)
            admission = authorization
            let receiver = EventReceiver { [weak self] event in
                Task { @MainActor [weak self] in self?.consume(event, attempt: attempt) }
            }
            callbacks = receiver
            let rtc = AgoraRtcEngineKit.sharedEngine(withAppId: appID, delegate: receiver)
            engine = rtc
            rtc.setAudioSessionOperationRestriction(.configureSession)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            rtc.enableAudio()
            rtc.enableLocalAudio(false)
            if mode == .live {
                rtc.enableVideo()
                rtc.enableLocalVideo(false)
                try attachHost(to: rtc, host: authorization.host)
            } else {
                rtc.disableVideo()
            }
            rtc.setChannelProfile(.liveBroadcasting)
            let options = AgoraRtcChannelMediaOptions()
            options.clientRoleType = .audience
            options.publishCameraTrack = false
            options.publishMicrophoneTrack = false
            options.autoSubscribeAudio = true
            options.autoSubscribeVideo = mode == .live

            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
                    joinReply = reply
                    let result = rtc.joinChannel(byToken: authorization.credential, channelId: authorization.channel,
                                                 uid: authorization.listener, mediaOptions: options, joinSuccess: nil)
                    guard result == 0 else { finishJoin(.failure(Failure.connection)); return }
                    timeout = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 16_000_000_000)
                        guard !Task.isCancelled, let self, self.lease == attempt else { return }
                        self.finishJoin(.failure(Failure.timeout))
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard let self, self.lease == attempt else { return }
                    self.finishJoin(.failure(Failure.cancelled))
                }
            }
            try verify(attempt)
            if mode == .voice {
                beginVoicePresence(authorization, attempt: attempt)
                monitorSeats(authorization, attempt: attempt)
            }
        } catch {
            await leave()
            throw error
        }
        #else
        throw Failure.unavailable
        #endif
    }

    func leave() async {
        setVideoFrame(nil)
        #if canImport(AgoraRtcKit)
        let departedRoom = admission
        let departedUser = voiceUser
        let outstandingWrite = seatWrite?.task
        stopVoicePresence()
        stopPublishing()
        lease = UUID()
        finishJoin(.failure(Failure.cancelled))
        renewal?.cancel()
        renewal = nil
        if hasReceivedLiveFrame { hasReceivedLiveFrame = false }
        connected = false
        admission = nil
        ownedSeat = nil
        voiceStageSeats = []
        voiceUser = 0
        roomTemplate = 0
        voiceMessagingRoom = ""
        seatAction = nil
        guard !releasing else { return }
        releasing = true
        defer {
            releasing = false
            releaseOwnershipIfIdle()
        }
        if let rtc = engine {
            engine = nil
            callbacks = nil
            rtc.leaveChannel(nil)
            await Task.detached(priority: .utility) {
                AgoraRtcEngineKit.destroy()
            }.value
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        if let outstandingWrite, let departedRoom, departedRoom.mode == .voice {
            // A seat change already sent to the server may complete after the user leaves.
            // Settle that write before reporting the final seat in the exit.
            try? await outstandingWrite.value
            if let result = try? await party("seat/list", fields: ["roomId": departedRoom.roomID], admission: departedRoom),
               let exit = pendingExit, exit.roomID == departedRoom.roomID, exit.session == departedRoom.session {
                let occupied = seatRows(result).compactMap(asSeat).first { $0.user == departedUser }
                pendingExit = VoiceExit(session: exit.session, roomID: exit.roomID, seat: occupied?.index ?? -1,
                                        messagingRoom: exit.messagingRoom)
            }
        }
        if let exit = pendingExit {
            try? await settlePreviousRoom(for: exit.session)
        }
        #endif
    }

    func voiceSeat(operation: String, roomID: Int64, enabled: Bool?, requestedSeat: Int64? = nil,
                   session: UUID) async throws -> [String: Any] {
        #if canImport(AgoraRtcKit)
        guard connected, let admission, admission.mode == .voice, admission.roomID == roomID,
              admission.session == session, !voiceMessagingRoom.isEmpty else { throw Failure.invalidRoom }
        guard seatAction == nil else { throw Failure.busy }
        let action = UUID()
        seatAction = action
        defer { if seatAction == action { seatAction = nil } }
        let attempt = lease
        let rows = try await refreshSeats(admission, attempt: attempt)
        switch operation {
        case "voiceSeat.status":
            return try await seatStatus(admission, attempt: attempt)
        case "voiceSeat.take":
            guard presenceReady else { throw Failure.heartbeat }
            if ownedSeat == nil {
                if try await waitingForSeat(admission, attempt: attempt) { return seatPayload(queued: true) }
                guard let open = rows.first(where: {
                    $0.user == 0 && !$0.locked && (requestedSeat == nil || $0.index == requestedSeat)
                }) else { throw Failure.seat }
                try await changeSeat("onSeat", seat: open.index, admission: admission, attempt: attempt)
                _ = try await refreshSeats(admission, attempt: attempt)
            }
            let status = try await seatStatus(admission, attempt: attempt)
            guard ownedSeat != nil || (status["queued"] as? Bool) == true else { throw Failure.seat }
            return status
        case "voiceSeat.leave":
            guard let ownedSeat else { return try await seatStatus(admission, attempt: attempt) }
            stopPublishing()
            try await changeSeat("downSeat", seat: ownedSeat.index, admission: admission, attempt: attempt)
            _ = try await refreshSeats(admission, attempt: attempt)
            guard self.ownedSeat == nil else { throw Failure.seat }
            return seatPayload()
        case "voiceSeat.microphone":
            guard let enabled, let seat = ownedSeat else { throw Failure.seat }
            if enabled {
                guard presenceReady else { throw Failure.heartbeat }
                guard seat.permitted else { throw Failure.seat }
                guard await AVCaptureDevice.requestAccess(for: .audio) else { throw Failure.permission }
                try verify(attempt)
                guard presenceReady else { throw Failure.heartbeat }
            } else {
                stopPublishing()
            }
            try await changeSeat("updateMedia", seat: seat.index, extra: ["type": 1, "enable": enabled ? 1 : 0],
                                 admission: admission, attempt: attempt)
            if enabled {
                do {
                    _ = try await refreshSeats(admission, attempt: attempt)
                    guard presenceReady, ownedSeat?.index == seat.index, ownedSeat?.permitted == true,
                          ownedSeat?.microphone == true else { throw Failure.seat }
                    try await startPublishing(attempt: attempt)
                } catch {
                    if lease == attempt {
                        stopPublishing()
                        try? await changeSeat("updateMedia", seat: seat.index, extra: ["type": 1, "enable": 0],
                                              admission: admission, attempt: attempt)
                    }
                    throw error
                }
            } else {
                _ = try await refreshSeats(admission, attempt: attempt)
            }
            return seatPayload()
        default:
            throw Failure.seat
        }
        #else
        throw Failure.unavailable
        #endif
    }

    #if canImport(AgoraRtcKit)
    private func releaseOwnershipIfIdle() {
        if Self.engineOwner === self, !joining, !releasing, engine == nil {
            Self.engineOwner = nil
        }
    }

    private func verify(_ attempt: UUID) throws {
        guard attempt == lease, !Task.isCancelled else { throw Failure.cancelled }
    }

    private func document(_ path: String, fields: [String: Any], session: UUID) async throws -> Any {
        let body = try JSONSerialization.data(withJSONObject: fields)
        let bytes = try await KakaAccountStore.shared.call(path: path, body: body, session: session)
        return try JSONSerialization.jsonObject(with: bytes, options: .fragmentsAllowed)
    }

    private func service(_ path: String, fields: [String: Any] = [:], session: UUID) async throws -> [String: Any] {
        try await document(path, fields: fields, session: session) as? [String: Any] ?? [:]
    }

    private func text(_ object: [String: Any], _ keys: String...) -> String {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty { return value }
            if let value = object[key] as? NSNumber { return value.stringValue }
        }
        return ""
    }

    private func identifier(_ value: String) -> UInt? {
        guard let result = UInt32(value), result > 0 else { return nil }
        return UInt(result)
    }

    private func admit(_ mode: Mode, roomID: Int64, password: String?, session: UUID, attempt: UUID) async throws -> Admission {
        switch mode {
        case .live:
            let result = try await service("/nebula/studio/retrieve", fields: ["habitatTag": roomID], session: session)
            try verify(attempt)
            let room = (result["venueBrief"] as? [String: Any]).flatMap {
                Int64(text($0, "habitatTag", "orbitMark")) == roomID ? $0 : nil
            } ?? result
            guard Int64(text(room, "habitatTag", "orbitMark")) == roomID else { throw Failure.invalidRoom }
            let profile = (room["anchor"] as? [String: Any]) ?? (room["anchorInfo"] as? [String: Any]) ?? room
            let host = identifier(text(profile, "voyagerBadge", "orbitMark")) ?? identifier(text(room, "voyagerBadge"))
            let channel = text(room, "studioRoute", "venueKey")
            guard let host, !channel.isEmpty else { throw Failure.invalidRoom }
            let token = try await service("/nebula/relay/passcode", fields: ["habitatTag": roomID], session: session)
            let issuedChannel = text(token, "venueKey")
            let credential = text(token, "relayPass")
            guard let listener = identifier(text(token, "starBadge")), listener != host, !credential.isEmpty,
                  issuedChannel.isEmpty || issuedChannel == channel else { throw Failure.invalidRoom }
            return Admission(mode: mode, roomID: roomID, session: session, channel: channel,
                             credential: credential, listener: listener, host: host)
        case .voice:
            let userID = try await KakaAccountStore.shared.remoteUserID(session: session)
            var fields: [String: Any] = ["roomId": roomID, "openPath": "card"]
            if let password, !password.isEmpty { fields["password"] = password }
            let room = try await service("/sapi/weidou/v1/client/party/room/enter", fields: fields, session: session)
            pendingExit = VoiceExit(session: session, roomID: roomID, seat: Int64(text(room, "inPartyRole")) ?? -1,
                                    messagingRoom: text(room, "yxRoomId"))
            try verify(attempt)
            voiceUser = userID
            roomTemplate = Int64(text(room, "roomTempId")) ?? 0
            voiceMessagingRoom = text(room, "yxRoomId")
            let channel = text(room, "agoraChannelId")
            guard text(room, "roomStatus") != "2", !channel.isEmpty else { throw Failure.invalidRoom }
            let token = try await service("/nebula/relay/identity-pass", session: session)
            let credential = text(token, "relayPass")
            let requestedID = text(token, "starBadge")
            guard let listener = identifier(requestedID.isEmpty ? String(userID) : requestedID), !credential.isEmpty else {
                throw Failure.invalidRoom
            }
            return Admission(mode: mode, roomID: roomID, session: session, channel: channel,
                             credential: credential, listener: listener, host: nil)
        }
    }

    private func settlePreviousRoom(for session: UUID) async throws {
        guard let exit = pendingExit else { return }
        if exit.session == session {
            _ = try await service("/sapi/weidou/v1/client/party/room/exitRoom",
                                  fields: ["roomId": exit.roomID, "seatIndex": exit.seat, "yxRoomId": exit.messagingRoom],
                                  session: exit.session)
        }
        pendingExit = nil
    }

    private func party(_ path: String, fields: [String: Any], admission: Admission) async throws -> Any {
        try await document("/sapi/weidou/v1/client/party/" + path, fields: fields, session: admission.session)
    }

    private func seatRows(_ value: Any) -> [[String: Any]] {
        if let rows = value as? [[String: Any]] { return rows }
        guard let fields = value as? [String: Any] else { return [] }
        for key in ["rows", "records", "list", "data", "result", "items", "roomSeatList", "seatList", "seats"] {
            if let child = fields[key], child is [Any] || child is [String: Any] { return seatRows(child) }
        }
        return []
    }

    private func asSeat(_ row: [String: Any]) -> Seat? {
        let member = ["userInfo", "user", "memberInfo", "member"]
            .compactMap { row[$0] as? [String: Any] }.first ?? [:]
        let fields = member.merging(row.filter { !($0.value is NSNull) }) { _, official in official }
        guard let index = Int64(text(fields, "seatIndex", "seatNo", "index")), index > 0 else { return nil }
        let user = Int64(text(fields, "userId", "seatUserId", "memberId", "uid")) ?? 0
        let portrait = text(fields, "avatar", "icon", "userAvatar", "avatarUrl")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let microphoneEnabled: Bool?
        switch text(fields, "microphoneEnabled", "micEnabled", "micOn").lowercased() {
        case "1", "true": microphoneEnabled = true
        case "0", "false": microphoneEnabled = false
        default: microphoneEnabled = nil
        }
        return Seat(index: index, user: user,
                    locked: ["true", "1"].contains(text(fields, "lockFlag", "isLocked", "locked").lowercased()),
                    permitted: !["false", "0"].contains(text(fields, "seatMicrophoneEnabled", "seatMicEnabled").lowercased()),
                    microphone: microphoneEnabled ?? true,
                    template: Int64(text(row, "roomTempId")) ?? 0,
                    name: text(fields, "nickname", "nickName", "userName", "memberName")
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    portrait: portrait.isEmpty ? nil : URL(string: portrait), microphoneEnabled: microphoneEnabled)
    }

    private func refreshSeats(_ room: Admission, attempt: UUID) async throws -> [Seat] {
        let value = try await party("seat/list", fields: ["roomId": room.roomID], admission: room)
        try verify(attempt)
        let rows = seatRows(value).compactMap(asSeat).sorted { $0.index < $1.index }
        var seen = Set<Int64>()
        voiceStageSeats = rows.compactMap { row in
            guard seen.insert(row.index).inserted else { return nil }
            return VoiceStageSeat(index: row.index, occupant: row.user > 0 ? row.user : nil,
                                  name: row.name, portrait: row.portrait, locked: row.locked,
                                  microphoneEnabled: row.microphoneEnabled)
        }
        let declaredTemplate = Int64(text(value as? [String: Any] ?? [:], "roomTempId")) ?? 0
        if declaredTemplate > 0 {
            roomTemplate = declaredTemplate
        } else {
            let templates = Set(rows.map(\.template).filter { $0 > 0 })
            if templates.count == 1, let template = templates.first { roomTemplate = template }
        }
        let previousIndex = ownedSeat?.index
        ownedSeat = rows.first { $0.user == voiceUser }
        if microphone && (ownedSeat?.index != previousIndex || ownedSeat?.permitted != true || ownedSeat?.microphone != true) {
            stopPublishing()
        }
        pendingExit = VoiceExit(session: room.session, roomID: room.roomID, seat: ownedSeat?.index ?? -1,
                                messagingRoom: voiceMessagingRoom)
        return rows
    }

    private func changeSeat(_ path: String, seat: Int64, extra: [String: Any] = [:], admission: Admission,
                            attempt: UUID) async throws {
        try verify(attempt)
        guard roomTemplate > 0, !voiceMessagingRoom.isEmpty else { throw Failure.seat }
        var fields: [String: Any] = ["roomId": admission.roomID, "roomTempId": roomTemplate,
                                     "yxRoomId": voiceMessagingRoom, "seatIndex": seat]
        fields.merge(extra) { current, _ in current }
        let writeID = UUID()
        let write = Task { _ = try await party("seat/" + path, fields: fields, admission: admission) }
        seatWrite = (writeID, write)
        defer { if seatWrite?.id == writeID { seatWrite = nil } }
        try await write.value
        try verify(attempt)
    }

    private func waitingForSeat(_ room: Admission, attempt: UUID) async throws -> Bool {
        let value = try await party("seat/getQueueSeatList", fields: ["roomId": room.roomID], admission: room)
        try verify(attempt)
        let index = Int64(text(value as? [String: Any] ?? [:], "myIndex")) ?? -1
        return index >= 0
    }

    private func seatPayload(queued: Bool = false) -> [String: Any] {
        ["index": ownedSeat?.index ?? 0, "microphone": microphone, "queued": queued, "stageSeats": voiceStageSeats]
    }

    private func seatStatus(_ room: Admission, attempt: UUID) async throws -> [String: Any] {
        if ownedSeat != nil { return seatPayload() }
        return seatPayload(queued: try await waitingForSeat(room, attempt: attempt))
    }

    private func monitorSeats(_ room: Admission, attempt: UUID) {
        seatWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, let self, self.lease == attempt else { return }
                if seatAction != nil || !publicationRequested { continue }
                let action = UUID()
                seatAction = action
                do {
                    _ = try await refreshSeats(room, attempt: attempt)
                } catch {
                    if lease == attempt { stopPublishing() }
                }
                if seatAction == action { seatAction = nil }
            }
        }
    }

    private func beginVoicePresence(_ room: Admission, attempt: UUID) {
        presence = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.lease == attempt else { return }
                do {
                    try await runHeartbeat(room, attempt: attempt)
                } catch {
                    if lease == attempt { closeHeartbeat() }
                }
                guard !Task.isCancelled, lease == attempt else { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func runHeartbeat(_ room: Admission, attempt: UUID) async throws {
        let url = try await KakaAccountStore.shared.voiceHeartbeatURL(session: room.session)
        try verify(attempt)
        let connection = URLSession.shared.webSocketTask(with: url)
        socket = connection
        connection.resume()
        let receive = Task { [weak self] in
            do {
                while !Task.isCancelled { _ = try await connection.receive() }
            } catch {
                guard !Task.isCancelled, let self, self.socket === connection else { return }
                self.closeHeartbeat()
            }
        }
        defer { receive.cancel() }
        try await sendHeartbeat(connection, type: 2, fields: ["onlineStatus": 1])
        try verify(attempt)
        while socket === connection, !Task.isCancelled {
            try await sendHeartbeat(connection, type: 3, fields: [
                "channelId": "", "roomId": room.roomID, "seatIndex": ownedSeat?.index ?? pendingExit?.seat ?? -1, "userStatus": 0,
            ])
            try verify(attempt)
            guard socket === connection else { return }
            presenceReady = true
            try await Task.sleep(nanoseconds: 10_000_000_000)
            guard socket === connection else { return }
            try await ping(connection)
            try await Task.sleep(nanoseconds: 10_000_000_000)
        }
    }

    private func sendHeartbeat(_ connection: URLSessionWebSocketTask, type: Int, fields: [String: Any]) async throws {
        let bytes = try JSONSerialization.data(withJSONObject: [
            "requestId": UUID().uuidString, "messageType": type, "expandParams": fields,
        ])
        try await connection.send(.string(String(decoding: bytes, as: UTF8.self)))
    }

    private func ping(_ connection: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
            connection.sendPing { error in
                if let error { reply.resume(throwing: error) }
                else { reply.resume() }
            }
        }
    }

    private func closeHeartbeat() {
        presenceReady = false
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        stopPublishing()
    }

    private func stopVoicePresence() {
        presence?.cancel()
        presence = nil
        seatWatch?.cancel()
        seatWatch = nil
        closeHeartbeat()
    }

    private func audioOptions(publishing: Bool) -> AgoraRtcChannelMediaOptions {
        let options = AgoraRtcChannelMediaOptions()
        options.clientRoleType = publishing ? .broadcaster : .audience
        options.publishCameraTrack = false
        options.publishMicrophoneTrack = publishing
        options.autoSubscribeAudio = true
        options.autoSubscribeVideo = false
        return options
    }

    private func startPublishing(attempt: UUID) async throws {
        if microphone { return }
        guard let engine else { throw Failure.connection }
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
        publicationRequested = true
        try audioSession.setActive(true)
        try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
            publishReply = reply
            guard engine.enableLocalAudio(true) == 0, engine.updateChannel(with: audioOptions(publishing: true)) == 0,
                  engine.muteLocalAudioStream(false) == 0 else {
                finishPublish(.failure(Failure.connection))
                return
            }
            publishTimeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                guard !Task.isCancelled, let self, self.lease == attempt else { return }
                self.finishPublish(.failure(Failure.timeout))
            }
        }
        try verify(attempt)
    }

    private func stopPublishing() {
        guard publicationRequested else { return }
        publicationRequested = false
        microphone = false
        finishPublish(.failure(Failure.cancelled))
        engine?.muteLocalAudioStream(true)
        engine?.enableLocalAudio(false)
        engine?.updateChannel(with: audioOptions(publishing: false))
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
    }

    private func finishPublish(_ result: Result<Void, Error>) {
        publishTimeout?.cancel()
        publishTimeout = nil
        let reply = publishReply
        publishReply = nil
        reply?.resume(with: result)
    }

    private func attachHost(to rtc: AgoraRtcEngineKit, host: UInt?) throws {
        guard let host else { return }
        let canvas = AgoraRtcVideoCanvas()
        canvas.uid = host
        canvas.view = videoView
        canvas.renderMode = .hidden
        guard rtc.setupRemoteVideo(canvas) == 0 else { throw Failure.connection }
    }

    private func updateVideoVisibility() {
        guard let frame, admission?.mode == .live, connected, hasReceivedLiveFrame else {
            videoView.isHidden = true
            return
        }
        videoView.frame = frame
        videoView.isHidden = false
    }

    private func finishJoin(_ result: Result<Void, Error>) {
        timeout?.cancel()
        timeout = nil
        let reply = joinReply
        joinReply = nil
        reply?.resume(with: result)
    }

    private func consume(_ event: Event, attempt: UUID) {
        guard lease == attempt, let admission else { return }
        switch event {
        case let .joined(channel, uid):
            guard channel == admission.channel, uid == admission.listener else {
                finishJoin(.failure(Failure.connection))
                return
            }
            connected = true
            finishJoin(.success(()))
            updateVideoVisibility()
        case .video(let uid):
            guard uid == admission.host else { return }
            if !hasReceivedLiveFrame { hasReceivedLiveFrame = true }
            updateVideoVisibility()
        case .departed(let uid):
            guard uid == admission.host else { return }
            if hasReceivedLiveFrame { hasReceivedLiveFrame = false }
            updateVideoVisibility()
        case .failure:
            if !connected { finishJoin(.failure(Failure.connection)) }
            else if publishReply != nil { finishPublish(.failure(Failure.connection)) }
        case let .publication(channel, published):
            guard admission.mode == .voice, admission.channel == channel else { return }
            if published && publishReply != nil {
                microphone = true
                finishPublish(.success(()))
            } else if !published && microphone {
                stopPublishing()
            }
        case .expiring:
            guard connected, renewal == nil else { return }
            renewal = Task { [weak self] in
                guard let self else { return }
                defer { if lease == attempt { renewal = nil } }
                do {
                    let token: [String: Any]
                    if admission.mode == .live {
                        token = try await service("/nebula/relay/passcode", fields: ["habitatTag": admission.roomID], session: admission.session)
                    } else {
                        token = try await service("/nebula/relay/identity-pass", session: admission.session)
                    }
                    try verify(attempt)
                    let credential = text(token, "relayPass")
                    let channel = text(token, "venueKey")
                    guard !credential.isEmpty, channel.isEmpty || channel == admission.channel,
                          engine?.renewToken(credential) == 0 else { throw Failure.connection }
                } catch {
                    guard lease == attempt else { return }
                    await leave()
                }
            }
        }
    }

    private enum Event: Sendable {
        case joined(String, UInt), video(UInt), departed(UInt), failure, expiring, publication(String, Bool)
    }

    private final class EventReceiver: NSObject, AgoraRtcEngineDelegate {
        let handle: @Sendable (Event) -> Void

        init(handle: @escaping @Sendable (Event) -> Void) {
            self.handle = handle
        }

        nonisolated func rtcEngine(_ engine: AgoraRtcEngineKit, didJoinChannel channel: String, withUid uid: UInt, elapsed: Int) {
            handle(.joined(channel, uid))
        }

        nonisolated func rtcEngine(_ engine: AgoraRtcEngineKit, firstRemoteVideoFrameOfUid uid: UInt, size: CGSize, elapsed: Int) {
            handle(.video(uid))
        }

        nonisolated func rtcEngine(_ engine: AgoraRtcEngineKit, remoteVideoStateChangedOfUid uid: UInt, state: AgoraVideoRemoteState,
                       reason: AgoraVideoRemoteReason, elapsed: Int) {
            if state == .decoding { handle(.video(uid)) }
        }

        nonisolated func rtcEngine(_ engine: AgoraRtcEngineKit, didOfflineOfUid uid: UInt, reason: AgoraUserOfflineReason) {
            handle(.departed(uid))
        }

        nonisolated func rtcEngine(_ engine: AgoraRtcEngineKit, didOccurError errorCode: AgoraErrorCode) {
            handle(.failure)
        }

        nonisolated func rtcEngine(_ engine: AgoraRtcEngineKit, didAudioPublishStateChange channelId: String,
                       oldState: AgoraStreamPublishState, newState: AgoraStreamPublishState, elapseSinceLastState: Int32) {
            handle(.publication(channelId, newState == .published))
        }

        nonisolated func rtcEngine(_ engine: AgoraRtcEngineKit, tokenPrivilegeWillExpire token: String) {
            handle(.expiring)
        }
    }
    #endif
}
