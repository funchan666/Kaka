import SwiftUI
import UIKit
import AVFoundation

struct KakaNativeHost: Identifiable, Equatable {
    let id: Int64
    let name: String
    let bio: String
    let portrait: URL?
    let style: String

    static func parse(_ source: [String: Any], expectedID: Int64? = nil, party: Bool = false) -> Self? {
        let value = ["venueBrief", "astralPortrait", "detail", "profile", "user"].lazy.compactMap {
            source[$0] as? [String: Any]
        }.first ?? source
        let remoteID = KakaRoomFields.id(value, keys: party ? ["userId", "id"] : ["voyagerBadge", "orbitMark"])
        if let expectedID, let remoteID, expectedID != remoteID { return nil }
        guard let id = remoteID ?? expectedID, id > 0 else { return nil }
        let name = KakaRoomFields.text(value, "nickname", "castMoniker", "nickName", "hostName", "ownerName")
        return Self(
            id: id,
            name: name.isEmpty ? "Host" : name,
            bio: KakaRoomFields.text(value, "cipherSeal", "showSummary", "signature", "description"),
            portrait: KakaRoomFields.url(KakaRoomFields.text(value, "cometGlyph", "spotlightFace", "icon", "avatar")),
            style: KakaRoomFields.text(value, "rapStyle", "style")
        )
    }
}

struct KakaNativeRoom: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case live, voice

        var title: String { self == .live ? "Live Rooms" : "Voice Rooms" }
        var art: String { self == .live ? "stage.jpg" : "voice.jpg" }
        var actionArt: String { self == .live ? "room-watch.png" : "room-listen.png" }
    }

    let kind: Kind
    let serverID: Int64
    let title: String
    let cover: URL?
    let host: KakaNativeHost?
    let format: String
    let genre: String
    let bpm: Int?
    let viewers: Int?
    let topic: String
    let description: String
    let exercise: String
    let style: String
    let locked: Bool
    let channel: String

    var id: String { kind == .voice ? "party-\(serverID)" : String(serverID) }

    static func parse(_ value: [String: Any], kind: Kind) -> Self? {
        let party = kind == .voice
        guard let id = KakaRoomFields.id(value, keys: party ? ["id", "roomId"] : ["habitatTag", "orbitMark"]),
              !party || KakaRemoteClient.userID(value["roomStatus"]) != 2 else { return nil }
        var hostData: [String: Any]
        if party {
            hostData = value
            for key in ["owner", "anchor"] {
                if let fields = value[key] as? [String: Any] {
                    hostData.merge(fields) { _, updated in updated }
                }
            }
            hostData.removeValue(forKey: "id")
        } else {
            hostData = (value["anchor"] as? [String: Any]) ?? (value["anchorInfo"] as? [String: Any]) ?? value
        }
        let host = KakaNativeHost.parse(hostData,
                                        expectedID: KakaRoomFields.id(value, keys: [party ? "ownerId" : "voyagerBadge"]),
                                        party: party)
        let label = party ? KakaRoomFields.text(value, "roomName") : KakaRoomFields.text(value, "programTitle", "roomName")
        let title = label.isEmpty ? (host?.name ?? "Room \(id)") : label
        let cover = party ? KakaRoomFields.text(value, "roomAvatar", "bigImgUrl") : KakaRoomFields.text(value, "stageBackdrop", "roomCover")
        let rawBPM = Int(KakaRoomFields.text(value, "bpm"))
        let viewers = Int(KakaRoomFields.text(value, "fanGather", "onlineNum", "onlineCount", "memberCount"))
        let topic = KakaRoomFields.text(value, "topic")
        let format = KakaRoomFields.text(value, "format")
        let style = KakaRoomFields.text(value, "style")
        return Self(
            kind: kind, serverID: id, title: title,
            cover: KakaRoomFields.url(cover) ?? host?.portrait, host: host,
            format: format.isEmpty ? (party ? "Voice room" : "Live") : format,
            genre: KakaRoomFields.text(value, "genre"),
            bpm: rawBPM.flatMap { (60...180).contains($0) ? $0 : nil },
            viewers: viewers.flatMap { $0 >= 0 ? $0 : nil },
            topic: topic.isEmpty ? title : topic,
            description: KakaRoomFields.text(value, "description", "showSummary", "roomSubtitle", "greetingMessage", "announcement"),
            exercise: KakaRoomFields.text(value, "exercise"),
            style: style.isEmpty ? "freestyle" : style,
            locked: party && ["lockFlag", "needPassword", "isLock", "locked"].contains { KakaRoomFields.flag(value[$0]) },
            channel: KakaRoomFields.text(value, "studioRoute", "venueKey", "agoraChannelId")
        )
    }
}

private enum KakaRoomFields {
    static func text(_ fields: [String: Any], _ keys: String...) -> String {
        for key in keys {
            if let string = fields[key] as? String {
                let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
            if let number = KakaRemoteClient.userID(fields[key]) { return String(number) }
        }
        return ""
    }

    static func id(_ fields: [String: Any], keys: [String]) -> Int64? {
        keys.lazy.compactMap { KakaRemoteClient.userID(fields[$0]) }.first { $0 > 0 }
    }

    static func flag(_ value: Any?) -> Bool {
        if let value = value as? NSNumber { return value.intValue == 1 }
        if let value = value as? String { return ["1", "true"].contains(value.lowercased()) }
        return false
    }

    static func url(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func rows(_ source: Any, keys: [String]) -> [[String: Any]] {
        if let rows = source as? [[String: Any]] { return rows }
        guard let fields = source as? [String: Any] else { return [] }
        for key in keys {
            if let rows = fields[key] as? [[String: Any]] { return rows }
            if let wrapper = fields[key] as? [String: Any] {
                return rows(wrapper, keys: keys)
            }
        }
        return []
    }
}

@MainActor
struct KakaNativeDirectoryView: View {
    @EnvironmentObject private var store: KakaNativeStore
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.scenePhase) private var scenePhase
    let kind: KakaNativeRoom.Kind

    @State private var filter = RoomFilter.all
    @State private var rooms: [KakaNativeRoom] = []
    @State private var activeLoad: RoomLoad?
    @State private var loadFailure: (operation: RoomLoad, message: String)?
    @State private var loadingFollowing = false
    @State private var followingError = ""
    @State private var hasMore = false
    @State private var requiresManualPaging = false
    @State private var page = 0
    @State private var initialSession: UUID?
    @State private var lastVisitedVoiceRoom: String?

    private enum RoomLoad: Equatable {
        case refresh, more
    }

    private struct PageRequest: Equatable {
        let session: UUID
        let filter: RoomFilter
        let page: Int
    }

    private enum LivePagePreference: PreferenceKey {
        static let scrollSpace = "KakaLiveRoomsViewport"
        static let defaultValue: PageRequest? = nil

        static func reduce(value: inout PageRequest?, nextValue: () -> PageRequest?) {
            value = nextValue() ?? value
        }
    }

    private var loading: Bool { activeLoad != nil }

    private enum RoomFilter: String, CaseIterable, Identifiable {
        case all, following, watched, open, locked, openMic, freestyle, beatLab

        var id: Self { self }
        var name: String {
            switch self {
            case .all: return "All rooms"
            case .following: return "Following"
            case .watched: return "Most watched"
            case .open: return "Open rooms"
            case .locked: return "Locked"
            case .openMic: return "Open mic"
            case .freestyle: return "Freestyle"
            case .beatLab: return "Beat lab"
            }
        }

        var genre: String? {
            switch self {
            case .openMic: return "open-mic"
            case .freestyle: return "cypher"
            case .beatLab: return "beats"
            default: return nil
            }
        }
    }

    private var visibleRooms: [KakaNativeRoom] {
        rooms.filter { !store.isHidden($0.id) }
    }

    private var filters: [RoomFilter] {
        if kind == .voice {
            return [.all, .following, .open] + (filter == .locked || visibleRooms.contains(where: \.locked) ? [.locked] : [])
        }
        return [.all, .following, .watched] + [.openMic, .freestyle, .beatLab].filter { option in
            filter == option || visibleRooms.contains(where: { $0.genre == option.genre })
        }
    }

    private var spotlight: [KakaNativeRoom] {
        guard kind == .live, filter == .all, visibleRooms.count >= 4 else { return [] }
        let picks = visibleRooms.enumerated().filter { $0.element.cover != nil }.sorted {
            let first = $0.element.viewers ?? 0
            let second = $1.element.viewers ?? 0
            return first == second ? $0.offset < $1.offset : first > second
        }.prefix(min(3, visibleRooms.count - 2)).map(\.element)
        return picks.count >= 2 ? picks : []
    }

    private var results: [KakaNativeRoom] {
        let featured = Set(spotlight.map(\.id))
        let filtered = visibleRooms.filter { room in
            switch filter {
            case .all: return !featured.contains(room.id)
            case .following: return room.host.map { store.followedIDs.contains($0.id) } ?? false
            case .watched: return (room.viewers ?? 0) > 0
            case .open: return !room.locked
            case .locked: return room.locked
            default: return room.genre == filter.genre
            }
        }
        return filter == .watched ? filtered.sorted { ($0.viewers ?? 0) > ($1.viewers ?? 0) } : filtered
    }

    var body: some View {
        GeometryReader { geometry in
            let gutter: CGFloat = geometry.size.width < 350 ? 16 : 20
            let contentWidth = max(1, min(geometry.size.width, 720) - gutter * 2)
            directory(viewport: CGSize(width: contentWidth, height: geometry.size.height), gutter: gutter)
        }
        .task(id: store.session?.token) {
            guard initialSession != store.session?.token || page == 0 else { return }
            initialSession = store.session?.token
            page = 0
            hasMore = false
            requiresManualPaging = false
            rooms = []
            await load()
        }
    }

    private func directory(viewport: CGSize, gutter: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if kind == .live {
                    liveHeader
                    let featured = spotlight
                    if let lead = featured.first {
                        featuredRooms(lead: lead, supporting: featured.dropFirst(), width: viewport.width)
                    }
                } else {
                    voiceHeader(width: viewport.width)
                }
                roomResults(viewport: viewport)
            }
            .padding(.horizontal, gutter)
            .padding(.top, 4)
            .padding(.bottom, 12)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .coordinateSpace(name: LivePagePreference.scrollSpace)
        .onPreferenceChange(LivePagePreference.self) { request in
            guard let request else { return }
            Task { @MainActor in
                guard request.session == store.session?.token, request.filter == filter, request.page == page,
                      canPageAutomatically, !results.isEmpty else { return }
                await load(.more)
            }
        }
        .accessibilityLabel(kind.title)
        .refreshable {
            await load()
            if filter == .following { await loadFollowing() }
        }
    }

