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
    let directoryLocale: String?
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
            directoryLocale: KakaRoomFields.directoryLocale(value, party: party),
            locked: party && ["lockFlag", "needPassword", "isLock", "locked"].contains { KakaRoomFields.flag(value[$0]) },
            channel: KakaRoomFields.text(value, "studioRoute", "venueKey", "agoraChannelId")
        )
    }
}

private enum KakaRoomFields {
    static func directoryLocale(_ fields: [String: Any], party: Bool) -> String? {
        if party {
            let code = text(fields, "languageCode").lowercased()
            let language = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
            guard (2...3).contains(language.count), language.utf8.allSatisfy({ (97...122).contains($0) }),
                  let name = Locale.autoupdatingCurrent.localizedString(forLanguageCode: language), name != language else { return nil }
            return name
        }
        let region = text(fields, "regionCode", "countryCode").uppercased()
        let conformedCode = (region.count == 2 && region.utf8.allSatisfy { (65...90).contains($0) })
            || (region.count == 3 && region.utf8.allSatisfy { (48...57).contains($0) })
        guard conformedCode, let name = Locale.autoupdatingCurrent.localizedString(forRegionCode: region),
              name != region else { return nil }
        return name
    }

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .body) private var spotlightCaptionHeight: CGFloat = 104
    let kind: KakaNativeRoom.Kind

    private static let scrollSpace = "KakaRoomDirectoryViewport"

    @State private var filter: RoomFilter
    @State private var category: RoomFilter?
    @State private var locale: String?
    @State private var searching = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var rooms: [KakaNativeRoom] = []
    @State private var activeLoad: RoomLoad?
    @State private var loadFailure: (operation: RoomLoad, message: String)?
    @State private var loadingFollowing = false
    @State private var followingError = ""
    @State private var hasMore = false
    @State private var requiresManualPaging = false
    @State private var page = 0
    @State private var initialSession: UUID?
    @State private var seenLiveRoomIDs: Set<String> = []
    @State private var newLiveRoomIDs: Set<String> = []
    @State private var selectedSpotlightID: String?
    @GestureState private var draggingSpotlight = false

    init(kind: KakaNativeRoom.Kind) {
        self.kind = kind
        _filter = State(initialValue: kind == .live ? .onAir : .all)
    }

    private enum RoomLoad: Equatable {
        case refresh, more
    }

    private struct PageRequest: Equatable {
        let session: UUID
        let filter: RoomFilter
        let page: Int
    }

    private struct SpotlightRotation: Equatable {
        let roomIDs: [String]
        let selection: String
        let enabled: Bool
    }

    private enum LivePagePreference: PreferenceKey {
        static let defaultValue: PageRequest? = nil

        static func reduce(value: inout PageRequest?, nextValue: () -> PageRequest?) {
            value = nextValue() ?? value
        }
    }

    private var loading: Bool { activeLoad != nil }

    private enum RoomFilter: String, Identifiable {
        case all, onAir, new, following, recent, watched, open, locked, music, chat, openMic, freestyle, beatLab, general

        static let liveCategories: [Self] = [.music, .chat, .openMic, .freestyle, .beatLab, .general]

        var id: Self { self }
        var name: String {
            switch self {
            case .all: return "All rooms"
            case .onAir: return "On air"
            case .new: return "New"
            case .following: return "Following"
            case .recent: return "Recent"
            case .watched: return "Most watched"
            case .open: return "Open rooms"
            case .locked: return "Locked"
            case .music: return "Music"
            case .chat: return "Chat"
            case .openMic: return "Open mic"
            case .freestyle: return "Freestyle"
            case .beatLab: return "Beat lab"
            case .general: return "Other rooms"
            }
        }

        static func liveCategory(_ value: String) -> Self? {
            let key = value.lowercased().split { $0.isWhitespace || $0 == "-" || $0 == "_" }.joined(separator: " ")
            switch key {
            case "music", "singing", "karaoke", "live music": return .music
            case "chat", "chatting", "just chatting", "talk", "talk show": return .chat
            case "open mic", "openmic": return .openMic
            case "freestyle", "cypher", "cipher", "freestyle rap": return .freestyle
            case "beats", "beat lab", "beatlab", "beat making", "beatmaking": return .beatLab
            default: return nil
            }
        }
    }

    private func liveCategory(for room: KakaNativeRoom) -> RoomFilter {
        RoomFilter.liveCategory(room.genre) ?? RoomFilter.liveCategory(room.format) ?? .general
    }

    private var visibleRooms: [KakaNativeRoom] {
        rooms.filter { !store.isHidden($0.id) }
    }

    private var filters: [RoomFilter] {
        kind == .voice ? [.all, .following, .recent] : [.all, .onAir, .new, .following]
    }

    private var spotlight: [KakaNativeRoom] {
        guard !searching, category == nil, locale == nil,
              filter == (kind == .live ? .onAir : .all) else { return [] }
        return Array(visibleRooms.enumerated().filter { !$0.element.locked }.sorted {
            if ($0.element.cover != nil) != ($1.element.cover != nil) { return $0.element.cover != nil }
            let first = $0.element.viewers ?? 0
            let second = $1.element.viewers ?? 0
            return first == second ? $0.offset < $1.offset : first > second
        }.prefix(4).map(\.element))
    }

    private var results: [KakaNativeRoom] {
        let term = searchTerm
        let matching = visibleRooms.filter { room in
            matchesCategory(room) && (locale == nil || room.directoryLocale == locale)
                && (term.isEmpty || [room.title, room.host?.name ?? "", room.topic, room.description, room.genre,
                                     room.directoryLocale ?? ""].contains { $0.localizedStandardContains(term) })
        }
        switch filter {
        case .new:
            return matching.filter { newLiveRoomIDs.contains($0.id) }
        case .following:
            return matching.filter { $0.host.map { store.followedIDs.contains($0.id) } ?? false }
        case .recent:
            let byID = Dictionary(uniqueKeysWithValues: matching.map { ($0.id, $0) })
            return store.recentVoiceRoomIDs.compactMap { byID[$0] }
        case .watched:
            return matching.enumerated().filter { $0.element.viewers != nil }.sorted {
                let first = $0.element.viewers ?? 0
                let second = $1.element.viewers ?? 0
                return first == second ? $0.offset < $1.offset : first > second
            }.map(\.element)
        default:
            return matching
        }
    }

    private var searchTerm: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func matchesCategory(_ room: KakaNativeRoom) -> Bool {
        switch category {
        case .open: return !room.locked
        case .locked: return room.locked
        case let selected?: return liveCategory(for: room) == selected
        case nil: return true
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let gutter: CGFloat = geometry.size.width < 350 ? 12 : 16
            let contentWidth = max(1, min(geometry.size.width, 720) - gutter * 2)
            VStack(spacing: 0) {
                directoryControls(width: contentWidth)
                    .padding(.horizontal, gutter)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                GeometryReader { content in
                    directory(viewport: CGSize(width: contentWidth, height: content.size.height), gutter: gutter)
                }
            }
        }
        .task(id: store.session?.token) {
            guard initialSession != store.session?.token || page == 0 else { return }
            initialSession = store.session?.token
            page = 0
            hasMore = false
            requiresManualPaging = false
            rooms = []
            seenLiveRoomIDs = []
            newLiveRoomIDs = []
            await load()
        }
        .onChange(of: store.tab) { tab in
            if tab != (kind == .live ? .live : .voice) { searchFocused = false }
        }
        .onChange(of: store.route) { route in
            if route != nil { searchFocused = false }
        }
    }

    private func directory(viewport: CGSize, gutter: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                let slides = spotlight
                if let first = slides.first {
                    featuredRooms(slides, first: first, viewport: viewport)
                }
                roomResults(viewport: viewport)
            }
            .padding(.horizontal, gutter)
            .padding(.top, 8)
            .padding(.bottom, 20)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .coordinateSpace(name: Self.scrollSpace)
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
        let columns = roomColumns(width: viewport.width)
        return VStack(alignment: .leading, spacing: 10) {
            if filter == .watched {
                Text(kind == .live ? "By viewers in loaded live rooms" : "By people in loaded voice rooms")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(KakaTheme.muted)
                    .accessibilityAddTraits(.isHeader)
            } else if filter == .new, !shownRooms.isEmpty {
                Text("Newly found in this feed")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(KakaTheme.muted)
            } else if !searchTerm.isEmpty, !shownRooms.isEmpty {
                Text("\(shownRooms.count) \(shownRooms.count == 1 ? "match" : "matches") in loaded rooms")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(KakaTheme.muted)
            }
            if shownRooms.isEmpty {
                if kind == .live {
                    liveDirectoryFeedback(columns: columns, width: viewport.width)
                } else {
                    voiceDirectoryFeedback(columns: columns)
                }
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: kind == .voice ? 9 : 10) {
                    ForEach(shownRooms) { room in
                        if kind == .live {
                            liveRoomButton(room, viewportHeight: viewport.height)
                        } else {
                            voiceRoomButton(room, viewportHeight: viewport.height)
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
        let spacing: CGFloat = 10
        let minimumWidth: CGFloat = kind == .voice ? 294 : 135
        let count = textSize.isAccessibilitySize ? 1 : max(1, Int((width + spacing) / (minimumWidth + spacing)))
        return Array(repeating: GridItem(.flexible(minimum: 0), spacing: spacing, alignment: .top), count: count)
    }

    private var directoryAccent: Color { kind == .live ? KakaTheme.liveAccent : KakaTheme.voiceAccent }

    private func directoryControls(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if textSize.isAccessibilitySize || width < 315 {
                primaryFilterBar
                directoryTools.frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                HStack(spacing: 8) {
                    primaryFilterBar
                    directoryTools
                }
            }
            if searching { searchField }
            secondaryFilters
        }
        .padding(.top, 4)
        .padding(.bottom, 5)
    }

    private var primaryFilterBar: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(filters) { item in
                        Button { selectFilter(item) } label: {
                            Text(item == .all ? (kind == .live ? "Explore" : "Rooms") : item.name)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(filter == item ? KakaTheme.ink : KakaTheme.muted)
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(minWidth: 44, minHeight: 45)
                                .overlay(alignment: .bottom) {
                                    if filter == item {
                                        Capsule()
                                            .fill(directoryAccent)
                                            .frame(width: 20, height: 2)
                                            .allowsHitTesting(false)
                                    }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(filter == item ? .isSelected : [])
                        .id(item)
                    }
                }
            }
            .onAppear { reader.scrollTo(filter) }
            .onChange(of: filter) { reader.scrollTo($0) }
            .accessibilityLabel("Room feeds")
        }
    }

    private var directoryTools: some View {
        HStack(spacing: 3) {
            directoryTool(searching ? "Done" : "Search", selected: searching) {
                searching.toggle()
                searchFocused = searching
                if !searching { query = "" }
            }
            directoryTool("Top", selected: filter == .watched) {
                selectFilter(filter == .watched ? (kind == .live ? .onAir : .all) : .watched)
            }
            .accessibilityLabel("Rank loaded rooms")
        }
        .modifier(KakaGlass(radius: 15, tint: directoryAccent.opacity(0.08)))
    }

    private func directoryTool(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(selected ? directoryAccent : KakaTheme.ink)
                .padding(.horizontal, 8)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            TextField("Search rooms or hosts", text: $query)
                .font(.subheadline)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .submitLabel(.search)
                .focused($searchFocused)
                .onSubmit { searchFocused = false }
                .padding(.leading, 12)
                .frame(minHeight: 44)
            if !query.isEmpty {
                directoryTool("Clear", selected: false) {
                    query = ""
                    searchFocused = true
                }
            }
        }
        .padding(.trailing, 4)
        .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13).strokeBorder(directoryAccent.opacity(0.4))
                .allowsHitTesting(false)
        }
        .onAppear { searchFocused = true }
    }

    private var secondaryFilters: some View {
        let places = Set(visibleRooms.compactMap(\.directoryLocale)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        let topics: [RoomFilter] = kind == .live ? RoomFilter.liveCategories : [.open] +
            ((category == .locked || visibleRooms.contains(where: \.locked)) ? [.locked] : []) +
            RoomFilter.liveCategories.filter { item in item != .general && visibleRooms.contains { liveCategory(for: $0) == item } }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                filterChip(kind == .live && !places.isEmpty ? "Anywhere" : "All", selected: category == nil && locale == nil) {
                    clearSecondaryFilters()
                }
                ForEach(places, id: \.self) { place in
                    filterChip(place, selected: locale == place) {
                        let next = locale == place ? nil : place
                        clearSecondaryFilters()
                        locale = next
                    }
                }
                ForEach(topics) { topic in
                    let label = topic == .open ? "Open" : topic.name
                    filterChip(label, selected: category == topic) {
                        let next = category == topic ? nil : topic
                        clearSecondaryFilters()
                        category = next
                    }
                }
            }
        }
        .accessibilityLabel(kind == .live ? "Live topics and locations" : "Voice room filters")
    }

    private func filterChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(selected ? directoryAccent : KakaTheme.muted)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .frame(minWidth: 44, minHeight: 29)
                .background(selected ? directoryAccent.opacity(0.12) : KakaTheme.surface,
                            in: RoundedRectangle(cornerRadius: 9))
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 9).strokeBorder(directoryAccent.opacity(0.55))
                            .allowsHitTesting(false)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func clearSecondaryFilters() {
        category = nil
        locale = nil
        requiresManualPaging = false
    }

    private func selectFilter(_ item: RoomFilter) {
        if filter != item {
            clearSecondaryFilters()
            filter = item
        }
        if item == .following { Task { await loadFollowing() } }
        if item == .new && newLiveRoomIDs.isEmpty { Task { await load() } }
    }

    private var checkingFollowing: Bool {
        filter == .following && (loadingFollowing || (!store.followingLoaded && followingError.isEmpty))
    }

    private var waitingForRooms: Bool {
        loading || (loadFailure == nil && (page == 0 || checkingFollowing))
    }

    @ViewBuilder
    private func liveDirectoryFeedback(columns: [GridItem], width: CGFloat) -> some View {
        if waitingForRooms {
            let title = activeLoad == .more ? "Checking more rooms…" : checkingFollowing && page > 0
                ? "Checking followed hosts…" : "Finding live rooms…"
            KakaDirectoryLoading(title: title, columns: columns,
                                 spotlightHeight: filter == .onAir && !searching && page == 0 ? spotlightHeight(width) : nil)
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
                if !searchTerm.isEmpty {
                    directoryStateButton("Clear search", prominent: true) { query = "" }
                } else if category != nil || locale != nil {
                    directoryStateButton("Clear filters", prominent: true) { clearSecondaryFilters() }
                } else if filter == .new || (!hasMore && (filter == .all || filter == .onAir)) {
                    directoryStateButton("Refresh live rooms", prominent: true) { Task { await load() } }
                } else if filter != .all && filter != .onAir {
                    directoryStateButton("Browse all live rooms", prominent: true) { selectFilter(.all) }
                }
                if hasMore && filter != .new && (filter != .following || !store.followedIDs.isEmpty) {
                    directoryStateButton("Check more rooms", prominent: filter == .all || filter == .onAir) { Task { await load(.more) } }
                }
                if rooms.contains(where: { store.isHidden($0.id) }) {
                    directoryStateButton("Manage hidden rooms") { store.select(.profile) }
                }
            }
        }
    }

    private var liveEmptyCopy: (title: String, detail: String) {
        if !searchTerm.isEmpty {
            return ("No matching live rooms", hasMore ? "Search checks the rooms loaded so far. Check more rooms to widen your search." : "Try a different room name, host or topic.")
        }
        if let locale { return ("No live rooms for \(locale)", "Browse all locations or check more rooms.") }
        if let category { return ("No \(category.name.lowercased()) rooms", "Try another topic or check more rooms.") }
        switch filter {
        case .all, .onAir:
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
        case .new:
            return ("No new rooms in this feed yet", "Refresh to find rooms added since you opened Live.")
        default:
            return ("No rooms in this category", "Browse the full lineup for other live rooms.")
        }
    }

    private func directoryStatusPanel<Actions: View>(
        _ title: String, detail: String, artwork: String? = "LiveEmptyStage", @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let artwork {
                KakaRoomArt(asset: artwork, remote: nil, ratio: 2.6)
                    .overlay(alignment: .bottom) {
                        LinearGradient(colors: [.clear, KakaTheme.surface], startPoint: .top, endPoint: .bottom)
                            .frame(height: 32)
                            .allowsHitTesting(false)
                    }
            }
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.title3.weight(.bold))
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
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(KakaTheme.line)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
    }

    private func directoryStateButton(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(prominent ? KakaTheme.ink : KakaTheme.accent)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, prominent ? 14 : 0)
                .padding(.vertical, 8)
                .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                .background(prominent ? KakaTheme.actionFill : .clear, in: Capsule())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var canPageAutomatically: Bool {
        hasMore && !requiresExplicitPaging && !loading && loadFailure == nil
            && store.tab == .live && store.route == nil && scenePhase == .active
            && (filter != .following || (!loadingFollowing && followingError.isEmpty))
    }

    private var requiresExplicitPaging: Bool {
        requiresManualPaging || searching || category != nil || locale != nil || filter == .watched || filter == .new
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
        } else if filter == .new {
            directoryStateButton("Refresh live rooms") { Task { await load() } }
                .disabled(loading)
        } else if hasMore {
            if requiresExplicitPaging {
                directoryStateButton("Check more rooms", prominent: true) { Task { await load(.more) } }
                    .disabled(loading)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            } else if canPageAutomatically, let session = store.session?.token, viewportHeight > 0 {
                GeometryReader { geometry in
                    let frame = geometry.frame(in: CoordinateSpace.named(Self.scrollSpace))
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
                                 columns: columns, kind: .voice)
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
                if !searchTerm.isEmpty {
                    directoryStateButton("Clear search", prominent: true) { query = "" }
                } else if category != nil || locale != nil {
                    directoryStateButton("Clear filters", prominent: true) { clearSecondaryFilters() }
                } else if filter == .all {
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
        if !searchTerm.isEmpty { return ("No matching voice rooms", "Try a different room name, host or topic.") }
        if let locale { return ("No rooms for \(locale)", "Try another language.") }
        if let category { return ("No \(category.name.lowercased()) rooms", "Try another room filter.") }
        switch filter {
        case .all:
            return rooms.isEmpty
                ? ("No voice rooms right now", "Check again for new rooms, or open Verse Lab to work on a verse.")
                : ("No visible voice rooms", "You can review hidden rooms from your profile.")
        case .following:
            return store.followedIDs.isEmpty
                ? ("Find voices to follow", "Follow a host from their room to find their voice rooms here.")
                : ("No followed voice rooms", "Rooms from hosts you follow will appear here when available.")
        case .recent:
            return ("No recent rooms available", "After you join a voice room, you can find it here while it’s listed.")
        case .watched:
            return ("No rooms ranked yet", "Rooms appear here when they report how many people are inside.")
        default:
            return ("No rooms in this category", "Browse all voice rooms to see the rest of the lineup.")
        }
    }

    private func featuredRooms(_ slides: [KakaNativeRoom], first: KakaNativeRoom, viewport: CGSize) -> some View {
        let ids = slides.map(\.id)
        let selection = selectedSpotlightID.flatMap { ids.contains($0) ? $0 : nil } ?? first.id
        return VStack(spacing: 0) {
            if slides.count > 1 {
                spotlightPager(slides, ids: ids, selection: selection, viewport: viewport)
                    .overlay(alignment: .bottomTrailing) {
                        if !textSize.isAccessibilitySize, viewport.width >= 310 {
                            spotlightPageControls(slides, selection: selection)
                        }
                    }
                if textSize.isAccessibilitySize || viewport.width < 310 {
                    spotlightPageControls(slides, selection: selection)
                        .frame(maxWidth: .infinity)
                }
            } else {
                featuredRoomButton(first, width: viewport.width, height: spotlightHeight(viewport.width))
            }
        }
    }

    private func spotlightPager(_ slides: [KakaNativeRoom], ids: [String], selection: String, viewport: CGSize) -> some View {
        let tab: KakaNativeTab = kind == .live ? .live : .voice
        return GeometryReader { geometry in
            let frame = geometry.frame(in: CoordinateSpace.named(Self.scrollSpace))
            let visibleHeight = min(frame.maxY, viewport.height) - max(frame.minY, 0)
            let rotates = visibleHeight >= frame.height * 0.5
                && cardMotionIsVisible(frame, viewportHeight: viewport.height, tab: tab)
                && !voiceOverEnabled && !draggingSpotlight
            TabView(selection: Binding(get: { selection }, set: { selectedSpotlightID = $0 })) {
                ForEach(slides) { room in
                    featuredRoomButton(room, width: geometry.size.width, height: geometry.size.height)
                        .accessibilityHidden(room.id != selection)
                        .tag(room.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .simultaneousGesture(
                DragGesture(minimumDistance: 5)
                    .updating($draggingSpotlight) { _, dragging, _ in dragging = true }
            )
            .task(id: SpotlightRotation(roomIDs: ids, selection: selection, enabled: rotates)) {
                guard rotates, let index = ids.firstIndex(of: selection) else { return }
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                guard !Task.isCancelled, !draggingSpotlight, store.tab == tab, store.route == nil else { return }
                selectSpotlight(ids[(index + 1) % ids.count])
            }
        }
        .frame(height: spotlightHeight(viewport.width))
    }

    private func spotlightPageControls(_ slides: [KakaNativeRoom], selection: String) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(slides.enumerated()), id: \.element.id) { index, room in
                let selected = room.id == selection
                Button { selectSpotlight(room.id) } label: {
                    Capsule()
                        .fill(selected ? directoryAccent : KakaTheme.ink.opacity(0.48))
                        .frame(width: selected ? 20 : 5, height: 4)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)
                        .background(KakaTheme.base.opacity(0.76), in: Capsule())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Featured room \(index + 1) of \(slides.count): \(room.title)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private func selectSpotlight(_ id: String) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.32)) {
            selectedSpotlightID = id
        }
    }

    private func spotlightHeight(_ width: CGFloat) -> CGFloat {
        max(spotlightCaptionHeight, min(156, width / 3.15))
    }

    private func featuredRoomButton(_ room: KakaNativeRoom, width: CGFloat, height: CGFloat) -> some View {
        let accent = directoryAccent
        let action = room.kind == .live ? "Watch live" : room.locked ? "Password required" : "Join voice"
        return Button { open(room) } label: {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(room.title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(KakaTheme.ink)
                        .lineLimit(2)
                    HStack(spacing: 5) {
                        KakaNativeImage(asset: room.kind.actionArt)
                            .frame(width: 17, height: 17)
                            .accessibilityHidden(true)
                        Text(action)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(accent)
                    }
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                if !textSize.isAccessibilitySize, width > 245 {
                    KakaRoomArt(asset: room.kind == .live ? "live-deck.jpg" : "voice-deck.jpg",
                                remote: room.cover, ratio: (width * 0.44) / max(1, height),
                                cropAlignment: room.kind == .live ? KakaLiveCardLayout.coverAlignment : .center)
                        .frame(width: width * 0.44, height: height)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: width, height: height)
            .background(accent.opacity(0.12))
            .background(KakaTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(KakaRoomCardPressStyle())
        .accessibilityLabel("\(action), \(room.title)")
        .accessibilityValue(roomCardDescription(room) ?? "")
    }

    private func liveStatusBadge(viewportHeight: CGFloat) -> some View {
        HStack(spacing: 5) {
            GeometryReader { geometry in
                let frame = geometry.frame(in: CoordinateSpace.named(Self.scrollSpace))
                let animates = cardMotionIsVisible(frame, viewportHeight: viewportHeight, tab: .live)
                TimelineView(.animation(minimumInterval: 1.0 / 12, paused: !animates)) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate * 2.2
                    Circle()
                        .fill(KakaTheme.liveAccent)
                        .opacity(animates ? 0.78 + 0.22 * sin(phase) : 1)
                }
            }
            .frame(width: 6, height: 6)
            Text("Live")
                .font(.caption2.weight(.bold))
                .foregroundStyle(KakaTheme.liveAccent)
        }
        .fixedSize()
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(KakaTheme.base.opacity(0.91), in: Capsule())
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func liveRoomButton(_ room: KakaNativeRoom, viewportHeight: CGFloat) -> some View {
        let description = roomCardDescription(room) ?? roomHostName(room)
        return Button { open(room) } label: {
            let art = KakaRoomArt(asset: room.kind.art, remote: room.cover,
                                  ratio: KakaLiveCardLayout.galleryRatio(for: textSize),
                                  cropAlignment: KakaLiveCardLayout.coverAlignment)
                .overlay(alignment: .topLeading) {
                    HStack(alignment: .top, spacing: 5) {
                        liveStatusBadge(viewportHeight: viewportHeight)
                        Spacer(minLength: 0)
                        if let count = room.viewers {
                            Text(count.formatted())
                                .font(.caption2.monospacedDigit().weight(.semibold))
                                .lineLimit(1)
                                .foregroundStyle(KakaTheme.ink)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 5)
                                .background(KakaTheme.base.opacity(0.91), in: Capsule())
                        }
                    }
                    .padding(8)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }

            VStack(spacing: 0) {
                if textSize.isAccessibilitySize {
                    art
                    liveRoomCaption(room, description: description)
                } else {
                    art
                        .overlay(alignment: .bottom) {
                            liveRoomCaption(room, description: description)
                                .padding(.top, 32)
                                .background {
                                    LinearGradient(stops: [
                                        .init(color: .clear, location: 0),
                                        .init(color: KakaTheme.base.opacity(0.90), location: 0.62),
                                        .init(color: KakaTheme.base.opacity(0.98), location: 1),
                                    ], startPoint: .top, endPoint: .bottom)
                                }
                        }
                }
            }
            .background(KakaTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(KakaRoomCardPressStyle())
        .accessibilityLabel("Watch \(room.title) live")
        .accessibilityValue([description, room.viewers.map { "\($0.formatted()) watching" }]
            .compactMap { $0 }.joined(separator: ", "))
    }

    private func liveRoomCaption(_ room: KakaNativeRoom, description: String?) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(room.title)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(textSize.isAccessibilitySize ? 3 : 2)
                if let description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(KakaTheme.muted)
                        .lineLimit(2)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            if !textSize.isAccessibilitySize {
                KakaNativeImage(asset: room.kind.actionArt)
                    .frame(width: 16, height: 16)
                    .frame(width: 30, height: 30)
                    .background(KakaTheme.liveAccent.opacity(0.16), in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(KakaTheme.ink)
        .padding(10)
    }

    private func roomCardDescription(_ room: KakaNativeRoom) -> String? {
        [room.description, room.topic].lazy
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .first { !$0.isEmpty && $0.caseInsensitiveCompare(room.title) != .orderedSame }
    }

    private func roomHostName(_ room: KakaNativeRoom) -> String? {
        guard let host = room.host, host.name != "Host",
              host.name.caseInsensitiveCompare(room.title) != .orderedSame else { return nil }
        return host.name
    }

    private func voiceRoomButton(_ room: KakaNativeRoom, viewportHeight: CGFloat) -> some View {
        let description = roomCardDescription(room)
        let category: String? = room.genre.isEmpty ? (room.format == "Voice room" ? nil : room.format) : room.genre
        return Button { open(room) } label: {
            HStack(alignment: .center, spacing: 10) {
                KakaRoomArt(asset: room.kind.art, remote: room.cover, ratio: 1, cropAlignment: .top)
                    .frame(width: textSize.isAccessibilitySize ? 56 : 76)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(room.title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(KakaTheme.ink)
                        .lineLimit(textSize.isAccessibilitySize ? 3 : 2)
                    if let description {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(KakaTheme.muted)
                            .lineLimit(textSize.isAccessibilitySize ? 2 : 1)
                    }
                    voiceRoomDetails(room, category: category)
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                if room.locked, !textSize.isAccessibilitySize {
                    Text("Locked")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(KakaTheme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                        .background(KakaTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                } else if !room.locked, !textSize.isAccessibilitySize {
                    voiceActionIcon(room, size: 33, viewportHeight: viewportHeight)
                }
            }
            .padding(9)
            .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(KakaRoomCardPressStyle())
        .accessibilityLabel(room.locked ? "Open locked room \(room.title)" : "Join \(room.title)")
        .accessibilityValue([description, category, roomHostName(room), room.viewers.map { "\($0.formatted()) in room" }]
            .compactMap { $0 }.joined(separator: ", "))
    }

    private func voiceRoomDetails(_ room: KakaNativeRoom, category: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if room.locked, textSize.isAccessibilitySize {
                Text("Locked")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(KakaTheme.accent)
            }
            HStack(spacing: 5) {
                if let portrait = room.host?.portrait, !textSize.isAccessibilitySize {
                    KakaRoomArt(asset: "member-mark.jpg", remote: portrait, ratio: 1)
                        .frame(width: 18)
                        .clipShape(Circle())
                }
                if let category {
                    Text(category)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(KakaTheme.voiceAccent)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(KakaTheme.voiceAccent.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
                }
                if let count = room.viewers {
                    Text("\(count.formatted()) in room")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(KakaTheme.muted)
                        .lineLimit(1)
                        .layoutPriority(1)
                } else if category == nil, let name = roomHostName(room) {
                    Text(name)
                        .font(.caption2)
                        .foregroundStyle(KakaTheme.muted)
                        .lineLimit(1)
                }
            }
        }
    }

    private func voiceActionIcon(_ room: KakaNativeRoom, size: CGFloat, viewportHeight: CGFloat) -> some View {
        KakaNativeImage(asset: room.kind.actionArt)
            .frame(width: 19, height: 19)
            .frame(width: size, height: size)
            .background(KakaTheme.voiceAccent.opacity(0.11), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                GeometryReader { geometry in
                    let frame = geometry.frame(in: CoordinateSpace.named(Self.scrollSpace))
                    let animates = !room.locked && cardMotionIsVisible(frame, viewportHeight: viewportHeight, tab: .voice)
                    TimelineView(.animation(minimumInterval: 1.0 / 12, paused: !animates)) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate * 2.2 + Double(room.serverID % 7)
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(KakaTheme.voiceAccent.opacity(animates ? 0.33 + 0.14 * sin(phase) : 0.26), lineWidth: 1)
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func cardMotionIsVisible(_ frame: CGRect, viewportHeight: CGFloat, tab: KakaNativeTab) -> Bool {
        viewportHeight > 0 && frame.maxY > 0 && frame.minY < viewportHeight
            && !reduceMotion && scenePhase == .active && store.tab == tab && store.route == nil
    }

    private func open(_ room: KakaNativeRoom) {
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
            if live {
                let loadedIDs = Set(result.map(\.id))
                if !append, page > 0 { newLiveRoomIDs.formUnion(loadedIDs.subtracting(seenLiveRoomIDs)) }
                seenLiveRoomIDs.formUnion(loadedIDs)
            }
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

private enum KakaLiveCardLayout {
    private enum CoverFocus: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context.height * 0.28 }
    }

    static let coverAlignment = Alignment(horizontal: .center, vertical: VerticalAlignment(CoverFocus.self))

    static func galleryRatio(for textSize: DynamicTypeSize) -> CGFloat {
        textSize.isAccessibilitySize ? 4 / 3 : 2 / 3
    }
}

private struct KakaRoomCardPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

private struct KakaDirectoryLoading: View {
    @EnvironmentObject private var store: KakaNativeStore
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    let title: String
    let columns: [GridItem]
    var spotlightHeight: CGFloat? = nil
    var kind: KakaNativeRoom.Kind = .live

    private var paused: Bool {
        let tab: KakaNativeTab = kind == .live ? .live : .voice
        return reduceMotion || scenePhase != .active || store.tab != tab || store.route != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(KakaTheme.muted)

            TimelineView(.animation(minimumInterval: 1.0 / 18, paused: paused)) { context in
                let pulse = sin(context.date.timeIntervalSinceReferenceDate * 3.5)
                VStack(alignment: .leading, spacing: 12) {
                    if let spotlightHeight {
                        Self.heroPlaceholder(height: spotlightHeight)
                    }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: kind == .voice ? 10 : 18) {
                        ForEach(0..<(columns.count * (kind == .voice ? 2 : 1)), id: \.self) { _ in
                            if kind == .voice {
                                voicePlaceholder
                            } else {
                                RoundedRectangle(cornerRadius: 17, style: .continuous)
                                    .fill(KakaTheme.surface)
                                    .aspectRatio(KakaLiveCardLayout.galleryRatio(for: textSize), contentMode: .fit)
                                    .overlay(alignment: .bottomLeading) {
                                        Capsule()
                                            .fill(KakaTheme.accent.opacity(0.17))
                                            .frame(maxWidth: 84)
                                            .frame(height: 9)
                                            .padding(12)
                                    }
                            }
                        }
                    }
                }
                .opacity(paused ? 1 : 0.86 + 0.12 * pulse)
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
    }

    static func heroPlaceholder(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Capsule().fill(KakaTheme.accent.opacity(0.20)).frame(maxWidth: 120).frame(height: 14)
            Capsule().fill(KakaTheme.accent.opacity(0.13)).frame(maxWidth: 84).frame(height: 9)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: height, alignment: .bottomLeading)
        .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var voicePlaceholder: some View {
        let thumbnailSize: CGFloat = textSize.isAccessibilitySize ? 54 : 68
        return HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(KakaTheme.accent.opacity(0.15))
                .frame(width: thumbnailSize, height: thumbnailSize)
            VStack(alignment: .leading, spacing: 9) {
                Capsule().fill(KakaTheme.accent.opacity(0.20)).frame(maxWidth: 124).frame(height: 9)
                Capsule().fill(KakaTheme.accent.opacity(0.13)).frame(maxWidth: 70).frame(height: 7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
    @Environment(\.dynamicTypeSize) private var textSize
    @ObservedObject private var media = KakaNativeRoomRuntime.shared.media
    let room: KakaNativeRoom
    let isMinimized: Bool
    let onMinimize: (() -> Void)?
    let onRestore: (() -> Void)?
    let onClose: (() -> Void)?

    @State private var details: KakaNativeRoom?
    @State private var visit: UUID?
    @State private var connectionTask: Task<Void, Never>?
    @State private var seatPoll: Task<Void, Never>?
    @State private var connected = false
    @State private var connecting = false
    @State private var entryPending = true
    @State private var connectionError = ""
    @State private var enteredPassword = ""
    @State private var seat = SeatStatus()
    @State private var updatingSeat = false
    @State private var seatRefreshFailed = false
    @State private var activeSheet: RoomSheet?
    @State private var selectedLiveGiftID: Int64?
    @State private var changingSavedRooms = false
    @State private var followableHostID: Int64?
    @State private var changingFollow = false
    @State private var hideAfterConfirm = false
    @State private var cueExpanded = false
    @State private var metronome: KakaRoomMetronome?
    @State private var metronomeStart: Task<Void, Never>?
    @State private var beat: Int?

    init(room: KakaNativeRoom, isMinimized: Bool = false, onMinimize: (() -> Void)? = nil,
         onRestore: (() -> Void)? = nil, onClose: (() -> Void)? = nil) {
        self.room = room
        self.isMinimized = isMinimized
        self.onMinimize = onMinimize
        self.onRestore = onRestore
        self.onClose = onClose
    }

    private enum RoomSheet: String, Identifiable {
        case notes, report, gifts, hide, options, people, hostProfile, messageHost, info, share, leaveLive
        var id: Self { self }
    }

    private struct SeatStatus {
        var index: Int64 = 0
        var microphone = false
        var queued = false
        var stage: [KakaRealtimeMedia.VoiceStageSeat]?
    }

    private var runtime: KakaNativeRoomRuntime { .shared }
    private var current: KakaNativeRoom { details ?? room }
    private var waitingForEntry: Bool { entryPending && !current.locked }
    private var openingConnection: Bool { waitingForEntry || connecting }
    private var displayingLiveVideo: Bool { connected && media.hasReceivedLiveFrame }
    private var liveConnectionTitle: String {
        if openingConnection { return "Connecting to live…" }
        if connected { return "Waiting for live video…" }
        return connectionError.isEmpty ? "Playback stopped" : "Couldn’t start the live stream"
    }
    private var carried: [String: Any]? {
        guard room.kind == .voice, let score = store.practiceScore,
              (score["roomID"] as? String) == room.id else { return nil }
        return score
    }
    private var tempo: Int? { (carried?["bpm"] as? Int) ?? current.bpm }
    private var isFavorite: Bool { (store.record["favorites"] as? [String] ?? []).contains(room.id) }

    var body: some View {
        Group {
            if room.kind == .live {
                liveStage
            } else {
                voiceRoom
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .notes:
                KakaRoomTextSheet(mode: .note, room: current)
            case .report:
                KakaRoomTextSheet(mode: .report, room: current)
            case .gifts:
                if let visit {
                    KakaRoomGiftSheet(room: current, visit: visit, initialGiftID: selectedLiveGiftID)
                }
            case .hide:
                KakaRoomTextSheet(mode: .hide, room: current, onHidden: { hideAfterConfirm = true })
            case .options:
                roomOptions
            case .people:
                if let visit { KakaRoomAudienceSheet(room: current, visit: visit) }
            case .hostProfile:
                if let host = current.host { roomHostProfile(host) }
            case .messageHost:
                if let host = current.host {
                    KakaRoomSheet(title: "Message \(host.name)", locked: false) {
                        KakaNativeChatView(hostID: host.id)
                    }
                }
            case .info:
                roomInfo
            case .share:
                KakaRoomSharing(text: "\(current.title) · Kaka \(current.kind == .live ? "live" : "voice") room \(current.serverID)")
            case .leaveLive:
                liveExitOptions
            }
        }
        .onChange(of: hideAfterConfirm) { hidden in
            if hidden, activeSheet == nil { store.back() }
        }
        .onChange(of: activeSheet) { sheet in
            if sheet == nil, hideAfterConfirm { store.back() }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                if !current.locked, connecting || connected { entryPending = true }
                stopConnection()
            }
        }
        .onDisappear { stopConnection() }
        .task(id: scenePhase) {
            guard waitingForEntry, !Task.isCancelled else { return }
            startConnection()
        }
        .task(id: current.host?.id) {
            await loadRoomFollow()
        }
    }

    private var liveStage: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let reservedHeight: CGFloat = textSize.isAccessibilitySize || !displayingLiveVideo ? 330 : 252
            let chatHeight = min(158, height * 0.24, max(0, height - reservedHeight))
            VStack(spacing: 10) {
                liveHeader
                Spacer(minLength: 4)
                if !displayingLiveVideo {
                    liveConnectionStatus(compact: height < 330)
                    Spacer(minLength: 4)
                }
                if let visit, connected {
                    if height >= 430, let announcement = liveAnnouncement {
                        Text(announcement)
                            .font(.footnote)
                            .lineLimit(2)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(KakaTheme.surface.opacity(0.93), in: RoundedRectangle(cornerRadius: 12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel("Room announcement. \(announcement)")
                    }
                    VStack(alignment: .trailing, spacing: 7) {
                        if textSize.isAccessibilitySize { roomOptionsButton }
                        HStack(alignment: .bottom, spacing: 8) {
                            KakaNativeChatView(room: current, visit: visit, liveOverlayHeight: chatHeight,
                                               onGifts: { openGiftCatalog() }, onGiftSelected: { openGiftCatalog($0) },
                                               isMinimized: isMinimized)
                            .id(visit)
                            if !textSize.isAccessibilitySize { roomOptionsButton }
                        }
                    }
                } else {
                    roomOptionsButton.frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, geometry.size.width < 350 ? 12 : 16)
            .padding(.vertical, 8)
            .frame(maxWidth: 680, maxHeight: .infinity)
            .frame(maxWidth: .infinity)
            .opacity(isMinimized ? 0 : 1)
            .allowsHitTesting(!isMinimized)
            .accessibilityHidden(isMinimized)
        }
        .foregroundStyle(KakaTheme.ink)
        .background { liveCanvas }
        .overlay { if isMinimized { compactLiveControls } }
    }

    private func openGiftCatalog(_ giftID: Int64? = nil) {
        selectedLiveGiftID = giftID
        activeSheet = .gifts
    }

    private var compactLiveControls: some View {
        ZStack(alignment: .topTrailing) {
            Button { onRestore?() } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Spacer(minLength: 0)
                    Text(displayingLiveVideo ? "Live" : "Open live room")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(KakaTheme.liveAccent)
                    Text(current.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(KakaTheme.ink)
                        .lineLimit(1)
                }
                .padding(9)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Restore live room, \(current.title)")
            roomCloseButton(label: "Close mini player", action: exitRoom)
                .padding(3)
        }
    }

    private var liveAnnouncement: String? {
        if !current.description.isEmpty, current.description != current.title { return current.description }
        return current.topic == current.title ? nil : current.topic
    }

    private var liveCanvas: some View {
        GeometryReader { geometry in
            ZStack {
                KakaTheme.base
                if !displayingLiveVideo {
                    KakaNativeImage(asset: room.kind.art, remote: current.cover)
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                    KakaTheme.base.opacity(0.55)
                }
                if connected {
                    KakaNativeVideo(media: media)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.76), location: 0),
                    .init(color: .clear, location: 0.30),
                    .init(color: .clear, location: 0.54),
                    .init(color: .black.opacity(0.77), location: 1),
                ], startPoint: .top, endPoint: .bottom)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(RoundedRectangle(cornerRadius: isMinimized ? 15 : 0))
        }
        .ignoresSafeArea(isMinimized ? [] : .all)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var liveHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let host = current.host {
                    Button { activeSheet = .hostProfile } label: {
                        liveIdentity(host: host)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the host profile")
                } else {
                    liveIdentity(host: nil)
                }
                Spacer(minLength: 0)
                if let host = current.host { roomFollowButton(host) }
                leaveRoomButton
            }
            if connected {
                HStack(spacing: 6) {
                    peopleButton
                    if current.host != nil {
                        KakaRoomButton(title: "Message") { activeSheet = .messageHost }
                            .accessibilityLabel("Message the host")
                    }
                }
            }
        }
    }

    private var roomOptionsButton: some View {
        KakaRoomButton(title: "More") { activeSheet = .options }
            .accessibilityLabel("Room options")
    }

    private var leaveRoomButton: some View {
        roomCloseButton(label: room.kind == .live ? "Leave live room" : "Leave voice room") {
            if room.kind == .live, connected, onMinimize != nil {
                activeSheet = .leaveLive
            } else {
                exitRoom()
            }
        }
    }

    private func roomCloseButton(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            KakaNativeImage(asset: "action-close.png")
                .frame(width: 22, height: 22)
                .frame(width: 44, height: 44)
                .modifier(KakaGlass(interactive: true, radius: 22, tint: .black.opacity(0.40)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var peopleButton: some View {
        KakaRoomButton(title: "People") { activeSheet = .people }
            .accessibilityLabel("Online chat participants")
    }

    private var liveExitOptions: some View {
        KakaRoomSheet(title: "Leave live room?", locked: false) {
            KakaRoomActionGroup {
                KakaRoomButton(title: "Exit room") { exitRoom() }
                if connected, let onMinimize {
                    KakaRoomButton(title: "Minimize player", selected: true) {
                        activeSheet = nil
                        onMinimize()
                    }
                }
            }
        }
    }

    private func exitRoom() {
        activeSheet = nil
        if let onClose { onClose() }
        else { store.back() }
    }

    @ViewBuilder
    private func roomFollowButton(_ host: KakaNativeHost) -> some View {
        if followableHostID == host.id {
            let followed = store.followedIDs.contains(host.id)
            KakaRoomButton(title: followed ? "Following" : "Follow", selected: followed) {
                Task { await toggleRoomFollow(host) }
            }
            .disabled(changingFollow)
            .accessibilityHint(followed ? "Unfollows this host" : "Follows this host")
        }
    }

    private func roomHostProfile(_ host: KakaNativeHost) -> some View {
        KakaRoomSheet(title: host.name, locked: false) {
            HStack(alignment: .top, spacing: 12) {
                KakaRoomArt(asset: "member-mark.jpg", remote: host.portrait, ratio: 1)
                    .frame(width: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .accessibilityHidden(true)
                if !host.bio.isEmpty {
                    Text(host.bio).font(.subheadline).foregroundStyle(KakaTheme.muted)
                }
            }
            KakaRoomActionGroup {
                roomFollowButton(host)
                KakaRoomButton(title: "Message") { activeSheet = .messageHost }
            }
            KakaRoomButton(title: "View full profile") {
                activeSheet = nil
                store.open(.host(host))
            }
        }
    }

    private func loadRoomFollow() async {
        followableHostID = nil
        guard let host = current.host, let session = store.session?.token else { return }
        do {
            let blocked = try await store.request("creator.blocked", ["userID": host.id])
            guard blocked as? Bool == false, !Task.isCancelled, store.session?.token == session else { return }
            try await store.loadFollowing()
            guard !Task.isCancelled, current.host?.id == host.id, store.session?.token == session else { return }
            followableHostID = host.id
        } catch {
            // Keep the action out of the room header when relationship state can't be verified.
        }
    }

    private func toggleRoomFollow(_ host: KakaNativeHost) async {
        guard !changingFollow, followableHostID == host.id, let session = store.session?.token else { return }
        changingFollow = true
        defer { changingFollow = false }
        do {
            try await store.toggleFollow(host)
        } catch {
            if store.session?.token == session { store.notify(store.message(error)) }
        }
    }

    private func liveIdentity(host: KakaNativeHost?) -> some View {
        HStack(spacing: 8) {
            if let host, !textSize.isAccessibilitySize {
                KakaRoomArt(asset: "member-mark.jpg", remote: host.portrait, ratio: 1)
                    .frame(width: 34)
                    .clipShape(Circle())
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(current.title)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(textSize.isAccessibilitySize ? 2 : 1)
                if displayingLiveVideo {
                    HStack(spacing: 5) {
                        Text("Live")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(KakaTheme.liveAccent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(KakaTheme.liveAccent.opacity(0.16), in: Capsule())
                        if let viewers = current.viewers, viewers > 0 {
                            Text("\(viewers.formatted()) watching")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(KakaTheme.muted)
                                .lineLimit(1)
                        }
                    }
                } else if let host, host.name != current.title, host.name != "Host" {
                    Text(host.name).font(.caption2).foregroundStyle(KakaTheme.muted).lineLimit(1)
                }
            }
            .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(minWidth: 44, minHeight: 44)
        .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 16))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func liveConnectionStatus(compact: Bool) -> some View {
        VStack(spacing: 8) {
            if !compact && (openingConnection || connected) {
                KakaRhythmProgress(title: "Loading live video").accessibilityHidden(true)
            }
            Text(liveConnectionTitle)
                .font(compact ? .subheadline.weight(.semibold) : .headline)
                .accessibilityAddTraits(.updatesFrequently)
            if !connectionError.isEmpty {
                Text(connectionError).font(.footnote).foregroundStyle(KakaTheme.muted)
            }
            if !openingConnection && !connected {
                KakaRoomButton(title: connectionTitle, asset: room.kind.actionArt) { startConnection() }
            }
        }
        .multilineTextAlignment(.center)
        .padding(compact ? 10 : 16)
        .background(.black.opacity(0.60), in: RoundedRectangle(cornerRadius: 18))
        .frame(maxWidth: 360)
    }

    private var roomOptions: some View {
        KakaRoomSheet(title: "Room options", locked: false) {
            KakaRoomButton(title: "Room info") { activeSheet = .info }
            KakaRoomButton(title: "Share room") { activeSheet = .share }
            if room.kind == .voice, current.host != nil {
                KakaRoomButton(title: "Message the host") { activeSheet = .messageHost }
            }
            if connected || connecting {
                KakaRoomButton(title: connectionTitle, asset: "action-stop.png") {
                    activeSheet = nil
                    stopConnection()
                }
            }
            personalActions
            if room.kind == .live { safetyActions }
        }
    }

    private var roomInfo: some View {
        KakaRoomSheet(title: current.title, locked: false) {
            Text("Room \(current.serverID) · \(current.format)")
                .font(.subheadline)
                .foregroundStyle(KakaTheme.muted)
                .textSelection(.enabled)
            roomDescription
            KakaRoomButton(title: "Share room") { activeSheet = .share }
        }
    }

    private var voiceRoom: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let roomForChat = min(150, height * 0.23, max(0, height - (textSize.isAccessibilitySize ? 385 : 300)))
            VStack(spacing: 0) {
                voiceHeader
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if connected {
                            voiceStage
                        } else {
                            voiceConnectionControls
                        }
                        if !connectionError.isEmpty {
                            Text(connectionError)
                                .font(.subheadline)
                                .foregroundStyle(KakaTheme.muted)
                                .accessibilityAddTraits(.updatesFrequently)
                        }
                        practiceControls
                    }
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let visit, connected {
                    VStack(alignment: .leading, spacing: 7) {
                        KakaNativeChatView(room: room, visit: visit, liveOverlayHeight: roomForChat,
                                           showsQuickReplies: true)
                            .id(visit)
                        KakaRoomActionGroup { voiceSeatButtons }
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .padding(.top, 7)
                }
            }
            .padding(.horizontal, geometry.size.width < 350 ? 12 : 16)
            .padding(.vertical, 8)
            .frame(maxWidth: 680, maxHeight: .infinity)
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(KakaTheme.ink)
        .background { voiceCanvas }
    }

    private var voiceCanvas: some View {
        GeometryReader { geometry in
            KakaNativeImage(asset: room.kind.art, remote: current.cover)
                .scaledToFill()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .overlay {
                    LinearGradient(
                        colors: [KakaTheme.base.opacity(0.82), KakaTheme.base.opacity(0.90), KakaTheme.base],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                }
        }
        .background(KakaTheme.base)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var roomDescription: some View {
        VStack(alignment: .leading, spacing: 6) {
            if current.topic != current.title {
                Text(current.topic).font(.headline)
            }
            if !current.description.isEmpty {
                Text(current.description).font(.subheadline).foregroundStyle(KakaTheme.muted)
            }
        }
    }

    private var voiceHeader: some View {
        HStack(spacing: 8) {
            if !textSize.isAccessibilitySize {
                KakaNativeImage(asset: room.kind.art, remote: current.cover)
                    .scaledToFill()
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 13))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(current.title)
                    .font(.headline)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                Text(voiceStatus)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(connected ? KakaTheme.voiceAccent : KakaTheme.muted)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            roomOptionsButton
            leaveRoomButton
        }
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            KakaTheme.line.frame(height: 1).allowsHitTesting(false)
        }
    }

    private var voiceStatus: String {
        if connected {
            if seat.queued { return "Waiting for a seat" }
            if seat.index == 0 { return "Listening" }
            if seatRefreshFailed { return "Seat status unavailable" }
            return seat.microphone ? "Microphone on" : "Microphone muted"
        }
        if openingConnection { return "Connecting" }
        if current.locked { return "Password required" }
        return current.format
    }

    private var voiceStage: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let host = current.host {
                Button { activeSheet = .hostProfile } label: {
                    HStack(spacing: 10) {
                        KakaRoomArt(asset: "member-mark.jpg", remote: host.portrait, ratio: 1)
                            .frame(width: 50)
                            .clipShape(Circle())
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(host.name).font(.subheadline.weight(.bold)).lineLimit(2)
                            if host.name != "Host" {
                                Text("Room host").font(.caption).foregroundStyle(KakaTheme.muted)
                            }
                        }
                        Spacer(minLength: 6)
                        if let tempo {
                            Text("\(tempo) BPM")
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(KakaTheme.accent)
                        }
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the host profile")
            }
            HStack {
                Text("Mic seats").font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                peopleButton
            }
            if let seats = seat.stage {
                if seats.isEmpty {
                    Text("No mic seats available.").font(.footnote).foregroundStyle(KakaTheme.muted)
                } else {
                    let occupied = seats.filter { $0.occupant != nil }
                    if !occupied.isEmpty { voiceSpeakers(occupied) }
                    let minimum: CGFloat = textSize.isAccessibilitySize ? 124 : 65
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: 8, alignment: .top)], spacing: 13) {
                        ForEach(seats.filter { $0.occupant == nil }) { voiceSeatTile($0) }
                    }
                }
            }
            if seatRefreshFailed || seat.stage == nil {
                Text(seatRefreshFailed ? "Couldn’t refresh seats. Retrying…" : "Loading seats…")
                    .font(.footnote)
                    .foregroundStyle(KakaTheme.muted)
            }
        }
    }

    private func voiceSpeakers(_ positions: [KakaRealtimeMedia.VoiceStageSeat]) -> some View {
        GeometryReader { geometry in
            let width = min(132, max(86, (geometry.size.width - 16) / (textSize.isAccessibilitySize ? 2 : 3)))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(positions) { position in
                        voiceSpeaker(position, width: width)
                    }
                }
            }
        }
        .frame(height: textSize.isAccessibilitySize ? 166 : 134)
    }

    private func voiceSpeaker(_ position: KakaRealtimeMedia.VoiceStageSeat, width: CGFloat) -> some View {
        let mine = position.index == seat.index
        let host = current.host.flatMap { $0.id == position.occupant ? $0 : nil }
        let memberName = position.name.isEmpty ? host?.name ?? "" : position.name
        let name = mine ? "You" : (memberName.isEmpty ? "Seat \(position.index)" : memberName)
        let microphone = mine ? seat.microphone : position.microphoneEnabled
        let status = microphone.map { $0 ? "Mic on" : "Muted" }
        let height: CGFloat = textSize.isAccessibilitySize ? 166 : 134
        return ZStack(alignment: .bottomLeading) {
            if let portrait = position.portrait ?? host?.portrait {
                KakaNativeImage(asset: "member-mark.jpg", remote: portrait)
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
                    .accessibilityHidden(true)
            } else {
                Text(memberName.isEmpty ? position.index.formatted() : String(memberName.prefix(1)))
                    .font(.title.weight(.semibold))
                    .foregroundStyle(KakaTheme.voiceAccent)
                    .frame(width: width, height: height)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.caption.weight(.semibold)).lineLimit(1)
                if let status {
                    Text(status)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(microphone == true ? KakaTheme.voiceAccent : KakaTheme.muted)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(KakaTheme.base.opacity(0.86))
        }
        .frame(width: width, height: height)
        .background(KakaTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func voiceSeatTile(_ position: KakaRealtimeMedia.VoiceStageSeat) -> some View {
        if position.locked {
            voiceSeatBadge(position)
                .accessibilityLabel("Seat \(position.index), locked")
        } else {
            Button {
                Task { await updateSeat("voiceSeat.take", requestedSeat: position.index) }
            } label: {
                voiceSeatBadge(position)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(seat.index > 0 || seat.queued || updatingSeat || seatRefreshFailed)
            .accessibilityLabel("Request seat \(position.index)")
        }
    }

    private func voiceSeatBadge(_ position: KakaRealtimeMedia.VoiceStageSeat) -> some View {
        VStack(spacing: 5) {
            Text(position.index.formatted())
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 48, height: 48)
                .background(KakaTheme.surface, in: Circle())
                .overlay(Circle().strokeBorder(KakaTheme.voiceAccent.opacity(position.locked ? 0.13 : 0.48)))
            Text(position.locked ? "Locked" : "Open")
                .font(.caption)
                .foregroundStyle(KakaTheme.muted)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var voiceConnectionControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            if current.locked, !connected {
                SecureField("Room password", text: $enteredPassword)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 46)
                    .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Room password")
                    .disabled(connecting)
                    .onSubmit { startConnection() }
            }
            if openingConnection {
                HStack(spacing: 10) {
                    KakaRhythmProgress(title: "Connecting").accessibilityHidden(true)
                    Text("Connecting to room audio…")
                        .font(.subheadline).foregroundStyle(KakaTheme.muted)
                }
            }
            if !waitingForEntry {
                KakaRoomButton(title: connectionTitle, asset: connected || connecting ? "action-stop.png" : room.kind.actionArt,
                               selected: connected) {
                    if connected || connecting { stopConnection() }
                    else { startConnection() }
                }
            }
        }
    }

    private var connectionTitle: String {
        if connecting { return "Cancel" }
        if connected { return room.kind == .live ? "Stop watching" : "Leave audio" }
        if current.locked { return "Join room" }
        if !connectionError.isEmpty { return room.kind == .live ? "Retry live" : "Retry audio" }
        return room.kind == .live ? "Resume live" : "Resume audio"
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
        if !connected, !openingConnection, let tempo {
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
        if current.locked {
            guard !enteredPassword.isEmpty, enteredPassword.utf8.count <= 96 else {
                connectionError = "Enter the room password."
                return
            }
            password = enteredPassword
            enteredPassword = ""
        }
        stopBeat()
        entryPending = false
        let newVisit = UUID()
        visit = newVisit
        connecting = true
        connectionError = ""
        connectionTask = Task { @MainActor in
            do {
                if room.kind == .live { try await refreshLive(visit: newVisit, session: session) }
                try Task.checkCancellation()
                guard visit == newVisit, store.session?.token == session,
                      scenePhase != .background else { throw CancellationError() }
                try await runtime.join(newVisit, room: current, password: password, session: session)
                try Task.checkCancellation()
                guard visit == newVisit, store.session?.token == session, scenePhase != .background else {
                    runtime.leave(newVisit)
                    throw CancellationError()
                }
                connected = true
                connecting = false
                if room.kind == .voice {
                    store.recordVoiceRoomVisit(current)
                    observeSeat()
                }
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
        seatRefreshFailed = false
        if activeSheet == .gifts || activeSheet == .people || activeSheet == .leaveLive {
            activeSheet = nil
        }
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

    private func updateSeat(_ operation: String, requestedSeat: Int64? = nil) async {
        guard !updatingSeat, connected, let visit, runtime.owns(visit), let session = store.session?.token else { return }
        updatingSeat = true
        defer { if self.visit == visit { updatingSeat = false } }
        if operation != "voiceSeat.status" { connectionError = "" }
        do {
            let result = try await runtime.media.voiceSeat(operation: operation, roomID: room.serverID,
                                                            enabled: operation == "voiceSeat.microphone" ? !seat.microphone : nil,
                                                            requestedSeat: requestedSeat, session: session)
            guard self.visit == visit, store.session?.token == session else { return }
            seat = SeatStatus(index: KakaRemoteClient.userID(result["index"]) ?? 0,
                              microphone: result["microphone"] as? Bool ?? false,
                              queued: result["queued"] as? Bool ?? false,
                              stage: result["stageSeats"] as? [KakaRealtimeMedia.VoiceStageSeat])
            seatRefreshFailed = false
        } catch {
            guard self.visit == visit else { return }
            store.expireIfNeeded(error)
            if operation == "voiceSeat.status" { seatRefreshFailed = true }
            else { connectionError = store.message(error) }
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
private struct KakaRoomAudienceSheet: View {
    @EnvironmentObject private var store: KakaNativeStore
    let room: KakaNativeRoom
    let visit: UUID

    @State private var members: [KakaRoomChat.AudienceMember] = []
    @State private var nextPageToken: String?
    @State private var visitedTokens: Set<String> = []
    @State private var loading = false
    @State private var loaded = false
    @State private var error = ""

    var body: some View {
        KakaRoomSheet(title: "People in chat", locked: false) {
            if loading && members.isEmpty {
                KakaRhythmProgress(title: "Loading chat participants")
            }
            if !error.isEmpty {
                Text(error).font(.footnote).foregroundStyle(KakaTheme.muted)
                KakaRoomButton(title: "Try again") { Task { await load() } }
                    .disabled(loading)
            } else if loaded && members.isEmpty {
                Text(nextPageToken == nil ? "No visible participants right now." : "No visible participants on this page.")
                    .font(.subheadline).foregroundStyle(KakaTheme.muted)
            }
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(members) { member in
                    HStack(spacing: 10) {
                        if let portrait = member.portrait {
                            KakaNativeImage(asset: "member-mark.jpg", remote: portrait)
                                .scaledToFill()
                                .frame(width: 36, height: 36)
                                .clipShape(Circle())
                                .accessibilityHidden(true)
                        }
                        Text(member.name).font(.subheadline.weight(.medium))
                    }
                    .frame(minHeight: 40, alignment: .leading)
                }
            }
            if nextPageToken != nil, error.isEmpty {
                KakaRoomButton(title: loading ? "Loading…" : "Show more") { Task { await load() } }
                    .disabled(loading)
            }
        }
        .task { await load() }
    }

    private func load() async {
        let runtime = KakaNativeRoomRuntime.shared
        guard !loading, runtime.owns(visit), let session = store.session?.token else { return }
        loading = true
        error = ""
        defer { loading = false }
        let pageToken = nextPageToken
        do {
            let page = try await runtime.chat.audience(kind: room.kind.rawValue, serverID: room.serverID,
                                                       session: session, pageToken: pageToken)
            guard !Task.isCancelled, runtime.owns(visit), store.session?.token == session else { return }
            var known = Set(members.map(\.id))
            members.append(contentsOf: page.members.filter { known.insert($0.id).inserted })
            if let pageToken { visitedTokens.insert(pageToken) }
            nextPageToken = page.nextPageToken.flatMap { visitedTokens.contains($0) ? nil : $0 }
            loaded = true
        } catch {
            guard !Task.isCancelled, runtime.owns(visit), store.session?.token == session else { return }
            store.expireIfNeeded(error)
            self.error = "Couldn’t load chat participants. Try again in a moment."
        }
    }
}

private struct KakaRoomSharing: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let target: Target
    private let liveOverlayHeight: CGFloat?
    private let onGifts: (() -> Void)?
    private let onGiftSelected: ((Int64) -> Void)?
    private let showsQuickReplies: Bool
    private let isMinimized: Bool
    @FocusState private var focused: Bool
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

    init(hostID: Int64) {
        target = .direct(hostID)
        liveOverlayHeight = nil
        onGifts = nil
        onGiftSelected = nil
        showsQuickReplies = false
        isMinimized = false
    }

    init(room: KakaNativeRoom, visit: UUID, liveOverlayHeight: CGFloat? = nil, onGifts: (() -> Void)? = nil,
         onGiftSelected: ((Int64) -> Void)? = nil, showsQuickReplies: Bool = false, isMinimized: Bool = false) {
        target = .room(room, visit)
        self.liveOverlayHeight = liveOverlayHeight
        self.onGifts = onGifts
        self.onGiftSelected = onGiftSelected
        self.showsQuickReplies = showsQuickReplies
        self.isMinimized = isMinimized
    }

    var body: some View {
        Group {
            if let liveOverlayHeight {
                liveOverlay(transcriptHeight: liveOverlayHeight)
            } else {
                chatPanel
            }
        }
        .task(id: retry) { await watch() }
        .onChange(of: isMinimized) { minimized in
            if minimized { focused = false }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background { close() }
            else if phase == .active && !connected { retry += 1 }
        }
        .onDisappear { close() }
    }

    private var chatPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(target.title).font(.headline).accessibilityAddTraits(.isHeader)
            if !transcript.isEmpty { messages() }
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
    }

    private var liveBackdrop: Color { .black.opacity(reduceTransparency ? 1 : 0.74) }

    private var liveStatus: String? {
        if !feedback.isEmpty { return feedback }
        if !connected { return "Connecting to chat…" }
        if !canSend { return "Chat is read-only." }
        return nil
    }

    private func liveOverlay(transcriptHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if !transcript.isEmpty {
                messages(liveHeight: max(0, transcriptHeight))
            }
            if let liveStatus {
                Text(liveStatus)
                    .font(.footnote)
                    .foregroundStyle(KakaTheme.ink)
                    .lineLimit(2)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(liveBackdrop, in: RoundedRectangle(cornerRadius: 12))
            }
            if !feedback.isEmpty, !connected {
                KakaRoomButton(title: "Retry chat") { retry += 1 }
            }
            if let onGiftSelected, case .room(let room, let visit) = target {
                let showPreview = !isMinimized && transcriptHeight >= 70
                KakaLiveGiftRail(room: room, visit: visit, onSelect: onGiftSelected)
                    .frame(height: showPreview ? nil : 0)
                    .clipped()
                    .allowsHitTesting(showPreview)
                    .accessibilityHidden(!showPreview)
            }
            if showsQuickReplies, canSend, !focused, input.isEmpty, transcriptHeight >= 45 {
                quickReplies
            }
            HStack(spacing: 8) {
                liveComposer
                if let onGifts {
                    Button(action: onGifts) {
                        Text("Gifts")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(KakaTheme.ink)
                            .padding(.horizontal, 12)
                            .frame(minWidth: 44, minHeight: 44)
                            .background(liveBackdrop, in: Capsule())
                            .modifier(KakaGlass(interactive: true, radius: 24, tint: KakaTheme.accent.opacity(0.18)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var quickReplies: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(["Hey, everyone!", "Good to hear you", "What are we listening to?"], id: \.self) { prompt in
                    Button {
                        input = prompt
                        focused = true
                    } label: {
                        Text(prompt)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(KakaTheme.voiceAccent)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .background(liveBackdrop, in: Capsule())
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Adds this text to the message field")
                }
            }
        }
    }

    private var liveComposer: some View {
        HStack(spacing: 2) {
            TextField("Write a message", text: $input)
                .foregroundStyle(KakaTheme.ink)
                .tint(KakaTheme.accent)
                .textInputAutocapitalization(.sentences)
                .submitLabel(.send)
                .focused($focused)
                .padding(.leading, 12)
                .frame(minHeight: 44)
                .onSubmit { submit() }
                .disabled(!canSend)
            Button { submit() } label: {
                KakaNativeImage(asset: "action-forward.png")
                    .scaledToFit()
                    .frame(width: 19, height: 19)
                    .frame(width: 44, height: 44)
                    .opacity(sending || !canSend || trimmed.isEmpty ? 0.45 : 1)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(sending ? "Sending message" : "Send message")
            .disabled(sending || !canSend || trimmed.isEmpty)
        }
        .background(liveBackdrop, in: Capsule())
        .modifier(KakaGlass(radius: 24))
    }

    private func messages(liveHeight: CGFloat? = nil) -> some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(transcript) { line in
                        if liveHeight != nil {
                            (Text(line.name + " ").fontWeight(.semibold).foregroundColor(KakaTheme.accent) + Text(line.text))
                                .font(.footnote)
                                .foregroundStyle(KakaTheme.ink)
                                .textSelection(.enabled)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .background(liveBackdrop, in: RoundedRectangle(cornerRadius: 12))
                        } else {
                            (Text(line.name + " ").fontWeight(.semibold) + Text(line.text))
                                .font(.subheadline)
                                .textSelection(.enabled)
                        }
                    }
                    Color.clear.frame(height: 1).id("chat-end")
                        .onAppear { nearBottom = true }
                        .onDisappear { nearBottom = false }
                }
                .frame(maxWidth: .infinity, minHeight: liveHeight, alignment: .bottomLeading)
            }
            .frame(minHeight: liveHeight ?? 42, maxHeight: liveHeight ?? 185)
            .clipped()
            .accessibilityHidden(liveHeight == 0)
            .allowsHitTesting(liveHeight != 0)
            .defaultScrollAnchorIfSupported()
            .task {
                guard liveHeight != nil else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                reader.scrollTo("chat-end", anchor: .bottom)
            }
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

private struct KakaLiveGift: Identifiable {
    let id: Int64
    let name: String
    let cost: String
    let image: URL?
    let available: Bool

    static func catalog(_ fields: [String: Any]) -> [Self] {
        (fields["gifts"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let id = KakaRemoteClient.userID(entry["id"]), id > 0, let name = entry["name"] as? String,
                  let cost = entry["cost"] as? String else { return nil }
            return Self(id: id, name: name, cost: cost,
                        image: KakaRoomFields.url(entry["image"] as? String ?? ""),
                        available: entry["available"] as? Bool == true)
        }
    }

    @ViewBuilder
    func artwork(size: CGFloat) -> some View {
        if let image {
            AsyncImage(url: image) { phase in
                if let picture = phase.image {
                    picture.resizable().scaledToFit()
                } else {
                    Color.clear
                }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        }
    }
}

@MainActor
private func liveRoomGiftRequest(_ operation: String, room: KakaNativeRoom, visit: UUID,
                                 session: UUID, gift: Int64? = nil) async throws -> [String: Any] {
    let runtime = KakaNativeRoomRuntime.shared
    let audience: KakaLiveGifts.Audience = { host, channel in
        runtime.owns(visit) && runtime.media.isLiveAudience(roomID: room.serverID, session: session,
                                                           hostID: host, channel: channel)
    }
    guard room.kind == .live, audience(nil, nil) else { throw KakaLiveGifts.Failure.unavailable }
    let data: Data
    if operation == "gift.preview" {
        data = try await KakaLiveGifts.shared.preview(roomID: room.serverID, session: session, isAudience: audience)
    } else {
        data = try await KakaLiveGifts.shared.perform(operation: operation, roomID: room.serverID, giftID: gift,
                                                     session: session, isAudience: audience)
    }
    return try KakaRemoteClient.object(data)
}

@MainActor
private struct KakaLiveGiftRail: View {
    @EnvironmentObject private var store: KakaNativeStore
    @ScaledMetric(relativeTo: .caption) private var tileWidth: CGFloat = 74
    let room: KakaNativeRoom
    let visit: UUID
    let onSelect: (Int64) -> Void
    @State private var gifts: [KakaLiveGift] = []

    var body: some View {
        VStack(spacing: 0) {
            if !gifts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .bottom, spacing: 6) {
                        ForEach(gifts) { gift in
                            Button { onSelect(gift.id) } label: {
                                VStack(spacing: 3) {
                                    ZStack {
                                        Color.clear
                                        gift.artwork(size: 32)
                                    }
                                    .frame(width: 32, height: 32)
                                    Text(gift.name)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(KakaTheme.ink)
                                        .lineLimit(1)
                                    Text(gift.cost)
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(KakaTheme.liveAccent)
                                }
                                .padding(.vertical, 7)
                                .padding(.horizontal, 5)
                                .frame(width: min(tileWidth, 150))
                                .frame(minHeight: 44)
                                .background(KakaTheme.base.opacity(0.78), in: RoundedRectangle(cornerRadius: 12))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(KakaRoomCardPressStyle())
                            .accessibilityLabel("\(gift.name), \(gift.cost) diamonds")
                            .accessibilityHint("Shows gift details")
                        }
                    }
                }
                .accessibilityLabel("Live gifts")
            }
        }
        .task(id: visit) {
            gifts = []
            guard let session = store.session?.token,
                  let catalog = try? await liveRoomGiftRequest("gift.preview", room: room, visit: visit, session: session),
                  !Task.isCancelled, store.session?.token == session,
                  KakaNativeRoomRuntime.shared.owns(visit) else { return }
            gifts = KakaLiveGift.catalog(catalog)
        }
    }
}

@MainActor
private struct KakaRoomGiftSheet: View {
    @EnvironmentObject private var store: KakaNativeStore
    let room: KakaNativeRoom
    let visit: UUID
    var initialGiftID: Int64? = nil
    @State private var gifts: [KakaLiveGift] = []
    @State private var balance = ""
    @State private var host = ""
    @State private var feedback = ""
    @State private var busy = false
    @State private var choice: KakaLiveGift?

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
                        gift.artwork(size: 34)
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
        .task { await fetch(initial: true) }
    }

    @ViewBuilder
    private func giftConfirmation(_ gift: KakaLiveGift) -> some View {
        KakaRoomButton(title: "Cancel") { choice = nil }
        KakaRoomButton(title: "Send gift") {
            choice = nil
            Task { await send(gift) }
        }
        .disabled(busy)
    }

    private func fetch(initial: Bool = false) async {
        guard !busy, let session = store.session?.token else { return }
        busy = true
        feedback = ""
        defer { busy = false }
        do {
            let fields = try await liveRoomGiftRequest("gift.catalog", room: room, visit: visit, session: session)
            guard !Task.isCancelled, store.session?.token == session, KakaNativeRoomRuntime.shared.owns(visit) else { return }
            balance = fields["balance"] as? String ?? ""
            host = fields["host"] as? String ?? room.host?.name ?? "the host"
            gifts = KakaLiveGift.catalog(fields)
            if gifts.isEmpty {
                feedback = "No gifts are available in this room."
            } else if initial, let initialGiftID {
                if let selected = gifts.first(where: { $0.id == initialGiftID && $0.available }) {
                    choice = selected
                } else {
                    feedback = "This gift is unavailable. Check your balance or choose another gift."
                }
            }
        } catch {
            guard !Task.isCancelled, store.session?.token == session else { return }
            store.expireIfNeeded(error)
            feedback = store.message(error)
        }
    }

    private func send(_ gift: KakaLiveGift) async {
        guard !busy, gift.available, gifts.contains(where: { $0.id == gift.id }),
              let session = store.session?.token else { return }
        busy = true
        feedback = ""
        gifts = []
        defer { busy = false }
        do {
            let result = try await liveRoomGiftRequest("gift.send", room: room, visit: visit, session: session, gift: gift.id)
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
