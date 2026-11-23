import AVFoundation
import Combine
import Foundation

struct KakaChatVoiceClip: Sendable {
    static let recordingLimit = 60
    static let playbackLimit = 120
    static let maximumBytes = 4 * 1_024 * 1_024

    let audio: Data
    let milliseconds: Int32

    @MainActor fileprivate init(file: URL) throws {
        let player = try AVAudioPlayer(contentsOf: file)
        guard player.duration.isFinite, player.duration >= 0.35,
              player.duration <= Double(Self.recordingLimit) + 0.25 else {
            throw KakaChatVoiceNote.Failure.recording
        }
        let fileHandle = try FileHandle(forReadingFrom: file)
        defer { try? fileHandle.close() }
        guard let bytes = try fileHandle.read(upToCount: Self.maximumBytes + 1),
              !bytes.isEmpty, bytes.count <= Self.maximumBytes else { throw KakaChatVoiceNote.Failure.recording }
        audio = bytes
        milliseconds = Int32((player.duration * 1_000).rounded())
    }

    static func durationLabel(_ milliseconds: Int) -> String {
        let seconds = max(1, (milliseconds + 500) / 1_000)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

@MainActor
final class KakaChatVoiceNote: NSObject, ObservableObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    fileprivate enum Failure: Error { case recording, playback }
    enum Playback: Equatable { case draft, message(String) }

    @Published private(set) var draft: KakaChatVoiceClip?
    @Published private(set) var requestingPermission = false
    @Published private(set) var recordingStarted: Date?
    @Published private(set) var loading: Playback?
    @Published private(set) var playing: Playback?
    @Published private(set) var feedback = ""
    var recording: Bool { recordingStarted != nil }

    private let audio = AVAudioSession.sharedInstance()
    private var audioLease: UUID?
    private var previousCategory: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?
    private var generation = UUID()
    private var recorder: AVAudioRecorder?
    private var recordingFile: URL?
    private var player: AVAudioPlayer?
    private var pending: Task<Void, Never>?

    func startRecording(allowed: @escaping @MainActor () -> Bool) {
        guard draft == nil, !recording, !requestingPermission, allowed() else { return }
        stopAudio()
        feedback = ""
        guard KakaRealtimeMedia.localAudioAvailable else {
            feedback = Self.busyMessage
            return
        }
        requestingPermission = true
        let attempt = generation
        pending = Task { [weak self] in
            let granted = await Self.microphonePermission()
            guard let self, generation == attempt, !Task.isCancelled else { return }
            pending = nil
            requestingPermission = false
            guard allowed() else { return }
            guard granted else {
                feedback = "Allow microphone access in Settings to record a voice message."
                return
            }
            do {
                try beginAudio(category: .playAndRecord, options: [.defaultToSpeaker])
                let file = FileManager.default.temporaryDirectory
                    .appendingPathComponent("kaka-voice-draft-\(UUID().uuidString).m4a")
                recordingFile = file
                try Data().write(to: file, options: [.completeFileProtection])
                let settings: [String: Any] = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64_000,
                ]
                let recorder = try AVAudioRecorder(url: file, settings: settings)
                recorder.delegate = self
                self.recorder = recorder
                guard recorder.record(forDuration: Double(KakaChatVoiceClip.recordingLimit)) else { throw Failure.recording }
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
                recordingStarted = Date()
            } catch {
                stopAudio()
                feedback = message(error, fallback: "Couldn’t start recording. Try again.")
            }
        }
    }

