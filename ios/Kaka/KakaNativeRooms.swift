import SwiftUI
import UIKit
import AVFoundation
import WebKit
import CoreFoundation

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
            locked: party && ["lockRoomFlag", "lockFlag", "needPassword", "isLock", "locked"].contains { KakaRoomFields.flag(value[$0]) },
            channel: KakaRoomFields.text(value, "studioRoute", "venueKey", "agoraChannelId")
        )
    }
}

enum KakaRoomFields {
    static func directoryLocale(_ fields: [String: Any], party: Bool) -> String? {
        if party {
            let code = text(fields, "roomLanguage", "languageCode").lowercased()
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
    @State private var campaigns: [KakaDirectoryCampaign] = []
    @State private var campaignSelection: String?
    @State private var openedCampaign: KakaDirectoryCampaign?
    @State private var campaignSession: UUID?
    @State private var campaignRequestID = UUID()
    @State private var showingDirectoryRankings = false
    @State private var showingVoiceCreation = false
    @State private var roomToOpenAfterCreation: (room: KakaNativeRoom, session: UUID)?
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
        kind == .voice ? [.all, .following, .recent, .watched] : [.all, .onAir, .new, .following, .watched]
    }

    private var showsDirectorySpotlight: Bool {
        !searching && category == nil && locale == nil && filter == (kind == .live ? .onAir : .all)
    }

    private var spotlight: [KakaNativeRoom] {
        guard showsDirectorySpotlight else { return [] }
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
            if campaignSession != initialSession {
                campaigns = []
                campaignSelection = nil
                openedCampaign = nil
            }
            await load()
        }
        .onChange(of: store.tab) { tab in
            if tab != (kind == .live ? .live : .voice) { searchFocused = false }
        }
        .onChange(of: store.route) { route in
            if route != nil { searchFocused = false }
        }
        .task(id: (store.session?.token.uuidString ?? "") + store.tab.rawValue) {
            guard store.tab == (kind == .live ? .live : .voice) else { return }
            await loadCampaigns()
        }
        .sheet(item: $openedCampaign) { campaign in
            switch campaign.destination {
            case .wallet:
                KakaStudioWalletView()
            case .support:
                KakaStudioHelpView()
            case .page(let target):
                KakaCampaignPage(target: target)
            case nil:
                EmptyView()
            }
        }
        .sheet(isPresented: $showingDirectoryRankings) { KakaDirectoryRankingSheet() }
        .sheet(isPresented: $showingVoiceCreation, onDismiss: openRoomAfterCreation) {
            KakaVoiceCreation { room in
                guard let session = store.session?.token else { return }
                roomToOpenAfterCreation = (room, session)
                showingVoiceCreation = false
            }
        }
    }

