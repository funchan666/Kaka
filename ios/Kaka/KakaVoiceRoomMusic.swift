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

    private nonisolated static func secureURL(_ text: String) -> URL? {
        guard text.utf8.count <= 2048, let url = URL(string: text), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.fragment == nil else { return nil }
        return url
    }
}

@MainActor
struct KakaVoiceRoomMusicSheet: View {
    @EnvironmentObject private var store: KakaNativeStore
    @Environment(\.dynamicTypeSize) private var textSize
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
            nowPlaying
            if let settings, canManage { musicActions(settings) }
            if busy { KakaRhythmProgress(title: settings == nil ? "Loading room music" : "Updating room music") }
            if !feedback.isEmpty {
                feedbackRow(feedback)
            } else if media.voiceMusicPlaybackFailed {
                feedbackRow("The track couldn’t be shared through the room. Choose another track or try again.")
            }
            playlist
        }
        .task { await update() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url): Task { await update(.upload(url)) }
            case .failure: feedback = "The audio file couldn’t be opened."
            }
        }
    }

    private var nowPlaying: some View {
        let playing = settings?.enabled == true && settings?.playing == true
        let title = settings?.title ?? ""
        let shape = RoundedRectangle(cornerRadius: 22)
        return VStack(alignment: .leading, spacing: 6) {
            if let settings {
                Text(playing ? "Now playing" : settings.enabled ? "On standby" : "Music off")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(KakaTheme.voiceAccent)
                if playing, !title.isEmpty {
                    Text(title).font(.title2.weight(.semibold))
                }
                if settings.enabled, let volume = settings.volume {
                    Text("Room volume · \(volume)%").font(.caption).foregroundStyle(KakaTheme.muted)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 154, alignment: .bottomLeading)
        .background {
            GeometryReader { geometry in
                KakaNativeImage(asset: "room-music-cover.jpg")
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            }
            .overlay(LinearGradient(colors: [.clear, KakaTheme.base.opacity(0.94)], startPoint: .top, endPoint: .bottom))
            .accessibilityHidden(true)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(KakaTheme.accent.opacity(0.24)).allowsHitTesting(false))
        .accessibilityElement(children: .combine)
    }

    private func musicActions(_ settings: KakaVoiceRoomMusic.Settings) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            KakaRoomActionGroup {
                KakaRoomButton(title: settings.enabled ? "Turn music off" : "Enable music",
                               asset: settings.enabled ? "action-stop.png" : "action-play.png",
                               selected: !settings.enabled) {
                    Task { await update(.enabled(!settings.enabled)) }
                }
                KakaRoomButton(title: "Import track", asset: "action-create.png") { importing = true }
            }
            .disabled(busy)
            if settings.enabled, !music.canPublish {
                Text("Take a mic seat and turn on your mic to play music.")
                    .font(.footnote).foregroundStyle(KakaTheme.muted)
            }
        }
    }

    private var playlist: some View {
        VStack(alignment: .leading, spacing: 10) {
            KakaRoomActionGroup {
                Text("Playlist")
                    .font(.headline).accessibilityAddTraits(.isHeader)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    Task { await update() }
                } label: {
                    Text("Refresh").font(.subheadline.weight(.semibold))
                        .foregroundStyle(KakaTheme.voiceAccent)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh playlist")
                .disabled(busy)
            }
            if settings != nil, tracks.isEmpty, !busy {
                Text("No tracks in this room yet.")
                    .font(.subheadline).foregroundStyle(KakaTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            }
            ForEach(tracks) { track in trackRow(track) }
        }
    }

    private func trackRow(_ track: KakaVoiceRoomMusic.Track) -> some View {
        let active = settings?.current == track.id && settings?.enabled == true && settings?.playing == true
        let shape = RoundedRectangle(cornerRadius: 14)
        return KakaRoomActionGroup {
            HStack(spacing: 10) {
                KakaNativeImage(asset: active ? "stage-signal.png" : "room-listen.png")
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .frame(width: 39, height: 39)
                    .background(KakaTheme.voiceAccent.opacity(active ? 0.18 : 0.06), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.name).font(.subheadline.weight(.semibold))
                    if active {
                        Text("Now playing").font(.caption).foregroundStyle(KakaTheme.voiceAccent)
                    } else if let duration = track.duration {
                        Text(String(format: "%lld:%02lld", duration / 60, duration % 60))
                            .font(.caption.monospacedDigit()).foregroundStyle(KakaTheme.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(textSize.isAccessibilitySize ? nil : 3)
                .accessibilityElement(children: .combine)
            }
            HStack(spacing: 4) {
                if canManage, settings?.enabled == true, track.url != nil {
                    KakaStageIconButton(title: "Play \(track.name)", artwork: "action-play.png", accent: KakaTheme.voiceAccent) {
                        Task { await update(.play(track)) }
                    }
                    .disabled(!music.canPublish || busy)
                    .opacity(!music.canPublish || busy ? 0.5 : 1)
                }
                KakaStageIconButton(title: track.liked ? "Remove like from \(track.name)" : "Like \(track.name)",
                                    artwork: track.liked ? "action-check.png" : "stage-follow.png",
                                    accent: track.liked ? KakaTheme.accent : nil) {
                    Task { await update(.liked(track, !track.liked)) }
                }
                .accessibilityAddTraits(track.liked ? .isSelected : [])
                .disabled(busy)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KakaTheme.surface, in: shape)
        .overlay(shape.strokeBorder(active ? KakaTheme.voiceAccent.opacity(0.55) : KakaTheme.line).allowsHitTesting(false))
    }

    private func feedbackRow(_ message: String) -> some View {
        Text(message)
            .font(.footnote).foregroundStyle(KakaTheme.liveAccent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityAddTraits(.updatesFrequently)
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