    func finishRecording() {
        guard let recorder, let file = recordingFile else { return }
        self.recorder = nil
        recordingFile = nil
        recorder.delegate = nil
        recorder.stop()
        stopAudio()
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            draft = try KakaChatVoiceClip(file: file)
            feedback = ""
        } catch {
            feedback = "The recording is too short or unreadable. Try again."
        }
    }

    func togglePreview() {
        guard let draft, !recording, !requestingPermission else { return }
        let wasPlaying = playing == .draft
        stopAudio()
        feedback = ""
        guard !wasPlaying else { return }
        do { try play(draft.audio, as: .draft) }
        catch { feedback = message(error, fallback: "Couldn’t play this recording.") }
    }

    func toggleMessage(id: String, url: URL, allowed: @escaping @MainActor () -> Bool) {
        guard !recording, !requestingPermission, allowed() else { return }
        let selection = Playback.message(id)
        let wasSelected = loading == selection || playing == selection
        stopAudio()
        feedback = ""
        guard !wasSelected else { return }
        guard KakaRealtimeMedia.localAudioAvailable else {
            feedback = Self.busyMessage
            return
        }
        loading = selection
        let attempt = generation
        pending = Task { [weak self] in
            do {
                let bytes = try await KakaChatAttachment.download(from: url, maximumBytes: KakaChatVoiceClip.maximumBytes)
                guard let self, generation == attempt, !Task.isCancelled else { return }
                pending = nil
                loading = nil
                guard allowed() else { return }
                try play(bytes, as: selection)
            } catch {
                guard let self, generation == attempt, !Task.isCancelled else { return }
                pending = nil
                loading = nil
                feedback = message(error, fallback: "Couldn’t play this voice message. Try again.")
            }
        }
    }

    func stopAudio() {
        generation = UUID()
        pending?.cancel()
        pending = nil
        requestingPermission = false
        recordingStarted = nil
        loading = nil
        playing = nil
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        if let recordingFile { try? FileManager.default.removeItem(at: recordingFile) }
        recordingFile = nil
        player?.delegate = nil
        player?.stop()
        player = nil
        if let audioLease {
            if let previousCategory {
                try? audio.setActive(false, options: .notifyOthersOnDeactivation)
                try? audio.setCategory(previousCategory.0, mode: previousCategory.1, options: previousCategory.2)
            }
            KakaRealtimeMedia.releaseLocalAudio(id: audioLease)
        }
        previousCategory = nil
        audioLease = nil
    }

    func discard() {
        stopAudio()
        draft = nil
        feedback = ""
    }

    func interrupt() {
        guard recorder != nil || player != nil else { return }
        stopAudio()
        feedback = "Audio was interrupted."
    }

    private func beginAudio(category: AVAudioSession.Category, options: AVAudioSession.CategoryOptions) throws {
        let lease = UUID()
        try KakaRealtimeMedia.claimLocalAudio(id: lease) { [weak self] in self?.interrupt() }
        audioLease = lease
        previousCategory = (audio.category, audio.mode, audio.categoryOptions)
        do {
            try audio.setCategory(category, mode: .default, options: options)
            try audio.setActive(true)
        } catch {
            stopAudio()
            throw error
        }
    }

    private func play(_ data: Data, as selection: Playback) throws {
        let player = try AVAudioPlayer(data: data)
        guard player.duration.isFinite, player.duration > 0,
              player.duration <= Double(KakaChatVoiceClip.playbackLimit) else { throw Failure.playback }
        try beginAudio(category: .playback, options: [.mixWithOthers])
        player.delegate = self
        self.player = player
        guard player.play() else {
            stopAudio()
            throw Failure.playback
        }
        playing = selection
    }

    private static let busyMessage = "Leave the room or call and stop any beat to use voice messages."

    private func message(_ error: Error, fallback: String) -> String {
        (error as? KakaRealtimeMedia.Failure) == .busy ? Self.busyMessage : fallback
    }

    private static func microphonePermission() async -> Bool {
        await withCheckedContinuation { reply in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { reply.resume(returning: $0) }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { reply.resume(returning: $0) }
            }
        }
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let id = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            guard let self, self.recorder.map(ObjectIdentifier.init) == id else { return }
            if flag { finishRecording() }
            else {
                stopAudio()
                feedback = "Couldn’t save the recording. Try again."
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, self.player.map(ObjectIdentifier.init) == id else { return }
            stopAudio()
            if !flag { feedback = "Couldn’t finish playing the voice message." }
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        audioRecorderDidFinishRecording(recorder, successfully: false)
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        audioPlayerDidFinishPlaying(player, successfully: false)
    }
}
