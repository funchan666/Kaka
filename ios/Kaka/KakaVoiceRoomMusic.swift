import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct KakaVoiceRoomMusic {
    let context: KakaVoiceManagementContext
    private var media: KakaRealtimeMedia { KakaNativeRoomRuntime.shared.media }

    struct Track: Identifiable {
        let id: Int64
        let name: String
        let duration: Int64?
        let url: URL?
        let liked: Bool

        init?(_ row: [String: Any]) {
            guard let id = KakaRoomFields.id(row, keys: ["songId"]) else { return nil }
            let name = KakaRoomFields.text(row, "songName").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            self.id = id
            self.name = String(name.prefix(120))
            duration = KakaRemoteClient.userID(row["durationSeconds"]).flatMap { (1...86_400).contains($0) ? $0 : nil }
            url = KakaVoiceRoomMusic.secureURL(KakaRoomFields.text(row, "musicUrl"))
            liked = KakaVoiceManagementContext.flag(row, "like") == true
        }
    }

    struct Settings {
        let enabled: Bool
        let current: Int64?
        let title: String
        let playing: Bool
        let volume: Int64?
    }

    enum Change {
        case enabled(Bool)
        case play(Track)
        case liked(Track, Bool)
        case upload(URL)
    }

    enum Failure: LocalizedError {
        case unavailable, microphone, disabled, expiredTrack, playback, fileType, fileSize, upload

        var errorDescription: String? {
            switch self {
            case .unavailable: return "Room music is unavailable."
            case .microphone: return "Take a mic seat and turn on your mic to play music."
            case .disabled: return "Enable room music before playing a track."
            case .expiredTrack: return "This track is unavailable. Refresh the playlist."
            case .playback: return "The track couldn’t be shared through the room. Choose another track or try again."
            case .fileType: return "Choose an MP3, M4A, AAC or WAV audio file."
            case .fileSize: return "Choose a nonempty audio file of 10 MB or less."
            case .upload: return "The track couldn’t be uploaded. Check the playlist before trying again."
            }
        }
    }

    var canPublish: Bool { media.canPlayVoiceMusic(roomID: context.roomID, session: context.session) }

    func catalog(in store: KakaNativeStore) async throws -> [Track] {
        let payload = try await request("list", in: store)
        guard payload is [String: Any] || payload is [[String: Any]] || payload is NSNull else { throw Failure.unavailable }
        var seen = Set<Int64>()
        return KakaRoomFields.rows(payload, keys: ["rows", "records", "list", "data", "result", "items"])
            .prefix(250)
            .compactMap(Track.init)
            .filter { seen.insert($0.id).inserted }
    }

    func settings(in store: KakaNativeStore) async throws -> Settings {
        let payload = try await request("settings", in: store)
        guard let fields = payload as? [String: Any],
              let enabled = KakaVoiceManagementContext.flag(fields, "isEnabled") else { throw Failure.unavailable }
        if let reported = KakaRoomFields.id(fields, keys: ["roomId"]), reported != context.roomID { throw Failure.unavailable }
        return Settings(enabled: enabled, current: KakaRoomFields.id(fields, keys: ["currentSongId"]),
                        title: String(KakaRoomFields.text(fields, "songName").prefix(120)),
                        playing: KakaRemoteClient.userID(fields["playStatus"]) == 1,
                        volume: KakaRemoteClient.userID(fields["volume"]).flatMap { (0...100).contains($0) ? $0 : nil })
    }

    func apply(_ change: Change, in store: KakaNativeStore) async throws {
        switch change {
        case .enabled(let enable):
            try await context.requirePermission(in: store)
            try await mutate("enableMusic", fields: try identity(in: store, extra: ["isEnable": enable ? 1 : 0]), in: store)
            if !enable { media.stopVoiceMusic(roomID: context.roomID, session: context.session) }
        case .liked(let track, let liked):
            try await mutate("like", fields: try identity(in: store, extra: ["songId": track.id, "like": liked ? 1 : 0]), in: store)
        case .play(let track):
            try await context.requirePermission(in: store)
            guard canPublish else { throw Failure.microphone }
            guard try await settings(in: store).enabled else { throw Failure.disabled }
            let latest = try await catalog(in: store)
            guard let selected = latest.first(where: { $0.id == track.id && $0.name == track.name }), let url = selected.url else {
                throw Failure.expiredTrack
            }
            guard canPublish else { throw Failure.microphone }
            try await mutate("play", fields: ["songId": track.id], in: store)
            guard context.state(in: store) != nil, canPublish else { throw Failure.microphone }
            do { try media.playVoiceMusic(url, roomID: context.roomID, session: context.session) }
            catch { throw Failure.playback }
        case .upload(let file):
            let owner = try await context.requirePermission(in: store).userID
            try await upload(file, owner: owner, in: store)
        }
    }

    private func upload(_ file: URL, owner: Int64, in store: KakaNativeStore) async throws {
        let suffix = file.pathExtension.lowercased()
        let types = ["m4a": "audio/mp4", "aac": "audio/aac", "wav": "audio/wav", "mp3": "audio/mpeg"]
        guard file.isFileURL, owner > 0, let contentType = types[suffix] else { throw Failure.fileType }
        let name = String(file.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !name.isEmpty, name.rangeOfCharacter(from: .controlCharacters) == nil else { throw Failure.fileType }
        let audio = try await Task.detached(priority: .utility) {
            let count = 10 * 1024 * 1024
            let access = file.startAccessingSecurityScopedResource()
            defer { if access { file.stopAccessingSecurityScopedResource() } }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, (1...count).contains(size) else {
                throw Failure.fileSize
            }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            guard let data = try handle.read(upToCount: count + 1), (1...count).contains(data.count) else { throw Failure.fileSize }
            return data
        }.value
        let url: URL
        do {
            url = try await KakaAvatarUpload.shared.storeMedia(audio, suffix: suffix, contentType: contentType,
                limit: 10 * 1024 * 1024, account: owner, session: context.session) { context.state(in: store) != nil }
        } catch is KakaAvatarUpload.Failure {
            throw Failure.upload
        }
        try await context.requirePermission(in: store)
        try await mutate("uploadLocalMusic", fields: ["songName": name, "musicUrl": url.absoluteString], in: store)
    }

    private func identity(in store: KakaNativeStore, extra: [String: Any]) throws -> [String: Any] {
        guard let state = context.state(in: store), state.hasRoomIdentity else { throw Failure.unavailable }
        var fields = extra
        fields["yxRoomId"] = state.messagingRoom
        fields["roomTempId"] = state.templateID
        return fields
    }

    private func mutate(_ command: String, fields: [String: Any], in store: KakaNativeStore) async throws {
        let result = try await request(command, fields: fields, in: store)
        if let fields = result as? [String: Any] {
            if KakaVoiceManagementContext.flag(fields, "success") == false { throw Failure.unavailable }
        } else if let accepted = result as? Bool, !accepted {
            throw Failure.unavailable
        }
    }

    private func request(_ command: String, fields: [String: Any] = [:], in store: KakaNativeStore) async throws -> Any {
        guard context.state(in: store) != nil else { throw CancellationError() }
        var body = fields
        body["roomId"] = context.roomID
        let data = try await KakaAccountStore.shared.call(path: "/sapi/weidou/v1/client/party/music/" + command,
                                                         body: try KakaRemoteClient.json(body), session: context.session)
        guard context.state(in: store) != nil else { throw CancellationError() }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private static func secureURL(_ text: String) -> URL? {
        guard text.utf8.count <= 2048, let url = URL(string: text), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.fragment == nil else { return nil }
        return url
    }
}

@MainActor
struct KakaVoiceRoomMusicSheet: View {
    @EnvironmentObject private var store: KakaNativeStore
    let music: KakaVoiceRoomMusic
    @ObservedObject private var media = KakaNativeRoomRuntime.shared.media
    @State private var tracks: [KakaVoiceRoomMusic.Track] = []
    @State private var settings: KakaVoiceRoomMusic.Settings?
    @State private var canManage = false
    @State private var busy = false
    @State private var importing = false
    @State private var feedback = ""

    var body: some View {
        KakaRoomSheet(title: "Room music", locked: busy) {
            if let settings { playback(settings) }
            if settings != nil, tracks.isEmpty, !busy { Text("No tracks in this room yet.").foregroundStyle(KakaTheme.muted) }
            ForEach(tracks) { track in trackRow(track) }
            if busy { KakaRhythmProgress(title: settings == nil ? "Loading room music" : "Updating room music") }
            if !feedback.isEmpty { Text(feedback).font(.footnote).foregroundStyle(KakaTheme.muted) }
            else if media.voiceMusicPlaybackFailed {
                Text("The track couldn’t be shared through the room. Choose another track or try again.")
                    .font(.footnote).foregroundStyle(KakaTheme.muted)
            }
            KakaRoomButton(title: "Refresh playlist") { Task { await update() } }.disabled(busy)
        }
        .task { await update() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url): Task { await update(.upload(url)) }
            case .failure: feedback = "The audio file couldn’t be opened."
            }
        }
    }

    private func playback(_ settings: KakaVoiceRoomMusic.Settings) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(settings.enabled && settings.playing && !settings.title.isEmpty ? settings.title : "Nothing playing")
                .font(.headline)
            Text(settings.enabled ?
                 (settings.volume.map { "Room volume · \($0)%" } ?? "Music plays through the room audio") : "Room music is off")
                .font(.caption).foregroundStyle(KakaTheme.muted)
            if canManage {
                if settings.enabled, !music.canPublish {
                    Text("Take a mic seat and turn on your mic to play music.")
                        .font(.caption).foregroundStyle(KakaTheme.muted)
                }
                KakaRoomButton(title: settings.enabled ? "Turn music off" : "Enable music", selected: !settings.enabled) {
                    Task { await update(.enabled(!settings.enabled)) }
                }
                .disabled(busy)
                KakaRoomButton(title: "Import track") { importing = true }.disabled(busy)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func trackRow(_ track: KakaVoiceRoomMusic.Track) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(track.name).font(.subheadline.weight(.semibold))
            if settings?.current == track.id, settings?.enabled == true, settings?.playing == true {
                Text("Current room track").font(.caption).foregroundStyle(KakaTheme.muted)
            } else if let duration = track.duration {
                Text(String(format: "%lld:%02lld", duration / 60, duration % 60))
                    .font(.caption.monospacedDigit()).foregroundStyle(KakaTheme.muted)
            }
            KakaRoomActionGroup {
                if canManage, settings?.enabled == true, track.url != nil {
                    KakaRoomButton(title: "Play", selected: true) { Task { await update(.play(track)) } }
                        .accessibilityLabel("Play \(track.name)")
                        .disabled(!music.canPublish || busy)
                }
                KakaRoomButton(title: track.liked ? "Liked" : "Like", selected: track.liked) {
                    Task { await update(.liked(track, !track.liked)) }
                }
                .accessibilityLabel(track.liked ? "Remove like from \(track.name)" : "Like \(track.name)")
                .accessibilityAddTraits(track.liked ? .isSelected : [])
                .disabled(busy)
            }
        }
        .padding(.vertical, 7)
    }

    private func update(_ change: KakaVoiceRoomMusic.Change? = nil) async {
        guard !busy, music.context.state(in: store) != nil else { return }
        busy = true
        feedback = ""
        defer { busy = false }
        do {
            if let change { try await music.apply(change, in: store) }
            let current = try await music.settings(in: store)
            let catalog = try await music.catalog(in: store)
            let role = try? await music.context.requirePermission(in: store)
            guard music.context.state(in: store) != nil else { return }
            canManage = role?.canManage == true
            settings = current
            tracks = catalog
        } catch {
            guard music.context.state(in: store) != nil else { return }
            store.expireIfNeeded(error)
            feedback = store.message(error)
        }
    }
}
