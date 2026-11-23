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
    let duelVideoView = UIView()
    let localCallVideoView = UIView()
    @Published private(set) var hasReceivedLiveFrame = false
    @Published private(set) var duel: LiveDuel?
    @Published private var voiceBackdrop: URL?
    @Published private(set) var voiceAudioEnabled = true
    @Published private(set) var voiceMusicPlaybackFailed = false

    struct LiveDuel: Equatable {
        struct Ranking: Equatable {
            let id: String
            let hostID: Int64
            let opponentID: Int64

            static func validID(_ id: String) -> Bool {
                !id.isEmpty && id.utf8.count <= 128
                    && id.trimmingCharacters(in: .whitespacesAndNewlines) == id
                    && id.rangeOfCharacter(from: .controlCharacters) == nil
            }
        }

        let opponent: UInt
        let channel: String
        let hostScore: String
        let opponentScore: String
        let ranking: Ranking?
    }

    enum PrivateVideoEvent { case remoteFrame, ended }
    var onPrivateVideoEvent: ((PrivateVideoEvent) -> Void)?

    struct VoiceStageSeat: Identifiable {
        let index: Int64
        let occupant: Int64?
        let name: String
        let portrait: URL?
        let locked: Bool
        let microphoneEnabled: Bool?

        var id: Int64 { index }
    }

    struct VoiceManagementState {
        let messagingRoom: String
        let templateID: Int64
        let locked: Bool?
        let seatApproval: Bool?

        var hasRoomIdentity: Bool { !messagingRoom.isEmpty && templateID > 0 }

        func sameRoom(as other: Self) -> Bool {
            messagingRoom == other.messagingRoom && templateID == other.templateID
        }
    }

    @Published private(set) var voiceAnnouncement = ""
    @Published private(set) var voiceLayoutRevision = UUID()

    private static var localAudio: (id: UUID, stop: () -> Void)?

    static var localAudioAvailable: Bool {
        #if canImport(AgoraRtcKit)
        guard engineOwner == nil else { return false }
        #endif
        return localAudio == nil
    }

    static func claimLocalAudio(id: UUID, onPreempt: @escaping () -> Void) throws {
        guard localAudioAvailable else { throw Failure.busy }
        localAudio = (id, onPreempt)
    }

    static func releaseLocalAudio(id: UUID) {
        if localAudio?.id == id { localAudio = nil }
    }

    private static func preemptLocalAudio() {
        guard let localAudio else { return }
        localAudio.stop()
        releaseLocalAudio(id: localAudio.id)
    }

    #if canImport(AgoraRtcKit)
    private enum Mode: String {
        case live, voice, privateCall
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
        let type: Int64
        let user: Int64
        let locked: Bool
        let permitted: Bool
        let microphone: Bool
        let template: Int64
        let name: String
        let portrait: URL?
        let microphoneEnabled: Bool?
        let giftAccount: String
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
    private var voiceExpressionSeats: [Seat] = []
    private var voiceStageTimestamp: TimeInterval = 0
    private var microphone = false
    private var voiceMixing = false
    private var publicationRequested = false
    private var roomTemplate: Int64 = 0
    private var expectedVoiceTemplate: (id: Int64, deadline: TimeInterval)?
    private var voiceRoomLocked: Bool?
    private var admittedVoiceRoom: KakaNativeRoom?
    private var voiceSeatApproval: Bool?
    private var voiceUser: Int64 = 0
    private var voiceMessagingRoom = ""
    private var voiceBackdropLoad: Task<Void, Never>?
    private var publishReply: CheckedContinuation<Void, Error>?
    private var publishTimeout: Task<Void, Never>?
    private var frame: CGRect?
    private var connected = false
    private var duelWatch: Task<Void, Never>?
    private var duelConnection: AgoraRtcConnection?
    private var duelCallbacks: EventReceiver?
    private var duelLease = UUID()
    private var duelDeparture: UUID?
    private var duelTarget: LiveDuel?
    private var duelStartedAt: Date?
    private var duelFrame: CGRect?
    private var duelReady = false
    #endif

    init() {
        videoView.backgroundColor = .black
        videoView.clipsToBounds = true
        videoView.isUserInteractionEnabled = false
        videoView.accessibilityElementsHidden = true
        videoView.isHidden = true
        duelVideoView.backgroundColor = .black
        duelVideoView.clipsToBounds = true
        duelVideoView.isUserInteractionEnabled = false
        duelVideoView.accessibilityElementsHidden = true
        duelVideoView.isHidden = true
        localCallVideoView.backgroundColor = .black
        localCallVideoView.clipsToBounds = true
        localCallVideoView.accessibilityElementsHidden = true
        localCallVideoView.isHidden = true
    }

    func setVideoFrame(_ frame: CGRect?) {
        #if canImport(AgoraRtcKit)
        self.frame = frame
        updateVideoVisibility()
        #endif
    }

    func voiceBackground(roomID: Int64, session: UUID) -> URL? {
        #if canImport(AgoraRtcKit)
        guard connected, let admission, admission.mode == .voice, admission.roomID == roomID,
              admission.session == session else { return nil }
        return voiceBackdrop
        #else
        return nil
        #endif
    }

    func voiceManagementState(roomID: Int64, session: UUID) -> VoiceManagementState? {
        #if canImport(AgoraRtcKit)
        guard connected, let admission, admission.mode == .voice, admission.roomID == roomID,
              admission.session == session else { return nil }
        return VoiceManagementState(messagingRoom: voiceMessagingRoom, templateID: expectedVoiceTemplate == nil ? roomTemplate : 0,
                                    locked: voiceRoomLocked, seatApproval: voiceSeatApproval)
        #else
        return nil
        #endif
    }

    func voiceRoomDetails(roomID: Int64, session: UUID) -> KakaNativeRoom? {
        #if canImport(AgoraRtcKit)
        guard voiceManagementState(roomID: roomID, session: session) != nil else { return nil }
        return admittedVoiceRoom
        #else
        return nil
        #endif
    }

    func voiceModerationSeats(roomID: Int64, session: UUID) async throws -> [VoiceStageSeat] {
        #if canImport(AgoraRtcKit)
        guard voiceManagementState(roomID: roomID, session: session) != nil, let admission else { throw Failure.invalidRoom }
        let attempt = lease
        let value = try await party("seat/list", fields: ["roomId": roomID], admission: admission)
        try verify(attempt)
        let seats = Dictionary(grouping: seatRows(value).compactMap(asSeat), by: \.index)
        return seats.values.compactMap { $0.count == 1 ? $0.first.map(stageSeat) : nil }
            .sorted { $0.index < $1.index }
        #else
        throw Failure.unavailable
        #endif
    }

    func switchVoiceLayout(to template: Int64, replacing previous: VoiceManagementState,
                           roomID: Int64, session: UUID) async throws {
        #if canImport(AgoraRtcKit)
        guard template > 0, template != previous.templateID, previous.hasRoomIdentity,
              let current = voiceManagementState(roomID: roomID, session: session), current.sameRoom(as: previous),
              let admission else { throw Failure.invalidRoom }
        guard seatAction == nil, seatWrite == nil else { throw Failure.busy }
        let attempt = lease
        let action = UUID()
        seatAction = action
        defer { if seatAction == action { seatAction = nil } }
        try await writeVoiceSeat("switchRoomTemp", fields: ["roomId": roomID, "yxRoomId": current.messagingRoom,
                                                            "roomTempId": template], admission: admission, attempt: attempt)
        expectedVoiceTemplate = (template, ProcessInfo.processInfo.systemUptime + 20)
        voiceStageSeats = []
        voiceExpressionSeats = []
        voiceStageTimestamp = 0
        ownedSeat = nil
        stopPublishing()
        _ = try? await refreshSeats(admission, attempt: attempt)
        try verify(attempt)
        voiceLayoutRevision = UUID()
        #else
        throw Failure.unavailable
        #endif
    }

    func updateVoiceManagementState(roomID: Int64, session: UUID, announcement: String? = nil,
                                    locked: Bool? = nil, seatApproval: Bool? = nil, background: URL? = nil) {
        #if canImport(AgoraRtcKit)
        guard voiceManagementState(roomID: roomID, session: session) != nil else { return }
        if let announcement { voiceAnnouncement = announcement }
        if let locked { voiceRoomLocked = locked }
        if let seatApproval { voiceSeatApproval = seatApproval }
        if let background {
            voiceBackdropLoad?.cancel()
            voiceBackdropLoad = nil
            voiceBackdrop = background
        }
        #endif
    }

    func setVoiceAudio(_ enabled: Bool, roomID: Int64, session: UUID) throws {
        #if canImport(AgoraRtcKit)
        guard connected, let admission, admission.mode == .voice, admission.roomID == roomID,
              admission.session == session, let engine else { throw Failure.invalidRoom }
        guard engine.muteAllRemoteAudioStreams(!enabled) == 0 else { throw Failure.connection }
        voiceAudioEnabled = enabled
        #else
        throw Failure.unavailable
        #endif
    }

    func canPlayVoiceMusic(roomID: Int64, session: UUID) -> Bool {
        #if canImport(AgoraRtcKit)
        return voiceManagementState(roomID: roomID, session: session) != nil
            && presenceReady && microphone && ownedSeat?.permitted == true
            && ownedSeat?.microphone == true && (ownedSeat?.index ?? 0) > 0
        #else
        return false
        #endif
    }

    func playVoiceMusic(_ url: URL, roomID: Int64, session: UUID) throws {
        #if canImport(AgoraRtcKit)
        guard canPlayVoiceMusic(roomID: roomID, session: session), let engine else { throw Failure.seat }
        guard engine.startAudioMixing(url.absoluteString, loopback: false, cycle: 1, startPos: 0) == 0 else {
            throw Failure.connection
        }
        voiceMixing = true
        voiceMusicPlaybackFailed = false
        #else
        throw Failure.unavailable
        #endif
    }

    func stopVoiceMusic(roomID: Int64, session: UUID) {
        #if canImport(AgoraRtcKit)
        guard voiceManagementState(roomID: roomID, session: session) != nil else { return }
        stopVoiceMix()
        #endif
    }

    func setDuelVideoFrame(_ frame: CGRect?) {
        #if canImport(AgoraRtcKit)
        duelFrame = frame
        updateDuelVideoVisibility()
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
        guard let mode = Mode(rawValue: kind), mode != .privateCall, roomID > 0,
              (password?.utf8.count ?? 0) <= 128 else { throw Failure.invalidRoom }
        guard !joining, !releasing, engine == nil,
              Self.engineOwner == nil || Self.engineOwner === self else { throw Failure.busy }
        Self.preemptLocalAudio()
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
                loadVoiceBackdrop(in: authorization, attempt: attempt)
            } else if mode == .live {
                watchDuel(in: authorization, attempt: attempt)
            }
        } catch {
            await leave()
            throw error
        }
        #else
        throw Failure.unavailable
        #endif
    }

    func joinPrivateVideo(channel: String, credential: String, listener: UInt, peer: UInt, session: UUID) async throws {
        #if canImport(AgoraRtcKit)
        guard !joining, !releasing, engine == nil, Self.engineOwner == nil,
              !channel.isEmpty, channel.utf8.count <= 64, !credential.isEmpty,
              listener > 0, peer > 0, listener <= UInt(UInt32.max), peer <= UInt(UInt32.max),
              listener != peer else { throw Failure.busy }
        Self.preemptLocalAudio()
        Self.engineOwner = self
        joining = true
        let attempt = UUID()
        lease = attempt
        defer {
            joining = false
            releaseOwnershipIfIdle()
        }
        do {
            let appID = try await KakaAccountStore.shared.rtcAppID(session: session)
            try verify(attempt)
            guard !appID.isEmpty else { throw Failure.unavailable }
            admission = Admission(mode: .privateCall, roomID: 0, session: session, channel: channel,
                                  credential: credential, listener: listener, host: peer)
            let receiver = EventReceiver { [weak self] event in
                Task { @MainActor [weak self] in self?.consume(event, attempt: attempt) }
            }
            callbacks = receiver
            let rtc = AgoraRtcEngineKit.sharedEngine(withAppId: appID, delegate: receiver)
            engine = rtc
            rtc.setAudioSessionOperationRestriction(.configureSession)
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord, mode: .videoChat, options: [.defaultToSpeaker])
            try audio.setActive(true)
            rtc.enableVideo()
            rtc.enableAudio()
            rtc.enableLocalVideo(false)
            rtc.enableLocalAudio(false)
            rtc.setChannelProfile(.liveBroadcasting)
            try attachHost(to: rtc, host: peer)
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
                    joinReply = reply
                    let code = rtc.joinChannel(byToken: credential, channelId: channel, uid: listener,
                                               mediaOptions: callOptions(publishing: false), joinSuccess: nil)
                    guard code == 0 else { finishJoin(.failure(Failure.connection)); return }
                    timeout = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 15_000_000_000)
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
        } catch {
            if lease == attempt { await leave() }
            throw error
        }
        #else
        throw Failure.unavailable
        #endif
    }

    func publishPrivateVideo() throws {
        #if canImport(AgoraRtcKit)
        guard let engine, connected, admission?.mode == .privateCall,
              AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw Failure.permission }
        let canvas = AgoraRtcVideoCanvas()
        canvas.uid = 0
        canvas.view = localCallVideoView
        canvas.renderMode = .hidden
        guard engine.setupLocalVideo(canvas) == 0, engine.enableLocalVideo(true) == 0,
              engine.enableLocalAudio(true) == 0, engine.updateChannel(with: callOptions(publishing: true)) == 0,
              engine.startPreview() == 0 else { throw Failure.connection }
        localCallVideoView.isHidden = false
        #else
        throw Failure.unavailable
        #endif
    }

    func pausePrivateVideo() {
        #if canImport(AgoraRtcKit)
        guard admission?.mode == .privateCall, let engine else { return }
        engine.updateChannel(with: callOptions(publishing: false))
        engine.enableLocalVideo(false)
        engine.enableLocalAudio(false)
        engine.stopPreview()
        localCallVideoView.isHidden = true
        #endif
    }

    func leave() async {
        setVideoFrame(nil)
        setDuelVideoFrame(nil)
        pausePrivateVideo()
        #if canImport(AgoraRtcKit)
        let departedRoom = admission
        let departedUser = voiceUser
        let outstandingWrite = seatWrite?.task
        let awaitingLayout = expectedVoiceTemplate != nil
        stopVoicePresence()
        stopPublishing()
        voiceBackdropLoad?.cancel()
        voiceBackdropLoad = nil
        if voiceBackdrop != nil { voiceBackdrop = nil }
        if !voiceAudioEnabled { voiceAudioEnabled = true }
        duelWatch?.cancel()
        duelWatch = nil
        removeDuel()
        lease = UUID()
        finishJoin(.failure(Failure.cancelled))
        renewal?.cancel()
        renewal = nil
        if hasReceivedLiveFrame { hasReceivedLiveFrame = false }
        connected = false
        admission = nil
        ownedSeat = nil
        voiceStageSeats = []
        voiceExpressionSeats = []
        voiceStageTimestamp = 0
        voiceUser = 0
        roomTemplate = 0
        expectedVoiceTemplate = nil
        voiceRoomLocked = nil
        admittedVoiceRoom = nil
        voiceSeatApproval = nil
        if !voiceAnnouncement.isEmpty { voiceAnnouncement = "" }
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
            duelDeparture = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        if let departedRoom, departedRoom.mode == .voice, outstandingWrite != nil || awaitingLayout {
            // A seat change already sent to the server may complete after the user leaves.
            // Settle that write before reporting the final seat in the exit.
            try? await outstandingWrite?.value
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
                if let position = try await queuePosition(admission, attempt: attempt) { return seatPayload(queuePosition: position) }
                guard let open = rows.first(where: {
                    $0.user == 0 && !$0.locked && (requestedSeat == nil || $0.index == requestedSeat)
                }) else { throw Failure.seat }
                try await changeSeat("onSeat", seat: open.index, admission: admission, attempt: attempt)
                _ = try await refreshSeats(admission, attempt: attempt)
            }
            let status = try await seatStatus(admission, attempt: attempt)
            guard ownedSeat != nil || (status["queued"] as? Bool) == true else { throw Failure.seat }
            return status
        case "voiceSeat.move":
            guard presenceReady else { throw Failure.heartbeat }
            guard ownedSeat != nil, let requestedSeat, requestedSeat > 0 else { throw Failure.seat }
            let targets = rows.filter { $0.index == requestedSeat }
            guard targets.count == 1, let target = targets.first, target.user == 0, !target.locked,
                  target.type == 1 || target.type == 2 else { throw Failure.seat }
            let resume = microphone
            if resume { stopPublishing() }
            try await changeSeat("exchangeSeat", seat: target.index, extra: ["operatorType": 10, "seatType": target.type],
                                 admission: admission, attempt: attempt)
            _ = try await refreshSeats(admission, attempt: attempt)
            guard let destination = ownedSeat, destination.index == requestedSeat else { throw Failure.seat }
            if resume && presenceReady && destination.permitted && destination.microphone,
               AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                do { try await startPublishing(attempt: attempt) }
                catch {
                    if lease == attempt { stopPublishing() }
                    throw error
                }
            }
            return seatPayload()
        case "voiceSeat.withdraw":
            if ownedSeat == nil, try await queuePosition(admission, attempt: attempt) != nil {
                try await writeVoiceSeat("giveUpQueueSeat", fields: ["roomId": roomID, "yxRoomId": voiceMessagingRoom],
                                         admission: admission, attempt: attempt)
            }
            return try await seatStatus(admission, attempt: attempt)
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

    func isVoiceGiftAudience(roomID: Int64, session: UUID) -> Bool {
        #if canImport(AgoraRtcKit)
        guard connected, engine != nil, let admission else { return false }
        return admission.mode == .voice && admission.roomID == roomID && admission.session == session
            && !voiceMessagingRoom.isEmpty && voiceUser > 0
        #else
        return false
        #endif
    }

    func voiceGiftRecipients(roomID: Int64, session: UUID) async throws -> [KakaVoiceGifts.Recipient] {
        #if canImport(AgoraRtcKit)
        guard isVoiceGiftAudience(roomID: roomID, session: session), let admission else { throw Failure.invalidRoom }
        let attempt = lease
        let value = try await party("seat/list", fields: ["roomId": roomID], admission: admission)
        try verify(attempt)
        guard isVoiceGiftAudience(roomID: roomID, session: session) else { throw Failure.invalidRoom }
        let eligible = seatRows(value).compactMap(asSeat).filter {
            $0.user > 0 && $0.user != voiceUser && !$0.giftAccount.isEmpty
        }
        let users = Dictionary(grouping: eligible, by: \.user)
        let accounts = Dictionary(grouping: eligible, by: \.giftAccount)
        return eligible.filter { users[$0.user]?.count == 1 && accounts[$0.giftAccount]?.count == 1 }
            .sorted { $0.index < $1.index }
            .map { seat in
                KakaVoiceGifts.Recipient(id: seat.user, account: seat.giftAccount,
                                         name: seat.name.isEmpty ? "Seat \(seat.index)" : seat.name,
                                         portrait: seat.portrait)
            }
        #else
        throw Failure.unavailable
        #endif
    }

    func verifiesVoiceExpression(roomID: Int64, session: UUID, userID: Int64, account: String, seat: Int64) -> Bool {
        #if canImport(AgoraRtcKit)
        guard voiceManagementState(roomID: roomID, session: session)?.hasRoomIdentity == true,
              seat > 0, userID > 0, !account.isEmpty,
              ProcessInfo.processInfo.systemUptime - voiceStageTimestamp < 12 else { return false }
        let matches = voiceExpressionSeats.filter { $0.index == seat || $0.user == userID || $0.giftAccount == account }
        guard matches.count == 1, let position = matches.first else { return false }
        return position.index == seat && position.user == userID && position.giftAccount == account
        #else
        return false
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
            var room = try await service("/sapi/weidou/v1/client/party/room/enter", fields: fields, session: session)
            let returnedIDs = ["id", "roomId"].compactMap { KakaRemoteClient.userID(room[$0]) }.filter { $0 > 0 }
            guard returnedIDs.allSatisfy({ $0 == roomID }) else { throw Failure.invalidRoom }
            pendingExit = VoiceExit(session: session, roomID: roomID, seat: Int64(text(room, "inPartyRole")) ?? -1,
                                    messagingRoom: text(room, "yxRoomId"))
            try verify(attempt)
            let channel = text(room, "agoraChannelId")
            guard text(room, "roomStatus") != "2", !channel.isEmpty else { throw Failure.invalidRoom }
            room["roomId"] = roomID
            admittedVoiceRoom = KakaNativeRoom.parse(room, kind: .voice)
            voiceUser = userID
            roomTemplate = Int64(text(room, "roomTempId")) ?? 0
            voiceRoomLocked = KakaVoiceManagementContext.flag(room, "lockRoomFlag", "lockFlag")
            voiceSeatApproval = KakaVoiceManagementContext.flag(room, "onSeatApplySwitch")
            voiceAnnouncement = KakaRoomFields.text(room, "announcement")
            voiceMessagingRoom = text(room, "yxRoomId")
            voiceBackdrop = KakaRoomFields.url(text(room, "bigImgUrl", "bgImgUrl"))
            let token = try await service("/nebula/relay/identity-pass", session: session)
            let credential = text(token, "relayPass")
            let requestedID = text(token, "starBadge")
            guard let listener = identifier(requestedID.isEmpty ? String(userID) : requestedID), !credential.isEmpty else {
                throw Failure.invalidRoom
            }
            return Admission(mode: mode, roomID: roomID, session: session, channel: channel,
                             credential: credential, listener: listener, host: nil)
        case .privateCall:
            throw Failure.invalidRoom
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

    private func loadVoiceBackdrop(in room: Admission, attempt: UUID) {
        voiceBackdropLoad?.cancel()
        voiceBackdropLoad = Task { [weak self] in
            guard let self else { return }
            defer { if lease == attempt { voiceBackdropLoad = nil } }
            guard let value = try? await party("room/getRoomBgImage", fields: ["roomId": room.roomID], admission: room),
                  !Task.isCancelled, lease == attempt, connected, admission?.mode == .voice,
                  admission?.roomID == room.roomID, admission?.session == room.session,
                  let fields = value as? [String: Any],
                  let url = KakaRoomFields.url(text(fields, "bigImgUrl", "bgImgUrl")), voiceBackdrop != url else { return }
            voiceBackdrop = url
        }
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
        let flatUser = Int64(text(row, "userId", "seatUserId", "memberId", "uid"))
        let nestedUser = Int64(text(member, "userId", "seatUserId", "memberId", "uid"))
        let flatAccount = text(row, "yxAccid", "accid", "imAccid", "yunxinAccid")
        let nestedAccount = text(member, "yxAccid", "accid", "imAccid", "yunxinAccid")
        let account = flatAccount.isEmpty ? nestedAccount : flatAccount
        let giftIdentityMatches = (flatUser == nil || flatUser == user) && (nestedUser == nil || nestedUser == user)
        let giftAccount = giftIdentityMatches && account.utf8.count <= 128
            && account.trimmingCharacters(in: .whitespacesAndNewlines) == account ? account : ""
        let portrait = text(fields, "avatar", "icon", "userAvatar", "avatarUrl")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let microphoneEnabled: Bool?
        switch text(fields, "microphoneEnabled", "micEnabled", "micOn").lowercased() {
        case "1", "true": microphoneEnabled = true
        case "0", "false": microphoneEnabled = false
        default: microphoneEnabled = nil
        }
        let type = Int64(text(fields, "seatType", "micType", "type")) ?? 2
        return Seat(index: index, type: type, user: user,
                    locked: ["true", "1"].contains(text(fields, "lockFlag", "isLocked", "locked").lowercased()),
                    permitted: !["false", "0"].contains(text(fields, "seatMicrophoneEnabled", "seatMicEnabled").lowercased()),
                    microphone: microphoneEnabled ?? true,
                    template: Int64(text(row, "roomTempId")) ?? 0,
                    name: text(fields, "nickname", "nickName", "userName", "memberName")
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    portrait: portrait.isEmpty ? nil : URL(string: portrait), microphoneEnabled: microphoneEnabled,
                    giftAccount: giftAccount)
    }

    private func refreshSeats(_ room: Admission, attempt: UUID) async throws -> [Seat] {
        let value = try await party("seat/list", fields: ["roomId": room.roomID], admission: room)
        try verify(attempt)
        let rows = seatRows(value).compactMap(asSeat).sorted { $0.index < $1.index }
        let declaredTemplate = Int64(text(value as? [String: Any] ?? [:], "roomTempId")) ?? 0
        let seatTemplates = Set(rows.map(\.template).filter { $0 > 0 })
        let returnedTemplate = declaredTemplate > 0 ? declaredTemplate : (seatTemplates.count == 1 ? seatTemplates.first ?? 0 : 0)
        if let expected = expectedVoiceTemplate {
            let coherent = returnedTemplate > 0 && (seatTemplates.isEmpty || seatTemplates == [returnedTemplate])
            let confirmed = coherent && returnedTemplate == expected.id
            guard confirmed || ProcessInfo.processInfo.systemUptime >= expected.deadline else { throw Failure.busy }
            expectedVoiceTemplate = nil
            roomTemplate = coherent ? returnedTemplate : 0
        } else if returnedTemplate > 0 {
            roomTemplate = returnedTemplate
        }
        var seen = Set<Int64>()
        voiceStageSeats = rows.compactMap { row in
            guard seen.insert(row.index).inserted else { return nil }
            return stageSeat(row)
        }
        voiceExpressionSeats = rows
        voiceStageTimestamp = ProcessInfo.processInfo.systemUptime
        let previousIndex = ownedSeat?.index
        ownedSeat = rows.first { $0.user == voiceUser }
        if microphone && (ownedSeat?.index != previousIndex || ownedSeat?.permitted != true || ownedSeat?.microphone != true) {
            stopPublishing()
        }
        pendingExit = VoiceExit(session: room.session, roomID: room.roomID, seat: ownedSeat?.index ?? -1,
                                messagingRoom: voiceMessagingRoom)
        return rows
    }

    private func stageSeat(_ row: Seat) -> VoiceStageSeat {
        VoiceStageSeat(index: row.index, occupant: row.user > 0 ? row.user : nil,
                       name: row.name, portrait: row.portrait, locked: row.locked,
                       microphoneEnabled: row.microphoneEnabled)
    }

    private func changeSeat(_ path: String, seat: Int64, extra: [String: Any] = [:], admission: Admission,
                            attempt: UUID) async throws {
        try verify(attempt)
        guard roomTemplate > 0, !voiceMessagingRoom.isEmpty else { throw Failure.seat }
        var fields: [String: Any] = ["roomId": admission.roomID, "roomTempId": roomTemplate,
                                     "yxRoomId": voiceMessagingRoom, "seatIndex": seat]
        fields.merge(extra) { current, _ in current }
        try await writeVoiceSeat(path, fields: fields, admission: admission, attempt: attempt)
    }

    private func writeVoiceSeat(_ path: String, fields: [String: Any], admission: Admission, attempt: UUID) async throws {
        try verify(attempt)
        let writeID = UUID()
        let write = Task {
            try verify(attempt)
            _ = try await party("seat/" + path, fields: fields, admission: admission)
        }
        seatWrite = (writeID, write)
        defer { if seatWrite?.id == writeID { seatWrite = nil } }
        try await write.value
        try verify(attempt)
    }

    private func queuePosition(_ room: Admission, attempt: UUID) async throws -> Int64? {
        let value = try await party("seat/getQueueSeatList", fields: ["roomId": room.roomID], admission: room)
        try verify(attempt)
        guard let index = Int64(text(value as? [String: Any] ?? [:], "myIndex")), index >= 0, index < Int64.max else { return nil }
        return index + 1
    }

    private func seatPayload(queuePosition: Int64? = nil) -> [String: Any] {
        var payload: [String: Any] = ["index": ownedSeat?.index ?? 0, "microphone": microphone,
                                      "queued": queuePosition != nil, "stageSeats": voiceStageSeats]
        if let queuePosition { payload["queuePosition"] = queuePosition }
        return payload
    }

    private func seatStatus(_ room: Admission, attempt: UUID) async throws -> [String: Any] {
        if ownedSeat != nil { return seatPayload() }
        return seatPayload(queuePosition: try await queuePosition(room, attempt: attempt))
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
        options.autoSubscribeAudio = voiceAudioEnabled
        options.autoSubscribeVideo = false
        return options
    }

    private func callOptions(publishing: Bool) -> AgoraRtcChannelMediaOptions {
        let options = AgoraRtcChannelMediaOptions()
        options.clientRoleType = .broadcaster
        options.publishCameraTrack = publishing
        options.publishMicrophoneTrack = publishing
        options.autoSubscribeAudio = publishing
        options.autoSubscribeVideo = true
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
        stopVoiceMix()
        guard publicationRequested else { return }
        publicationRequested = false
        microphone = false
        finishPublish(.failure(Failure.cancelled))
        engine?.muteLocalAudioStream(true)
        engine?.enableLocalAudio(false)
        engine?.updateChannel(with: audioOptions(publishing: false))
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
    }

    private func stopVoiceMix() {
        if voiceMixing { engine?.stopAudioMixing() }
        voiceMixing = false
        if voiceMusicPlaybackFailed { voiceMusicPlaybackFailed = false }
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

    private func watchDuel(in room: Admission, attempt: UUID) {
        duelWatch?.cancel()
        duelWatch = Task { @MainActor [weak self] in
            guard let self else { return }
            var phase = 0
            var failures = 0
            var nextRoomCheck = Date.distantPast
            while !Task.isCancelled, lease == attempt, connected {
                do {
                    if Date() >= nextRoomCheck {
                        phase = try await duelRoomPhase(room, attempt: attempt)
                        nextRoomCheck = Date().addingTimeInterval(15)
                    }
                    if [3, 4, 5, 6, 7, 8, 10].contains(phase) {
                        phase = try await refreshDuel(room, attempt: attempt)
                    } else {
                        removeDuel()
                    }
                    failures = 0
                } catch {
                    guard !Task.isCancelled, lease == attempt else { return }
                    failures += 1
                    if failures >= 3 { removeDuel() }
                }
                let interval: UInt64 = [3, 4, 5, 6, 7, 8, 10].contains(phase) ? 3 : 15
                do { try await Task.sleep(nanoseconds: interval * 1_000_000_000) } catch { return }
            }
        }
    }

    private func duelRoomPhase(_ room: Admission, attempt: UUID) async throws -> Int {
        let result = try await service("/nebula/studio/retrieve", fields: ["habitatTag": room.roomID], session: room.session)
        try verify(attempt)
        let data = result["venueBrief"] as? [String: Any] ?? result
        let host = data["anchor"] as? [String: Any] ?? data["anchorInfo"] as? [String: Any] ?? data
        let verifiedHost = identifier(text(host, "voyagerBadge", "orbitMark")) ?? identifier(text(data, "voyagerBadge"))
        guard Int64(text(data, "habitatTag", "orbitMark")) == room.roomID, verifiedHost == room.host,
              text(data, "studioRoute", "venueKey") == room.channel else { throw Failure.invalidRoom }
        return Int(text(result, "beaconCondition")) ?? Int(text(data, "beaconCondition")) ?? 0
    }

    private func refreshDuel(_ room: Admission, attempt: UUID) async throws -> Int {
        let response = try await service("/nebula/duel/brief", fields: ["habitatTag": room.roomID], session: room.session)
        try verify(attempt)
        let reportedRoom = text(response, "habitatTag")
        let reportedHost = text(response, "fanBadge")
        let reportedChannel = text(response, "curtainRelay")
        guard reportedRoom.isEmpty || reportedRoom == "0" || Int64(reportedRoom) == room.roomID,
              reportedHost.isEmpty || reportedHost == "0" || identifier(reportedHost) == room.host,
              reportedChannel.isEmpty || reportedChannel == room.channel,
              let phase = Int(text(response, "beaconCondition")) else { throw Failure.invalidRoom }
        guard [7, 8].contains(phase) else {
            removeDuel()
            return phase
        }
        let channel = text(response, "flankRelayId")
        let hostScore = text(response, "spotlightScore")
        let opponentScore = text(response, "flankTally")
        guard let opponent = identifier(text(response, "flankPilotTag")), opponent != room.host,
              opponent != room.listener, !channel.isEmpty, channel != room.channel, channel.utf8.count <= 64,
              let own = Decimal(string: hostScore), own >= 0, hostScore.count <= 24,
              let other = Decimal(string: opponentScore), other >= 0, opponentScore.count <= 24 else {
            throw Failure.invalidRoom
        }
        let duelID = text(response, "cometMarker")
        let ranking: LiveDuel.Ranking?
        if let host = room.host, let hostID = Int64(exactly: host), let opponentID = Int64(exactly: opponent),
           LiveDuel.Ranking.validID(duelID) {
            ranking = LiveDuel.Ranking(id: duelID, hostID: hostID, opponentID: opponentID)
        } else {
            ranking = nil
        }
        let target = LiveDuel(opponent: opponent, channel: channel, hostScore: hostScore,
                              opponentScore: opponentScore, ranking: ranking)
        if duelConnection?.channelId == channel, duelTarget?.opponent == opponent,
           duelStartedAt.map({ Date().timeIntervalSince($0) < 12 }) ?? true {
            duelTarget = target
            if duel != nil && duel != target { duel = target }
            return phase
        }
        removeDuel()
        guard duelDeparture == nil else { return phase }
        let authorization = try await service("/nebula/relay/identity-pass", session: room.session)
        try verify(attempt)
        try attachDuel(target, authorization: authorization, room: room, attempt: attempt)
        return phase
    }

    private func attachDuel(_ target: LiveDuel, authorization: [String: Any], room: Admission, attempt: UUID) throws {
        let token = text(authorization, "relayPass")
        let supplied = text(authorization, "starBadge")
        let listener = supplied.isEmpty ? room.listener : identifier(supplied)
        let channel = text(authorization, "venueKey")
        guard let engine, connected, let listener, listener != target.opponent, !token.isEmpty,
              channel.isEmpty || channel == target.channel else { throw Failure.invalidRoom }
        let connection = AgoraRtcConnection()
        connection.channelId = target.channel
        connection.localUid = listener
        let marker = UUID()
        let receiver = EventReceiver { [weak self] event in
            Task { @MainActor [weak self] in self?.consumeDuel(event, room: room, attempt: attempt, marker: marker) }
        }
        let options = AgoraRtcChannelMediaOptions()
        options.clientRoleType = .audience
        options.publishCameraTrack = false
        options.publishMicrophoneTrack = false
        options.autoSubscribeAudio = true
        options.autoSubscribeVideo = true
        guard engine.joinChannelEx(byToken: token, connection: connection, delegate: receiver,
                                   mediaOptions: options, joinSuccess: nil) == 0 else { throw Failure.connection }
        duelLease = marker
        duelConnection = connection
        duelCallbacks = receiver
        duelTarget = target
        duelStartedAt = Date()
    }

    private func consumeDuel(_ event: Event, room: Admission, attempt: UUID, marker: UUID) {
        guard lease == attempt, duelLease == marker, let engine, let connection = duelConnection,
              let target = duelTarget else { return }
        switch event {
        case let .joined(channel, listener):
            guard channel == target.channel, listener == connection.localUid else { removeDuel(); return }
            let canvas = AgoraRtcVideoCanvas()
            canvas.uid = target.opponent
            canvas.view = duelVideoView
            canvas.renderMode = .hidden
            guard engine.setupRemoteVideoEx(canvas, connection: connection) == 0 else { removeDuel(); return }
            duelStartedAt = nil
            duel = target
        case .video(let uid, _):
            guard uid == target.opponent else { return }
            duelReady = true
            updateDuelVideoVisibility()
        case .departed(let uid):
            if uid == target.opponent { removeDuel() }
        case .failure:
            removeDuel()
        case .expiring:
            Task { @MainActor [weak self] in
                guard let self else { return }
                let authorization = try? await service("/nebula/relay/identity-pass", session: room.session)
                guard lease == attempt, duelLease == marker, let engine, let connection = duelConnection else { return }
                let token = text(authorization ?? [:], "relayPass")
                let uid = text(authorization ?? [:], "starBadge")
                let channel = text(authorization ?? [:], "venueKey")
                guard !token.isEmpty, uid.isEmpty || identifier(uid) == connection.localUid,
                      channel.isEmpty || channel == connection.channelId else { removeDuel(); return }
                let options = AgoraRtcChannelMediaOptions()
                options.token = token
                if engine.updateChannelEx(with: options, connection: connection) != 0 { removeDuel() }
            }
        case .publication:
            break
        }
    }

    private func removeDuel() {
        duelLease = UUID()
        if let engine, let connection = duelConnection {
            engine.muteAllRemoteAudioStreamsEx(true, connection: connection)
            let disabled = AgoraRtcChannelMediaOptions()
            disabled.autoSubscribeAudio = false
            disabled.autoSubscribeVideo = false
            engine.updateChannelEx(with: disabled, connection: connection)
            if let target = duelTarget {
                let canvas = AgoraRtcVideoCanvas()
                canvas.uid = target.opponent
                canvas.view = nil
                engine.setupRemoteVideoEx(canvas, connection: connection)
            }
            let callbacks = duelCallbacks
            let departure = UUID()
            duelDeparture = departure
            engine.leaveChannelEx(connection, leaveChannelBlock: { [weak self] _ in
                _ = callbacks
                Task { @MainActor [weak self] in
                    if self?.duelDeparture == departure { self?.duelDeparture = nil }
                }
            })
        }
        duelConnection = nil
        duelCallbacks = nil
        duelTarget = nil
        duelStartedAt = nil
        duelReady = false
        if duel != nil { duel = nil }
        updateDuelVideoVisibility()
    }

    private func updateDuelVideoVisibility() {
        guard let duelFrame, duelReady, duelConnection != nil, duel != nil else {
            duelVideoView.isHidden = true
            return
        }
        duelVideoView.frame = duelFrame
        duelVideoView.isHidden = false
    }

    private func updateVideoVisibility() {
        guard let frame, let mode = admission?.mode, mode == .live || mode == .privateCall,
              connected, hasReceivedLiveFrame else {
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
        case let .video(uid, rendered):
            guard uid == admission.host else { return }
            if !hasReceivedLiveFrame { hasReceivedLiveFrame = true }
            if rendered, admission.mode == .privateCall { onPrivateVideoEvent?(.remoteFrame) }
            updateVideoVisibility()
        case .departed(let uid):
            guard uid == admission.host else { return }
            if hasReceivedLiveFrame { hasReceivedLiveFrame = false }
            updateVideoVisibility()
            if admission.mode == .privateCall { onPrivateVideoEvent?(.ended) }
        case .failure:
            if !connected { finishJoin(.failure(Failure.connection)) }
            else if admission.mode == .privateCall { onPrivateVideoEvent?(.ended) }
            else if publishReply != nil { finishPublish(.failure(Failure.connection)) }
        case let .publication(channel, published):
            guard admission.mode == .voice, admission.channel == channel else { return }
            if published && publishReply != nil {
                microphone = true
                finishPublish(.success(()))
            } else if !published && microphone {
                stopPublishing()
            }
        case .musicFailed:
            guard admission.mode == .voice, voiceMixing else { return }
            voiceMixing = false
            voiceMusicPlaybackFailed = true
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
                    if admission.mode == .privateCall { onPrivateVideoEvent?(.ended) }
                    else { await leave() }
                }
            }
        }
    }

    private enum Event: Sendable {
        case joined(String, UInt), video(UInt, rendered: Bool), departed(UInt), failure, expiring, publication(String, Bool), musicFailed
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
            handle(.video(uid, rendered: true))
        }

        nonisolated func rtcEngine(_ engine: AgoraRtcEngineKit, remoteVideoStateChangedOfUid uid: UInt, state: AgoraVideoRemoteState,
                       reason: AgoraVideoRemoteReason, elapsed: Int) {
            if state == .decoding { handle(.video(uid, rendered: false)) }
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

        nonisolated func rtcEngine(_ engine: AgoraRtcEngineKit, audioMixingStateChanged state: AgoraAudioMixingStateType,
                                   reasonCode: AgoraAudioMixingReasonCode) {
            if state.rawValue == 714 { handle(.musicFailed) }
        }

        nonisolated func rtcEngine(_ engine: AgoraRtcEngineKit, tokenPrivilegeWillExpire token: String) {
            handle(.expiring)
        }
    }
    #endif
}