    private func directory(viewport: CGSize, gutter: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if showsDirectorySpotlight, let first = campaigns.first {
                    campaignGallery(first: first, viewport: viewport)
                } else {
                    let slides = spotlight
                    if let first = slides.first {
                        featuredRooms(slides, first: first, viewport: viewport)
                    }
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
            await loadCampaigns(force: true)
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
            if textSize.isAccessibilitySize || width < (kind == .voice ? 365 : 315) {
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
            directoryTool("Ranks", selected: false) {
                searchFocused = false
                showingDirectoryRankings = true
            }
            .accessibilityLabel("Platform rankings")
            if kind == .voice {
                directoryTool("Create", selected: false) {
                    searchFocused = false
                    showingVoiceCreation = true
                }
                .accessibilityLabel("Create voice room")
            }
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

    private func campaignGallery(first: KakaDirectoryCampaign, viewport: CGSize) -> some View {
        let ids = campaigns.map(\.id)
        let selection = campaignSelection.flatMap { ids.contains($0) ? $0 : nil } ?? first.id
        let position = ids.firstIndex(of: selection) ?? 0
        let tab: KakaNativeTab = kind == .live ? .live : .voice
        return VStack(spacing: 0) {
            GeometryReader { geometry in
                let frame = geometry.frame(in: CoordinateSpace.named(Self.scrollSpace))
                let visibleHeight = min(frame.maxY, viewport.height) - max(frame.minY, 0)
                let rotates = ids.count > 1 && visibleHeight >= frame.height * 0.5
                    && cardMotionIsVisible(frame, viewportHeight: viewport.height, tab: tab)
                    && !voiceOverEnabled && !draggingSpotlight && openedCampaign == nil
                TabView(selection: Binding(get: { selection }, set: { campaignSelection = $0 })) {
                    ForEach(campaigns) { campaign in
                        campaignTile(campaign, size: geometry.size)
                            .accessibilityHidden(campaign.id != selection)
                            .tag(campaign.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .simultaneousGesture(
                    DragGesture(minimumDistance: 5)
                        .updating($draggingSpotlight) { _, dragging, _ in dragging = true }
                )
                .task(id: SpotlightRotation(roomIDs: ids, selection: selection, enabled: rotates)) {
                    guard rotates else { return }
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                    guard !Task.isCancelled, !draggingSpotlight, store.tab == tab, store.route == nil,
                          openedCampaign == nil else { return }
                    selectCampaign(ids[(position + 1) % ids.count])
                }
            }
            .frame(height: spotlightHeight(viewport.width))
            if ids.count > 1 {
                HStack(spacing: 7) {
                    campaignArrow("Previous campaign", backward: true) {
                        selectCampaign(ids[(position + ids.count - 1) % ids.count])
                    }
                    Text("\(position + 1) / \(ids.count)")
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(KakaTheme.muted)
                        .accessibilityLabel("Campaign \(position + 1) of \(ids.count)")
                    campaignArrow("Next campaign", backward: false) {
                        selectCampaign(ids[(position + 1) % ids.count])
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func campaignTile(_ campaign: KakaDirectoryCampaign, size: CGSize) -> some View {
        let art = KakaNativeImage(asset: kind == .live ? "live-deck.jpg" : "voice-deck.jpg", remote: campaign.art)
            .scaledToFit()
            .frame(width: size.width, height: size.height)
            .background(KakaTheme.surface)
        if let destination = campaign.destination {
            Button { openedCampaign = campaign } label: { art.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityLabel(destination.accessibilityLabel)
        } else {
            art.accessibilityLabel("Campaign banner")
        }
    }

    private func campaignArrow(_ title: String, backward: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            KakaNativeImage(asset: "action-forward.png")
                .rotationEffect(.degrees(backward ? 180 : 0))
                .frame(width: 16, height: 16)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func selectCampaign(_ id: String) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.32)) { campaignSelection = id }
    }

    private func loadCampaigns(force: Bool = false) async {
        guard let session = store.session?.token, force || campaignSession != session else { return }
        let request = UUID()
        campaignRequestID = request
        do {
            let response = try await store.request("directory.campaigns", ["cosmicModes": [2]])
            guard !Task.isCancelled, campaignRequestID == request, store.session?.token == session else { return }
            let rows = KakaRoomFields.rows(response, keys: ["gridBands"])
            var seen = Set<String>()
            campaigns = rows.compactMap { KakaDirectoryCampaign($0) }.filter { seen.insert($0.id).inserted }
            campaignSession = session
        } catch {
            // Keep the existing room spotlight when no campaign content is available.
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
        if room.kind == .live {
            store.openLive(room, lineup: results)
        } else {
            store.open(.room(room))
        }
    }

    private func openRoomAfterCreation() {
        guard let result = roomToOpenAfterCreation else { return }
        roomToOpenAfterCreation = nil
        guard store.tab == .voice, store.session?.token == result.session, store.route == nil else { return }
        let room = result.room
        rooms.removeAll { $0.id == room.id }
        rooms.insert(room, at: 0)
        store.remember([room])
        open(room)
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

private struct KakaDirectoryCampaign: Identifiable {
    enum Destination {
        case wallet
        case support
        case page(URL)

        var accessibilityLabel: String {
            switch self {
            case .wallet: return "Open wallet and rewards"
            case .support: return "Open help center"
            case .page: return "Open campaign"
            }
        }
    }

    let id: String
    let art: URL
    let destination: Destination?

    @MainActor init?(_ fields: [String: Any]) {
        if let type = KakaRemoteClient.userID(fields["signalKind"]), type != 2 { return nil }
        guard let art = KakaRoomFields.url(KakaRoomFields.text(fields, "cometImage")) else { return nil }
        self.art = art
        id = KakaRoomFields.id(fields, keys: ["orbitMark"]).map(String.init) ?? art.absoluteString
        let action = KakaRoomFields.text(fields, "stageLink").trimmingCharacters(in: .whitespacesAndNewlines)
        switch KakaRemoteClient.userID(fields["stageTap"]) {
        case 0:
            switch action.lowercased() {
            case "recharge", "rechargeservice", "wallet": destination = .wallet
            case "customerservice", "support": destination = .support
            case "store", "backpack", "invite": destination = nil
            default: destination = Self.page(action)
            }
        case 1:
            destination = Self.page(action)
        default:
            destination = nil
        }
    }

    @MainActor private static func page(_ action: String) -> Destination? {
        guard let target = KakaRoomFields.url(action), allows(target) else { return nil }
        return .page(target)
    }

    @MainActor static func allows(_ url: URL) -> Bool {
        guard let address = KakaServiceBridge.configuration["origin"], let origin = URL(string: address),
              origin.scheme?.lowercased() == "https", url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), host == origin.host?.lowercased(),
              (url.port ?? 443) == (origin.port ?? 443), url.user == nil, url.password == nil,
              url.query == nil else { return false }
        return true
    }
}

@MainActor
private struct KakaCampaignPage: View {
    @Environment(\.dismiss) private var dismiss
    let target: URL
    @State private var isLoading = true
    @State private var failed = false
    @State private var revision = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Campaign").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                KakaRoomButton(title: "Close") { dismiss() }
            }
            .padding(.horizontal, 14)
            if failed {
                VStack(spacing: 12) {
                    Text("Couldn’t open the campaign page.").font(.subheadline).foregroundStyle(KakaTheme.muted)
                    KakaRoomButton(title: "Try again") {
                        isLoading = true
                        failed = false
                        revision = UUID()
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                KakaCampaignBrowser(target: target) { success in
                    isLoading = false
                    failed = !success
                }
                .id(revision)
                .overlay(alignment: .top) {
                    if isLoading { KakaRhythmProgress(title: "Loading campaign").allowsHitTesting(false) }
                }
            }
        }
        .padding(.top, 8)
        .background(KakaTheme.base.ignoresSafeArea())
        .foregroundStyle(KakaTheme.ink)
    }
}

@MainActor
private struct KakaCampaignBrowser: UIViewRepresentable {
    let target: URL
    let onLoad: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onLoad: onLoad) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsLinkPreview = false
        if KakaDirectoryCampaign.allows(target) {
            var request = URLRequest(url: target)
            request.httpMethod = "GET"
            view.load(request)
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.navigationDelegate = nil
        view.stopLoading()
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        private let onLoad: (Bool) -> Void

        init(onLoad: @escaping (Bool) -> Void) { self.onLoad = onLoad }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard action.targetFrame?.isMainFrame == true, let target = action.request.url,
                  KakaDirectoryCampaign.allows(target), action.request.httpMethod == "GET" else {
                decisionHandler(.cancel)
                if webView.url == nil, action.targetFrame?.isMainFrame == true { onLoad(false) }
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            guard response.isForMainFrame, response.canShowMIMEType, let url = response.response.url,
                  KakaDirectoryCampaign.allows(url) else {
                decisionHandler(.cancel)
                if response.isForMainFrame { onLoad(false) }
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onLoad(true) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { onLoad(false) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onLoad(false)
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

struct KakaRoomButton: View {
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

struct KakaRoomActionGroup<Content: View>: View {
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
final class KakaNativeRoomRuntime {
    static let shared = KakaNativeRoomRuntime()

    let media = KakaRealtimeMedia()
    lazy var chat = KakaRoomChat { [weak self] session, roomID in
        self?.media.chatroomID(session: session, serverID: roomID)
    }
    lazy var directChat = KakaRoomChat { _, _ in nil }
    private var owner: UUID?
    private var entry: (visit: UUID, task: Task<Void, Error>)?
    private var release: Task<Void, Never>?

    func join(_ visit: UUID, room: KakaNativeRoom, password: String?, session: UUID,
              onVoiceClosure: @escaping (String) -> Void) async throws {
        if let owner, owner != visit { leave(owner) }
        owner = visit
        await release?.value
        guard owner == visit, !Task.isCancelled else {
            leave(visit)
            throw CancellationError()
        }
        chat.onVoiceClosure = { [weak self] closedVisit, reason in
            guard let self, room.kind == .voice, self.owner == closedVisit, closedVisit == visit else { return }
            onVoiceClosure(reason)
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

    func leaveForCall() async {
        if let owner { leave(owner) }
        await settle()
    }

    func leave(_ visit: UUID) {
        guard owner == visit else { return }
        owner = nil
        chat.onVoiceClosure = nil
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
    let showsDuel: Bool

    func makeUIView(context: Context) -> Renderer { Renderer(media: media) }
    func updateUIView(_ uiView: Renderer, context: Context) {
        uiView.showsDuel = showsDuel
        uiView.setNeedsLayout()
    }

    static func dismantleUIView(_ uiView: Renderer, coordinator: ()) {
        uiView.detach()
    }

    final class Renderer: UIView {
        private let media: KakaRealtimeMedia
        var showsDuel = false

        init(media: KakaRealtimeMedia) {
            self.media = media
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            accessibilityElementsHidden = true
            backgroundColor = .clear
            addSubview(media.videoView)
            addSubview(media.duelVideoView)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard media.videoView.superview === self else { return }
            if bounds.isEmpty {
                media.setVideoFrame(nil)
                media.setDuelVideoFrame(nil)
            } else if showsDuel {
                let halves = bounds.divided(atDistance: bounds.width / 2, from: .minXEdge)
                media.setVideoFrame(halves.slice)
                media.setDuelVideoFrame(halves.remainder)
            } else {
                media.setVideoFrame(bounds)
                media.setDuelVideoFrame(nil)
            }
        }

        func detach() {
            guard media.videoView.superview === self else { return }
            media.setVideoFrame(nil)
            media.setDuelVideoFrame(nil)
            media.videoView.removeFromSuperview()
            media.duelVideoView.removeFromSuperview()
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
    @State private var voiceLockOverride: Bool?
    @State private var seat = SeatStatus()
    @State private var updatingSeat = false
    @State private var seatRefreshFailed = false
    @State private var activeSheet: RoomSheet?
    @State private var selectedLiveGiftID: Int64?
    @State private var callPermitted = false
    @State private var callUnlocked = false
    @State private var activeLiveSeconds: TimeInterval = 0
    @State private var sentLiveMessages = 0
    @State private var resumeAfterPrivateCall = false
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
        case notes, report, gifts, voiceGifts, giftWall, wishlist, ranking, duelRanking, privateCall, hide, options, people, hostProfile, messageHost, info, share, leaveLive, voiceManagement
        var id: Self { self }
    }

    private struct SeatStatus {
        var index: Int64 = 0
        var microphone = false
        var queued = false
        var queuePosition: Int64?
        var stage: [KakaRealtimeMedia.VoiceStageSeat]?
    }

    private var runtime: KakaNativeRoomRuntime { .shared }
    private var current: KakaNativeRoom { details ?? room }
    private var roomLocked: Bool { voiceLockOverride ?? current.locked }
    private var waitingForEntry: Bool { entryPending && !roomLocked }
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
    private var voiceManagementContext: KakaVoiceManagementContext? {
        guard room.kind == .voice, connected, let visit, let session = store.session?.token else { return nil }
        return KakaVoiceManagementContext(roomID: room.serverID, visit: visit, session: session)
    }

    var body: some View {
        Group {
            if room.kind == .live {
                liveStage
            } else {
                voiceRoom
            }
        }
        .sheet(item: $activeSheet, onDismiss: resumeLiveAfterCall) { sheet in
            switch sheet {
            case .notes:
                KakaRoomTextSheet(mode: .note, room: current)
            case .report:
                KakaRoomTextSheet(mode: .report, room: current)
            case .gifts:
                if let visit {
                    KakaRoomGiftSheet(room: current, visit: visit, initialGiftID: selectedLiveGiftID,
                                      onSent: { callUnlocked = true })
                }
            case .voiceGifts:
                if let visit { KakaVoiceGiftSheet(room: current, visit: visit) }
            case .giftWall:
                if let host = current.host { KakaHostGiftWallSheet(host: host) }
            case .wishlist:
                if let visit { KakaLiveWishlistSheet(room: current, visit: visit) }
            case .ranking:
                if let visit { KakaRoomRankingSheet(room: current, visit: visit) }
            case .duelRanking:
                if let visit, let ranking = media.duel?.ranking {
                    KakaRankingSheet(room: current, visit: visit, duel: ranking)
                }
            case .privateCall:
                if let session = store.session?.token {
                    KakaPrivateCallSheet(room: current, session: session, ownsRoom: {
                        guard let visit else { return false }
                        return callPermitted && callUnlocked && scenePhase == .active && runtime.owns(visit)
                            && store.session?.token == session
                    }, suspendRoom: {
                        resumeAfterPrivateCall = true
                        stopConnection()
                        await runtime.settle()
                    })
                }
            case .hide:
                KakaRoomTextSheet(mode: .hide, room: current, onHidden: { hideAfterConfirm = true })
            case .options:
                roomOptions
            case .voiceManagement:
                if let context = voiceManagementContext {
                    KakaVoiceRoomManagementSheet(context: context) { voiceLockOverride = $0 }
                }
            case .people:
                if let visit { KakaRoomAudienceSheet(room: current, visit: visit) }
            case .hostProfile:
                if let host = current.host { roomHostProfile(host) }
            case .messageHost:
                if let host = current.host {
                    KakaRoomSheet(title: "Message \(host.name)", locked: false) {
                        KakaNativeChatView(hostID: host.id, hostName: host.name)
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
        .onChange(of: media.duel?.ranking) { _ in
            if activeSheet == .duelRanking { activeSheet = nil }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                if !roomLocked, connecting || connected { entryPending = true }
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
        .task(id: monitoringCallUnlock) {
            await waitForLiveCallUnlock()
        }
    }

    private var liveStage: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let reservedHeight: CGFloat = textSize.isAccessibilitySize || !displayingLiveVideo ? 330 : 252
            let chatHeight = min(158, height * 0.24, max(0, height - reservedHeight))
            VStack(spacing: 10) {
                liveHeader
                if let duel = media.duel { duelScore(duel) }
                liveSwitchRegion
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
                                               isMinimized: isMinimized, onMessageSent: recordLiveMessage)
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

    private var liveSwitchRegion: some View {
        Color.clear
            .frame(minHeight: 4, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 38).onEnded { gesture in
                let vertical = gesture.translation.height
                guard !isMinimized, activeSheet == nil, abs(vertical) >= 60,
                      abs(vertical) > abs(gesture.translation.width) * 1.4 else { return }
                store.switchLiveRoom(from: room, forward: vertical < 0)
            })
            .accessibilityHidden(true)
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
                    KakaNativeVideo(media: media, showsDuel: media.duel != nil && !isMinimized)
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
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        peopleButton
                        KakaRoomButton(title: "Ranking") { activeSheet = .ranking }
                        if current.host != nil {
                            KakaRoomButton(title: "Message") { activeSheet = .messageHost }
                                .accessibilityLabel("Message the host")
                        }
                        if callPermitted && callUnlocked {
                            KakaRoomButton(title: "Call", asset: "room-watch.png") { activeSheet = .privateCall }
                                .accessibilityLabel("Private video call")
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
    }

    private var monitoringCallUnlock: UUID? {
        guard room.kind == .live, callPermitted, !callUnlocked, displayingLiveVideo,
              scenePhase == .active, !isMinimized, activeSheet == nil else { return nil }
        return visit
    }

    private func waitForLiveCallUnlock() async {
        guard let activeVisit = monitoringCallUnlock else { return }
        let began = ProcessInfo.processInfo.systemUptime
        let remaining = max(0, 60 - activeLiveSeconds)
        defer {
            if visit == activeVisit {
                activeLiveSeconds = min(60, activeLiveSeconds + max(0, ProcessInfo.processInfo.systemUptime - began))
            }
        }
        do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) } catch { return }
        if monitoringCallUnlock == activeVisit { callUnlocked = true }
    }

    private func recordLiveMessage() {
        sentLiveMessages = min(4, sentLiveMessages + 1)
        if sentLiveMessages >= 4 { callUnlocked = true }
    }

    private func resumeLiveAfterCall() {
        guard resumeAfterPrivateCall else { return }
        resumeAfterPrivateCall = false
        guard case .room(let routed) = store.route, routed.id == room.id else { return }
        entryPending = true
        startConnection()
    }

    @ViewBuilder
    private func duelScore(_ duel: KakaRealtimeMedia.LiveDuel) -> some View {
        let score = HStack(spacing: 0) {
            Text(duel.hostScore)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .foregroundStyle(KakaTheme.liveAccent)
            Text("PK")
                .foregroundStyle(KakaTheme.ink)
            Text(duel.opponentScore)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 12)
                .foregroundStyle(KakaTheme.voiceAccent)
        }
        .font(.caption.weight(.bold).monospacedDigit())
        .padding(.vertical, 7)
        .background(KakaTheme.base.opacity(0.8), in: Capsule())
        let description = "Duel score. Host \(duel.hostScore), opponent \(duel.opponentScore)"
        if duel.ranking != nil, connected, let visit, runtime.owns(visit) {
            Button { activeSheet = .duelRanking } label: {
                score.frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(description)
            .accessibilityHint("Opens the PK rankings")
        } else {
            score.accessibilityLabel(description)
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
            .accessibilityLabel(room.kind == .live ? "Live audience" : "Online chat participants")
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
            if room.kind == .live {
                KakaRoomButton(title: "Gift wall") { activeSheet = .giftWall }
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
            if room.kind == .live {
                if connected { KakaRoomButton(title: "Gift wishlist") { activeSheet = .wishlist } }
                KakaRoomActionGroup {
                    adjacentRoomButton(forward: false)
                    adjacentRoomButton(forward: true)
                }
            }
            if room.kind == .voice, current.host != nil {
                KakaRoomButton(title: "Message the host") { activeSheet = .messageHost }
            }
            if let context = voiceManagementContext {
                KakaVoiceManagementOption(context: context) { activeSheet = .voiceManagement }
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

    @ViewBuilder
    private func adjacentRoomButton(forward: Bool) -> some View {
        if store.adjacentLiveRoom(to: room, forward: forward) != nil {
            KakaRoomButton(title: forward ? "Next live" : "Previous live") {
                activeSheet = nil
                store.switchLiveRoom(from: room, forward: forward)
            }
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
                                           onGifts: { activeSheet = .voiceGifts },
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
            let background: URL? = store.session.flatMap { session in
                guard connected, let visit, runtime.owns(visit) else { return nil }
                return media.voiceBackground(roomID: room.serverID, session: session.token)
            }
            KakaNativeImage(asset: room.kind.art, remote: background ?? current.cover)
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
            if let position = seat.queuePosition { return "Seat queue · \(position)" }
            if seat.queued { return "Waiting for a seat" }
            if seat.index == 0 { return media.voiceAudioEnabled ? "Listening" : "Room audio muted" }
            if seatRefreshFailed { return "Seat status unavailable" }
            return seat.microphone ? "Microphone on" : "Microphone muted"
        }
        if openingConnection { return "Connecting" }
        if roomLocked { return "Password required" }
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
            if !media.voiceAnnouncement.isEmpty {
                Text(media.voiceAnnouncement)
                    .font(.subheadline).foregroundStyle(KakaTheme.muted)
                    .accessibilityLabel("Announcement: \(media.voiceAnnouncement)")
            }
            KakaRoomActionGroup {
                Text("Mic seats").font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
                KakaRoomButton(title: media.voiceAudioEnabled ? "Mute audio" : "Unmute audio",
                               selected: !media.voiceAudioEnabled) { toggleVoiceAudio() }
                    .accessibilityLabel(media.voiceAudioEnabled ? "Mute room audio" : "Unmute room audio")
                KakaRoomButton(title: "Ranking") { activeSheet = .ranking }
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
                let operation = seat.index > 0 ? "voiceSeat.move" : "voiceSeat.take"
                Task { await updateSeat(operation, requestedSeat: position.index) }
            } label: {
                voiceSeatBadge(position)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(seat.queued || updatingSeat || seatRefreshFailed)
            .accessibilityLabel(seat.index > 0 ? "Move to seat \(position.index)" : "Request seat \(position.index)")
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
            if roomLocked, !connected {
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
        if roomLocked { return "Join room" }
        if !connectionError.isEmpty { return room.kind == .live ? "Retry live" : "Retry audio" }
        return room.kind == .live ? "Resume live" : "Resume audio"
    }

    @ViewBuilder
    private var voiceSeatButtons: some View {
        KakaRoomButton(title: seat.index > 0 ? "Leave seat" : seat.queued ? "Leave queue" : "Take a seat",
                       asset: "action-seat.png") {
            let operation = seat.index > 0 ? "voiceSeat.leave" : seat.queued ? "voiceSeat.withdraw" : "voiceSeat.take"
            Task { await updateSeat(operation) }
        }
        .disabled(updatingSeat)
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
        if roomLocked {
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
        if room.kind == .live {
            activeLiveSeconds = 0
            sentLiveMessages = 0
            callUnlocked = false
            callPermitted = false
        }
        visit = newVisit
        connecting = true
        connectionError = ""
        connectionTask = Task { @MainActor in
            do {
                if room.kind == .live { try await refreshLive(visit: newVisit, session: session) }
                try Task.checkCancellation()
                guard visit == newVisit, store.session?.token == session,
                      scenePhase != .background else { throw CancellationError() }
                try await runtime.join(newVisit, room: current, password: password, session: session) { reason in
                    guard visit == newVisit, store.session?.token == session else { return }
                    stopConnection()
                    activeSheet = nil
                    store.back()
                    store.notify(reason)
                }
                try Task.checkCancellation()
                guard visit == newVisit, store.session?.token == session, scenePhase != .background else {
                    runtime.leave(newVisit)
                    throw CancellationError()
                }
                connected = true
                connecting = false
                if room.kind == .voice {
                    if let locked = media.voiceManagementState(roomID: current.serverID, session: session)?.locked {
                        voiceLockOverride = locked
                    }
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
        callPermitted = KakaRoomFields.flag(fields["cipherAccess"] ?? values["cipherAccess"])
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
        if let sheet = activeSheet, [.gifts, .voiceGifts, .ranking, .duelRanking, .wishlist, .people, .leaveLive, .voiceManagement].contains(sheet) {
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
                              queuePosition: KakaRemoteClient.userID(result["queuePosition"]),
                              stage: result["stageSeats"] as? [KakaRealtimeMedia.VoiceStageSeat])
            seatRefreshFailed = false
        } catch {
            guard self.visit == visit else { return }
            store.expireIfNeeded(error)
            if operation == "voiceSeat.status" { seatRefreshFailed = true }
            else { connectionError = store.message(error) }
        }
    }

    private func toggleVoiceAudio() {
        guard connected, let visit, runtime.owns(visit), let session = store.session?.token else { return }
        do { try media.setVoiceAudio(!media.voiceAudioEnabled, roomID: room.serverID, session: session) }
        catch { store.notify(store.message(error)) }
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
private struct KakaPrivateCallSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var call = KakaLivePrivateCall()
    let room: KakaNativeRoom
    let session: UUID
    let ownsRoom: () -> Bool
    let suspendRoom: () async -> Void

    var body: some View {
        KakaRoomSheet(title: room.host?.name ?? "Private video call", locked: call.holdsRoom) {
            if call.phase == .offer {
                offer
            } else {
                KakaPrivateCallConversation(call: call, returnTitle: "Back to live", finished: { dismiss() },
                                            recipientName: room.host?.name ?? "the host")
            }
            if !call.feedback.isEmpty {
                Text(call.feedback).font(.footnote).foregroundStyle(KakaTheme.muted)
            }
        }
        .interactiveDismissDisabled(call.holdsRoom)
        .task { await call.loadOffer(room: room, session: session, ownsRoom: ownsRoom) }
        .onChange(of: scenePhase) { phase in
            if phase == .background, call.phase != .waiting { Task { await call.hangUp() } }
        }
        .onDisappear { Task { await call.hangUp() } }
    }

    @ViewBuilder
    private var offer: some View {
        if call.checking {
            KakaRhythmProgress(title: "Checking the call price")
        } else if let quote = call.quote {
            KakaRoomArt(asset: "member-mark.jpg", remote: room.host?.portrait, ratio: 1)
                .frame(width: 66)
                .clipShape(RoundedRectangle(cornerRadius: 15))
                .accessibilityHidden(true)
            let entryCost = NSDecimalNumber(decimal: quote.entryCost).stringValue
            let minuteCost = NSDecimalNumber(decimal: quote.minuteCost).stringValue
            Text(quote.entryMinutes > 0 ? "First \(quote.entryMinutes) min · \(entryCost) diamonds" : "Connection costs \(entryCost) diamonds")
                .font(.headline)
            Text("Then \(minuteCost) diamonds per minute.")
                .font(.subheadline).foregroundStyle(KakaTheme.muted)
            KakaRoomButton(title: "Start video call", asset: "room-watch.png", selected: true) {
                Task { await call.start(room: room, session: session, ownsRoom: ownsRoom, suspendRoom: suspendRoom) }
            }
        } else {
            KakaRoomButton(title: "Check the offer") {
                Task { await call.loadOffer(room: room, session: session, ownsRoom: ownsRoom) }
            }
        }
    }

}

@MainActor
struct KakaIncomingCallPane: View {
    @ObservedObject var call: KakaLivePrivateCall
    let stillActive: () -> Bool
    let suspendRoom: () async -> Void
    let dismiss: () -> Void

    @State private var showingWallet = false

    var body: some View {
        ZStack {
            KakaTheme.base.opacity(0.94).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    Text(call.incomingCaller?.name ?? "Incoming video call")
                        .font(.title2.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    if call.phase == .incoming {
                        incomingOffer
                    } else {
                        KakaPrivateCallConversation(call: call, returnTitle: "Close", finished: dismiss)
                    }
                    if !call.feedback.isEmpty {
                        Text(call.feedback).font(.footnote).foregroundStyle(KakaTheme.muted)
                    }
                }
                .frame(maxWidth: 500, alignment: .leading)
                .padding(22)
                .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 10)
        }
        .foregroundStyle(KakaTheme.ink)
        .task { await call.loadIncomingOffer() }
        .sheet(isPresented: $showingWallet) { KakaStudioWalletView() }
        .accessibilityAction(.escape) {
            if call.phase == .finished { dismiss() }
            else { Task { await call.hangUp() } }
        }
    }

    @ViewBuilder
    private var incomingOffer: some View {
        if let caller = call.incomingCaller {
            KakaRoomArt(asset: "member-mark.jpg", remote: caller.portrait, ratio: 1)
                .frame(width: 84)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .accessibilityHidden(true)
        }
        if call.checking {
            KakaRhythmProgress(title: "Checking incoming call")
        } else if let quote = call.quote {
            let cost = NSDecimalNumber(decimal: quote.minuteCost).stringValue
            Text("Private video call · \(cost) diamonds per minute")
                .font(.subheadline)
                .foregroundStyle(KakaTheme.muted)
            KakaRoomActionGroup {
                KakaRoomButton(title: "Accept video call", asset: "room-watch.png", selected: true) {
                    Task { await call.acceptIncoming(stillActive: stillActive, suspendRoom: suspendRoom) }
                }
                KakaRoomButton(title: "Wallet") { showingWallet = true }
            }
        } else {
            KakaRoomButton(title: "Check the call") { Task { await call.loadIncomingOffer() } }
        }
        KakaRoomButton(title: "Decline", asset: "action-stop.png") { Task { await call.hangUp() } }
    }
}

@MainActor
private struct KakaPrivateCallConversation: View {
    @ObservedObject var call: KakaLivePrivateCall
    let returnTitle: String
    let finished: () -> Void
    var recipientName = "the host"
    @State private var showingWallet = false
    @State private var showingGifts = false
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            conversation
        }
        .sheet(isPresented: $showingWallet, onDismiss: {
            call.setRechargeWalletVisible(false)
            Task { await call.refreshRechargeStatus() }
        }) {
            KakaStudioWalletView()
        }
        .sheet(isPresented: $showingGifts) {
            KakaPeerGiftSheet(recipientName: recipientName, showsQuantity: true, loadCatalog: {
                try await call.callGiftCatalog()
            }, sendGift: { gift, quantity in
                try await call.sendCallGift(gift, quantity: quantity)
            })
        }
        .onChange(of: call.phase) { phase in
            if phase != .active { showingGifts = false }
        }
    }

    @ViewBuilder
    private var conversation: some View {
        if call.phase == .connecting || call.phase == .active {
            KakaNativeVideo(media: call.media, showsDuel: false)
                .frame(height: 320)
                .frame(maxWidth: .infinity)
                .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                .overlay(alignment: .topTrailing) {
                    KakaCallSelfPreview(video: call.media.localCallVideoView)
                        .frame(width: 82, height: 112)
                        .clipShape(RoundedRectangle(cornerRadius: 13))
                        .padding(10)
                        .accessibilityHidden(true)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        Text(status)
            .font(.subheadline.weight(.medium))
            .accessibilityAddTraits(.updatesFrequently)
        if let remaining = call.secondsRemaining {
            Text("\(remaining) sec in the current interval")
                .font(.caption.monospacedDigit())
                .foregroundStyle(KakaTheme.muted)
        }
        if call.phase == .waiting {
            if let remaining = call.rechargeSecondsRemaining {
                Text("\(remaining) sec to add diamonds")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(KakaTheme.liveAccent)
            }
            KakaRoomActionGroup {
                KakaRoomButton(title: "Open wallet", selected: true) {
                    if call.setRechargeWalletVisible(true) { showingWallet = true }
                }
                .disabled(call.resumingRecharge)
                KakaRoomButton(title: "Check balance") { Task { await call.refreshRechargeStatus() } }
                    .disabled(call.resumingRecharge || call.checkingRecharge)
            }
        }
        if call.phase == .active || call.phase == .waiting { callChat }
        if call.phase == .finished {
            KakaRoomButton(title: returnTitle, action: finished)
        } else if call.phase != .ending {
            KakaRoomActionGroup {
                if call.canOpenCallGifts {
                    KakaRoomButton(title: "Gifts") { showingGifts = true }
                }
                KakaRoomButton(title: "End call", asset: "action-stop.png") { Task { await call.hangUp() } }
            }
        }
    }

    private var callChat: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(call.callMessages.suffix(8)) { message in
                Text(message.isLocal ? "You · \(message.text)" : message.text)
                    .font(.footnote)
                    .foregroundStyle(message.isLocal ? KakaTheme.muted : KakaTheme.ink)
            }
            if !call.callMessageFeedback.isEmpty {
                Text(call.callMessageFeedback).font(.caption).foregroundStyle(KakaTheme.muted)
            }
            if call.phase == .active {
                HStack(spacing: 4) {
                    TextField("Send a call message", text: $draft)
                        .font(.subheadline)
                        .padding(.leading, 12)
                        .frame(minHeight: 44)
                        .submitLabel(.send)
                        .onSubmit(sendMessage)
                    KakaRoomButton(title: call.sendingCallMessage ? "Sending…" : "Send", action: sendMessage)
                        .disabled(call.sendingCallMessage || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func sendMessage() {
        let text = draft
        Task { if await call.sendCallMessage(text), draft == text { draft = "" } }
    }

    private var status: String {
        switch call.phase {
        case .offer: return "Private video call"
        case .incoming: return "Incoming video call"
        case .contacting: return "Preparing your call…"
        case .ringing: return "Waiting for the host…"
        case .connecting: return "Connecting video…"
        case .active: return "Video call in progress"
        case .waiting: return "Call paused while you add diamonds"
        case .ending: return "Ending the call…"
        case .finished: return "Call ended"
        }
    }
}

private struct KakaCallSelfPreview: UIViewRepresentable {
    let video: UIView

    func makeUIView(context: Context) -> Preview {
        let view = Preview()
        view.addSubview(video)
        return view
    }

    func updateUIView(_ uiView: Preview, context: Context) {}

    final class Preview: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            subviews.first?.frame = bounds
        }
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
    @State private var liveViewerCount: Int64?
    @State private var loading = false
    @State private var loaded = false
    @State private var error = ""

    var body: some View {
        KakaRoomSheet(title: room.kind == .live ? "Live audience" : "People in chat", locked: false) {
            if let count = liveViewerCount {
                Text("\(count.formatted()) watching")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(KakaTheme.liveAccent)
            }
            if loading && members.isEmpty {
                KakaRhythmProgress(title: room.kind == .live ? "Loading viewers" : "Loading chat participants")
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
            } else if room.kind == .live, loaded, error.isEmpty {
                KakaRoomButton(title: "Refresh audience") { Task { await load() } }
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
            if room.kind == .live {
                try await loadLiveAudience(session)
                return
            }
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
            self.error = room.kind == .live ? "Couldn’t load the live audience. Try again in a moment."
                : "Couldn’t load chat participants. Try again in a moment."
        }
    }

    private func loadLiveAudience(_ session: UUID) async throws {
        let runtime = KakaNativeRoomRuntime.shared
        guard runtime.media.isLiveAudience(roomID: room.serverID, session: session, hostID: nil, channel: nil) else {
            throw KakaAccountStore.Failure.unavailable
        }
        let data = try await store.request("audience.live", ["habitatTag": room.serverID])
        guard !Task.isCancelled, runtime.owns(visit), store.session?.token == session,
              runtime.media.isLiveAudience(roomID: room.serverID, session: session, hostID: nil, channel: nil) else { return }
        let rows = KakaRoomFields.rows(data, keys: ["gridBands", "records", "roster", "data", "result", "nebulaPieces", "viewers"])
        var seen = Set<Int64>()
        members = rows.compactMap { fields in
            let name = KakaRoomFields.text(fields, "nickname", "castMoniker")
            let account = KakaRoomFields.text(fields, "relayCode")
            guard let id = KakaRoomFields.id(fields, keys: ["voyagerBadge", "orbitMark"]), !name.isEmpty,
                  runtime.chat.canShowLiveViewer(account: account, session: session), seen.insert(id).inserted else { return nil }
            return KakaRoomChat.AudienceMember(id: String(id), name: String(name.prefix(80)),
                                              portrait: KakaRoomFields.url(KakaRoomFields.text(fields, "cometGlyph", "spotlightFace")))
        }
        liveViewerCount = (data as? [String: Any]).flatMap { KakaRemoteClient.userID($0["cosmicSum"]) }
            .flatMap { $0 >= 0 ? $0 : nil }
        loaded = true
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
    private let onMessageSent: (() -> Void)?
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
    @State private var giftVisit: GiftVisit?

    private enum Target {
        case room(KakaNativeRoom, UUID)
        case direct(Int64, String)

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
        let giftQuantity: Int?
        let giftImage: URL?
    }

    private struct GiftVisit: Identifiable {
        let id: UUID
        let hostID: Int64
        let hostName: String
        let session: UUID
    }

    init(hostID: Int64, hostName: String = "this host") {
        target = .direct(hostID, hostName)
        liveOverlayHeight = nil
        onGifts = nil
        onGiftSelected = nil
        showsQuickReplies = false
        isMinimized = false
        onMessageSent = nil
    }

    init(room: KakaNativeRoom, visit: UUID, liveOverlayHeight: CGFloat? = nil, onGifts: (() -> Void)? = nil,
         onGiftSelected: ((Int64) -> Void)? = nil, showsQuickReplies: Bool = false, isMinimized: Bool = false,
         onMessageSent: (() -> Void)? = nil) {
        target = .room(room, visit)
        self.liveOverlayHeight = liveOverlayHeight
        self.onGifts = onGifts
        self.onGiftSelected = onGiftSelected
        self.showsQuickReplies = showsQuickReplies
        self.isMinimized = isMinimized
        self.onMessageSent = onMessageSent
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
        .sheet(item: $giftVisit) { context in
            let chat = KakaNativeRoomRuntime.shared.directChat
            KakaPeerGiftSheet(recipientName: context.hostName, showsQuantity: false, loadCatalog: {
                try await chat.directGiftCatalog(hostID: context.hostID, visit: context.id, session: context.session)
            }, sendGift: { gift, quantity in
                try await chat.sendDirectGift(gift, quantity: quantity, hostID: context.hostID,
                                              visit: context.id, session: context.session)
            })
        }
        .onDisappear { close() }
    }

    private var chatPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(target.title).font(.headline).accessibilityAddTraits(.isHeader)
                if case .direct(let hostID, let hostName) = target {
                    Spacer(minLength: 0)
                    KakaRoomButton(title: "Gifts") {
                        guard canSend, let session = store.session?.token else { return }
                        focused = false
                        giftVisit = GiftVisit(id: visit, hostID: hostID, hostName: hostName, session: session)
                    }
                    .accessibilityLabel("Gifts for \(hostName)")
                    .disabled(!canSend)
                }
            }
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
                    .focused($focused)
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
                        } else if let count = line.giftQuantity {
                            HStack(alignment: .center, spacing: 8) {
                                KakaNativeImage(asset: "Dock-crate", remote: line.giftImage)
                                    .scaledToFit().frame(width: 34, height: 34)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(line.name).font(.caption.weight(.semibold)).foregroundStyle(KakaTheme.muted)
                                    Text(count == 1 ? "Gift · \(line.text)" : "Gift · \(line.text) ×\(count)")
                                        .font(.subheadline.weight(.semibold))
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(KakaTheme.base, in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityElement(children: .combine)
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
        case .direct(let host, _):
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
                return ChatLine(id: id, name: (line["own"] as? Bool == true ? "You" : name), text: text,
                                giftQuantity: line["giftQuantity"] as? Int,
                                giftImage: (line["giftImage"] as? String).flatMap(URL.init(string:)))
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
                if visit == id, store.session?.token == session, !Task.isCancelled {
                    if input == draft { input = "" }
                    onMessageSent?()
                }
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
        giftVisit = nil
        connected = false
        canSend = false
        sending = false
        guard let token = store.session?.token else { return }
        Task { @MainActor in _ = try? await request("close", visit: id, session: token) }
    }
}

@MainActor
struct KakaPeerGiftSheet: View {
    @EnvironmentObject private var store: KakaNativeStore
    let recipientName: String
    let showsQuantity: Bool
    let loadCatalog: @MainActor () async throws -> KakaPeerGifts.Catalog
    let sendGift: @MainActor (KakaPeerGifts.Gift, Int) async throws -> KakaVoiceGifts.Delivery
    var onRecharge: (() -> Void)? = nil

    @State private var catalog: KakaPeerGifts.Catalog?
    @State private var selection: KakaPeerGifts.Gift?
    @State private var quantity = 1
    @State private var busy = false
    @State private var uncertain = false
    @State private var feedback = ""
    @State private var wallet = false
    @State private var visible = false

    var body: some View {
        KakaRoomSheet(title: "Gifts for \(recipientName)", locked: busy) {
            if let catalog {
                KakaRoomActionGroup {
                    Text("\(KakaLiveGifts.display(catalog.balance)) diamonds available")
                        .font(.subheadline).foregroundStyle(KakaTheme.muted)
                    KakaRoomButton(title: "Recharge") {
                        selection = nil
                        if let onRecharge { onRecharge() } else { wallet = true }
                    }
                    .disabled(busy)
                }
            }
            if let selection {
                Text("Send \(quantity) × \(selection.name) for \(cost(selection)) diamonds?").font(.headline)
                KakaRoomActionGroup {
                    KakaRoomButton(title: "Cancel") { self.selection = nil }
                    KakaRoomButton(title: "Send gift") { Task { await send(selection, quantity: quantity) } }
                }
                .disabled(busy || uncertain)
            } else if let catalog, !catalog.gifts.isEmpty {
                if showsQuantity {
                    KakaRoomActionGroup {
                        ForEach([1, 5, 10, 99], id: \.self) { amount in
                            KakaRoomButton(title: "×\(amount)", selected: quantity == amount) { quantity = amount }
                                .accessibilityLabel("Quantity \(amount)")
                        }
                    }
                    .disabled(busy || uncertain)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                    ForEach(catalog.gifts, id: \.id) { gift in
                        Button { selection = gift } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                KakaNativeImage(asset: "Dock-crate", remote: gift.image)
                                    .scaledToFit().frame(width: 43, height: 43)
                                    .accessibilityHidden(true)
                                Text(gift.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                                Text("\(cost(gift)) diamonds").font(.caption).foregroundStyle(KakaTheme.muted)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                            .contentShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(gift.name), \(cost(gift)) diamonds")
                        .disabled(busy || uncertain || catalog.balance < gift.cost * Decimal(quantity))
                    }
                }
            }
            if busy { KakaRhythmProgress(title: selection == nil ? "Loading gifts" : "Sending gift") }
            if !feedback.isEmpty { Text(feedback).font(.footnote).foregroundStyle(KakaTheme.muted) }
            if uncertain {
                KakaRoomButton(title: "Open wallet") {
                    if let onRecharge { onRecharge() } else { wallet = true }
                }
            } else if !busy, selection == nil {
                KakaRoomButton(title: "Refresh gifts") { Task { await load() } }
            }
        }
        .interactiveDismissDisabled(busy)
        .task { await load() }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .sheet(isPresented: $wallet, onDismiss: { Task { await load() } }) { KakaStudioWalletView() }
    }

    private func cost(_ gift: KakaPeerGifts.Gift) -> String { KakaLiveGifts.display(gift.cost * Decimal(quantity)) }

    private func load() async {
        guard !busy, !uncertain, let token = store.session?.token else { return }
        busy = true
        catalog = nil
        selection = nil
        feedback = ""
        defer { busy = false }
        do {
            let next = try await loadCatalog()
            guard store.session?.token == token, !Task.isCancelled else { return }
            catalog = next
            if next.gifts.isEmpty { feedback = "No gifts are available for this conversation." }
        } catch {
            show(error, session: token)
        }
    }

    private func send(_ gift: KakaPeerGifts.Gift, quantity: Int) async {
        guard !busy, !uncertain, selection?.id == gift.id, let token = store.session?.token else { return }
        busy = true
        feedback = ""
        defer { busy = false }
        do {
            let result = try await sendGift(gift, quantity)
            guard store.session?.token == token else { return }
            switch result {
            case .sent(let balance):
                feedback = balance.map { "Gift sent. Balance \(KakaLiveGifts.display($0)) diamonds." } ?? "Gift sent."
                if !visible { store.notify("Gift sent.") }
            case .declined:
                feedback = "The gift wasn’t sent. Refresh gifts to try again."
            case .uncertain:
                uncertain = true
                feedback = "Delivery couldn’t be confirmed. Check your wallet before sending another gift."
                if !visible { store.notify(feedback) }
            }
        } catch {
            show(error, session: token)
        }
        selection = nil
        catalog = nil
    }

    private func show(_ error: Error, session: UUID) {
        guard !Task.isCancelled, store.session?.token == session else { return }
        store.expireIfNeeded(error)
        if (error as? KakaLiveGifts.Failure) == .unavailable {
            feedback = "Gifts aren’t available for this conversation."
        } else {
            feedback = store.message(error)
        }
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

    @MainActor
    func total(for quantity: Int) -> String {
        guard let amount = Decimal(string: cost, locale: Locale(identifier: "en_US_POSIX")) else { return cost }
        return KakaLiveGifts.display(amount * Decimal(quantity))
    }

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
                                 session: UUID, gift: Int64? = nil, quantity: Int = 1) async throws -> [String: Any] {
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
                                                     quantity: quantity, session: session, isAudience: audience)
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
private struct KakaVoiceGiftSheet: View {
    @EnvironmentObject private var store: KakaNativeStore
    @Environment(\.dynamicTypeSize) private var textSize
    let room: KakaNativeRoom
    let visit: UUID

    @State private var catalog: KakaVoiceGifts.Catalog?
    @State private var recipients: [KakaVoiceGifts.Recipient] = []
    @State private var selectedPeople: Set<Int64> = []
    @State private var categoryID: Int?
    @State private var giftID: Int64?
    @State private var quantity = 1
    @State private var review: Review?
    @State private var loading = false
    @State private var sending = false
    @State private var feedback = ""
    @State private var showsWallet = false

    private struct Review {
        let gift: KakaVoiceGifts.Gift
        let quantity: Int
        let recipients: [KakaVoiceGifts.Recipient]

        var total: Decimal { gift.cost * Decimal(quantity * recipients.count) }
    }

    private var runtime: KakaNativeRoomRuntime { .shared }

    private var selection: Review? {
        guard let gift = catalog?.categories.first(where: { $0.id == categoryID })?.gifts.first(where: { $0.id == giftID }) else {
            return nil
        }
        let people = recipients.filter { selectedPeople.contains($0.id) }
        guard !people.isEmpty else { return nil }
        return Review(gift: gift, quantity: quantity, recipients: people)
    }

    var body: some View {
        KakaRoomSheet(title: "Voice room gifts", locked: sending) {
            if let review {
                checkout(review)
            } else if let catalog {
                KakaRoomActionGroup {
                    Text("Balance \(KakaLiveGifts.display(catalog.balance)) diamonds")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(KakaTheme.muted)
                    KakaRoomButton(title: "Recharge") { showsWallet = true }
                }
                peoplePicker
                if catalog.categories.isEmpty {
                    Text("There are no gifts available right now.")
                        .font(.subheadline).foregroundStyle(KakaTheme.muted)
                } else {
                    giftPicker(catalog)
                    quantityPicker(catalog.quantities)
                    if let selection {
                        KakaRoomButton(title: "Review · \(KakaLiveGifts.display(selection.total)) diamonds", selected: true) {
                            if selection.total <= catalog.balance { review = selection }
                        }
                        .disabled(selection.total > catalog.balance)
                        if selection.total > catalog.balance {
                            Text("Your balance is too low for this selection.")
                                .font(.footnote).foregroundStyle(KakaTheme.muted)
                        }
                    }
                }
            }
            if !feedback.isEmpty {
                Text(feedback)
                    .font(.subheadline).foregroundStyle(KakaTheme.muted)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if loading {
                KakaRhythmProgress(title: "Loading voice gifts")
            } else if review == nil {
                KakaRoomButton(title: "Refresh gifts and recipients") { Task { await load() } }
            }
        }
        .interactiveDismissDisabled(sending)
        .task { await load() }
        .sheet(isPresented: $showsWallet, onDismiss: { Task { await load() } }) { KakaStudioWalletView() }
    }

    private var peoplePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(selectedPeople.isEmpty ? "People on mic" : "People on mic · \(selectedPeople.count) selected")
                .font(.headline).accessibilityAddTraits(.isHeader)
            if recipients.isEmpty {
                Text("Gifts can be sent to people currently on mic.")
                    .font(.footnote).foregroundStyle(KakaTheme.muted)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if recipients.count > 1 {
                            let limit = min(recipients.count, KakaVoiceGifts.recipientLimit)
                            let full = selectedPeople.count == limit
                            let title = full ? "Clear selection" : limit == recipients.count ? "Everyone" : "Select first \(limit)"
                            KakaRoomButton(title: title, selected: full) {
                                selectedPeople = full ? [] : Set(recipients.prefix(limit).map(\.id))
                            }
                        }
                        ForEach(recipients) { person in
                            let selected = selectedPeople.contains(person.id)
                            Button {
                                if selected { selectedPeople.remove(person.id) }
                                else { selectedPeople.insert(person.id) }
                            } label: {
                                HStack(spacing: 5) {
                                    if let portrait = person.portrait {
                                        KakaNativeImage(asset: "member-mark.jpg", remote: portrait)
                                            .scaledToFill().frame(width: 27, height: 27).clipShape(Circle())
                                            .accessibilityHidden(true)
                                    }
                                    Text(person.name).font(.footnote.weight(.semibold)).lineLimit(1)
                                }
                                .padding(.horizontal, 10)
                                .frame(minWidth: 44, maxWidth: textSize.isAccessibilitySize ? 235 : 148, minHeight: 44)
                                .background(selected ? KakaTheme.voiceAccent.opacity(0.23) : KakaTheme.surface,
                                            in: Capsule())
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(!selected && selectedPeople.count >= KakaVoiceGifts.recipientLimit)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                }
            }
        }
    }

    private func giftPicker(_ catalog: KakaVoiceGifts.Catalog) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if catalog.categories.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(catalog.categories) { category in
                            KakaRoomButton(title: category.name, selected: category.id == categoryID) {
                                categoryID = category.id
                                giftID = nil
                            }
                        }
                    }
                }
                .accessibilityLabel("Gift categories")
            }
            if let category = catalog.categories.first(where: { $0.id == categoryID }) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: textSize.isAccessibilitySize ? 145 : 98), spacing: 8)], spacing: 8) {
                    ForEach(category.gifts) { gift in
                        let selected = gift.id == giftID
                        Button { giftID = gift.id } label: {
                            VStack(spacing: 5) {
                                if let image = gift.image, let url = KakaRoomFields.url(image.absoluteString) {
                                    AsyncImage(url: url) { phase in
                                        if let picture = phase.image { picture.resizable().scaledToFit() }
                                    }
                                    .frame(height: 48)
                                    .accessibilityHidden(true)
                                }
                                Text(gift.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                                Text(KakaLiveGifts.display(gift.cost) + " diamonds")
                                    .font(.caption.monospacedDigit()).foregroundStyle(KakaTheme.voiceAccent)
                            }
                            .multilineTextAlignment(.center)
                            .padding(8)
                            .frame(maxWidth: .infinity, minHeight: 84)
                            .background(selected ? KakaTheme.voiceAccent.opacity(0.18) : KakaTheme.surface,
                                        in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(KakaRoomCardPressStyle())
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
        }
    }

    private func quantityPicker(_ quantities: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Quantity per person").font(.subheadline.weight(.semibold))
            HStack(spacing: 10) {
                KakaRoomButton(title: "−") { quantity -= 1 }
                    .disabled(quantity <= 1)
                    .accessibilityLabel("Decrease quantity")
                Text(quantity.formatted())
                    .font(.subheadline.monospacedDigit())
                    .accessibilityLabel("Quantity \(quantity)")
                KakaRoomButton(title: "+") { quantity += 1 }
                    .disabled(quantity >= KakaVoiceGifts.quantityLimit)
                    .accessibilityLabel("Increase quantity")
            }
            if quantities.count > 1 { quantityPresets(quantities) }
        }
    }

    private func quantityPresets(_ quantities: [Int]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(quantities, id: \.self) { amount in
                    KakaRoomButton(title: amount.formatted(), selected: amount == quantity) { quantity = amount }
                        .accessibilityLabel("\(amount) per person")
                }
            }
        }
    }

    private func checkout(_ review: Review) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Confirm gift").font(.headline).accessibilityAddTraits(.isHeader)
            Text("\(review.quantity) × \(review.gift.name) per person")
                .font(.subheadline.weight(.semibold))
            Text(review.recipients.map(\.name).joined(separator: ", "))
                .font(.subheadline).foregroundStyle(KakaTheme.muted)
            Text("Total \(KakaLiveGifts.display(review.total)) diamonds")
                .font(.subheadline.monospacedDigit()).foregroundStyle(KakaTheme.voiceAccent)
            KakaRoomActionGroup {
                KakaRoomButton(title: "Back to gifts") { self.review = nil }.disabled(sending)
                KakaRoomButton(title: sending ? "Sending…" : "Send gift", selected: true) {
                    guard !sending else { return }
                    sending = true
                    Task { await send(review) }
                }
                .disabled(sending)
            }
        }
    }

    private func admitted(_ session: UUID) -> Bool {
        room.kind == .voice && store.session?.token == session && runtime.owns(visit)
            && runtime.media.isVoiceGiftAudience(roomID: room.serverID, session: session)
    }

    private func load() async {
        guard !loading, let session = store.session?.token, admitted(session) else { return }
        loading = true
        defer { loading = false }
        feedback = ""
        catalog = nil
        selectedPeople = []
        giftID = nil
        quantity = 1
        do {
            let current = try await KakaVoiceGifts.catalog(roomID: room.serverID, session: session) { admitted(session) }
            let people = try await runtime.media.voiceGiftRecipients(roomID: room.serverID, session: session)
            guard !Task.isCancelled, admitted(session) else { return }
            recipients = people
            categoryID = current.categories.first(where: \.preferred)?.id ?? current.categories.first?.id
            catalog = current
        } catch {
            guard !Task.isCancelled, admitted(session) else { return }
            store.expireIfNeeded(error)
            feedback = store.message(error)
        }
    }

    private func send(_ review: Review) async {
        defer { sending = false }
        guard let session = store.session?.token, admitted(session) else { return }
        feedback = ""
        do {
            let result = try await KakaVoiceGifts.send(review.gift, quantity: review.quantity, recipients: review.recipients,
                                                       roomID: room.serverID, session: session, media: runtime.media) { admitted(session) }
            guard store.session?.token == session else { return }
            if case .sent = result, !admitted(session) { store.notify("Gift sent.") }
            guard admitted(session) else { return }
            switch result {
            case .sent(let balance):
                feedback = balance.map { "Gift sent. Balance \(KakaLiveGifts.display($0)) diamonds." } ?? "Gift sent."
            case .declined:
                feedback = "The gift wasn’t sent."
            case .uncertain:
                feedback = "Delivery couldn’t be confirmed. Check your balance before sending again."
            }
        } catch {
            guard admitted(session) else { return }
            store.expireIfNeeded(error)
            feedback = store.message(error)
        }
        catalog = nil
        self.review = nil
    }
}

@MainActor
private struct KakaRoomGiftSheet: View {
    @EnvironmentObject private var store: KakaNativeStore
    let room: KakaNativeRoom
    let visit: UUID
    var initialGiftID: Int64? = nil
    var onSent: (() -> Void)? = nil
    @State private var gifts: [KakaLiveGift] = []
    @State private var balance = ""
    @State private var host = ""
    @State private var feedback = ""
    @State private var busy = false
    @State private var choice: KakaLiveGift?
    @State private var quantity = 1
    @State private var duelGift = false
    @State private var showsWallet = false

    var body: some View {
        KakaRoomSheet(title: duelGift ? "PK gifts" : "Gifts", locked: busy) {
            if !balance.isEmpty {
                KakaRoomActionGroup {
                    Text("\(balance) diamonds available").font(.subheadline).foregroundStyle(KakaTheme.muted)
                    KakaRoomButton(title: "Recharge") {
                        choice = nil
                        showsWallet = true
                    }
                    .disabled(busy)
                }
            }
            if let choice {
                Text("Send a gift?").font(.headline)
                Text("Send \(quantity) × \(choice.name) to \(host) for \(choice.total(for: quantity)) diamonds.")
                    .font(.subheadline).foregroundStyle(KakaTheme.muted)
                KakaRoomActionGroup { giftConfirmation(choice) }
            } else {
                if !gifts.isEmpty {
                    KakaRoomActionGroup {
                        ForEach([1, 5, 10, 99], id: \.self) { amount in
                            KakaRoomButton(title: "×\(amount)", selected: amount == quantity) { quantity = amount }
                                .foregroundStyle(amount == quantity ? KakaTheme.liveAccent : KakaTheme.ink)
                                .accessibilityLabel("Quantity \(amount)")
                        }
                    }
                    .disabled(busy)
                }
                ForEach(gifts) { gift in
                    HStack(spacing: 8) {
                        gift.artwork(size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(gift.name).font(.subheadline.weight(.semibold))
                            Text("\(gift.total(for: quantity)) diamonds").font(.caption).foregroundStyle(KakaTheme.muted)
                        }
                        Spacer(minLength: 4)
                        KakaRoomButton(title: "Give") { choice = gift }
                            .accessibilityLabel("Give \(quantity) × \(gift.name) for \(gift.total(for: quantity)) diamonds")
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
        .sheet(isPresented: $showsWallet, onDismiss: { Task { await fetch() } }) { KakaStudioWalletView() }
    }

    @ViewBuilder
    private func giftConfirmation(_ gift: KakaLiveGift) -> some View {
        KakaRoomButton(title: "Cancel") { choice = nil }
        KakaRoomButton(title: "Send gift") {
            let count = quantity
            choice = nil
            Task { await send(gift, quantity: count) }
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
            duelGift = fields["duel"] as? Bool == true
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

    private func send(_ gift: KakaLiveGift, quantity: Int) async {
        guard !busy, gift.available, gifts.contains(where: { $0.id == gift.id }),
              let session = store.session?.token else { return }
        busy = true
        feedback = ""
        gifts = []
        defer { busy = false }
        do {
            let result = try await liveRoomGiftRequest("gift.send", room: room, visit: visit, session: session,
                                                       gift: gift.id, quantity: quantity)
            guard store.session?.token == session else { return }
            balance = result["balance"] as? String ?? ""
            switch result["status"] as? String {
            case "sent":
                feedback = "Gift sent."
                onSent?()
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

struct KakaRoomSheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: KakaNativeStore
    @State private var sheetID = UUID()
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
        .onAppear { store.setSheet(sheetID, presented: true) }
        .onDisappear { store.setSheet(sheetID, presented: false) }
    }
}

@MainActor
fileprivate struct KakaDirectoryRankingSheet: View {
    var body: some View { KakaRankingSheet() }
}

@MainActor
fileprivate struct KakaRoomRankingSheet: View {
    let room: KakaNativeRoom
    let visit: UUID

    var body: some View { KakaRankingSheet(room: room, visit: visit) }
}

@MainActor
private struct KakaRankingSheet: View {
    @EnvironmentObject private var store: KakaNativeStore
    @Environment(\.dynamicTypeSize) private var textSize
    private let room: KakaNativeRoom?
    private let visit: UUID?
    private let duel: KakaRealtimeMedia.LiveDuel.Ranking?
    @State private var selection: Selection
    @State private var entries: [Entry] = []
    @State private var ownEntry: Entry?
    @State private var loadedSelection: Selection?
    @State private var requestID = UUID()
    @State private var loadError = ""

    private enum Board: String {
        case wealth, charm, contribution, room, family, duelHost, duelOpponent

        var title: String {
            switch self {
            case .wealth: return "Wealth"
            case .charm: return "Charm"
            case .contribution: return "Contribution"
            case .room: return "Rooms"
            case .family: return "Family"
            case .duelHost: return "Host"
            case .duelOpponent: return "Opponent"
            }
        }
    }

    private enum Period: String {
        case now, day, week, month

        func title(liveRoom: Bool) -> String {
            switch self {
            case .now: return "This room"
            case .day: return liveRoom ? "Today" : "Daily"
            case .week: return liveRoom ? "This week" : "Weekly"
            case .month: return "Monthly"
            }
        }
    }

    private struct Selection: Hashable {
        var board: Board
        var period: Period
    }

    private struct Entry: Identifiable {
        let id: Int
        let userID: Int64?
        let rank: Int64?
        let name: String
        let portrait: URL?
        let score: String

        init?(_ fields: [String: Any], index: Int, voice: Bool, scoreField: String, fallbackRank: Int64? = nil) {
            let name = KakaRoomFields.text(fields, "nickname", "nickName", "castMoniker", "roomName")
            let userID = KakaRoomFields.id(fields, keys: voice ? ["userId"] : ["voyagerBadge", "orbitMark"])
            let rank = KakaRoomFields.id(fields, keys: [voice ? "rankIndex" : "stellarGrade"]) ?? fallbackRank
            guard !name.isEmpty || rank != nil || userID != nil else { return nil }
            self.id = index
            self.userID = userID
            self.rank = rank
            self.name = String(name.prefix(80))
            portrait = KakaRoomFields.url(KakaRoomFields.text(fields, voice ? "avatar" : "cometGlyph", "spotlightFace"))
            let value: String
            if let number = fields[scoreField] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                value = number.stringValue
            } else {
                value = KakaRoomFields.text(fields, scoreField)
            }
            score = value.utf8.count <= 32 && value.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil
                ? value : ""
        }
    }

    init(room: KakaNativeRoom? = nil, visit: UUID? = nil, duel: KakaRealtimeMedia.LiveDuel.Ranking? = nil) {
        self.room = room
        self.visit = visit
        self.duel = duel
        let firstBoard: Board = duel != nil ? .duelHost : (room?.kind == .voice ? .contribution : .wealth)
        _selection = State(initialValue: Selection(board: firstBoard,
                                                   period: room?.kind == .live ? .now : .day))
    }

    private var boards: [Board] {
        if duel != nil { return [.duelHost, .duelOpponent] }
        if room?.kind == .voice { return [.contribution, .charm, .room, .wealth, .family] }
        return room == nil ? [.wealth, .charm] : []
    }

    private var periods: [Period] { room?.kind == .live ? [.now, .day, .week] : [.day, .week, .month] }
    private var accent: Color { room?.kind == .voice ? KakaTheme.voiceAccent : KakaTheme.liveAccent }

    var body: some View {
        KakaRoomSheet(title: duel != nil ? "PK contributions" : (room == nil ? "Rankings" : "Room rankings"), locked: false) {
            if !boards.isEmpty {
                rankingControls {
                    ForEach(boards, id: \.self) { board in
                        KakaRoomButton(title: board.title, selected: selection.board == board) { selection.board = board }
                    }
                }
                .accessibilityLabel("Ranking category")
            }
            if duel == nil {
                rankingControls {
                    ForEach(periods, id: \.self) { period in
                        KakaRoomButton(title: period.title(liveRoom: room?.kind == .live), selected: selection.period == period) {
                            selection.period = period
                        }
                    }
                }
                .accessibilityLabel("Ranking period")
            }
            if loadedSelection != selection {
                KakaRhythmProgress(title: "Loading rankings")
            } else if !loadError.isEmpty {
                Text(loadError).font(.footnote).foregroundStyle(KakaTheme.muted)
                KakaRoomButton(title: "Try again") { Task { await load(selection) } }
            } else if entries.isEmpty && ownEntry == nil {
                Text(duel != nil ? "No contributions yet." : "No rankings for this period.")
                    .font(.subheadline).foregroundStyle(KakaTheme.muted)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(entries) { entry in
                        rankingRow(entry)
                        if entry.id != entries.last?.id { Divider() }
                    }
                }
                if let ownEntry {
                    Text("Your rank").font(.caption.weight(.semibold)).foregroundStyle(KakaTheme.muted)
                    rankingRow(ownEntry)
                } else if room == nil {
                    Text("You aren’t ranked for this period.").font(.footnote).foregroundStyle(KakaTheme.muted)
                }
            }
        }
        .task(id: selection) { await load(selection) }
    }

    private func rankingControls<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 7, content: content) }
    }

    private func rankingRow(_ entry: Entry) -> some View {
        HStack(spacing: 10) {
            if let rank = entry.rank {
                Text(rank.formatted())
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(accent)
                    .accessibilityLabel("Rank \(rank.formatted())")
                    .frame(minWidth: 26, alignment: .leading)
            }
            if !textSize.isAccessibilitySize, let portrait = entry.portrait {
                KakaNativeImage(asset: "member-mark.jpg", remote: portrait)
                    .scaledToFill()
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
            }
            if textSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name.isEmpty ? "Member" : entry.name).font(.subheadline.weight(.semibold))
                    if !entry.score.isEmpty { rankingScore(entry.score) }
                }
                Spacer(minLength: 0)
            } else {
                Text(entry.name.isEmpty ? "Member" : entry.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                Spacer(minLength: 6)
                if !entry.score.isEmpty { rankingScore(entry.score) }
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private func rankingScore(_ score: String) -> some View {
        Text(score).font(.footnote.monospacedDigit()).foregroundStyle(KakaTheme.muted)
            .accessibilityLabel("Score \(score)")
    }

    private func load(_ requested: Selection) async {
        loadedSelection = nil
        loadError = ""
        let request = UUID()
        requestID = request
        guard let session = store.session?.token, isCurrentRoom else {
            loadedSelection = requested
            loadError = "The rankings are unavailable right now."
            return
        }
        let operation: String
        let fields: [String: Any]
        switch (duel, room?.kind) {
        case (.some(let duel), .live):
            operation = "ranking.liveDuel"
            fields = ["cometMarker": duel.id, "hostBadge": requested.board == .duelOpponent ? duel.opponentID : duel.hostID]
        case (_, .live):
            operation = "ranking.liveRoom"
            fields = ["habitatTag": room?.serverID ?? 0,
                      "orbitGrade": requested.period == .day ? "today" : requested.period.rawValue]
        case (_, .voice):
            operation = "ranking.voice.\(requested.board.rawValue)"
            fields = ["roomId": room?.serverID ?? 0, "rankType": requested.period.rawValue]
        case (_, nil):
            operation = "ranking.directory"
            fields = ["stageFormat": requested.board == .charm ? "anchor" : "wealth",
                      "orbitCycle": requested.period.rawValue]
        }
        do {
            let source = try await store.request(operation, fields)
            let directoryUser: Int64?
            if room == nil { directoryUser = try await KakaAccountStore.shared.remoteUserID(session: session) }
            else { directoryUser = nil }
            guard !Task.isCancelled, requestID == request, requested == selection,
                  store.session?.token == session, isCurrentRoom else { return }
            if room?.kind == .voice {
                guard let contents = source as? [String: Any],
                      contents["rankList"] == nil || contents["rankList"] is NSNull || contents["rankList"] is [[String: Any]] else {
                    throw KakaRemoteClient.Fault.response
                }
                let rows = contents["rankList"] as? [[String: Any]] ?? []
                entries = rows.enumerated().compactMap { index, fields in
                    Entry(fields, index: index, voice: true, scoreField: "rankValue", fallbackRank: Int64(index + 1))
                }
                let mine = (contents["myRank"] as? [String: Any]).flatMap { Entry($0, index: -1, voice: true, scoreField: "rankValue") }
                if let id = mine?.userID, entries.contains(where: { $0.userID == id }) { ownEntry = nil }
                else { ownEntry = mine }
            } else if duel != nil {
                guard let contents = source as? [String: Any],
                      contents["gridBands"] == nil || contents["gridBands"] is NSNull || contents["gridBands"] is [[String: Any]] else {
                    throw KakaRemoteClient.Fault.response
                }
                let rows = contents["gridBands"] as? [[String: Any]] ?? []
                entries = rows.enumerated().compactMap { index, fields in
                    Entry(fields, index: index, voice: false, scoreField: "cheerOffering", fallbackRank: Int64(index + 1))
                }
                .sorted { ($0.rank ?? .max, $0.id) < ($1.rank ?? .max, $1.id) }
                ownEntry = nil
            } else {
                let rows = KakaRoomFields.rows(source, keys: ["gridBands", "records", "roster", "data", "result", "nebulaPieces", "rankList"])
                let scoreField = room == nil ? "tally" : "cheerSpend"
                entries = rows.enumerated().compactMap { index, fields in
                    Entry(fields, index: index, voice: false, scoreField: scoreField)
                }
                .filter { room != nil || $0.userID != nil }
                .sorted { ($0.rank ?? .max, $0.id) < ($1.rank ?? .max, $1.id) }
                ownEntry = directoryUser.flatMap { id in entries.first { $0.userID == id } }
            }
            loadedSelection = requested
        } catch {
            guard !Task.isCancelled, requestID == request, requested == selection,
                  store.session?.token == session, isCurrentRoom else { return }
            loadedSelection = requested
            loadError = store.message(error)
        }
    }

    private var isCurrentRoom: Bool {
        guard let visit else { return room == nil }
        let runtime = KakaNativeRoomRuntime.shared
        guard runtime.owns(visit) else { return false }
        guard let duel else { return true }
        guard let room, let session = store.session?.token else { return false }
        return runtime.media.duel?.ranking == duel
            && runtime.media.isLiveAudience(roomID: room.serverID, session: session, hostID: duel.hostID, channel: nil)
    }
}

@MainActor
fileprivate struct KakaHostGiftWallSheet: View {
    @EnvironmentObject private var store: KakaNativeStore
    @Environment(\.dynamicTypeSize) private var textSize
    let host: KakaNativeHost
    @State private var received = true
    @State private var receivedGifts: [Gift] = []
    @State private var sentGifts: [Gift] = []
    @State private var loaded = false
    @State private var loading = false
    @State private var loadError = ""

    private struct Gift: Identifiable {
        let id: Int
        let name: String
        let art: URL?
        let quantity: Int64?
    }

    var body: some View {
        KakaRoomSheet(title: "Gift wall", locked: false) {
            Text(host.name).font(.headline).foregroundStyle(KakaTheme.muted)
            KakaRoomActionGroup {
                KakaRoomButton(title: "Received", selected: received) { received = true }
                KakaRoomButton(title: "Sent", selected: !received) { received = false }
            }
            if loading || !loaded && loadError.isEmpty {
                KakaRhythmProgress(title: "Loading gift wall")
            } else if !loadError.isEmpty {
                Text(loadError).font(.footnote).foregroundStyle(KakaTheme.muted)
                KakaRoomButton(title: "Try again") { Task { await load() } }
            } else {
                let gifts = received ? receivedGifts : sentGifts
                if gifts.isEmpty {
                    Text(received ? "No gifts received yet." : "No gifts sent yet.")
                        .font(.subheadline).foregroundStyle(KakaTheme.muted)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: textSize.isAccessibilitySize ? 145 : 92), spacing: 8)], spacing: 8) {
                        ForEach(gifts) { gift in giftCard(gift) }
                    }
                }
            }
        }
        .task(id: host.id) { await load() }
    }

    private func giftCard(_ gift: Gift) -> some View {
        VStack(spacing: 5) {
            if let art = gift.art {
                AsyncImage(url: art) { phase in
                    if let image = phase.image { image.resizable().scaledToFit() }
                    else { Color.clear }
                }
                    .frame(width: 50, height: 50)
                    .accessibilityHidden(true)
            }
            Text(gift.name).font(.footnote.weight(.semibold)).multilineTextAlignment(.center)
            if let quantity = gift.quantity {
                Text("×\(quantity.formatted())").font(.caption.monospacedDigit()).foregroundStyle(KakaTheme.liveAccent)
                    .accessibilityLabel("Quantity \(quantity.formatted())")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 94)
        .padding(8)
        .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 13))
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        guard !loading, let session = store.session?.token else { return }
        loading = true
        loadError = ""
        defer { loading = false }
        do {
            let source = try await store.request("getHost", ["voyagerBadge": host.id])
            guard !Task.isCancelled, session == store.session?.token else { return }
            guard let fields = source as? [String: Any] else { throw KakaRemoteClient.Fault.response }
            let profile = (fields["venueBrief"] as? [String: Any]) ?? (fields["astralPortrait"] as? [String: Any]) ?? fields
            if let id = KakaRoomFields.id(profile, keys: ["voyagerBadge", "orbitMark"]), id != host.id {
                throw KakaRemoteClient.Fault.response
            }
            let card = fields["consolePanels"] != nil || fields["tributePanels"] != nil ? fields : profile
            for key in ["consolePanels", "tributePanels"] {
                if let value = card[key], !(value is NSNull), !(value is [[String: Any]]) {
                    throw KakaRemoteClient.Fault.response
                }
            }
            let isAnchor = [2, 3].contains(KakaRemoteClient.userID(card["stellarKind"]) ?? 0)
            receivedGifts = parse(card[isAnchor ? "consolePanels" : "tributePanels"])
            sentGifts = parse(card[isAnchor ? "tributePanels" : "consolePanels"])
            loaded = true
        } catch {
            guard !Task.isCancelled, session == store.session?.token else { return }
            loadError = store.message(error)
        }
    }

    private func parse(_ value: Any?) -> [Gift] {
        let gifts = value as? [[String: Any]] ?? []
        return gifts.enumerated().compactMap { index, fields in
            let name = KakaRoomFields.text(fields, "voyagerLabel")
            let art = KakaRoomFields.url(KakaRoomFields.text(fields, "nebulaCanvas"))
            guard !name.isEmpty || art != nil else { return nil }
            let quantity = KakaRemoteClient.userID(fields["beaconTally"]).flatMap { $0 >= 0 ? $0 : nil }
            return Gift(id: index, name: name.isEmpty ? "Gift" : String(name.prefix(80)), art: art, quantity: quantity)
        }
    }
}

@MainActor
fileprivate struct KakaLiveWishlistSheet: View {
    @EnvironmentObject private var store: KakaNativeStore
    let room: KakaNativeRoom
    let visit: UUID
    @State private var wishes: [Wish] = []
    @State private var loading = false
    @State private var loaded = false
    @State private var loadError = ""

    private struct Wish: Identifiable {
        let id: Int64
        let name: String
        let image: URL?
        let completed: Int64?
        let target: Int64?
    }

    var body: some View {
        KakaRoomSheet(title: "Gift wish list", locked: false) {
            if loading || !loaded && loadError.isEmpty {
                KakaRhythmProgress(title: "Loading gift wishes")
            } else if !loadError.isEmpty {
                Text(loadError).font(.footnote).foregroundStyle(KakaTheme.muted)
                KakaRoomButton(title: "Try again") { Task { await load() } }
            } else if wishes.isEmpty {
                Text("The host hasn’t added any gift wishes.").font(.subheadline).foregroundStyle(KakaTheme.muted)
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(wishes) { wish in wishRow(wish) }
                }
            }
        }
        .task { await load() }
    }

    private func wishRow(_ wish: Wish) -> some View {
        HStack(spacing: 10) {
            if let image = wish.image {
                AsyncImage(url: image) { phase in
                    if let picture = phase.image { picture.resizable().scaledToFit() }
                    else { Color.clear }
                }
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(wish.name).font(.subheadline.weight(.semibold))
                if let completed = wish.completed, let target = wish.target {
                    Text("\(completed.formatted()) of \(target.formatted()) received")
                        .font(.caption.monospacedDigit()).foregroundStyle(KakaTheme.muted)
                    ProgressView(value: Double(min(completed, target)), total: Double(target))
                        .tint(KakaTheme.liveAccent)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        guard !loading, let session = store.session?.token, isActive(session) else {
            if !loading { loadError = "The live room is unavailable." }
            return
        }
        loading = true
        loadError = ""
        defer { loading = false }
        do {
            let response = try await store.request("live.wishlist", ["habitatTag": room.serverID])
            guard !Task.isCancelled, store.session?.token == session, isActive(session) else { return }
            var seen = Set<Int64>()
            wishes = KakaRoomFields.rows(response, keys: ["gridBands"]).compactMap { fields in
                let name = KakaRoomFields.text(fields, "voyagerLabel")
                guard let id = KakaRoomFields.id(fields, keys: ["beaconMark"]), !name.isEmpty, seen.insert(id).inserted else { return nil }
                let completed = KakaRemoteClient.userID(fields["encoreGifts"]).flatMap { $0 >= 0 ? $0 : nil }
                return Wish(id: id, name: String(name.prefix(80)), image: KakaRoomFields.url(KakaRoomFields.text(fields, "nebulaTile")),
                            completed: completed, target: KakaRoomFields.id(fields, keys: ["orbitTally"]))
            }
            loaded = true
        } catch {
            guard !Task.isCancelled, store.session?.token == session, isActive(session) else { return }
            loadError = store.message(error)
        }
    }

    private func isActive(_ session: UUID) -> Bool {
        let runtime = KakaNativeRoomRuntime.shared
        return room.kind == .live && runtime.owns(visit)
            && runtime.media.isLiveAudience(roomID: room.serverID, session: session, hostID: nil, channel: nil)
    }
}