    private func roomResults(viewport: CGSize) -> some View {
        let shownRooms = results
        let title: String? = kind == .voice
            ? (shownRooms.isEmpty ? nil : "Room lineup")
            : (spotlight.isEmpty ? nil : "More rooms")
        let columns = roomColumns(width: viewport.width)
        return VStack(alignment: .leading, spacing: 12) {
            if title != nil || !shownRooms.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let title {
                        Text(title)
                            .font(.title3.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 0)
                    }
                    if !shownRooms.isEmpty {
                        Text("\(shownRooms.count) \(shownRooms.count == 1 ? "room" : "rooms")")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(KakaTheme.muted)
                    }
                }
            }
            if shownRooms.isEmpty {
                if kind == .live {
                    liveDirectoryFeedback(columns: columns)
                } else {
                    voiceDirectoryFeedback(columns: columns)
                }
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: kind == .voice ? 10 : 18) {
                    ForEach(shownRooms) { room in
                        if kind == .live {
                            liveRoomButton(room, singleColumn: columns.count == 1)
                        } else {
                            voiceRoomButton(room)
                        }
                    }
                }
                if kind == .live {
                    liveDirectoryFooter(columns: columns, viewportHeight: viewport.height)
                } else if let loadFailure {
                    Text(loadFailure.message).font(.footnote).foregroundStyle(KakaTheme.muted)
                    directoryStateButton("Try again") { Task { await load(loadFailure.operation) } }
                } else if filter == .following, !followingError.isEmpty {
                    Text(followingError).font(.footnote).foregroundStyle(KakaTheme.muted)
                    directoryStateButton("Retry following") { Task { await loadFollowing() } }
                }
            }
        }
    }

    private func roomColumns(width: CGFloat) -> [GridItem] {
        let spacing: CGFloat = kind == .voice ? 16 : 12
        let minimumWidth: CGFloat = kind == .voice ? 284 : 148
        let count = textSize.isAccessibilitySize ? 1 : max(1, Int((width + spacing) / (minimumWidth + spacing)))
        return Array(repeating: GridItem(.flexible(minimum: 0), spacing: spacing, alignment: .top), count: count)
    }

    private var directoryAccent: Color {
        kind == .live ? KakaTheme.accent : Color(red: 0.64, green: 0.87, blue: 0.94)
    }

    private func voiceHeader(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if textSize.isAccessibilitySize || width < 290 {
                VStack(alignment: .leading, spacing: 0) {
                    directoryTitle("Voice rooms")
                    verseLabLink
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    directoryTitle("Voice rooms")
                    Spacer(minLength: 0)
                    verseLabLink
                }
            }
            if let target = visibleRooms.first(where: { $0.id == lastVisitedVoiceRoom }) ?? visibleRooms.first {
                quickPractice(target, width: width)
            }
            directoryFilterBar
        }
    }

    private var verseLabLink: some View {
        Button { store.select(.write) } label: {
            HStack(spacing: 6) {
                KakaNativeImage(asset: "room-write.png")
                    .frame(width: 19, height: 19)
                    .accessibilityHidden(true)
                Text("Verse Lab").font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(directoryAccent)
            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func quickPractice(_ room: KakaNativeRoom, width: CGFloat) -> some View {
        Button { open(room) } label: {
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Quick practice")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(KakaTheme.ink)
                    Text(room.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(directoryAccent)
                        .lineLimit(textSize.isAccessibilitySize ? 3 : 2)
                    if room.locked {
                        Text("Locked room").font(.caption).foregroundStyle(KakaTheme.muted)
                    }
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                if !textSize.isAccessibilitySize {
                    KakaNativeImage(asset: room.kind.actionArt)
                        .frame(width: 31, height: 31)
                        .accessibilityHidden(true)
                }
            }
            .padding(16)
            .frame(minHeight: min(188, max(134, width * 0.37)), alignment: .bottomLeading)
            .background {
                GeometryReader { artwork in
                    KakaNativeImage(asset: "voice-deck.jpg")
                        .scaledToFill()
                        .frame(width: artwork.size.width, height: artwork.size.height)
                        .clipped()
                        .overlay {
                            LinearGradient(stops: [
                                .init(color: KakaTheme.base.opacity(0.96), location: 0),
                                .init(color: KakaTheme.base.opacity(0.78), location: 0.58),
                                .init(color: KakaTheme.base.opacity(textSize.isAccessibilitySize ? 0.62 : 0.30), location: 1),
                            ], startPoint: .leading, endPoint: .trailing)
                        }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .background(KakaTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Quick practice, \(room.title)")
        .accessibilityValue(room.locked ? "Locked room" : "")
    }

    private func directoryTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.largeTitle.weight(.bold))
            .tracking(-0.7)
            .foregroundStyle(KakaTheme.ink)
            .accessibilityAddTraits(.isHeader)
    }

    private var liveHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            directoryTitle("Live rooms")
            directoryFilterBar
        }
    }

    private var directoryFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 20) {
                ForEach(filters) { item in
                    Button { selectFilter(item) } label: {
                        Text(item == .all && kind == .live ? "All live" : item.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(filter == item ? directoryAccent : KakaTheme.muted)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                            .overlay(alignment: .bottom) {
                                if filter == item {
                                    directoryAccent.frame(height: 2).allowsHitTesting(false)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(filter == item ? .isSelected : [])
                }
            }
        }
        .background(alignment: .bottom) { KakaTheme.muted.opacity(0.16).frame(height: 1) }
        .accessibilityLabel("Filter rooms")
    }

    private func selectFilter(_ item: RoomFilter) {
        if filter != item { requiresManualPaging = false }
        filter = item
        if item == .following { Task { await loadFollowing() } }
    }

    private var checkingFollowing: Bool {
        filter == .following && (loadingFollowing || (!store.followingLoaded && followingError.isEmpty))
    }

    private var waitingForRooms: Bool {
        loading || (loadFailure == nil && (page == 0 || checkingFollowing))
    }

    @ViewBuilder
    private func liveDirectoryFeedback(columns: [GridItem]) -> some View {
        if waitingForRooms {
            let title = activeLoad == .more ? "Checking more rooms…" : checkingFollowing && page > 0
                ? "Checking followed hosts…" : "Finding live rooms…"
            KakaDirectoryLoading(title: title, columns: columns, showsSpotlight: filter == .all && page == 0)
        } else if let loadFailure {
            let title = loadFailure.operation == .more ? "Couldn’t load more rooms" : "Couldn’t load live rooms"
            directoryStatusPanel(title, detail: loadFailure.message) {
                directoryStateButton("Try again", prominent: true) { Task { await load(loadFailure.operation) } }
            }
        } else if filter == .following, !followingError.isEmpty {
            directoryStatusPanel("Couldn’t load followed hosts", detail: followingError) {
                directoryStateButton("Try again", prominent: true) { Task { await loadFollowing() } }
                directoryStateButton("Browse all live rooms") { selectFilter(.all) }
            }
        } else {
            let copy = liveEmptyCopy
            directoryStatusPanel(copy.title, detail: copy.detail) {
                if filter != .all {
                    directoryStateButton("Browse all live rooms", prominent: true) { selectFilter(.all) }
                } else if !hasMore {
                    directoryStateButton("Refresh live rooms", prominent: true) { Task { await load() } }
                }
                if hasMore && (filter != .following || !store.followedIDs.isEmpty) {
                    directoryStateButton("Check more rooms") { Task { await load(.more) } }
                }
                if rooms.contains(where: { store.isHidden($0.id) }) {
                    directoryStateButton("Manage hidden rooms") { store.select(.profile) }
                }
            }
        }
    }

    private var liveEmptyCopy: (title: String, detail: String) {
        switch filter {
        case .all:
            if !rooms.isEmpty {
                return ("No visible live rooms", "You can review hidden rooms from your profile.")
            }
            return hasMore
                ? ("No live rooms found yet", "Check more rooms to see the rest of the lineup.")
                : ("The stage is quiet", "Refresh to check if anyone has gone live.")
        case .following:
            if store.followedIDs.isEmpty {
                return ("Find your first host", "Follow a host from any live room to find their streams here.")
            }
            return hasMore
                ? ("No followed hosts in these rooms", "Check more rooms to look for hosts you follow.")
                : ("No followed rooms to show", "Rooms from hosts you follow will appear here when available.")
        case .watched:
            return ("No rooms ranked yet", "Rooms appear here when they report viewers.")
        default:
            return ("No rooms in this category", "Browse the full lineup for other live rooms.")
        }
    }

    private func directoryStatusPanel<Actions: View>(
        _ title: String, detail: String, artwork: String? = "LiveEmptyStage", @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let artwork {
                KakaRoomArt(asset: artwork, remote: nil, ratio: 2.4)
            }
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(KakaTheme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(KakaTheme.muted)
                }
                .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 2, content: actions)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
        .background(KakaTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
    }

    private func directoryStateButton(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(prominent ? KakaTheme.base : directoryAccent)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, prominent ? 14 : 0)
                .padding(.vertical, 8)
                .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                .background(prominent ? directoryAccent : .clear, in: RoundedRectangle(cornerRadius: 11))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var canPageAutomatically: Bool {
        hasMore && !requiresManualPaging && !loading && loadFailure == nil
            && store.tab == .live && store.route == nil && scenePhase == .active
            && (filter != .following || (!loadingFollowing && followingError.isEmpty))
    }

    @ViewBuilder
    private func liveDirectoryFooter(columns: [GridItem], viewportHeight: CGFloat) -> some View {
        if activeLoad == .more {
            KakaDirectoryLoading(title: "Loading more rooms…", columns: columns)
        } else if let loadFailure {
            Text(loadFailure.message).font(.footnote).foregroundStyle(KakaTheme.muted)
            directoryStateButton("Try again") { Task { await load(loadFailure.operation) } }
        } else if filter == .following, !followingError.isEmpty {
            Text(followingError).font(.footnote).foregroundStyle(KakaTheme.muted)
            directoryStateButton("Retry following") { Task { await loadFollowing() } }
        } else if hasMore {
            if requiresManualPaging {
                directoryStateButton("Check more rooms") { Task { await load(.more) } }
                    .disabled(loading)
            } else if canPageAutomatically, let session = store.session?.token, viewportHeight > 0 {
                GeometryReader { geometry in
                    let frame = geometry.frame(in: CoordinateSpace.named(LivePagePreference.scrollSpace))
                    let prefetchDistance = min(112, viewportHeight * 0.2)
                    let isNearBottom = frame.height > 0 && frame.maxY >= 0 && frame.minY <= viewportHeight + prefetchDistance
                    let request = isNearBottom
                        ? PageRequest(session: session, filter: filter, page: page) : nil
                    Color.clear.preference(key: LivePagePreference.self, value: request)
                }
                .frame(height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        } else if !loading {
            Text("End of list")
                .font(.caption)
                .foregroundStyle(KakaTheme.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func voiceDirectoryFeedback(columns: [GridItem]) -> some View {
        let artwork = visibleRooms.isEmpty ? "voice-deck.jpg" : nil
        if waitingForRooms {
            KakaDirectoryLoading(title: checkingFollowing && page > 0 ? "Checking followed hosts…" : "Finding voice rooms…",
                                 columns: columns, kind: .voice, accent: directoryAccent)
        } else if let loadFailure {
            directoryStatusPanel("Couldn’t load voice rooms", detail: loadFailure.message, artwork: artwork) {
                directoryStateButton("Try again", prominent: true) { Task { await load(loadFailure.operation) } }
            }
        } else if filter == .following, !followingError.isEmpty {
            directoryStatusPanel("Couldn’t load followed hosts", detail: followingError, artwork: artwork) {
                directoryStateButton("Try again", prominent: true) { Task { await loadFollowing() } }
                directoryStateButton("Browse all voice rooms") { selectFilter(.all) }
            }
        } else {
            let copy = voiceEmptyCopy
            directoryStatusPanel(copy.title, detail: copy.detail, artwork: artwork) {
                if filter == .all {
                    directoryStateButton("Refresh voice rooms", prominent: true) { Task { await load() } }
                } else {
                    directoryStateButton("Browse all voice rooms", prominent: true) { selectFilter(.all) }
                }
                if rooms.contains(where: { store.isHidden($0.id) }) {
                    directoryStateButton("Manage hidden rooms") { store.select(.profile) }
                }
            }
        }
    }

    private var voiceEmptyCopy: (title: String, detail: String) {
        switch filter {
        case .all:
            return rooms.isEmpty
                ? ("No voice rooms right now", "Check again for new rooms, or open Verse Lab to work on a verse.")
                : ("No visible voice rooms", "You can review hidden rooms from your profile.")
        case .following:
            return store.followedIDs.isEmpty
                ? ("Find voices to follow", "Follow a host from their room to find their voice rooms here.")
                : ("No followed voice rooms", "Rooms from hosts you follow will appear here when available.")
        case .open:
            return ("No open rooms", "Browse all voice rooms to include rooms that need a password.")
        case .locked:
            return ("No locked rooms", "Browse all voice rooms to see what’s open.")
        default:
            return ("No rooms in this category", "Browse all voice rooms to see the rest of the lineup.")
        }
    }

    private func featuredRooms(lead: KakaNativeRoom, supporting: ArraySlice<KakaNativeRoom>, width: CGFloat) -> some View {
        let stacked = textSize.isAccessibilitySize || width < 300
        return VStack(alignment: .leading, spacing: 8) {
            featuredRoomButton(lead, width: width, stacked: stacked)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 10),
                                     count: stacked ? 1 : supporting.count), spacing: 8) {
                ForEach(supporting) { room in
                    supportingRoomButton(room)
                }
            }
        }
    }

    private func featuredRoomButton(_ room: KakaNativeRoom, width: CGFloat, stacked: Bool) -> some View {
        Button { open(room) } label: {
            Group {
                if stacked {
                    VStack(spacing: 0) {
                        KakaRoomArt(asset: "live-deck.jpg", remote: room.cover, ratio: 1.8, cropAlignment: .top)
                        featuredRoomDetails(room)
                    }
                } else {
                    let imageWidth = width * 0.47
                    featuredRoomDetails(room)
                        .frame(minHeight: min(216, max(148, width * 0.43)))
                        .padding(.trailing, imageWidth)
                        .overlay(alignment: .trailing) {
                            GeometryReader { portrait in
                                KakaRoomArt(asset: "live-deck.jpg", remote: room.cover,
                                            ratio: portrait.size.width / max(1, portrait.size.height), cropAlignment: .top)
                            }
                            .frame(width: imageWidth)
                            .allowsHitTesting(false)
                        }
                }
            }
            .background(KakaTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Spotlight, watch \(room.title)")
        .accessibilityValue(liveRoomSubtitle(room) ?? "")
    }

    private func featuredRoomDetails(_ room: KakaNativeRoom) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Spotlight")
                .font(.caption2.weight(.bold))
                .tracking(1.5)
                .textCase(.uppercase)
                .foregroundStyle(KakaTheme.accent)
            VStack(alignment: .leading, spacing: 5) {
                Text(room.title)
                    .font(.title2.weight(.bold))
                    .lineLimit(textSize.isAccessibilitySize ? 3 : 2)
                if let subtitle = liveRoomSubtitle(room) {
                    Text(subtitle).font(.caption).foregroundStyle(KakaTheme.muted).lineLimit(1)
                }
            }
            HStack(spacing: 5) {
                KakaNativeImage(asset: room.kind.actionArt)
                    .frame(width: 17, height: 17)
                    .accessibilityHidden(true)
                Text("Watch live").font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(KakaTheme.accent.opacity(0.14), in: Capsule())
        }
        .foregroundStyle(KakaTheme.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func supportingRoomButton(_ room: KakaNativeRoom) -> some View {
        Button { open(room) } label: {
            HStack(spacing: 9) {
                KakaRoomArt(asset: "live-deck.jpg", remote: room.cover, ratio: 1, cropAlignment: .top)
                    .frame(width: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(room.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(KakaTheme.ink)
            .padding(8)
            .background(KakaTheme.surface.opacity(0.66), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Watch \(room.title)")
    }

    private func liveRoomButton(_ room: KakaNativeRoom, singleColumn: Bool) -> some View {
        Button { open(room) } label: {
            VStack(alignment: .leading, spacing: 8) {
                KakaRoomArt(asset: room.kind.art, remote: room.cover, ratio: singleColumn ? 1.65 : 1.35, cropAlignment: .top)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(room.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                        if let subtitle = liveRoomSubtitle(room) {
                            Text(subtitle).font(.caption).foregroundStyle(KakaTheme.muted).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    KakaNativeImage(asset: room.kind.actionArt)
                        .frame(width: 19, height: 19)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 2)
            }
            .foregroundStyle(KakaTheme.ink)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Watch \(room.title)")
        .accessibilityValue(liveRoomSubtitle(room) ?? "")
    }

    private func liveRoomSubtitle(_ room: KakaNativeRoom) -> String? {
        if let count = room.viewers, count > 0 { return "\(count.formatted()) watching" }
        if let host = room.host, host.name != "Host", host.name.caseInsensitiveCompare(room.title) != .orderedSame {
            return host.name
        }
        return nil
    }

    private func voiceRoomButton(_ room: KakaNativeRoom) -> some View {
        let metadata = voiceRoomMetadata(room)
        return Button { open(room) } label: {
            HStack(spacing: 12) {
                KakaRoomArt(asset: room.kind.art, remote: room.cover, ratio: 1, cropAlignment: .top)
                    .frame(width: textSize.isAccessibilitySize ? 54 : 68)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    Text(room.title)
                        .font(.headline)
                        .foregroundStyle(KakaTheme.ink)
                        .lineLimit(textSize.isAccessibilitySize ? 3 : 2)
                    if !metadata.isEmpty {
                        Text(metadata)
                            .font(.caption)
                            .foregroundStyle(room.locked ? directoryAccent : KakaTheme.muted)
                            .lineLimit(textSize.isAccessibilitySize ? 2 : 1)
                    }
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                if !textSize.isAccessibilitySize {
                    KakaNativeImage(asset: room.kind.actionArt)
                        .frame(width: 24, height: 24)
                        .padding(.trailing, 4)
                        .accessibilityHidden(true)
                }
            }
            .padding(8)
            .background(KakaTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(room.title)")
        .accessibilityValue(metadata)
    }

    private func voiceRoomMetadata(_ room: KakaNativeRoom) -> String {
        var labels = room.locked ? ["Locked room"] : []
        if let host = room.host, host.name != "Host", host.name.caseInsensitiveCompare(room.title) != .orderedSame {
            labels.append(host.name)
        } else if let bpm = room.bpm {
            labels.append("\(bpm) BPM")
        }
        return labels.joined(separator: " · ")
    }

    private func open(_ room: KakaNativeRoom) {
        if room.kind == .voice { lastVisitedVoiceRoom = room.id }
        store.open(.room(room))
    }

    private func load(_ operation: RoomLoad = .refresh) async {
        let append = operation == .more
        guard let token = store.session?.token, !loading, !append || hasMore else { return }
        activeLoad = operation
        loadFailure = nil
        defer { activeLoad = nil }
        let live = kind == .live
        let next = append ? page + 1 : 1
        do {
            let source = try await store.request(live ? "listLiveRooms" : "listVoiceRooms",
                                                 live ? ["stagePage": next, "folioScale": 10, "desertSector": false]
                                                      : ["pageSize": 20, "languageCode": "", "version": "v2"])
            guard store.session?.token == token else { return }
            let values = KakaRoomFields.rows(source, keys: live
                ? ["gridBands", "records", "roster", "data", "result", "nebulaPieces"]
                : ["rows", "records", "list", "data", "result", "items"])
            var result = append ? rooms : []
            for room in values.compactMap({ KakaNativeRoom.parse($0, kind: kind) }) {
                if let index = result.firstIndex(where: { $0.id == room.id }) {
                    result[index] = room
                } else {
                    result.append(room)
                }
            }
            let count = (source as? [String: Any]).flatMap { Int(KakaRoomFields.text($0, "cosmicSum")) } ?? 0
            let previousResultCount = live && append ? results.count : 0
            hasMore = live && (!append || result.count > rooms.count)
                && (count >= result.count && count > 0 ? count > result.count : values.count >= 10)
            rooms = result
            // An unchanged grid leaves the footer in range for another automatic request.
            requiresManualPaging = live && append && hasMore && results.count <= previousResultCount
            store.remember(rooms)
            page = next
        } catch {
            guard !Task.isCancelled, store.session?.token == token else { return }
            loadFailure = (operation, store.message(error))
        }
    }

    private func loadFollowing() async {
        guard let token = store.session?.token, !loadingFollowing else { return }
        loadingFollowing = true
        defer { loadingFollowing = false }
        followingError = ""
        do {
            try await store.loadFollowing(force: true)
        } catch {
            guard !Task.isCancelled, store.session?.token == token else { return }
            followingError = store.message(error)
        }
    }
}

private struct KakaDirectoryLoading: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let columns: [GridItem]
    var showsSpotlight = false
    var kind: KakaNativeRoom.Kind = .live
    var accent = KakaTheme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(KakaTheme.muted)

            TimelineView(.animation(minimumInterval: 1.0 / 18, paused: reduceMotion)) { context in
                let pulse = sin(context.date.timeIntervalSinceReferenceDate * 3.5)
                VStack(alignment: .leading, spacing: 12) {
                    if showsSpotlight, columns.count > 1 {
                        HStack(spacing: 0) {
                            VStack(alignment: .leading, spacing: 10) {
                                Capsule().fill(KakaTheme.accent.opacity(0.24)).frame(width: 44, height: 6)
                                Capsule().fill(KakaTheme.accent.opacity(0.20)).frame(maxWidth: 104).frame(height: 10)
                                Capsule().fill(KakaTheme.accent.opacity(0.17)).frame(width: 62, height: 7)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            KakaTheme.accent.opacity(0.13).frame(maxWidth: .infinity)
                        }
                        .frame(height: 148)
                        .background(KakaTheme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: kind == .voice ? 10 : 18) {
                        ForEach(0..<(columns.count * (kind == .voice ? 2 : 1)), id: \.self) { _ in
                            if kind == .voice {
                                voicePlaceholder
                            } else {
                                VStack(alignment: .leading, spacing: 9) {
                                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                                        .fill(accent.opacity(0.13))
                                        .aspectRatio(columns.count == 1 ? 1.65 : 1.35, contentMode: .fit)
                                    Capsule()
                                        .fill(accent.opacity(0.18))
                                        .frame(width: 64, height: 7)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .opacity(reduceMotion ? 1 : 0.84 + 0.14 * pulse)
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
    }

    private var voicePlaceholder: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(accent.opacity(0.16))
                .frame(width: 68, height: 68)
            VStack(alignment: .leading, spacing: 9) {
                Capsule().fill(accent.opacity(0.24)).frame(maxWidth: 124).frame(height: 9)
                Capsule().fill(accent.opacity(0.14)).frame(maxWidth: 70).frame(height: 7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(KakaTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct KakaRoomArt: View {
    let asset: String
    let remote: URL?
    let ratio: CGFloat
    var cropAlignment: Alignment = .center

    var body: some View {
        GeometryReader { geometry in
            KakaNativeImage(asset: asset, remote: remote)
                .scaledToFill()
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: cropAlignment)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(KakaTheme.surface)
                .clipped()
        }
        .aspectRatio(ratio, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

private struct KakaRoomButton: View {
    let title: String
    var asset: String? = nil
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let asset {
                    KakaNativeImage(asset: asset).frame(width: 23, height: 23).accessibilityHidden(true)
                }
                Text(title).font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 13)
            .frame(minWidth: 44, minHeight: 44)
            .modifier(KakaGlass(interactive: true, radius: 24))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct KakaRoomActionGroup<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var textSize
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(iOS 16.0, *) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8, content: content)
                VStack(alignment: .leading, spacing: 8, content: content)
            }
        } else if textSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8, content: content)
        } else {
            HStack(spacing: 8, content: content)
        }
    }
}

@MainActor
private final class KakaNativeRoomRuntime {
    static let shared = KakaNativeRoomRuntime()

    let media = KakaRealtimeMedia()
    lazy var chat = KakaRoomChat { [weak self] session, roomID in
        self?.media.chatroomID(session: session, serverID: roomID)
    }
    lazy var directChat = KakaRoomChat { _, _ in nil }
    private var owner: UUID?
    private var entry: (visit: UUID, task: Task<Void, Error>)?
    private var release: Task<Void, Never>?

    func join(_ visit: UUID, room: KakaNativeRoom, password: String?, session: UUID) async throws {
        if let owner, owner != visit { leave(owner) }
        owner = visit
        await release?.value
        guard owner == visit, !Task.isCancelled else {
            leave(visit)
            throw CancellationError()
        }
        let operation = Task { @MainActor [media] in
            try await media.join(kind: room.kind.rawValue, roomID: room.serverID, password: password, session: session)
        }
        entry = (visit, operation)
        defer { if entry?.visit == visit { entry = nil } }
        do {
            try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: {
                operation.cancel()
            }
            guard owner == visit, !Task.isCancelled else {
                leave(visit)
                throw CancellationError()
            }
        } catch {
            leave(visit)
            throw error
        }
    }

    func owns(_ visit: UUID) -> Bool { owner == visit }

    func settle() async { await release?.value }

    func leave(_ visit: UUID) {
        guard owner == visit else { return }
        owner = nil
        chat.close()
        media.setVideoFrame(nil)
        let joining = entry?.visit == visit ? entry?.task : nil
        joining?.cancel()
        let previous = release
        release = Task { @MainActor [media] in
            await previous?.value
            await media.leave()
            _ = try? await joining?.value
        }
    }
}

private struct KakaNativeVideo: UIViewRepresentable {
    let media: KakaRealtimeMedia

    func makeUIView(context: Context) -> Renderer { Renderer(media: media) }
    func updateUIView(_ uiView: Renderer, context: Context) { uiView.setNeedsLayout() }

    static func dismantleUIView(_ uiView: Renderer, coordinator: ()) {
        uiView.detach()
    }

    final class Renderer: UIView {
        private let media: KakaRealtimeMedia

        init(media: KakaRealtimeMedia) {
            self.media = media
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            accessibilityElementsHidden = true
            backgroundColor = .clear
            addSubview(media.videoView)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            if media.videoView.superview === self {
                media.setVideoFrame(bounds.isEmpty ? nil : bounds)
            }
        }

        func detach() {
            guard media.videoView.superview === self else { return }
            media.setVideoFrame(nil)
            media.videoView.removeFromSuperview()
        }
    }
}

@MainActor
struct KakaNativeRoomView: View {
    @EnvironmentObject private var store: KakaNativeStore
    @Environment(\.scenePhase) private var scenePhase
    let room: KakaNativeRoom

    @State private var details: KakaNativeRoom?
    @State private var visit: UUID?
    @State private var connectionTask: Task<Void, Never>?
    @State private var seatPoll: Task<Void, Never>?
    @State private var connected = false
    @State private var connecting = false
    @State private var enteredOnce = false
    @State private var connectionError = ""
    @State private var enteredPassword = ""
    @State private var seat = SeatStatus()
    @State private var updatingSeat = false
    @State private var activeSheet: RoomSheet?
    @State private var changingSavedRooms = false
    @State private var hideAfterConfirm = false
    @State private var cueExpanded = false
    @State private var metronome: KakaRoomMetronome?
    @State private var metronomeStart: Task<Void, Never>?
    @State private var beat: Int?

    private enum RoomSheet: String, Identifiable {
        case notes, report, gifts, hide
        var id: Self { self }
    }

    private struct SeatStatus {
        var index = 0
        var microphone = false
        var queued = false
    }

    private var runtime: KakaNativeRoomRuntime { .shared }
    private var current: KakaNativeRoom { details ?? room }
    private var carried: [String: Any]? {
        guard room.kind == .voice, let score = store.practiceScore,
              (score["roomID"] as? String) == room.id else { return nil }
        return score
    }
    private var tempo: Int? { (carried?["bpm"] as? Int) ?? current.bpm }
    private var isFavorite: Bool { (store.record["favorites"] as? [String] ?? []).contains(room.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                roomHeading
                cover
                connectionControls
                if !connectionError.isEmpty {
                    Text(connectionError)
                        .font(.subheadline)
                        .foregroundStyle(KakaTheme.muted)
                }
                if room.kind == .voice { practiceControls }
                if current.topic != current.title || !current.description.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        if current.topic != current.title {
                            Text(current.topic).font(.headline)
                        }
                        if !current.description.isEmpty {
                            Text(current.description).font(.subheadline).foregroundStyle(KakaTheme.muted)
                        }
                    }
                }
                if let visit, connected {
                    KakaNativeChatView(room: room, visit: visit)
                        .id(visit)
                }
                roomActions
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .notes:
                KakaRoomTextSheet(mode: .note, room: current)
            case .report:
                KakaRoomTextSheet(mode: .report, room: current)
            case .gifts:
                if let visit {
                    KakaRoomGiftSheet(room: current, visit: visit)
                }
            case .hide:
                KakaRoomTextSheet(mode: .hide, room: current, onHidden: { hideAfterConfirm = true })
            }
        }
        .onChange(of: hideAfterConfirm) { hidden in
            if hidden, activeSheet == nil { store.back() }
        }
        .onChange(of: activeSheet) { sheet in
            if sheet == nil, hideAfterConfirm { store.back() }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background { stopConnection() }
        }
        .onDisappear { stopConnection() }
        .task {
            guard !enteredOnce else { return }
            enteredOnce = true
            if room.kind == .live, scenePhase == .active { startConnection() }
        }
    }

    private var roomHeading: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(current.title).font(.title2.weight(.bold)).accessibilityAddTraits(.isHeader)
                HStack(spacing: 6) {
                    Text(current.format)
                    if let viewers = current.viewers, viewers > 0, room.kind == .live {
                        Text("· \(viewers) watching")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(KakaTheme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let host = current.host {
                Button { store.open(.host(host)) } label: {
                    VStack(spacing: 4) {
                        KakaRoomArt(asset: "member-mark.jpg", remote: host.portrait, ratio: 1)
                            .frame(width: 40)
                            .clipShape(Circle())
                        Text(host.name).font(.caption2).lineLimit(1)
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .frame(maxWidth: 96)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View host \(host.name)")
            }
        }
    }

    private var cover: some View {
        KakaRoomArt(asset: room.kind.art, remote: current.cover, ratio: room.kind == .live ? 4 / 3 : 2)
            .overlay {
                if room.kind == .live, connected {
                    KakaNativeVideo(media: runtime.media)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if room.kind == .voice, let tempo {
                    Text("\(tempo) BPM")
                        .font(.headline.monospacedDigit())
                        .padding(.horizontal, 11)
                        .frame(minHeight: 36)
                        .modifier(KakaGlass(radius: 18))
                        .padding(10)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private var connectionControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            if current.locked, !connected {
                SecureField("Room password", text: $enteredPassword)
                    .textContentType(.password)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 46)
                    .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Room password")
                    .disabled(connecting)
            }
            if connecting {
                HStack(spacing: 10) {
                    KakaRhythmProgress(title: "Connecting").accessibilityHidden(true)
                    Text(room.kind == .live ? "Connecting to the live room…" : "Connecting to room audio…")
                        .font(.subheadline).foregroundStyle(KakaTheme.muted)
                }
            }
            HStack(spacing: 7) {
                KakaRoomButton(title: connectionTitle, asset: connected || connecting ? "action-stop.png" : room.kind.actionArt,
                               selected: connected) {
                    if connected || connecting { stopConnection() }
                    else { startConnection() }
                }
                if room.kind == .live, connected {
                    KakaRoomButton(title: "Gifts") { activeSheet = .gifts }
                }
            }
            if connected, room.kind == .voice {
                voiceSeat
            }
        }
    }

    private var connectionTitle: String {
        if connecting { return "Cancel" }
        if connected { return room.kind == .live ? "Stop watching" : "Leave audio" }
        if !connectionError.isEmpty && room.kind == .live { return "Retry live" }
        return room.kind == .live ? "Watch live" : "Listen in"
    }

    private var voiceSeat: some View {
        VStack(alignment: .leading, spacing: 8) {
            if seat.queued || seat.index > 0 {
                Text(seat.queued ? "Waiting for a seat" : "Mic seat \(seat.index)")
                    .font(.subheadline).foregroundStyle(KakaTheme.muted)
            }
            KakaRoomActionGroup { voiceSeatButtons }
        }
    }

    @ViewBuilder
    private var voiceSeatButtons: some View {
        KakaRoomButton(title: seat.index > 0 ? "Leave seat" : seat.queued ? "Seat requested" : "Take a seat",
                       asset: "action-seat.png") {
            let operation = seat.index > 0 ? "voiceSeat.leave" : "voiceSeat.take"
            Task { await updateSeat(operation) }
        }
        .disabled(updatingSeat || seat.queued)
        if seat.index > 0 {
            KakaRoomButton(title: seat.microphone ? "Mute microphone" : "Turn microphone on",
                           selected: seat.microphone) {
                Task { await updateSeat("voiceSeat.microphone") }
            }
            .disabled(updatingSeat)
        }
    }

    @ViewBuilder
    private var practiceControls: some View {
        if !connected, !connecting, let tempo {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    ForEach(0..<4, id: \.self) { index in
                        Text("\(index + 1)")
                            .font(.headline.monospacedDigit())
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .background(beat == index ? KakaTheme.accent.opacity(0.32) : KakaTheme.surface,
                                        in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityHidden(true)
                    }
                }
                KakaRoomButton(title: metronome == nil ? "Start \(tempo) BPM metronome" : "Stop metronome",
                               asset: metronome == nil ? "action-play.png" : "action-stop.png",
                               selected: metronome != nil) {
                    if metronome == nil { startBeat(tempo) }
                    else { stopBeat() }
                }
                .disabled(metronomeStart != nil)
            }
        }
        if !current.exercise.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    cueExpanded.toggle()
                } label: {
                    HStack(spacing: 10) {
                        Text("Practice cue").font(.subheadline.weight(.semibold))
                        Spacer()
                        KakaNativeImage(asset: "action-forward.png")
                            .frame(width: 19, height: 19)
                            .rotationEffect(.degrees(cueExpanded ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(cueExpanded ? "Expanded" : "Collapsed")
                if cueExpanded {
                    Text(current.exercise).font(.subheadline).foregroundStyle(KakaTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 8)
                }
            }
            .padding(.horizontal, 12)
            .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        }
        if let carried, let topic = carried["topic"] as? String, let lines = carried["bars"] as? [[String: Any]] {
            VStack(alignment: .leading, spacing: 8) {
                Text("Rehearsing · \(topic)").font(.headline)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    if let text = line["text"] as? String {
                        Text(text).font(.subheadline)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var roomActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            KakaRoomActionGroup { personalActions }
            if room.kind == .live {
                KakaRoomActionGroup { safetyActions }
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var personalActions: some View {
        KakaRoomButton(title: "Write a verse", asset: "room-write.png") { store.openVerse(current) }
        if room.kind == .live {
            KakaRoomButton(title: "Voice rooms", asset: "room-listen.png") { store.select(.voice) }
            KakaRoomButton(title: isFavorite ? "Saved room" : "Save room", asset: "action-bookmark.png", selected: isFavorite) {
                Task { await toggleFavorite() }
            }
            .disabled(changingSavedRooms)
        }
    }

    @ViewBuilder
    private var safetyActions: some View {
        KakaRoomButton(title: "Rehearsal note") { activeSheet = .notes }
        KakaRoomButton(title: "Hide room") { activeSheet = .hide }
        if current.host != nil {
            KakaRoomButton(title: "Report room") { activeSheet = .report }
        }
    }

    private func toggleFavorite() async {
        guard !changingSavedRooms else { return }
        changingSavedRooms = true
        defer { changingSavedRooms = false }
        do {
            let id = room.id
            try await store.updateRecord { state in
                var rooms = state["favorites"] as? [String] ?? []
                if let index = rooms.firstIndex(of: id) { rooms.remove(at: index) }
                else { rooms.append(id) }
                state["favorites"] = rooms
            }
            store.notify(isFavorite ? "Room saved." : "Room removed from saved rooms.")
        } catch {
            store.notify(store.message(error))
        }
    }

    private func startConnection() {
        guard scenePhase == .active, !connecting, !connected, let session = store.session?.token else { return }
        var password: String?
        if room.locked {
            guard !enteredPassword.isEmpty, enteredPassword.utf8.count <= 96 else {
                connectionError = "Enter the room password."
                return
            }
            password = enteredPassword
            enteredPassword = ""
        }
        stopBeat()
        let newVisit = UUID()
        visit = newVisit
        connecting = true
        connectionError = ""
        connectionTask = Task { @MainActor in
            do {
                if room.kind == .live { try await refreshLive(visit: newVisit, session: session) }
                try Task.checkCancellation()
                guard visit == newVisit, store.session?.token == session, scenePhase == .active else { throw CancellationError() }
                try await runtime.join(newVisit, room: current, password: password, session: session)
                try Task.checkCancellation()
                guard visit == newVisit, store.session?.token == session, scenePhase != .background else {
                    runtime.leave(newVisit)
                    throw CancellationError()
                }
                connected = true
                connecting = false
                if room.kind == .voice { observeSeat() }
            } catch {
                runtime.leave(newVisit)
                guard visit == newVisit else { return }
                connecting = false
                visit = nil
                store.expireIfNeeded(error)
                if !(error is CancellationError) && !Task.isCancelled { connectionError = store.message(error) }
            }
        }
    }

    private func refreshLive(visit expected: UUID, session: UUID) async throws {
        let source = try await store.request("getLiveRoom", ["habitatTag": room.serverID])
        guard visit == expected, store.session?.token == session, !Task.isCancelled else { throw CancellationError() }
        guard let fields = source as? [String: Any] else { throw RoomFailure.unavailable }
        let keys = ["habitatTag", "orbitMark"]
        let own = KakaRoomFields.id(fields, keys: keys) == room.serverID
        guard let values = own ? fields : fields["venueBrief"] as? [String: Any],
              let fresh = KakaNativeRoom.parse(values, kind: .live), fresh.serverID == room.serverID else {
            throw RoomFailure.unavailable
        }
        if let original = room.host, let changed = fresh.host, original.id != changed.id {
            throw RoomFailure.changed
        }
        if !room.channel.isEmpty, !fresh.channel.isEmpty, room.channel != fresh.channel { throw RoomFailure.changed }
        details = fresh
        store.remember([fresh])
    }

    private enum RoomFailure: LocalizedError {
        case unavailable, changed
        var errorDescription: String? {
            switch self {
            case .unavailable: return "This stream is no longer available."
            case .changed: return "This stream changed. Return to Live Rooms to reload it."
            }
        }
    }

    private func stopConnection() {
        connectionTask?.cancel()
        connectionTask = nil
        seatPoll?.cancel()
        seatPoll = nil
        if let visit { runtime.leave(visit) }
        visit = nil
        connecting = false
        connected = false
        updatingSeat = false
        seat = SeatStatus()
        if activeSheet == .gifts { activeSheet = nil }
        stopBeat()
    }

    private func observeSeat() {
        seatPoll?.cancel()
        seatPoll = Task { @MainActor in
            while !Task.isCancelled {
                await updateSeat("voiceSeat.status")
                do { try await Task.sleep(nanoseconds: 7_000_000_000) } catch { return }
            }
        }
    }

    private func updateSeat(_ operation: String) async {
        guard !updatingSeat, connected, let visit, runtime.owns(visit), let session = store.session?.token else { return }
        updatingSeat = true
        defer { if self.visit == visit { updatingSeat = false } }
        if operation != "voiceSeat.status" { connectionError = "" }
        do {
            let result = try await runtime.media.voiceSeat(operation: operation, roomID: room.serverID,
                                                            enabled: operation == "voiceSeat.microphone" ? !seat.microphone : nil,
                                                            session: session)
            guard self.visit == visit, store.session?.token == session else { return }
            seat = SeatStatus(index: result["index"] as? Int ?? 0,
                              microphone: result["microphone"] as? Bool ?? false,
                              queued: result["queued"] as? Bool ?? false)
        } catch {
            guard self.visit == visit else { return }
            store.expireIfNeeded(error)
            if operation != "voiceSeat.status" { connectionError = store.message(error) }
        }
    }

    private func startBeat(_ tempo: Int) {
        guard metronomeStart == nil else { return }
        metronomeStart = Task { @MainActor in
            await runtime.settle()
            guard !Task.isCancelled else { return }
            metronomeStart = nil
            guard scenePhase == .active, !connected, !connecting else { return }
            let player = KakaRoomMetronome()
            do {
                try player.start(bpm: tempo) { beat = $0 }
                metronome = player
            } catch {
                player.stop()
                store.notify("The beat could not play. Try again.")
            }
        }
    }

    private func stopBeat() {
        metronomeStart?.cancel()
        metronomeStart = nil
        metronome?.stop()
        metronome = nil
        beat = nil
    }
}

@MainActor
private final class KakaRoomMetronome {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var clockTask: Task<Void, Never>?
    private var ownsAudioSession = false

    func start(bpm: Int, onBeat: @escaping @MainActor (Int) -> Void) throws {
        guard (60...180).contains(bpm),
              let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let downbeat = pulse(frequency: 1_420, format: format),
              let upbeat = pulse(frequency: 990, format: format) else {
            throw KakaAccountStore.Failure.unavailable
        }

        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try audio.setActive(true)
        ownsAudioSession = true
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()

        clockTask = Task { @MainActor [weak self] in
            let interval = UInt64(60_000_000_000 / Double(bpm))
            var next = DispatchTime.now().uptimeNanoseconds
            var beat = 0
            while let self, !Task.isCancelled {
                self.player.scheduleBuffer(beat == 0 ? downbeat : upbeat, completionHandler: nil)
                if !self.player.isPlaying { self.player.play() }
                onBeat(beat)
                beat = (beat + 1) % 4
                let now = DispatchTime.now().uptimeNanoseconds
                next = max(next + interval, now + 15_000_000)
                do { try await Task.sleep(nanoseconds: next - now) } catch { return }
            }
        }
    }

    func stop() {
        clockTask?.cancel()
        clockTask = nil
        player.stop()
        engine.stop()
        if ownsAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsAudioSession = false
        }
    }

    private func pulse(frequency: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_205),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<Int(buffer.frameLength) {
            let time = Double(index) / format.sampleRate
            samples[index] = Float(sin(time * frequency * .pi * 2) * exp(-95 * time) * min(1, time * 900) * 0.36)
        }
        return buffer
    }
}

@MainActor
struct KakaNativeChatView: View {
    @EnvironmentObject private var store: KakaNativeStore
    @Environment(\.scenePhase) private var scenePhase
    private let target: Target
    @State private var visit = UUID()
    @State private var transcript: [ChatLine] = []
    @State private var revision = -1
    @State private var connected = false
    @State private var canSend = false
    @State private var sending = false
    @State private var nearBottom = true
    @State private var feedback = ""
    @State private var input = ""
    @State private var retry = 0

    private enum Target {
        case room(KakaNativeRoom, UUID)
        case direct(Int64)

        var service: String {
            switch self {
            case .room: return "roomChat"
            case .direct: return "directChat"
            }
        }

        var limit: Int { service == "roomChat" ? 280 : 500 }
        var title: String { service == "roomChat" ? "Room chat" : "Messages" }
    }

    private struct ChatLine: Identifiable {
        let id: String
        let name: String
        let text: String
    }

    init(hostID: Int64) { target = .direct(hostID) }
    init(room: KakaNativeRoom, visit: UUID) { target = .room(room, visit) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(target.title).font(.headline).accessibilityAddTraits(.isHeader)
            if !transcript.isEmpty { messages }
            if !feedback.isEmpty {
                Text(feedback).font(.footnote).foregroundStyle(KakaTheme.muted)
            } else if !connected {
                Text("Connecting to chat…").font(.footnote).foregroundStyle(KakaTheme.muted)
            } else if !canSend {
                Text("Messaging is unavailable for this conversation.").font(.footnote).foregroundStyle(KakaTheme.muted)
            } else if transcript.isEmpty {
                Text("Start the conversation.").font(.footnote).foregroundStyle(KakaTheme.muted)
            }
            if !feedback.isEmpty, !connected {
                KakaRoomButton(title: "Retry chat") { retry += 1 }
            }
            HStack(spacing: 8) {
                TextField("Write a message", text: $input)
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.send)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)
                    .background(KakaTheme.base, in: RoundedRectangle(cornerRadius: 12))
                    .onSubmit { submit() }
                    .disabled(!canSend)
                KakaRoomButton(title: sending ? "Sending…" : "Send") { submit() }
                    .disabled(sending || !canSend || trimmed.isEmpty)
            }
        }
        .padding(12)
        .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        .task(id: retry) { await watch() }
        .onChange(of: scenePhase) { phase in
            if phase == .background { close() }
            else if phase == .active && !connected { retry += 1 }
        }
        .onDisappear { close() }
    }

    private var messages: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(transcript) { line in
                        (Text(line.name + " ").fontWeight(.semibold) + Text(line.text))
                            .font(.subheadline)
                            .textSelection(.enabled)
                    }
                    Color.clear.frame(height: 1).id("chat-end")
                        .onAppear { nearBottom = true }
                        .onDisappear { nearBottom = false }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 42, maxHeight: 185)
            .defaultScrollAnchorIfSupported()
            .onChange(of: transcript.last?.id) { _ in
                if nearBottom { reader.scrollTo("chat-end", anchor: .bottom) }
            }
        }
    }

    private var trimmed: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func watch() async {
        guard scenePhase != .background, let token = store.session?.token else { return }
        let id = visit
        feedback = ""
        revision = -1
        do {
            try consume(await request("open", visit: id, session: token), visit: id, session: token)
            while !Task.isCancelled, visit == id, store.session?.token == token, scenePhase != .background {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                guard visit == id, store.session?.token == token, scenePhase != .background else { return }
                try consume(await request("snapshot", visit: id, session: token), visit: id, session: token)
            }
        } catch {
            guard visit == id, store.session?.token == token, !Task.isCancelled else { return }
            connected = false
            canSend = false
            store.expireIfNeeded(error)
            feedback = store.message(error)
        }
    }

    private func request(_ operation: String, visit: UUID, session: UUID, text: String? = nil) async throws -> Data {
        let runtime = KakaNativeRoomRuntime.shared
        var fields: [String: Any] = ["visit": visit.uuidString]
        if let text { fields["text"] = text }
        switch target {
        case .room(let room, let owner):
            guard runtime.owns(owner) else { throw CancellationError() }
            fields["kind"] = room.kind.rawValue
            fields["serverID"] = String(room.serverID)
            return try await runtime.chat.perform(operation: "roomChat.\(operation)", input: fields, session: session)
        case .direct(let host):
            fields["userID"] = host
            return try await runtime.directChat.performDirect(operation: "directChat.\(operation)", input: fields, session: session)
        }
    }

    private func consume(_ result: Data, visit: UUID, session: UUID) throws {
        guard visit == self.visit, store.session?.token == session, !Task.isCancelled else { return }
        let fields = try KakaRemoteClient.object(result)
        let nextRevision = fields["revision"] as? Int ?? 0
        guard nextRevision >= revision else { return }
        connected = fields["connected"] as? Bool == true
        canSend = connected && fields["canSend"] as? Bool != false && fields["blocked"] as? Bool != true
        if nextRevision != revision {
            revision = nextRevision
            let lines = fields["messages"] as? [[String: Any]] ?? []
            var ids = Set<String>()
            transcript = lines.suffix(50).compactMap { line in
                guard let id = line["id"] as? String, ids.insert(id).inserted,
                      let name = line["name"] as? String, let text = line["text"] as? String else { return nil }
                return ChatLine(id: id, name: (line["own"] as? Bool == true ? "You" : name), text: text)
            }
        }
    }

    private func submit() {
        guard !sending, canSend, !trimmed.isEmpty, let session = store.session?.token else { return }
        let id = visit
        let draft = input
        let text = trimmed.utf16.count <= target.limit ? trimmed : ""
        guard !text.isEmpty else {
            feedback = "Keep the message under \(target.limit + 1) characters."
            return
        }
        sending = true
        feedback = ""
        Task { @MainActor in
            defer { if visit == id { sending = false } }
            do {
                try consume(await request("send", visit: id, session: session, text: text), visit: id, session: session)
                if visit == id, input == draft { input = "" }
            } catch {
                guard visit == id, store.session?.token == session else { return }
                store.expireIfNeeded(error)
                feedback = store.message(error)
            }
        }
    }

    private func close() {
        let id = visit
        visit = UUID()
        connected = false
        canSend = false
        sending = false
        guard let token = store.session?.token else { return }
        Task { @MainActor in _ = try? await request("close", visit: id, session: token) }
    }
}

private extension View {
    @ViewBuilder
    func defaultScrollAnchorIfSupported() -> some View {
        if #available(iOS 17.0, *) {
            defaultScrollAnchor(.bottom)
        } else {
            self
        }
    }
}

@MainActor
private struct KakaRoomTextSheet: View {
    enum Mode {
        case note, report, hide

        var title: String {
            switch self {
            case .note: return "Rehearsal note"
            case .report: return "Report room"
            case .hide: return "Hide this room?"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: KakaNativeStore
    let mode: Mode
    let room: KakaNativeRoom
    var onHidden: () -> Void = {}

    @State private var text = ""
    @State private var selectedReason = ""
    @State private var working = false
    @State private var feedback = ""

    private let reasons: [(code: String, title: String)] = [
        ("HARASS", "Harassment or bullying"),
        ("NUDITY", "Nudity or sexual content"),
        ("SPAM", "Spam or scam"),
        ("UNDERAGE", "Underage user"),
        ("FRAUD", "Fraud"),
        ("OTHER", "Other")
    ]

    var body: some View {
        KakaRoomSheet(title: mode.title, locked: working) {
            switch mode {
            case .note:
                TextEditor(text: $text)
                    .frame(minHeight: 116)
                    .padding(7)
                    .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Rehearsal note")
                Text("\(text.utf16.count) of 480 characters")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(KakaTheme.muted)
                KakaRoomButton(title: "Save note", asset: "action-check.png") { perform() }
                    .disabled(text.utf16.count > 480 || working)
            case .report:
                Text("Why are you reporting this room?")
                    .font(.subheadline)
                    .foregroundStyle(KakaTheme.muted)
                ForEach(reasons, id: \.code) { reason in
                    KakaRoomButton(title: reason.title, asset: selectedReason == reason.code ? "action-check.png" : nil,
                                   selected: selectedReason == reason.code) { selectedReason = reason.code }
                        .disabled(working)
                }
                KakaRoomButton(title: "Send report") { perform() }
                    .disabled(selectedReason.isEmpty || working)
            case .hide:
                Text("This room will be removed from your lists. You can restore it from your profile.")
                    .font(.subheadline)
                    .foregroundStyle(KakaTheme.muted)
                KakaRoomButton(title: "Hide room") { perform() }
                    .disabled(working)
            }
            if !feedback.isEmpty {
                Text(feedback).font(.footnote).foregroundStyle(KakaTheme.muted)
            }
        }
        .interactiveDismissDisabled(working)
        .onAppear {
            if mode == .note {
                text = (store.record["notes"] as? [[String: Any]] ?? [])
                    .first { $0["roomID"] as? String == room.id }?["text"] as? String ?? ""
            }
        }
    }

    private func perform() {
        guard !working else { return }
        working = true
        feedback = ""
        Task { @MainActor in
            defer { working = false }
            do {
                switch mode {
                case .note:
                    let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard note.utf16.count <= 480 else { throw KakaAccountStore.Failure.invalidInput }
                    let id = room.id
                    try await store.updateRecord { state in
                        var notes = state["notes"] as? [[String: Any]] ?? []
                        notes.removeAll { $0["roomID"] as? String == id }
                        if !note.isEmpty { notes.append(["roomID": id, "text": note]) }
                        state["notes"] = notes
                    }
                    store.notify(note.isEmpty ? "Rehearsal note cleared." : "Rehearsal note saved.")
                case .report:
                    guard let host = room.host, reasons.contains(where: { $0.code == selectedReason }) else {
                        throw KakaAccountStore.Failure.invalidInput
                    }
                    _ = try await store.request("reportUser", ["castEmblem": host.id, "habitatTag": room.serverID,
                                                               "reviewMode": selectedReason])
                    store.notify("Report submitted.")
                case .hide:
                    let id = room.id
                    try await store.updateRecord { state in
                        var reports = state["reports"] as? [[String: Any]] ?? []
                        if !reports.contains(where: { $0["roomID"] as? String == id }) {
                            reports.append(["roomID": id, "reason": "Hidden by you",
                                            "createdAt": Date().timeIntervalSince1970 * 1_000])
                        }
                        state["reports"] = reports
                    }
                    onHidden()
                    store.notify("Room hidden from your list.")
                }
                dismiss()
            } catch {
                feedback = store.message(error)
            }
        }
    }
}

@MainActor
private struct KakaRoomGiftSheet: View {
    @EnvironmentObject private var store: KakaNativeStore
    let room: KakaNativeRoom
    let visit: UUID
    @State private var gifts: [Gift] = []
    @State private var balance = ""
    @State private var host = ""
    @State private var feedback = ""
    @State private var busy = false
    @State private var choice: Gift?

    private struct Gift: Identifiable {
        let id: Int64
        let name: String
        let cost: String
        let image: URL?
        let available: Bool
    }

    var body: some View {
        KakaRoomSheet(title: "Gifts", locked: busy) {
            if !balance.isEmpty {
                Text("\(balance) diamonds available").font(.subheadline).foregroundStyle(KakaTheme.muted)
            }
            if let choice {
                Text("Send a gift?").font(.headline)
                Text("Send one \(choice.name) to \(host) for \(choice.cost) diamonds.")
                    .font(.subheadline).foregroundStyle(KakaTheme.muted)
                KakaRoomActionGroup { giftConfirmation(choice) }
            } else {
                ForEach(gifts) { gift in
                    HStack(spacing: 8) {
                        if let image = gift.image {
                            KakaNativeImage(asset: "member-mark.jpg", remote: image)
                                .scaledToFill()
                                .frame(width: 34, height: 34)
                                .clipShape(Circle())
                                .accessibilityHidden(true)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(gift.name).font(.subheadline.weight(.semibold))
                            Text("\(gift.cost) diamonds").font(.caption).foregroundStyle(KakaTheme.muted)
                        }
                        Spacer(minLength: 4)
                        KakaRoomButton(title: "Give") { choice = gift }
                            .accessibilityLabel("Give \(gift.name) for \(gift.cost) diamonds")
                            .disabled(!gift.available || busy)
                    }
                    .padding(.vertical, 3)
                }
                KakaRoomButton(title: "Refresh gifts") { Task { await fetch() } }
                    .disabled(busy)
            }
            if busy { KakaRhythmProgress(title: "Updating gifts") }
            if !feedback.isEmpty { Text(feedback).font(.footnote).foregroundStyle(KakaTheme.muted) }
        }
        .interactiveDismissDisabled(busy)
        .task { await fetch() }
    }

    @ViewBuilder
    private func giftConfirmation(_ gift: Gift) -> some View {
        KakaRoomButton(title: "Cancel") { choice = nil }
        KakaRoomButton(title: "Send gift") {
            choice = nil
            Task { await send(gift) }
        }
        .disabled(busy)
    }

    private func fetch() async {
        guard !busy, let session = store.session?.token else { return }
        busy = true
        feedback = ""
        defer { busy = false }
        do {
            let fields = try await request("gift.catalog", session: session)
            guard store.session?.token == session else { return }
            balance = fields["balance"] as? String ?? ""
            host = fields["host"] as? String ?? room.host?.name ?? "the host"
            gifts = (fields["gifts"] as? [[String: Any]] ?? []).compactMap { entry in
                guard let id = KakaRemoteClient.userID(entry["id"]), id > 0, let name = entry["name"] as? String,
                      let cost = entry["cost"] as? String else { return nil }
                return Gift(id: id, name: name, cost: cost,
                            image: KakaRoomFields.url(entry["image"] as? String ?? ""),
                            available: entry["available"] as? Bool == true)
            }
            if gifts.isEmpty { feedback = "No gifts are available in this room." }
        } catch {
            guard store.session?.token == session else { return }
            store.expireIfNeeded(error)
            feedback = store.message(error)
        }
    }

    private func send(_ gift: Gift) async {
        guard !busy, gift.available, gifts.contains(where: { $0.id == gift.id }),
              let session = store.session?.token else { return }
        busy = true
        feedback = ""
        gifts = []
        defer { busy = false }
        do {
            let result = try await request("gift.send", session: session, gift: gift.id)
            guard store.session?.token == session else { return }
            balance = result["balance"] as? String ?? ""
            switch result["status"] as? String {
            case "sent": feedback = "Gift sent."
            case "declined": feedback = "The gift wasn’t sent."
            default: feedback = "Delivery couldn’t be confirmed. Check your balance before sending again."
            }
        } catch {
            guard store.session?.token == session else { return }
            store.expireIfNeeded(error)
            feedback = store.message(error)
        }
    }

    private func request(_ operation: String, session: UUID, gift: Int64? = nil) async throws -> [String: Any] {
        let runtime = KakaNativeRoomRuntime.shared
        guard runtime.owns(visit) else { throw KakaLiveGifts.Failure.unavailable }
        let data = try await KakaLiveGifts.shared.perform(operation: operation, roomID: room.serverID, giftID: gift,
                                                         session: session) { host, channel in
            runtime.owns(visit) && runtime.media.isLiveAudience(roomID: room.serverID, session: session,
                                                               hostID: host, channel: channel)
        }
        return try KakaRemoteClient.object(data)
    }
}

private struct KakaRoomSheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let locked: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    Button { dismiss() } label: {
                        KakaNativeImage(asset: "action-close.png")
                            .frame(width: 24, height: 24)
                            .frame(width: 44, height: 44)
                            .modifier(KakaGlass(interactive: true, radius: 22))
                    }
                    .buttonStyle(.plain)
                    .disabled(locked)
                    .accessibilityLabel("Close")
                }
                content()
            }
            .padding(18)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(KakaTheme.base.ignoresSafeArea())
        .foregroundStyle(KakaTheme.ink)
    }
}
