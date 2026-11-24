import SwiftUI
import UIKit
import AVFoundation
import Combine
import WebKit
import CoreFoundation
import ImageIO

struct KakaNativeHost: Identifiable, Equatable {
    let id: Int64
    let name: String
    let bio: String
    let portrait: URL?
    let style: String

    static func fields(in source: [String: Any]) -> [String: Any] {
        ["venueBrief", "astralPortrait", "detail", "profile", "user"].lazy.compactMap {
            source[$0] as? [String: Any]
        }.first ?? source
    }

    static func parse(_ source: [String: Any], expectedID: Int64? = nil, party: Bool = false) -> Self? {
        let value = fields(in: source)
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
    let voiceLanguage: String
    let voiceRegion: String
    let locked: Bool
    let channel: String
    private(set) var awaitingVoiceDetails = false

    var id: String { kind == .voice ? "party-\(serverID)" : String(serverID) }

    static func voiceInvitation(roomID: Int64) -> Self? {
        guard var room = parse(["roomId": roomID, "roomName": "Voice room"], kind: .voice) else { return nil }
        room.awaitingVoiceDetails = true
        return room
    }

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
            voiceLanguage: party ? KakaRoomFields.text(value, "roomLanguage", "languageCode") : "",
            voiceRegion: party ? KakaRoomFields.text(value, "region") : "",
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
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .body) private var spotlightCaptionHeight: CGFloat = 104
    let kind: KakaNativeRoom.Kind

    private static let scrollSpace = "KakaRoomDirectoryViewport"
    private static let contentTop = "KakaRoomDirectoryTop"

    @State private var filter: RoomFilter
    @State private var category: RoomFilter?
    @State private var voiceLanguage: KakaVoiceDirectoryData.Language?
    @State private var voiceLanguages: [KakaVoiceDirectoryData.Language] = []
    @State private var ownedVoiceRoom: KakaNativeRoom?
    @State private var voiceMetadataRequest = UUID()
    @State private var liveRegions: [LiveRegion] = []
    @State private var liveRegion: LiveRegion?
    @State private var regionSession: UUID?
    @State private var regionRequest = UUID()
    @State private var regionLoadFailed = false
    @State private var searching = false
    @State private var query = ""
    @State private var hostRefresh = UUID()
    @FocusState private var searchFocused: Bool
    @State private var rooms: [KakaNativeRoom] = []
    @State private var activeLoad: RoomLoad?
    @State private var loadFailure: (operation: RoomLoad, message: String)?
    @State private var loadingFollowing = false
    @State private var followingError = ""
    @State private var hasMore = false
    @State private var requiresManualPaging = false
    @State private var page = 0
    @State private var currentFeed: FeedScope?
    @State private var roomRequest = UUID()
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

    private struct LiveRegion: Identifiable, Equatable {
        let id: Int64
        let name: String
    }

    private struct FeedScope: Equatable {
        let session: UUID?
        let region: Int64?
    }

    private var feed: FeedScope { FeedScope(session: store.session?.token, region: liveRegion?.id) }

    private struct PageRequest: Equatable {
        let feed: FeedScope
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
        guard currentFeed == feed else { return [] }
        let ownedID = personalVoiceRoom?.id
        return rooms.filter { $0.id != ownedID && !store.isHidden($0.id) && !store.isLiveEnded($0) }
    }

    private var personalVoiceRoom: KakaNativeRoom? {
        guard kind == .voice, !searching, currentFeed == feed, let ownedVoiceRoom,
              !store.isHidden(ownedVoiceRoom.id) else { return nil }
        return ownedVoiceRoom
    }

    private var filters: [RoomFilter] {
        kind == .voice ? [.all, .following, .recent, .watched] : [.all, .onAir, .new, .following, .watched]
    }

    private var showsDirectorySpotlight: Bool {
        !searching && category == nil && voiceLanguage == nil && liveRegion == nil && filter == (kind == .live ? .onAir : .all)
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
            matchesCategory(room) && (voiceLanguage?.matches(room) ?? true)
                && (term.isEmpty || [room.title, room.host?.name ?? "", room.topic, room.description, room.genre,
                                     room.directoryLocale ?? "", room.voiceLanguage, room.voiceRegion]
                    .contains { $0.localizedStandardContains(term) })
        }
        switch filter {
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
    private var showsNewHosts: Bool { kind == .live && filter == .new && !searching }

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
        .task(id: feed) {
            guard !Task.isCancelled, currentFeed != feed || page == 0 else { return }
            currentFeed = feed
            roomRequest = UUID()
            activeLoad = nil
            loadFailure = nil
            page = 0
            hasMore = false
            requiresManualPaging = false
            rooms = []
            if campaignSession != feed.session {
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
            async let campaigns: Void = loadCampaigns()
            async let metadata: Void = loadDirectoryMetadata()
            _ = await (campaigns, metadata)
        }
        .sheet(item: $openedCampaign) { campaign in
            switch campaign.destination {
            case .wallet:
                KakaStudioWalletView()
            case .support:
                KakaStudioHelpView()
            case .backpack:
                KakaStudioGiftBackpackView()
            case .page(let target):
                KakaCampaignPage(target: target)
            case .external:
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
        ScrollViewReader { scroll in
            directoryScroll(viewport: viewport, gutter: gutter)
                .onChange(of: searching) { active in
                    if active { scroll.scrollTo(Self.contentTop, anchor: .top) }
                }
                .onChange(of: searchTerm) { _ in
                    if searching { scroll.scrollTo(Self.contentTop, anchor: .top) }
                }
                .onChange(of: feed) { _ in scroll.scrollTo(Self.contentTop, anchor: .top) }
                .onChange(of: filter) { _ in scroll.scrollTo(Self.contentTop, anchor: .top) }
        }
    }

    private func directoryScroll(viewport: CGSize, gutter: CGFloat) -> some View {
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
                if (searching || showsNewHosts), store.tab == (kind == .live ? .live : .voice), store.route == nil,
                   let session = store.session?.token {
                    let source: KakaDirectoryHostResults.Source = searching ? .search(searchTerm) : .newHosts(region: liveRegion?.id)
                    KakaDirectoryHostResults(source: source, session: session) { host in
                        searchFocused = false
                        store.open(.host(host))
                    }
                    .id(KakaDirectoryHostResults.Scope(source: source, session: session, refresh: hostRefresh))
                }
                if let room = personalVoiceRoom {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your room")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(KakaTheme.voiceAccent)
                            .accessibilityAddTraits(.isHeader)
                        voiceRoomButton(room, viewportHeight: viewport.height)
                    }
                }
                if !showsNewHosts { roomResults(viewport: viewport) }
            }
            .padding(.horizontal, gutter)
            .padding(.top, 8)
            .padding(.bottom, 20)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .id(Self.contentTop)
        }
        .coordinateSpace(name: Self.scrollSpace)
        .onPreferenceChange(LivePagePreference.self) { request in
            guard let request else { return }
            Task { @MainActor in
                guard request.feed == feed, request.filter == filter, request.page == page,
                      canPageAutomatically, !results.isEmpty else { return }
                await load(.more)
            }
        }
        .accessibilityLabel(kind.title)
        .refreshable {
            if searching || showsNewHosts { hostRefresh = UUID() }
            await load()
            await loadCampaigns(force: true)
            await loadDirectoryMetadata(force: true)
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
            if textSize.isAccessibilitySize || width < (kind == .voice ? 304 : 274) {
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
                HStack(spacing: 14) {
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
        HStack(spacing: 4) {
            directoryTool(searching ? "action-close.png" : "action-search.png",
                          label: searching ? "Close search" : "Search rooms or hosts",
                          size: searching ? 24 : 30,
                          glassTint: searching ? directoryAccent.opacity(0.24) : .white.opacity(0.07)) {
                searching.toggle()
                searchFocused = searching
                if !searching { query = "" }
            }
            directoryTool("action-ranks.png", label: "Platform rankings", glassTint: .white.opacity(0.07)) {
                searchFocused = false
                showingDirectoryRankings = true
            }
            if kind == .voice {
                directoryTool("action-create.png", label: "Create voice room", glassTint: directoryAccent.opacity(0.22)) {
                    searchFocused = false
                    showingVoiceCreation = true
                }
            }
        }
    }

    private func directoryTool(_ asset: String, label: String, size: CGFloat = 30,
                               glassTint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            let icon = KakaNativeImage(asset: asset)
                .scaledToFit()
                .frame(width: size, height: size)
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)
            Group {
                if let glassTint {
                    icon.modifier(KakaGlass(interactive: true, radius: 14, tint: glassTint))
                } else {
                    icon
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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
                directoryTool("action-close.png", label: "Clear search text", size: 21) {
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
        let languages = kind == .voice ? KakaVoiceDirectoryData.choices(voiceLanguages, rooms: visibleRooms) : []
        let topics: [RoomFilter] = kind == .live ? (showsNewHosts ? [] : RoomFilter.liveCategories) : [.open] +
            ((category == .locked || visibleRooms.contains(where: \.locked)) ? [.locked] : []) +
            RoomFilter.liveCategories.filter { item in item != .general && visibleRooms.contains { liveCategory(for: $0) == item } }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                filterChip(kind == .live ? "Global" : "All", selected: category == nil && voiceLanguage == nil && liveRegion == nil) {
                    clearSecondaryFilters()
                }
                if kind == .live {
                    ForEach(liveRegions) { region in
                        filterChip(region.name, selected: liveRegion?.id == region.id) {
                            liveRegion = liveRegion?.id == region.id ? nil : region
                        }
                    }
                    if regionLoadFailed {
                        filterChip("Retry locations", selected: false) { Task { await loadLiveRegions(force: true) } }
                    }
                } else {
                    ForEach(languages) { language in
                        filterChip(language.label, selected: voiceLanguage?.code == language.code) {
                            voiceLanguage = voiceLanguage?.code == language.code ? nil : language
                        }
                    }
                }
                ForEach(topics) { topic in
                    let label = topic == .open ? "Open" : topic.name
                    filterChip(label, selected: category == topic) {
                        category = category == topic ? nil : topic
                        requiresManualPaging = false
                    }
                }
            }
        }
        .onChange(of: languages) { choices in
            if let code = voiceLanguage?.code {
                voiceLanguage = choices.first { $0.code == code }
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
        voiceLanguage = nil
        liveRegion = nil
        requiresManualPaging = false
    }

    private func selectFilter(_ item: RoomFilter) {
        if filter != item {
            category = nil
            voiceLanguage = nil
            requiresManualPaging = false
            filter = item
        }
        if item == .following { Task { await loadFollowing() } }
    }

    private var checkingFollowing: Bool {
        filter == .following && (loadingFollowing || (!store.followingLoaded && followingError.isEmpty))
    }

    private var waitingForRooms: Bool {
        currentFeed != feed || loading || (loadFailure == nil && (page == 0 || checkingFollowing))
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
                } else if category != nil || liveRegion != nil {
                    directoryStateButton("Clear filters", prominent: true) { clearSecondaryFilters() }
                } else if !hasMore && (filter == .all || filter == .onAir) {
                    directoryStateButton("Refresh live rooms", prominent: true) { Task { await load() } }
                } else if filter != .all && filter != .onAir {
                    directoryStateButton("Browse all live rooms", prominent: true) { selectFilter(.all) }
                }
                if hasMore && (filter != .following || !store.followedIDs.isEmpty) {
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
        if let category { return ("No \(category.name.lowercased()) rooms", "Try another topic or check more rooms.") }
        if let liveRegion { return ("No live rooms for \(liveRegion.name)", "Browse all locations or check more rooms.") }
        switch filter {
        case .all, .onAir, .new:
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
        currentFeed == feed && hasMore && !requiresExplicitPaging && !loading && loadFailure == nil
            && store.tab == .live && store.route == nil && scenePhase == .active
            && (filter != .following || (!loadingFollowing && followingError.isEmpty))
    }

    private var requiresExplicitPaging: Bool {
        requiresManualPaging || searching || category != nil || filter == .watched
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
            if requiresExplicitPaging {
                directoryStateButton("Check more rooms", prominent: true) { Task { await load(.more) } }
                    .disabled(loading)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            } else if canPageAutomatically, viewportHeight > 0 {
                GeometryReader { geometry in
                    let frame = geometry.frame(in: CoordinateSpace.named(Self.scrollSpace))
                    let prefetchDistance = min(112, viewportHeight * 0.2)
                    let isNearBottom = frame.height > 0 && frame.maxY >= 0 && frame.minY <= viewportHeight + prefetchDistance
                    let request = isNearBottom
                        ? PageRequest(feed: feed, filter: filter, page: page) : nil
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
                } else if category != nil || voiceLanguage != nil {
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
        if let voiceLanguage { return ("No rooms for \(voiceLanguage.label)", "Try another language.") }
        if let category { return ("No \(category.name.lowercased()) rooms", "Try another room filter.") }
        switch filter {
        case .all:
            if personalVoiceRoom != nil && visibleRooms.isEmpty {
                return ("No other voice rooms right now", "Refresh to see who’s on the mic.")
            }
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

    private func campaignTile(_ campaign: KakaDirectoryCampaign, size: CGSize) -> some View {
        Button {
            if case .external(let url) = campaign.destination {
                openURL(url) { accepted in
                    if !accepted { Task { @MainActor in store.notify("Couldn’t open the campaign link.") } }
                }
            } else {
                openedCampaign = campaign
            }
        } label: {
            KakaNativeImage(asset: kind == .live ? "live-deck.jpg" : "voice-deck.jpg", remote: campaign.art)
                .scaledToFit()
                .frame(width: size.width, height: size.height)
                .background(KakaTheme.surface)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(campaign.destination.accessibilityLabel)
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
        voiceMetadataRequest = UUID()
        ownedVoiceRoom = room
        rooms.removeAll { $0.id == room.id }
        rooms.insert(room, at: 0)
        store.remember([room])
        open(room)
    }

    private func load(_ operation: RoomLoad = .refresh) async {
        let append = operation == .more
        let target = feed
        guard target.session != nil, currentFeed == target, !Task.isCancelled, !loading, !append || hasMore else { return }
        let request = UUID()
        roomRequest = request
        activeLoad = operation
        loadFailure = nil
        defer { if roomRequest == request { activeLoad = nil } }
        let live = kind == .live
        let next = append ? page + 1 : 1
        do {
            let source: Any
            if live {
                var input: [String: Any] = ["stagePage": next, "folioScale": 10, "desertSector": false]
                if let region = target.region { input["castTerritories"] = String(region) }
                source = try await store.request(target.region == nil ? "listLiveRooms" : "listLiveRoomsByRegion", input)
            } else {
                source = try await store.request("listVoiceRooms", ["pageSize": 20, "languageCode": "", "version": "v2"])
            }
            guard !Task.isCancelled, target == feed, roomRequest == request else { return }
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
            guard !Task.isCancelled, target == feed, roomRequest == request else { return }
            loadFailure = (operation, store.message(error))
        }
    }

    private func loadLiveRegions(force: Bool = false) async {
        guard kind == .live, let token = store.session?.token,
              force || regionSession != token else { return }
        let request = UUID()
        regionRequest = request
        regionLoadFailed = false
        do {
            let source = try await store.request("listLiveRegions", ["signalKind": 1])
            guard !Task.isCancelled, regionRequest == request, store.session?.token == token else { return }
            var seen: Set<Int64> = []
            liveRegions = KakaRoomFields.rows(source, keys: ["gridBands", "records", "roster", "data", "result", "nebulaPieces"])
                .prefix(200).compactMap { row in
                    let name = KakaRoomFields.text(row, "hostNation")
                    guard !name.isEmpty, let id = KakaRoomFields.id(row, keys: ["orbitMark"]), seen.insert(id).inserted else { return nil }
                    return LiveRegion(id: id, name: String(name.prefix(48)))
                }
            regionSession = token
            if let choice = liveRegion { liveRegion = liveRegions.first { $0.id == choice.id } }
        } catch {
            guard !Task.isCancelled, regionRequest == request, store.session?.token == token else { return }
            regionLoadFailed = liveRegions.isEmpty
        }
    }

    private func loadDirectoryMetadata(force: Bool = false) async {
        if kind == .live {
            await loadLiveRegions(force: force)
            return
        }
        guard let session = store.session?.token else { return }
        let request = UUID()
        voiceMetadataRequest = request
        async let room = KakaVoiceDirectoryData.ownedRoom(using: store)
        async let languages = KakaVoiceDirectoryData.languages(using: store)
        if let catalog = try? await languages, !Task.isCancelled,
           voiceMetadataRequest == request, store.session?.token == session {
            voiceLanguages = catalog
        }
        do {
            let personal = try await room
            guard !Task.isCancelled, voiceMetadataRequest == request, store.session?.token == session else { return }
            ownedVoiceRoom = personal
            if let personal { store.remember([personal]) }
        } catch {
            // The public room directory is still usable if personal room lookup fails.
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

private struct KakaDirectoryHostResults: View {
    enum Source: Hashable {
        case search(String)
        case newHosts(region: Int64?)

        var title: String? {
            switch self {
            case .search(let query): return query.isEmpty ? "Suggested hosts" : "Hosts"
            case .newHosts: return nil
            }
        }

        var emptyMessage: String {
            switch self {
            case .search(let query):
                return query.isEmpty ? "No suggestions right now." : "No hosts found. Try a nickname or user ID."
            case .newHosts:
                return "No new hosts on these pages."
            }
        }
    }

    struct Scope: Hashable {
        let source: Source
        let session: UUID
        let refresh: UUID
    }

    private struct Request: Equatable {
        let page: Int
        let id = UUID()
    }

    @EnvironmentObject private var store: KakaNativeStore
    let source: Source
    let session: UUID
    let open: (KakaNativeHost) -> Void

    @State private var request = Request(page: 1)
    @State private var hosts: [KakaNativeHost] = []
    @State private var seen: Set<Int64> = []
    @State private var loading = true
    @State private var error: String?
    @State private var hasMore = false

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            if let title = source.title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KakaTheme.ink)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(hosts) { host in
                Button { open(host) } label: {
                    HStack(spacing: 10) {
                        KakaNativeImage(asset: "member-mark.jpg", remote: host.portrait)
                            .frame(width: 38, height: 38)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .accessibilityHidden(true)
                        Text(host.name).font(.subheadline.weight(.medium))
                        Spacer(minLength: 0)
                        KakaNativeImage(asset: "action-forward.png")
                            .frame(width: 15, height: 15)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(KakaTheme.ink)
                    .padding(7)
                    .frame(minHeight: 44)
                    .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 13))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if loading {
                KakaRhythmProgress(title: "Finding hosts")
            } else if let error {
                Text(error).font(.caption).foregroundStyle(KakaTheme.muted)
                KakaRoomButton(title: "Try again") { submit(page: request.page) }
            } else {
                if hosts.isEmpty {
                    Text(source.emptyMessage)
                        .font(.caption).foregroundStyle(KakaTheme.muted)
                }
                if hasMore {
                    KakaRoomButton(title: "More hosts") { submit(page: request.page + 1) }
                }
            }
        }
        .padding(.bottom, 6)
        .task(id: request) { await load(request) }
    }

    private func submit(page: Int) {
        loading = true
        error = nil
        request = Request(page: page)
    }

    private func load(_ current: Request) async {
        do {
            if case .search(let query) = source, current.page == 1 && !query.isEmpty {
                try await Task.sleep(nanoseconds: 300_000_000)
            }
            try Task.checkCancellation()
            let (payload, pageSize) = try await requestPage(current.page)
            let rows = KakaRoomFields.rows(payload, keys: ["gridBands", "records", "roster", "data", "result", "nebulaPieces"])
            guard rows.count <= pageSize else { throw KakaAccountStore.Failure.rejected }
            var nextSeen = seen
            let people = rows.compactMap { row -> (host: KakaNativeHost, account: String)? in
                guard let host = KakaNativeHost.parse(row), nextSeen.insert(host.id).inserted else { return nil }
                let fields = KakaNativeHost.fields(in: row)
                if case .newHosts = source, KakaRoomFields.text(fields, "spotlightRank", "tierTitle").uppercased() != "NEW" {
                    return nil
                }
                return (host, fields["relayCode"] as? String ?? "")
            }
            let allowed = try await KakaRoomChat.visibleDiscoveryHosts(
                people.map { ($0.host.id, $0.account) }, session: session
            )
            guard !Task.isCancelled, request == current, store.session?.token == session else { return }
            hosts.append(contentsOf: people.filter { allowed.contains($0.host.id) }.map(\.host))
            let didAdvance = nextSeen.count > seen.count
            seen = nextSeen
            let total = KakaRemoteClient.userID((payload as? [String: Any])?["cosmicSum"])
            let offset = (current.page - 1) * pageSize
            hasMore = didAdvance && (total.map { $0 > Int64(offset + rows.count) } ?? (rows.count == pageSize))
            loading = false
        } catch {
            guard !Task.isCancelled, request == current, store.session?.token == session else { return }
            loading = false
            self.error = store.message(error)
        }
    }

    private func requestPage(_ page: Int) async throws -> (payload: Any, size: Int) {
        switch source {
        case .search(let query):
            let isID = !query.isEmpty && query.utf8.allSatisfy { (48...57).contains($0) }
            let payload = try await store.request(query.isEmpty ? "directory.peopleSuggestions" : "directory.peopleSearch", [
                "stageRule": query, "signalKind": isID ? "0" : "1", "folioIndex": page, "folioScale": 20,
            ])
            return (payload, 20)
        case .newHosts(let region):
            var input: [String: Any] = ["stagePage": page, "folioScale": 10]
            if let region { input["encoreToken"] = region }
            return (try await store.request("directory.newHosts", input), 10)
        }
    }
}

@MainActor
enum KakaVoiceDirectoryData {
    struct Language: Identifiable, Equatable {
        var id: String { code }
        let code: String
        let label: String

        func matches(_ room: KakaNativeRoom) -> Bool {
            room.kind == .voice && (matches(language: room.voiceLanguage) || matches(language: room.voiceRegion))
        }

        fileprivate func matches(language value: String) -> Bool {
            let key = KakaVoiceDirectoryData.languageKey(value)
            return !key.isEmpty && (key == code || key == KakaVoiceDirectoryData.languageKey(label))
        }
    }

    static func languages(using store: KakaNativeStore) async throws -> [Language] {
        let value = try await store.request("voice.creation.languages")
        let rows = KakaRoomFields.rows(value, keys: ["rows", "records", "list", "data", "result", "items"])
        var seen: Set<String> = []
        return rows.compactMap { row in
            let code = languageKey(KakaRoomFields.text(row, "languageCode"))
            guard !code.isEmpty, code.utf8.count <= 64, seen.insert(code).inserted else { return nil }
            let name = KakaRoomFields.text(row, "languageName")
            let label = name.isEmpty || name.utf8.count > 128 ? code : name
            return Language(code: code, label: label)
        }
    }

    static func choices(_ catalog: [Language], rooms: [KakaNativeRoom]) -> [Language] {
        var result = catalog
        var seen = Set(catalog.map(\.code))
        for room in rooms where room.kind == .voice {
            let code = languageKey(room.voiceLanguage)
            guard !code.isEmpty, code.utf8.count <= 64,
                  !catalog.contains(where: { $0.matches(language: room.voiceLanguage) }),
                  seen.insert(code).inserted else { continue }
            result.append(Language(code: code, label: room.directoryLocale ?? room.voiceLanguage))
        }
        return result
    }

    static func ownedRoom(using store: KakaNativeStore) async throws -> KakaNativeRoom? {
        guard let session = store.session?.token else { throw KakaAccountStore.Failure.sessionChanged }
        let account = try await KakaAccountStore.shared.remoteUserID(session: session)
        try Task.checkCancellation()
        guard store.session?.token == session else { throw KakaAccountStore.Failure.sessionChanged }
        guard let value = try await store.request("voice.creation.ownedRoom") as? [String: Any],
              let fields = value["myRoom"] as? [String: Any] else { return nil }
        if let owner = fields["ownerId"], !(owner is NSNull), KakaRemoteClient.userID(owner) != account { return nil }
        return KakaNativeRoom.parse(fields, kind: .voice)
    }

    private nonisolated static func languageKey(_ value: String) -> String {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return key == "all" || key == "global" ? "" : key
    }
}

struct KakaDirectoryCampaign: Identifiable {
    enum Destination: Identifiable {
        case wallet
        case support
        case backpack
        case page(URL)
        case external(URL)

        var id: String {
            switch self {
            case .wallet: return "wallet"
            case .support: return "support"
            case .backpack: return "backpack"
            case .page(let url): return "page|\(url.absoluteString)"
            case .external(let url): return "external|\(url.absoluteString)"
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .wallet: return "Open wallet and rewards"
            case .support: return "Open help center"
            case .backpack: return "Open gift backpack"
            case .page: return "Open campaign"
            case .external: return "Open campaign link"
            }
        }
    }

    let id: String
    let art: URL
    let destination: Destination

    @MainActor init?(_ fields: [String: Any]) {
        if let type = KakaRemoteClient.userID(fields["signalKind"]), type != 2 { return nil }
        guard let art = KakaRoomFields.url(KakaRoomFields.text(fields, "cometImage")) else { return nil }
        self.art = art
        id = KakaRoomFields.id(fields, keys: ["orbitMark"]).map(String.init) ?? art.absoluteString
        let action = KakaRoomFields.text(fields, "stageLink").trimmingCharacters(in: .whitespacesAndNewlines)
        let destination: Destination?
        switch KakaRemoteClient.userID(fields["stageTap"]) {
        case 0:
            destination = Self.internalDestination(action)
        case 1:
            destination = KakaRoomFields.url(action).map(Destination.external)
        default:
            return nil
        }
        guard let destination else { return nil }
        self.destination = destination
    }

    @MainActor static func internalDestination(_ raw: String) -> Destination? {
        let action = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch action.lowercased() {
        case "recharge", "rechargeservice", "wallet": return .wallet
        case "customerservice", "support": return .support
        case "backpack": return .backpack
        default:
            guard let target = KakaRoomFields.url(action), allows(target) else { return nil }
            return .page(target)
        }
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
struct KakaCampaignPage: View {
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

private struct KakaStageChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(KakaTheme.base.opacity(0.53), in: RoundedRectangle(cornerRadius: 20))
            .modifier(KakaGlass(radius: 20, tint: KakaTheme.base.opacity(0.26)))
    }
}

private struct KakaRoomUtilityPresentation: ViewModifier {
    @Environment(\.dynamicTypeSize) private var textSize
    var fraction: CGFloat = 0.60

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content
                .presentationDetents(textSize.isAccessibilitySize ? [.large] : [.fraction(fraction), .large])
                .presentationDragIndicator(.visible)
        } else {
            content
        }
    }
}

struct KakaStageIconButton: View {
    let title: String
    let artwork: String
    var accent: Color? = nil
    var inRail = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
            let icon = KakaNativeImage(asset: artwork)
                .scaledToFit()
                .frame(width: 29, height: 29)
                .accessibilityHidden(true)
                .frame(width: 40, height: 40)
            Group {
                if inRail {
                    icon.background(accent?.opacity(0.32) ?? .clear, in: shape)
                } else {
                    icon.background((accent ?? KakaTheme.base).opacity(accent == nil ? 0.70 : 0.34), in: shape)
                        .modifier(KakaGlass(interactive: true, radius: 13, tint: accent?.opacity(0.20)))
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(KakaRoomCardPressStyle())
        .accessibilityLabel(title)
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
    lazy var chat = KakaRoomChat(verifySeat: { [weak self] roomID, session, userID, account, seat in
        self?.media.verifiesVoiceExpression(roomID: roomID, session: session, userID: userID,
                                            account: account, seat: seat) == true
    }) { [weak self] session, roomID in
        self?.media.chatroomID(session: session, serverID: roomID)
    }
    lazy var directChat = KakaRoomChat { _, _ in nil }
    private var owner: UUID?
    private var entry: (visit: UUID, task: Task<Void, Error>)?
    private var release: Task<Void, Never>?

    func join(_ visit: UUID, room: KakaNativeRoom, password: String?, session: UUID,
              onLiveChatConnection: ((Bool) -> Void)? = nil,
              onNotice: @escaping (KakaRoomChat.RoomNotice) -> Void) async throws {
        if let owner, owner != visit { leave(owner) }
        owner = visit
        await release?.value
        guard owner == visit, !Task.isCancelled else {
            leave(visit)
            throw CancellationError()
        }
        chat.onRoomNotice = { [weak self] observedVisit, notice in
            guard self?.owner == observedVisit, observedVisit == visit else { return }
            onNotice(notice)
        }
        chat.onLiveConnectionChanged = { [weak self] observedVisit, connected in
            guard self?.owner == observedVisit, observedVisit == visit else { return }
            onLiveChatConnection?(connected)
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
        chat.onRoomNotice = nil
        chat.onLiveConnectionChanged = nil
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    @State private var voiceRelockCheck: Task<Void, Never>?
    @State private var lastVoiceRelockAt = -Double.infinity
    @State private var seat = SeatStatus()
    @State private var lastSeatNoticeRefresh = -Double.infinity
    @State private var updatingSeat = false
    @State private var seatRefreshFailed = false
    @State private var activeSheet: RoomSheet?
    @State private var showingLiveExit = false
    @State private var liveExitID = UUID()
    @AccessibilityFocusState private var liveExitHeadingFocused: Bool
    @State private var prefersCleanLiveView = false
    @State private var selectedLiveGiftID: Int64?
    @State private var roomGift: RoomGiftBanner?
    @StateObject private var giftEffects = KakaRoomGiftEffects()
    @State private var seatExpressions: [Int64: SeatExpression] = [:]
    @State private var callPermitted = false
    @State private var callUnlocked = false
    @State private var activeLiveSeconds: TimeInterval = 0
    @State private var sentLiveMessages = 0
    @State private var liveMessagingRoom = ""
    @State private var liveChatReady = false
    @State private var liveViewingVisit: UUID?
    @State private var reportedLiveViewingVisit: UUID?
    @State private var resumeAfterPrivateCall = false
    @State private var changingSavedRooms = false
    @State private var followableHostID: Int64?
    @State private var changingFollow = false
    @State private var hideAfterConfirm = false
    @State private var cueExpanded = false
    @State private var voiceAnnouncementExpanded = false
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
        case notes, report, gifts, voiceGifts, giftWall, wishlist, ranking, duelRanking, privateCall, hide, options, people, hostProfile, messageHost, info, share, voiceManagement, voiceInvite, voiceMusic, voiceExpressions
        var id: Self { self }
    }

    private struct SeatStatus {
        var index: Int64 = 0
        var microphone = false
        var queued = false
        var queuePosition: Int64?
        var stage: [KakaRealtimeMedia.VoiceStageSeat]?
    }

    private struct RoomGiftBanner {
        let id = UUID()
        let label: String
        let artwork: URL?
        let time: TimeInterval
    }

    private struct SeatExpression {
        let id = UUID()
        let user: Int64
        let item: KakaRoomChat.VoiceExpression
    }

    private var runtime: KakaNativeRoomRuntime { .shared }
    private var current: KakaNativeRoom { details ?? room }
    private var roomLocked: Bool { voiceLockOverride ?? current.locked }
    private var waitingForEntry: Bool { entryPending && !roomLocked }
    private var openingConnection: Bool { waitingForEntry || connecting }
    private var displayingLiveVideo: Bool { connected && media.hasReceivedLiveFrame }
    private var cleanLiveView: Bool { prefersCleanLiveView && displayingLiveVideo && !isMinimized }
    private var watchingLiveVisit: UUID? {
        room.kind == .live && connected && scenePhase == .active ? visit : nil
    }

    private var reportingLiveVisit: UUID? {
        liveChatReady && media.hasRenderedLiveHostFrame ? watchingLiveVisit : nil
    }

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

    private var acceptsGiftEffects: Bool {
        guard scenePhase == .active, !isMinimized, !reduceMotion, connected, let visit else { return false }
        return runtime.owns(visit)
    }

    private var showsGiftEffects: Bool { acceptsGiftEffects && activeSheet == nil && !showingLiveExit }

    var body: some View {
        Group {
            if room.kind == .live {
                liveStage
            } else {
                voiceRoom
            }
        }
        .allowsHitTesting(!showingLiveExit)
        .accessibilityHidden(showingLiveExit)
        .modifier(KakaRoomGiftEffectOverlay(effects: giftEffects, accepting: acceptsGiftEffects, presenting: showsGiftEffects))
        .overlay(alignment: .topTrailing) {
            Group { roomGiftOverlay }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: roomGift?.id)
        }
        .overlay { if showingLiveExit { liveExitOptions } }
        .accessibilityAction(.escape) {
            if showingLiveExit { showingLiveExit = false }
            else { exitRoom() }
        }
        .task(id: roomGift?.id) {
            guard let id = roomGift?.id else { return }
            do { try await Task.sleep(nanoseconds: 3_600_000_000) } catch { return }
            if roomGift?.id == id { roomGift = nil }
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
                        stopConnection(preservingLiveVisit: true)
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
            case .voiceInvite:
                if let context = voiceManagementContext { KakaVoiceRoomInviteSheet(context: context) }
            case .voiceMusic:
                if let context = voiceManagementContext { KakaVoiceRoomMusicSheet(music: .init(context: context)) }
            case .voiceExpressions:
                if let context = voiceManagementContext, seat.index > 0 {
                    KakaVoiceExpressionsSheet(context: context, seat: seat.index)
                }
            case .people:
                if let visit { KakaRoomAudienceSheet(room: current, visit: visit) }
            case .hostProfile:
                if let host = current.host { roomHostProfile(host) }
            case .messageHost:
                if let host = current.host {
                    KakaRoomSheet(title: host.name, locked: false, scrolls: false) {
                        KakaNativeChatView(hostID: host.id, hostName: host.name, fillsConversation: true)
                    }
                }
            case .info:
                roomInfo
            case .share:
                KakaRoomSharing(text: "\(current.title) · Kaka \(current.kind == .live ? "live" : "voice") room \(current.serverID)")
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
        .onChange(of: media.voiceLayoutRevision) { _ in
            guard room.kind == .voice, connected, let visit, runtime.owns(visit) else { return }
            seat = SeatStatus()
            seatRefreshFailed = false
            Task { await updateSeat("voiceSeat.status") }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                if !roomLocked, connecting || connected { entryPending = true }
                stopConnection(preservingLiveVisit: true)
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
        .task(id: watchingLiveVisit) {
            if let visit = watchingLiveVisit { await watchLiveEnding(visit) }
        }
        .task(id: reportingLiveVisit) {
            if let visit = reportingLiveVisit { await reportLiveEntry(visit) }
        }
    }

    @ViewBuilder
    private var roomGiftOverlay: some View {
        if scenePhase == .active, !isMinimized, !cleanLiveView, !showingLiveExit, let gift = roomGift {
            HStack(spacing: 8) {
                if let artwork = gift.artwork {
                    AsyncImage(url: artwork) { phase in
                        if let image = phase.image { image.resizable().scaledToFit() }
                    }
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
                }
                Text(verbatim: gift.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KakaTheme.ink)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .modifier(KakaGlass(radius: 18))
            .padding(.horizontal, 16)
            .padding(.top, 74)
            .transition(.opacity)
            .allowsHitTesting(false)
            .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private var liveStage: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let compact = textSize >= .xxxLarge || geometry.size.width < 370
            let showsCallShortcut = height >= 390 && callPermitted && callUnlocked
            let reservedHeight: CGFloat = compact || !displayingLiveVideo ? 330 : 252
            let chatHeight = min(158, height * 0.24, max(0, height - reservedHeight))
            VStack(spacing: 8) {
                liveHeader(compact: compact)
                if let duel = media.duel { duelScore(duel) }
                liveSwitchRegion
                if !displayingLiveVideo {
                    liveConnectionStatus(compact: height < 330)
                    Spacer(minLength: 4)
                }
                if let visit, connected {
                    let announcement = height >= 430 ? liveAnnouncement : nil
                    if announcement != nil || showsCallShortcut {
                        HStack(alignment: .bottom, spacing: 8) {
                            if let announcement { liveAnnouncementCard(announcement) }
                            Spacer(minLength: 0)
                            if showsCallShortcut {
                                KakaStageIconButton(title: "Private video call", artwork: "room-watch.png",
                                                    accent: KakaTheme.liveAccent) { activeSheet = .privateCall }
                            }
                        }
                    }
                    KakaNativeChatView(room: current, visit: visit, liveOverlayHeight: chatHeight,
                                       onGifts: { openGiftCatalog() }, onGiftSelected: { openGiftCatalog($0) },
                                       onRoomOptions: { activeSheet = .options },
                                       onMessageHost: current.host == nil ? nil : { activeSheet = .messageHost },
                                       isMinimized: isMinimized || cleanLiveView,
                                       controlsSuspended: showingLiveExit,
                                       stacksRoomDock: geometry.size.width < 330, onMessageSent: recordLiveMessage)
                        .id(visit)
                } else {
                    roomOptionsButton.frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, geometry.size.width < 350 ? 12 : 16)
            .padding(.vertical, 8)
            .frame(maxWidth: 680, maxHeight: .infinity)
            .frame(maxWidth: .infinity)
            .opacity(isMinimized || cleanLiveView ? 0 : 1)
            .allowsHitTesting(!isMinimized && !cleanLiveView)
            .accessibilityHidden(isMinimized || cleanLiveView)
        }
        .foregroundStyle(KakaTheme.ink)
        .background { liveCanvas }
        .overlay(alignment: .topTrailing) {
            if cleanLiveView {
                KakaRoomButton(title: "Show controls") { prefersCleanLiveView = false }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
        }
        .overlay { if isMinimized { compactLiveControls } }
    }

    private var liveSwitchRegion: some View {
        Color.clear
            .frame(minHeight: 4, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 38).onEnded { gesture in
                let vertical = gesture.translation.height
                guard !isMinimized, activeSheet == nil, !showingLiveExit, abs(vertical) >= 60,
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

    private func liveAnnouncementCard(_ announcement: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return HStack(alignment: .top, spacing: 8) {
            KakaNativeImage(asset: "stage-message.png")
                .scaledToFit()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            Text(announcement)
                .font(.footnote)
                .lineLimit(textSize.isAccessibilitySize ? 3 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(9)
        .background(KakaTheme.surface, in: shape)
        .overlay { shape.strokeBorder(KakaTheme.liveAccent.opacity(0.28)).allowsHitTesting(false) }
        .frame(maxWidth: 305, alignment: .leading)
        .accessibilityLabel("Room announcement. \(announcement)")
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
                    .init(color: .black.opacity(0.52), location: 0),
                    .init(color: .clear, location: 0.23),
                    .init(color: .clear, location: 0.59),
                    .init(color: .black.opacity(0.74), location: 1),
                ], startPoint: .top, endPoint: .bottom)
                .opacity(cleanLiveView ? 0 : 1)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(RoundedRectangle(cornerRadius: isMinimized ? 15 : 0))
        }
        .ignoresSafeArea(isMinimized ? [] : .all)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func liveHeader(compact: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 2) {
                liveHostCard
                Spacer(minLength: 0)
                if !compact { liveHeaderTools }
                leaveButton(inRail: true)
            }
            if compact && (connected || followableHostID != nil) {
                HStack(spacing: 2) {
                    liveHeaderTools
                }
            }
        }
        .padding(4)
        .modifier(KakaStageChrome())
    }

    @ViewBuilder
    private var liveHostCard: some View {
        if let host = current.host {
            Button { activeSheet = .hostProfile } label: { liveIdentity(host: host) }
                .buttonStyle(KakaRoomCardPressStyle())
                .accessibilityHint("Opens the host profile")
        } else {
            liveIdentity(host: nil)
        }
    }

    @ViewBuilder
    private var liveHeaderTools: some View {
        if let host = current.host { roomFollowButton(host, inRail: true) }
        if connected {
            KakaStageIconButton(title: "Live audience", artwork: "stage-people.png", inRail: true) { activeSheet = .people }
            KakaStageIconButton(title: "Room ranking", artwork: "action-ranks.png", inRail: true) { activeSheet = .ranking }
        }
    }

    private var monitoringCallUnlock: UUID? {
        guard room.kind == .live, callPermitted, !callUnlocked, displayingLiveVideo,
              scenePhase == .active, !isMinimized, activeSheet == nil, !showingLiveExit else { return nil }
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
        if let deadline = duel.countdownEndsAtUptime, scenePhase == .active {
            TimelineView(.periodic(from: Date(timeIntervalSince1970: 0), by: 1)) { _ in
                let seconds = max(0, Int((deadline - ProcessInfo.processInfo.systemUptime).rounded(.up)))
                duelScoreStrip(duel, remainingSeconds: seconds > 0 ? seconds : nil)
            }
        } else {
            duelScoreStrip(duel, remainingSeconds: nil)
        }
    }

    @ViewBuilder
    private func duelScoreStrip(_ duel: KakaRealtimeMedia.LiveDuel, remainingSeconds: Int?) -> some View {
        let score = HStack(spacing: 0) {
            Text(duel.hostScore)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .foregroundStyle(KakaTheme.liveAccent)
            VStack(spacing: 2) {
                Text("PK")
                    .foregroundStyle(KakaTheme.ink)
                if let remainingSeconds {
                    Text(verbatim: String(format: "%d:%02d", remainingSeconds / 60, remainingSeconds % 60))
                        .foregroundStyle(KakaTheme.muted)
                }
            }
            Text(duel.opponentScore)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 12)
                .foregroundStyle(KakaTheme.voiceAccent)
        }
        .font(.caption.weight(.bold).monospacedDigit())
        .padding(.vertical, 7)
        .background(KakaTheme.base.opacity(0.8), in: Capsule())
        let description = "Duel score. Host \(duel.hostScore), opponent \(duel.opponentScore)"
        let remainingDescription = remainingSeconds.map { "Time remaining \($0 / 60) minutes \($0 % 60) seconds" } ?? ""
        if duel.ranking != nil, connected, let visit, runtime.owns(visit) {
            Button { activeSheet = .duelRanking } label: {
                score.frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(description)
            .accessibilityValue(remainingDescription)
            .accessibilityHint("Opens the PK rankings")
        } else {
            score.accessibilityLabel(description)
                .accessibilityValue(remainingDescription)
        }
    }

    private var roomOptionsButton: some View {
        KakaStageIconButton(title: "Room options", artwork: "stage-tools.png") { activeSheet = .options }
    }

    private var leaveRoomButton: some View {
        leaveButton(inRail: false)
    }

    private func leaveButton(inRail: Bool) -> some View {
        KakaStageIconButton(title: room.kind == .live ? "Leave live room" : "Leave voice room",
                            artwork: "action-close.png", inRail: inRail) {
            if room.kind == .live, connected, onMinimize != nil {
                showingLiveExit = true
            } else {
                exitRoom()
            }
        }
    }

    private func roomCloseButton(label: String, action: @escaping () -> Void) -> some View {
        KakaStageIconButton(title: label, artwork: "action-close.png", action: action)
    }

    private var peopleButton: some View {
        KakaStageIconButton(title: room.kind == .live ? "Live audience" : "Online chat participants",
                            artwork: "stage-people.png") { activeSheet = .people }
    }

    private var liveExitOptions: some View {
        ZStack {
            Color.black.opacity(0.61).ignoresSafeArea().accessibilityHidden(true)
            GeometryReader { geometry in
                ScrollView {
                    liveExitCard
                        .frame(maxWidth: 360)
                        .padding(16)
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
            }
        }
        .onAppear {
            store.setSheet(liveExitID, presented: true)
            liveExitHeadingFocused = true
        }
        .onDisappear {
            liveExitHeadingFocused = false
            store.setSheet(liveExitID, presented: false)
        }
    }

    private var liveExitCard: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Text("Leave live room?")
                    .font(.title3.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 176, alignment: .leading)
                    .padding(.top, 13)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($liveExitHeadingFocused)
                Spacer(minLength: 0)
                roomCloseButton(label: "Keep watching") { showingLiveExit = false }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .frame(minHeight: 111, alignment: .topLeading)
            .background {
                GeometryReader { geometry in
                    KakaNativeImage(asset: "stage-exit-cover.jpg")
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .trailing)
                        .clipped()
                        .overlay {
                            LinearGradient(colors: [KakaTheme.base, KakaTheme.base.opacity(0.68), .clear],
                                           startPoint: .leading, endPoint: .trailing)
                        }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            KakaRoomActionGroup {
                liveExitChoice("Exit room", artwork: "action-close.png", emphasized: false, action: exitRoom)
                if connected, let onMinimize {
                    liveExitChoice("Minimize player", artwork: "stage-minimize.png", emphasized: true) {
                        showingLiveExit = false
                        onMinimize()
                    }
                }
            }
            .padding(12)
        }
        .foregroundStyle(KakaTheme.ink)
        .background(KakaTheme.base, in: shape)
        .clipShape(shape)
        .overlay { shape.strokeBorder(KakaTheme.accent.opacity(0.28)).allowsHitTesting(false) }
        .accessibilityElement(children: .contain)
    }

    private func liveExitChoice(_ title: String, artwork: String, emphasized: Bool,
                                action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Button(action: action) {
            HStack(spacing: 7) {
                KakaNativeImage(asset: artwork)
                    .scaledToFit()
                    .frame(width: 25, height: 25)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.leading)
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(emphasized ? KakaTheme.actionFill : KakaTheme.surface, in: shape)
            .overlay { shape.strokeBorder(KakaTheme.accent.opacity(emphasized ? 0.32 : 0.14)).allowsHitTesting(false) }
            .contentShape(shape)
        }
        .buttonStyle(KakaRoomCardPressStyle())
    }

    private func exitRoom() {
        showingLiveExit = false
        activeSheet = nil
        if let onClose { onClose() }
        else { store.back() }
    }

    @ViewBuilder
    private func roomFollowButton(_ host: KakaNativeHost, inRail: Bool = false) -> some View {
        if followableHostID == host.id {
            let followed = store.followedIDs.contains(host.id)
            KakaStageIconButton(title: followed ? "Following" : "Follow host",
                                artwork: followed ? "action-check.png" : "stage-follow.png",
                                accent: followed ? nil : KakaTheme.actionFill, inRail: inRail) {
                Task { await toggleRoomFollow(host) }
            }
            .disabled(changingFollow)
            .opacity(changingFollow ? 0.56 : 1)
            .accessibilityAddTraits(followed ? .isSelected : [])
            .accessibilityHint(followed ? "Unfollows this host" : "Follows this host")
        }
    }

    private func roomHostProfile(_ host: KakaNativeHost) -> some View {
        KakaRoomSheet(title: "Host profile", locked: false) {
            roomHostCover(host)
            if !host.bio.isEmpty {
                Text(host.bio)
                    .font(.subheadline)
                    .foregroundStyle(KakaTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 3)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: textSize.isAccessibilitySize ? 220 : 134), spacing: 8)], spacing: 8) {
                roomQuickAction("Message", artwork: "stage-message.png") { activeSheet = .messageHost }
                if room.kind == .live {
                    roomQuickAction("Gift wall", artwork: "stage-gift.png") { activeSheet = .giftWall }
                }
                roomQuickAction("Full profile", artwork: "profile-card-account.png") {
                    activeSheet = nil
                    store.open(.host(host))
                }
            }
        }
        .modifier(KakaRoomUtilityPresentation())
    }

    private func roomHostCover(_ host: KakaNativeHost) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return HStack(alignment: .center, spacing: 12) {
            if !textSize.isAccessibilitySize {
                KakaRoomArt(asset: "member-mark.jpg", remote: host.portrait, ratio: 1, cropAlignment: .top)
                    .frame(width: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 13))
            }
            Text(host.name)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            roomFollowButton(host)
        }
        .padding(12)
        .frame(minHeight: 102)
        .background {
            GeometryReader { geometry in
                KakaNativeImage(asset: "room-chat-cover.jpg")
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .trailing)
                    .clipped()
                    .overlay(KakaTheme.base.opacity(0.48))
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(KakaTheme.line).allowsHitTesting(false) }
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
                    .frame(width: 38)
                    .clipShape(Circle())
                    .overlay { Circle().strokeBorder(KakaTheme.liveAccent.opacity(0.52)).allowsHitTesting(false) }
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(current.title)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(textSize.isAccessibilitySize ? 2 : 1)
                if displayingLiveVideo {
                    HStack(spacing: 5) {
                        KakaNativeImage(asset: "stage-signal.png")
                            .scaledToFit()
                            .frame(width: 14, height: 14)
                            .accessibilityHidden(true)
                        Text("Live")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(KakaTheme.liveAccent)
                        if let viewers = current.viewers, viewers > 0 {
                            Text("\(viewers.formatted()) watching")
                                .font(.caption2.weight(.medium).monospacedDigit())
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
            roomUtilityCover("room-tools-cover.jpg")
            roomQuickActions
            if room.kind == .live {
                if connected || connecting || hasAdjacentLiveRoom {
                    roomUtilitySection("Playback") {
                        if connected { liveQualityOptions }
                        if displayingLiveVideo {
                            roomUtilityRow("Hide controls", artwork: "stage-tools.png") {
                                prefersCleanLiveView = true
                                activeSheet = nil
                            }
                        }
                        adjacentRoomButton(forward: false)
                        adjacentRoomButton(forward: true)
                        if connected || connecting { stopRoomUtilityRow }
                    }
                }
            } else if voiceManagementContext != nil || connected || connecting {
                roomUtilitySection("Room audio") {
                    if let context = voiceManagementContext {
                        roomUtilityRow("Room music", artwork: "room-listen.png") { activeSheet = .voiceMusic }
                        if context.state(in: store)?.hasRoomIdentity == true {
                            roomUtilityRow("Invite people", artwork: "stage-people.png") { activeSheet = .voiceInvite }
                        }
                        KakaVoiceManagementOption(context: context) { activeSheet = .voiceManagement }
                            .padding(.horizontal, 8)
                    }
                    if connected || connecting { stopRoomUtilityRow }
                }
            }
            roomUtilitySection("Your library") { personalActions }
            if room.kind == .live {
                roomUtilitySection("Room safety") {
                    safetyActions
                }
            }
        }
        .modifier(KakaRoomUtilityPresentation())
    }

    private var hasAdjacentLiveRoom: Bool {
        store.adjacentLiveRoom(to: room, forward: false) != nil || store.adjacentLiveRoom(to: room, forward: true) != nil
    }

    private var stopRoomUtilityRow: some View {
        roomUtilityRow(connectionTitle, artwork: "action-stop.png") {
            activeSheet = nil
            stopConnection()
        }
    }

    private var roomQuickActions: some View {
        let width: CGFloat = textSize >= .xxxLarge ? 244 : 132
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: width), spacing: 8)], spacing: 8) {
            roomQuickAction("Room info", artwork: "room-tool-info.png") { activeSheet = .info }
            roomQuickAction("Share room", artwork: "room-tool-share.png") { activeSheet = .share }
            if room.kind == .voice, current.host != nil {
                roomQuickAction("Message the host", artwork: "stage-message.png") { activeSheet = .messageHost }
            }
            if room.kind == .live, connected {
                roomQuickAction("Gift wishlist", artwork: "stage-gift.png") { activeSheet = .wishlist }
                if callPermitted && callUnlocked {
                    roomQuickAction("Private video call", artwork: "room-watch.png") { activeSheet = .privateCall }
                }
            }
        }
    }

    private func roomUtilityCover(_ artwork: String, remote: URL? = nil) -> some View {
        let accent = room.kind == .live ? KakaTheme.liveAccent : KakaTheme.voiceAccent
        let shape = RoundedRectangle(cornerRadius: 19, style: .continuous)
        return VStack(alignment: .leading, spacing: 4) {
            Text(current.title)
                .font(.title3.weight(.semibold))
                .lineLimit(textSize.isAccessibilitySize ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
            Text(current.format)
                .font(.footnote.weight(.medium))
                .foregroundStyle(accent)
        }
        .frame(maxWidth: 230, alignment: .leading)
        .frame(maxWidth: .infinity, minHeight: 91, alignment: .leading)
        .padding(.horizontal, 15)
        .padding(.vertical, 8)
        .background {
            GeometryReader { geometry in
                KakaNativeImage(asset: artwork, remote: remote)
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .trailing)
                    .clipped()
                    .overlay {
                        LinearGradient(stops: [
                            .init(color: KakaTheme.base.opacity(0.98), location: 0),
                            .init(color: KakaTheme.base.opacity(0.83), location: 0.58),
                            .init(color: KakaTheme.base.opacity(remote == nil ? 0.07 : 0.68), location: 1)
                        ], startPoint: .leading, endPoint: .trailing)
                    }
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
        .background(KakaTheme.surface)
        .clipShape(shape)
        .overlay { shape.strokeBorder(KakaTheme.line).allowsHitTesting(false) }
        .accessibilityElement(children: .combine)
    }

    private func roomQuickAction(_ title: String, artwork: String, action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Button(action: action) {
            HStack(spacing: 8) {
                KakaNativeImage(asset: artwork)
                    .scaledToFit()
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .frame(minHeight: 64)
            .background(KakaTheme.surface, in: shape)
            .overlay { shape.strokeBorder(KakaTheme.line).allowsHitTesting(false) }
            .contentShape(shape)
        }
        .buttonStyle(KakaRoomCardPressStyle())
    }

    private func roomUtilitySection<Items: View>(_ title: String, @ViewBuilder items: () -> Items) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 2, content: items)
                .padding(4)
                .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func roomUtilityRow(_ title: String, artwork: String? = nil, selected: Bool = false,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let artwork {
                    KakaNativeImage(asset: artwork)
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                KakaNativeImage(asset: selected ? "action-check.png" : "action-forward.png")
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(KakaRoomCardPressStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var liveQualityOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Video quality")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            KakaRoomActionGroup {
                ForEach(KakaRealtimeMedia.LiveQuality.allCases) { quality in
                    let selected = media.liveQuality == quality
                    Button {
                        guard let visit, runtime.owns(visit), let session = store.session?.token else { return }
                        media.setLiveQuality(quality, roomID: room.serverID, session: session)
                    } label: {
                        Text(quality.title)
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(selected ? KakaTheme.liveAccent : KakaTheme.ink)
                            .background(selected ? KakaTheme.liveAccent.opacity(0.13) : KakaTheme.base,
                                        in: RoundedRectangle(cornerRadius: 11))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(KakaRoomCardPressStyle())
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            Text("Data Saver uses a lower-quality stream when the broadcaster provides one.")
                .font(.caption)
                .foregroundStyle(KakaTheme.muted)
        }
        .padding(8)
    }

    @ViewBuilder
    private func adjacentRoomButton(forward: Bool) -> some View {
        if store.adjacentLiveRoom(to: room, forward: forward) != nil {
            roomUtilityRow(forward ? "Next live" : "Previous live", artwork: "room-watch.png") {
                activeSheet = nil
                store.switchLiveRoom(from: room, forward: forward)
            }
        }
    }

    private var roomInfo: some View {
        KakaRoomSheet(title: "Room info", locked: false) {
            roomUtilityCover("room-tools-cover.jpg", remote: current.cover)
            Text("Room \(current.serverID)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(KakaTheme.muted)
                .textSelection(.enabled)
            roomDescription
            roomQuickAction("Share room", artwork: "room-tool-share.png") { activeSheet = .share }
        }
        .modifier(KakaRoomUtilityPresentation())
    }

    private var voiceRoom: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let gutter: CGFloat = geometry.size.width < 350 ? 12 : 16
            let contentWidth = max(1, min(680, geometry.size.width) - gutter * 2)
            let roomForChat = min(150, height * 0.23, max(0, height - (textSize.isAccessibilitySize ? 385 : 300)))
            VStack(spacing: 0) {
                voiceHeader
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if connected {
                            voiceStage(width: contentWidth)
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
                    .padding(.vertical, 10)
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
                    .padding(.top, 8)
                    .background(alignment: .bottom) {
                        LinearGradient(colors: [.clear, KakaTheme.base.opacity(0.82)],
                                       startPoint: .top, endPoint: .bottom)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(.horizontal, gutter)
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
            KakaNativeImage(asset: "stage-voice-lounge.jpg", remote: background)
                .scaledToFill()
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                .clipped()
                .overlay {
                    LinearGradient(stops: [
                        .init(color: KakaTheme.base.opacity(0.30), location: 0),
                        .init(color: KakaTheme.base.opacity(0.37), location: 0.34),
                        .init(color: KakaTheme.base.opacity(0.79), location: 0.76),
                        .init(color: KakaTheme.base.opacity(0.97), location: 1)
                    ], startPoint: .top, endPoint: .bottom)
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
            HStack(spacing: 9) {
                if !textSize.isAccessibilitySize {
                    KakaNativeImage(asset: room.kind.art, remote: current.cover)
                        .scaledToFill()
                        .frame(width: 42, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(current.title)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(textSize.isAccessibilitySize ? 3 : 2)
                        .accessibilityAddTraits(.isHeader)
                    Text(voiceStatus)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(connected ? KakaTheme.voiceAccent : KakaTheme.muted)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .padding(.vertical, 5)
            .padding(.leading, 5)
            .padding(.trailing, 12)
            .background(KakaTheme.base.opacity(0.83), in: RoundedRectangle(cornerRadius: 17))
            .layoutPriority(1)

            Spacer(minLength: 0)
            roomOptionsButton
            leaveRoomButton
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

    private func voiceStage(width: CGFloat) -> some View {
        let occupied = seat.stage?.filter { $0.occupant != nil } ?? []
        let unoccupied = seat.stage?.filter { $0.occupant == nil } ?? []
        let inset: CGFloat = width < 300 ? 8 : 11
        let stageShape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                voiceStageToolbar
                if occupied.isEmpty, let host = current.host {
                    voiceHostCard(host, prominent: true)
                }
                if !occupied.isEmpty {
                    voiceSpeakers(occupied, width: max(1, width - inset * 2))
                }
                if !unoccupied.isEmpty {
                    let minimum: CGFloat = textSize.isAccessibilitySize ? 112 : 59
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: 7, alignment: .top)], spacing: 7) {
                        ForEach(unoccupied) { voiceSeatTile($0) }
                    }
                }
                if seatRefreshFailed || seat.stage == nil {
                    Text(seatRefreshFailed ? "Couldn’t refresh seats. Retrying…" : "Loading seats…")
                        .font(.footnote)
                        .foregroundStyle(KakaTheme.muted)
                } else if occupied.isEmpty && unoccupied.isEmpty {
                    Text("No mic seats available.")
                        .font(.footnote)
                        .foregroundStyle(KakaTheme.muted)
                }
                if !occupied.isEmpty, let host = current.host {
                    Divider().overlay(KakaTheme.line).accessibilityHidden(true)
                    voiceHostCard(host, prominent: false)
                }
            }
            .padding(inset)
            .background(KakaTheme.base.opacity(0.78), in: stageShape)
            .overlay {
                stageShape.strokeBorder(KakaTheme.accent.opacity(0.30))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            if !media.voiceAnnouncement.isEmpty {
                voiceAnnouncementCard
            }
        }
    }

    private var voiceStageToolbar: some View {
        KakaRoomActionGroup {
            Text("Mic seats")
                .font(.title3.weight(.semibold))
                .tracking(-0.4)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                KakaStageIconButton(title: media.voiceAudioEnabled ? "Mute room audio" : "Unmute room audio",
                                    artwork: "room-listen.png",
                                    accent: media.voiceAudioEnabled ? KakaTheme.voiceAccent : nil) { toggleVoiceAudio() }
                    .accessibilityValue(media.voiceAudioEnabled ? "Audio on" : "Audio muted")
                KakaStageIconButton(title: "Room ranking", artwork: "action-ranks.png") { activeSheet = .ranking }
                peopleButton
            }
        }
    }

    private func voiceHostCard(_ host: KakaNativeHost, prominent: Bool) -> some View {
        Button { activeSheet = .hostProfile } label: {
            HStack(spacing: 8) {
                KakaRoomArt(asset: "member-mark.jpg", remote: host.portrait, ratio: 1)
                    .frame(width: prominent ? 60 : 33)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                    if host.name != "Host" {
                        Text("Room host").font(.caption2).foregroundStyle(KakaTheme.muted)
                    }
                }
                Spacer(minLength: 4)
                if let tempo {
                    Text("\(tempo) BPM")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(KakaTheme.accent)
                }
                KakaNativeImage(asset: "action-forward.png")
                    .scaledToFit()
                    .frame(width: 13, height: 13)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, prominent ? 12 : 9)
            .padding(.vertical, prominent ? 10 : 5)
            .frame(minHeight: 44)
            .background(KakaTheme.voiceAccent.opacity(prominent ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the host profile")
    }

    private var voiceAnnouncementCard: some View {
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        return Button { voiceAnnouncementExpanded.toggle() } label: {
            HStack(alignment: .top, spacing: 9) {
                KakaNativeImage(asset: "stage-message.png")
                    .scaledToFit()
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Room announcement")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(KakaTheme.voiceAccent)
                    Text(media.voiceAnnouncement)
                        .font(.subheadline)
                        .foregroundStyle(KakaTheme.ink)
                        .lineLimit(voiceAnnouncementExpanded ? nil : 2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                KakaNativeImage(asset: "action-forward.png")
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                    .rotationEffect(.degrees(voiceAnnouncementExpanded ? 90 : 0))
                    .padding(.top, 6)
                    .accessibilityHidden(true)
            }
            .padding(11)
            .frame(minHeight: 44, alignment: .leading)
            .background(KakaTheme.surface.opacity(0.95), in: shape)
            .overlay { shape.strokeBorder(KakaTheme.voiceAccent.opacity(0.25)).allowsHitTesting(false) }
            .contentShape(shape)
        }
        .buttonStyle(KakaRoomCardPressStyle())
        .accessibilityValue(voiceAnnouncementExpanded ? "Expanded" : "Collapsed")
    }

    private func voiceSpeakers(_ positions: [KakaRealtimeMedia.VoiceStageSeat], width: CGFloat) -> some View {
        let maximumColumns = textSize.isAccessibilitySize || width < 276 ? 2 : width >= 510 ? 4 : 3
        let columnCount = max(1, min(positions.count, maximumColumns))
        let tileWidth = min(230, max(1, (width - CGFloat(columnCount - 1) * 7) / CGFloat(columnCount)))
        let columns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: 7, alignment: .top), count: columnCount)
        return LazyVGrid(columns: columns, spacing: 7) {
            ForEach(positions) { position in
                voiceSpeaker(position, width: tileWidth)
            }
        }
    }

    private func voiceSpeaker(_ position: KakaRealtimeMedia.VoiceStageSeat, width: CGFloat) -> some View {
        let mine = position.index == seat.index
        let host = current.host.flatMap { $0.id == position.occupant ? $0 : nil }
        let memberName = position.name.isEmpty ? host?.name ?? "" : position.name
        let name = mine ? "You" : (memberName.isEmpty ? "Seat \(position.index)" : memberName)
        let microphone = mine ? seat.microphone : position.microphoneEnabled
        let status = microphone.map { $0 ? "Mic on" : "Muted" }
        let height = min(172, max(68, width * 1.03))
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let artwork = ZStack {
            if let portrait = position.portrait ?? host?.portrait {
                KakaNativeImage(asset: "member-mark.jpg", remote: portrait)
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .accessibilityHidden(true)
            } else {
                Text(memberName.isEmpty ? position.index.formatted() : String(memberName.prefix(1)))
                    .font(.title.weight(.semibold))
                    .foregroundStyle(KakaTheme.voiceAccent)
                    .accessibilityHidden(true)
            }
            if let expression = seatExpressions[position.index], expression.user == position.occupant {
                KakaVoiceExpressionArtwork(expression: expression.item)
                    .id(expression.id)
                    .frame(width: 56, height: 56)
                    .allowsHitTesting(false)
                    .accessibilityLabel(expression.item.name.isEmpty ? "Seat expression" : expression.item.name)
            }
        }
        .frame(width: width, height: height)
        .background(KakaTheme.voiceAccent.opacity(0.12))
        .clipped()
        let caption = VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.caption.weight(.bold))
                .lineLimit(textSize.isAccessibilitySize ? 3 : 1)
            if let status {
                Text(status)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(microphone == true ? KakaTheme.voiceAccent : KakaTheme.muted)
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        let rim = mine ? KakaTheme.accent.opacity(0.82)
            : KakaTheme.voiceAccent.opacity(microphone == true ? 0.57 : 0.17)
        return Group {
            if textSize.isAccessibilitySize {
                VStack(spacing: 0) {
                    artwork
                    caption
                }
            } else {
                artwork.overlay(alignment: .bottomLeading) {
                    caption.background {
                        LinearGradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: KakaTheme.base.opacity(0.84), location: 0.40),
                            .init(color: KakaTheme.base.opacity(0.97), location: 1)
                        ], startPoint: .top, endPoint: .bottom)
                            .padding(.top, -22)
                    }
                }
            }
        }
        .frame(width: width)
        .background(KakaTheme.surface)
        .clipShape(shape)
        .overlay { shape.strokeBorder(rim, lineWidth: mine ? 1.5 : 1).allowsHitTesting(false) }
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
            .buttonStyle(KakaRoomCardPressStyle())
            .disabled(seat.queued || updatingSeat || seatRefreshFailed)
            .accessibilityLabel(seat.index > 0 ? "Move to seat \(position.index)" : "Request seat \(position.index)")
        }
    }

    private func voiceSeatBadge(_ position: KakaRealtimeMedia.VoiceStageSeat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        return VStack(spacing: 4) {
            KakaNativeImage(asset: "action-seat.png")
                .scaledToFit()
                .frame(width: 27, height: 27)
                .opacity(position.locked ? 0.46 : 1)
                .accessibilityHidden(true)
            Text(position.locked ? "\(position.index) · Locked" : "Seat \(position.index)")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(position.locked ? KakaTheme.muted : KakaTheme.ink)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 60)
        .background(KakaTheme.voiceAccent.opacity(position.locked ? 0.04 : 0.11), in: shape)
        .overlay { shape.strokeBorder(KakaTheme.voiceAccent.opacity(position.locked ? 0.10 : 0.26))
                .allowsHitTesting(false) }
        .accessibilityElement(children: .combine)
    }

    private var voiceConnectionControls: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return VStack(alignment: .leading, spacing: 10) {
            if roomLocked, !connected {
                Label {
                    Text("Password required")
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    KakaNativeImage(asset: "room-listen.png")
                        .scaledToFit()
                        .frame(width: 30, height: 30)
                        .accessibilityHidden(true)
                }
                SecureField("Room password", text: $enteredPassword)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 46)
                    .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(KakaTheme.voiceAccent.opacity(0.23))
                            .allowsHitTesting(false)
                    }
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
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { viewport in
                KakaNativeImage(asset: "room-control-cover.jpg")
                    .scaledToFill()
                    .frame(width: viewport.size.width, height: viewport.size.height, alignment: .trailing)
                    .clipped()
                    .overlay {
                        LinearGradient(colors: [KakaTheme.base, KakaTheme.base.opacity(0.79), KakaTheme.base.opacity(0.34)],
                                       startPoint: .leading, endPoint: .trailing)
                    }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(KakaTheme.line).allowsHitTesting(false) }
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
            KakaStageIconButton(title: seat.microphone ? "Mute microphone" : "Turn microphone on",
                                artwork: "Dock-stage", accent: seat.microphone ? KakaTheme.voiceAccent : nil) {
                Task { await updateSeat("voiceSeat.microphone") }
            }
            .accessibilityValue(seat.microphone ? "Microphone on" : "Microphone muted")
            .disabled(updatingSeat)
            KakaStageIconButton(title: "Expressions", artwork: "Dock-voice") { activeSheet = .voiceExpressions }
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
        roomUtilityRow("Write a verse", artwork: "room-write.png") { store.openVerse(current) }
        if room.kind == .live {
            roomUtilityRow("Voice rooms", artwork: "room-listen.png") { store.select(.voice) }
            roomUtilityRow(isFavorite ? "Saved room" : "Save room", artwork: "action-bookmark.png", selected: isFavorite) {
                Task { await toggleFavorite() }
            }
            .disabled(changingSavedRooms)
            roomUtilityRow("Rehearsal note", artwork: "room-tool-info.png") { activeSheet = .notes }
        }
    }

    @ViewBuilder
    private var safetyActions: some View {
        roomUtilityRow("Hide room") { activeSheet = .hide }
        if current.host != nil {
            roomUtilityRow("Report room") { activeSheet = .report }
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
            if liveViewingVisit == nil { liveViewingVisit = newVisit }
            activeLiveSeconds = 0
            sentLiveMessages = 0
            callUnlocked = false
            callPermitted = false
            liveMessagingRoom = ""
            liveChatReady = false
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
                try await runtime.join(newVisit, room: current, password: password, session: session,
                                       onLiveChatConnection: { ready in
                    guard visit == newVisit, store.session?.token == session else { return }
                    liveChatReady = ready
                }) { notice in
                    guard visit == newVisit, store.session?.token == session else { return }
                    switch notice {
                    case .voiceClosed(let reason):
                        stopConnection()
                        activeSheet = nil
                        store.back()
                        store.notify(reason)
                    case .voiceRelocked(let time):
                        checkVoiceRelock(time: time, visit: newVisit, session: session)
                    case .voiceSeatsChanged:
                        let now = ProcessInfo.processInfo.systemUptime
                        guard !updatingSeat, now - lastSeatNoticeRefresh >= 1 else { return }
                        lastSeatNoticeRefresh = now
                        Task { @MainActor in
                            guard visit == newVisit, store.session?.token == session else { return }
                            await updateSeat("voiceSeat.status")
                        }
                    case .voiceSeatApprovalChanged(let enabled):
                        media.updateVoiceManagementState(roomID: current.serverID, session: session, seatApproval: enabled)
                    case .voiceBackdropChanged:
                        media.refreshVoiceBackdrop(roomID: current.serverID, session: session)
                    case .gift(let label, let artwork, let effect, let time):
                        guard roomGift?.time != time || roomGift?.label != label else { return }
                        roomGift = RoomGiftBanner(label: label, artwork: artwork, time: time)
                        if let effect { giftEffects.enqueue(effect, time: time) }
                    case .expression(let choice, let user, let index):
                        let expression = SeatExpression(user: user, item: choice)
                        seatExpressions[index] = expression
                        Task { @MainActor in
                            do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
                            guard visit == newVisit, seatExpressions[index]?.id == expression.id else { return }
                            seatExpressions.removeValue(forKey: index)
                        }
                    }
                }
                try Task.checkCancellation()
                guard visit == newVisit, store.session?.token == session, scenePhase != .background else {
                    runtime.leave(newVisit)
                    throw CancellationError()
                }
                connected = true
                connecting = false
                if room.kind == .voice {
                    if current.awaitingVoiceDetails,
                       let admitted = media.voiceRoomDetails(roomID: current.serverID, session: session) {
                        details = admitted
                        store.remember([admitted])
                    }
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
                guard !(error is CancellationError), !Task.isCancelled else { return }
                if room.kind == .live, (error as? KakaAccountStore.Failure) == .liveRoomEnded {
                    finishEndedLive()
                } else if room.kind == .voice, (error as? KakaAccountStore.Failure) == .roomPasswordRequired {
                    voiceLockOverride = true
                    connectionError = password == nil ? "Enter the room password." : "Incorrect password. Try again."
                } else {
                    connectionError = store.message(error)
                }
            }
        }
    }

    private func checkVoiceRelock(time: TimeInterval, visit: UUID, session: UUID) {
        guard voiceRelockCheck == nil, time > lastVoiceRelockAt,
              let context = voiceManagementContext, context.visit == visit, context.session == session else { return }
        voiceRelockCheck = Task { @MainActor in
            defer { if self.visit == visit { voiceRelockCheck = nil } }
            do {
                let user = try await KakaAccountStore.shared.remoteUserID(session: session)
                let role = try await context.roomRole(for: user, in: store)
                guard !Task.isCancelled, voiceManagementContext == context, context.state(in: store) != nil,
                      role.value == 3, !role.canManage else { return }
                lastVoiceRelockAt = time
                voiceLockOverride = true
                entryPending = false
                enteredPassword = ""
                stopConnection()
                activeSheet = nil
                connectionError = "The room password changed. Enter the new password to rejoin."
            } catch {
                if !Task.isCancelled, voiceManagementContext == context { store.expireIfNeeded(error) }
            }
        }
    }

    private func refreshLive(visit expected: UUID, session: UUID) async throws {
        let source = try await store.request("getLiveRoom", ["habitatTag": room.serverID])
        guard visit == expected, store.session?.token == session, !Task.isCancelled else { throw CancellationError() }
        if source is NSNull { throw KakaAccountStore.Failure.liveRoomEnded }
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
        liveMessagingRoom = KakaRoomFields.text(values, "chamberGlyph")
        if liveMessagingRoom.isEmpty { liveMessagingRoom = KakaRoomFields.text(fields, "chamberGlyph") }
        callPermitted = KakaRoomFields.flag(fields["cipherAccess"] ?? values["cipherAccess"])
        store.remember([fresh])
    }

    private func watchLiveEnding(_ expected: UUID) async {
        guard let session = store.session?.token, let details, let host = details.host else { return }
        let channel = details.channel
        while ownsLiveObservation(expected, room: details, hostID: host.id, session: session) {
            do {
                let fields = try await store.request("live.condition", ["venueKey": channel]) as? [String: Any]
                guard ownsLiveObservation(expected, room: details, hostID: host.id, session: session) else { return }
                let reportedChannel = fields?["venueKey"]
                if reportedChannel == nil || reportedChannel as? String == channel,
                   let flag = fields?["onstage"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(), !flag.boolValue {
                    finishEndedLive()
                    return
                }
            } catch {
                guard ownsLiveObservation(expected, room: details, hostID: host.id, session: session) else { return }
                if (error as? KakaAccountStore.Failure) == .liveRoomEnded {
                    finishEndedLive()
                    return
                }
            }
            do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
        }
    }

    private func reportLiveEntry(_ expected: UUID) async {
        guard let logicalVisit = liveViewingVisit, reportedLiveViewingVisit != logicalVisit,
              let session = store.session?.token, let details, let host = details.host,
              ownsLiveObservation(expected, room: details, hostID: host.id, session: session), media.hasRenderedLiveHostFrame,
              runtime.chat.isConnectedToLiveRoom(visit: expected, roomID: details.serverID,
                                                 channel: liveMessagingRoom, session: session) else { return }
        reportedLiveViewingVisit = logicalVisit
        _ = try? await store.request("live.entryEffect", ["hostIdentity": host.id])
    }

    private func ownsLiveObservation(_ expected: UUID, room: KakaNativeRoom, hostID: Int64, session: UUID) -> Bool {
        !Task.isCancelled && watchingLiveVisit == expected && store.session?.token == session && runtime.owns(expected)
            && !room.channel.isEmpty
            && media.isLiveAudience(roomID: room.serverID, session: session, hostID: hostID, channel: room.channel)
    }

    private func finishEndedLive() {
        let ended = current
        stopConnection()
        activeSheet = nil
        store.markLiveEnded(ended)
        store.notify("This live has ended.")
        if !isMinimized, store.adjacentLiveRoom(to: room, forward: true) != nil {
            store.switchLiveRoom(from: room, forward: true)
        } else if let onClose {
            onClose()
        } else if case .room(let displayed) = store.route, displayed.id == room.id {
            store.back()
        }
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

    private func stopConnection(preservingLiveVisit: Bool = false) {
        connectionTask?.cancel()
        connectionTask = nil
        voiceRelockCheck?.cancel()
        voiceRelockCheck = nil
        seatPoll?.cancel()
        seatPoll = nil
        if let visit { runtime.leave(visit) }
        visit = nil
        liveChatReady = false
        if !preservingLiveVisit {
            liveViewingVisit = nil
            reportedLiveViewingVisit = nil
        }
        roomGift = nil
        giftEffects.clear()
        seatExpressions = [:]
        connecting = false
        connected = false
        updatingSeat = false
        seat = SeatStatus()
        lastSeatNoticeRefresh = -Double.infinity
        seatRefreshFailed = false
        showingLiveExit = false
        if let sheet = activeSheet, [.gifts, .voiceGifts, .ranking, .duelRanking, .wishlist, .people, .voiceManagement, .voiceInvite, .voiceMusic, .voiceExpressions].contains(sheet) {
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
            let nextIndex = KakaRemoteClient.userID(result["index"]) ?? 0
            if nextIndex != seat.index, activeSheet == .voiceExpressions { activeSheet = nil }
            seat = SeatStatus(index: nextIndex,
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

struct KakaPrivateCallCover<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        content()
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 154, alignment: .bottomLeading)
            .background {
                GeometryReader { geometry in
                    KakaNativeImage(asset: "room-call-cover.jpg")
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .trailing)
                        .clipped()
                }
                .overlay {
                    LinearGradient(colors: [KakaTheme.base.opacity(0.96), KakaTheme.base.opacity(0.80), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                }
                .background(KakaTheme.surface)
                .accessibilityHidden(true)
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(KakaTheme.line).allowsHitTesting(false) }
    }
}

private struct KakaCallIdentity: View {
    let name: String
    let portrait: URL?
    var caption: String? = nil

    var body: some View {
        KakaPrivateCallCover {
            VStack(alignment: .leading, spacing: 8) {
                if let portrait {
                    KakaRoomArt(asset: "member-mark.jpg", remote: portrait, ratio: 1)
                        .frame(width: 50)
                        .clipShape(Circle())
                        .overlay { Circle().strokeBorder(.white.opacity(0.24)) }
                } else {
                    KakaNativeImage(asset: "room-watch.png")
                        .scaledToFit()
                        .frame(width: 34, height: 34)
                        .accessibilityHidden(true)
                }
                Text(name)
                    .font(.title2.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                    .fixedSize(horizontal: false, vertical: true)
                if let caption {
                    Text(caption)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(KakaTheme.muted)
                }
            }
        }
    }
}

struct KakaCallAction: View {
    let title: String
    let artwork: String
    var prominence: Color? = nil
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                KakaNativeImage(asset: artwork)
                    .scaledToFit()
                    .frame(width: 25, height: 25)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .frame(minHeight: 48)
            .frame(maxWidth: .infinity)
            .modifier(KakaGlass(interactive: true, radius: 15, tint: prominence?.opacity(0.75)))
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .opacity(isEnabled ? 1 : 0.52)
        }
        .buttonStyle(KakaRoomCardPressStyle())
    }
}

private struct KakaCallRate: View {
    let quote: KakaLivePrivateCall.Quote
    var incoming = false

    var body: some View {
        let entryCost = NSDecimalNumber(decimal: quote.entryCost).stringValue
        let minuteCost = NSDecimalNumber(decimal: quote.minuteCost).stringValue
        VStack(alignment: .leading, spacing: 10) {
            Text("Call rates")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(KakaTheme.accent)
                .accessibilityAddTraits(.isHeader)
            if incoming {
                Text("\(minuteCost) diamonds per minute")
                    .font(.headline)
            } else {
                Text(quote.entryMinutes > 0
                     ? "First \(quote.entryMinutes) min · \(entryCost) diamonds"
                     : "Connection costs \(entryCost) diamonds")
                    .font(.headline)
                Text("Then \(minuteCost) diamonds per minute.")
                    .font(.subheadline)
                    .foregroundStyle(KakaTheme.muted)
            }
        }
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

@MainActor
private struct KakaPrivateCallSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var call = KakaLivePrivateCall()
    @StateObject private var giftEffects = KakaRoomGiftEffects()
    @State private var showingGifts = false
    let room: KakaNativeRoom
    let session: UUID
    let ownsRoom: () -> Bool
    let suspendRoom: () async -> Void

    var body: some View {
        KakaRoomSheet(title: call.phase == .offer ? "Private video call" : room.host?.name ?? "Private video call",
                      locked: call.holdsRoom) {
            if call.phase == .offer {
                offer
            } else {
                KakaPrivateCallConversation(call: call, returnTitle: "Back to live", finished: { dismiss() },
                                            giftEffects: giftEffects, showingGifts: $showingGifts,
                                            recipientName: room.host?.name ?? "the host")
            }
        }
        .modifier(KakaRoomGiftEffectOverlay(effects: giftEffects, accepting: acceptsGiftEffects,
                                            presenting: acceptsGiftEffects && !showingGifts))
        .interactiveDismissDisabled(call.holdsRoom)
        .task { await call.loadOffer(room: room, session: session, ownsRoom: ownsRoom) }
        .onChange(of: scenePhase) { phase in
            if phase == .background, call.phase != .waiting { Task { await call.hangUp() } }
        }
        .onDisappear {
            giftEffects.clear()
            Task { await call.hangUp() }
        }
    }

    private var acceptsGiftEffects: Bool { call.phase == .active && scenePhase == .active && !reduceMotion }

    @ViewBuilder
    private var offer: some View {
        KakaCallIdentity(name: room.host?.name ?? room.title, portrait: room.host?.portrait)
        if !call.feedback.isEmpty {
            Text(call.feedback).font(.subheadline).foregroundStyle(KakaTheme.muted)
        }
        if call.checking {
            KakaRhythmProgress(title: "Checking the call price")
                .padding(.vertical, 12)
        } else if let quote = call.quote {
            KakaCallRate(quote: quote)
            KakaCallAction(title: "Start video call", artwork: "room-watch.png", prominence: KakaTheme.actionFill) {
                Task { await call.start(room: room, session: session, ownsRoom: ownsRoom, suspendRoom: suspendRoom) }
            }
        } else {
            KakaCallAction(title: "Check the offer", artwork: "action-forward.png") {
                Task { await call.loadOffer(room: room, session: session, ownsRoom: ownsRoom) }
            }
        }
    }
}

@MainActor
struct KakaIncomingCallPane: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var call: KakaLivePrivateCall
    let stillActive: () -> Bool
    let suspendRoom: () async -> Void
    let dismiss: () -> Void

    @State private var showingWallet = false
    @State private var showingGifts = false
    @StateObject private var giftEffects = KakaRoomGiftEffects()

    var body: some View {
        ZStack {
            KakaTheme.base.opacity(0.94).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if call.phase == .incoming {
                        incomingOffer
                    } else {
                        Text(call.incomingCaller?.name ?? "Private video call")
                            .font(.title2.weight(.bold))
                            .accessibilityAddTraits(.isHeader)
                        KakaPrivateCallConversation(call: call, returnTitle: "Close", finished: dismiss,
                                                    giftEffects: giftEffects, showingGifts: $showingGifts,
                                                    recipientName: call.incomingCaller?.name ?? "the caller")
                    }
                }
                .frame(maxWidth: 500, alignment: .leading)
                .padding(22)
                .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 10)
        }
        .modifier(KakaRoomGiftEffectOverlay(effects: giftEffects, accepting: acceptsGiftEffects,
                                            presenting: acceptsGiftEffects && !showingGifts && !showingWallet))
        .onDisappear { giftEffects.clear() }
        .foregroundStyle(KakaTheme.ink)
        .task { await call.loadIncomingOffer() }
        .sheet(isPresented: $showingWallet) { KakaStudioWalletView() }
        .accessibilityAction(.escape) {
            if call.phase == .finished { dismiss() }
            else { Task { await call.hangUp() } }
        }
    }

    private var acceptsGiftEffects: Bool { call.phase == .active && scenePhase == .active && !reduceMotion }

    @ViewBuilder
    private var incomingOffer: some View {
        let caller = call.incomingCaller
        KakaCallIdentity(name: caller?.name ?? "Incoming video call", portrait: caller?.portrait,
                         caption: caller?.name == nil ? nil : "Incoming video call")
        if !call.feedback.isEmpty {
            Text(call.feedback).font(.subheadline).foregroundStyle(KakaTheme.muted)
        }
        if call.checking {
            KakaRhythmProgress(title: "Checking incoming call")
                .padding(.vertical, 12)
        } else if let quote = call.quote {
            KakaCallRate(quote: quote, incoming: true)
            KakaCallAction(title: "Accept video call", artwork: "room-watch.png", prominence: KakaTheme.actionFill) {
                Task { await call.acceptIncoming(stillActive: stillActive, suspendRoom: suspendRoom) }
            }
        } else {
            KakaCallAction(title: "Check the call", artwork: "action-forward.png") {
                Task { await call.loadIncomingOffer() }
            }
        }
        KakaRoomActionGroup {
            KakaCallAction(title: "Decline", artwork: "action-stop.png") { Task { await call.hangUp() } }
            if call.quote != nil && !call.checking {
                KakaCallAction(title: "Wallet", artwork: "profile-card-wallet.png") { showingWallet = true }
            }
        }
    }
}

@MainActor
private struct KakaPrivateCallConversation: View {
    @EnvironmentObject private var store: KakaNativeStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ObservedObject var call: KakaLivePrivateCall
    let returnTitle: String
    let finished: () -> Void
    let giftEffects: KakaRoomGiftEffects
    @Binding var showingGifts: Bool
    var recipientName = "the host"
    @State private var showingWallet = false
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
            }, onGiftSent: { effect in
                guard call.phase == .active, scenePhase == .active, !reduceMotion else { return }
                giftEffects.enqueue(effect, time: Date().timeIntervalSince1970)
                showingGifts = false
                store.notify("Gift sent.")
            })
        }
        .onChange(of: call.phase) { phase in
            if phase != .active { showingGifts = false }
        }
    }

    @ViewBuilder
    private var conversation: some View {
        if call.phase == .connecting || call.phase == .active {
            video
        }
        callStatus
        if call.phase == .waiting {
            KakaRoomActionGroup {
                KakaCallAction(title: "Open wallet", artwork: "profile-card-wallet.png", prominence: KakaTheme.actionFill) {
                    if call.setRechargeWalletVisible(true) { showingWallet = true }
                }
                .disabled(call.resumingRecharge)
                KakaCallAction(title: "Check balance", artwork: "action-check.png") {
                    Task { await call.refreshRechargeStatus() }
                }
                .disabled(call.resumingRecharge || call.checkingRecharge)
            }
        }
        if call.phase == .finished {
            KakaCallAction(title: returnTitle, artwork: "action-close.png", action: finished)
        } else if call.phase != .ending {
            KakaRoomActionGroup {
                if call.canOpenCallGifts {
                    KakaCallAction(title: "Gifts", artwork: "stage-gift.png") { showingGifts = true }
                }
                KakaCallAction(title: "End call", artwork: "action-stop.png", prominence: KakaTheme.liveAccent.opacity(0.35)) {
                    Task { await call.hangUp() }
                }
            }
        }
        if call.phase == .active || call.phase == .waiting { callChat }
    }

    private var video: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        let previewShape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Color.black
            .aspectRatio(verticalSizeClass == .compact ? 2.2 : 1.1, contentMode: .fit)
            .frame(maxWidth: 530)
            .overlay {
                KakaNativeVideo(media: call.media, showsDuel: false)
            }
            .overlay(alignment: .bottomTrailing) {
                GeometryReader { geometry in
                    let previewWidth = min(100, geometry.size.width * 0.24, geometry.size.height * 0.32)
                    KakaCallSelfPreview(video: call.media.localCallVideoView)
                        .frame(width: previewWidth, height: previewWidth * 1.3)
                        .background(KakaTheme.base)
                        .clipShape(previewShape)
                        .overlay { previewShape.strokeBorder(.white.opacity(0.34)) }
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(KakaTheme.line).allowsHitTesting(false) }
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }

    private var callStatus: some View {
        HStack(alignment: .center, spacing: 11) {
            KakaNativeImage(asset: call.phase == .waiting ? "profile-card-wallet.png" : "stage-signal.png")
                .scaledToFit()
                .frame(width: 29, height: 29)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(status)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.updatesFrequently)
                if let remaining = call.secondsRemaining {
                    Text("\(remaining) sec in the current interval")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(KakaTheme.muted)
                }
                if call.phase == .waiting, let remaining = call.rechargeSecondsRemaining {
                    Text("\(remaining) sec to add diamonds")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(KakaTheme.liveAccent)
                }
                if !call.feedback.isEmpty {
                    Text(call.feedback).font(.footnote).foregroundStyle(KakaTheme.muted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private var callChat: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label {
                Text("Call chat").font(.subheadline.weight(.semibold))
            } icon: {
                KakaNativeImage(asset: "stage-message.png")
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
            }
            .accessibilityAddTraits(.isHeader)
            ForEach(call.callMessages.suffix(8)) { message in
                Text(message.isLocal ? "You · \(message.text)" : message.text)
                    .font(.footnote)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .foregroundStyle(message.isLocal ? KakaTheme.muted : KakaTheme.ink)
                    .background(message.isLocal ? KakaTheme.accent.opacity(0.10) : KakaTheme.base,
                                in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .frame(maxWidth: .infinity, alignment: message.isLocal ? .trailing : .leading)
            }
            if !call.callMessageFeedback.isEmpty {
                Text(call.callMessageFeedback).font(.caption).foregroundStyle(KakaTheme.muted)
            }
            if call.phase == .active {
                let canSend = !call.sendingCallMessage &&
                    !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                HStack(spacing: 6) {
                    TextField("Send a call message", text: $draft)
                        .font(.subheadline)
                        .padding(.leading, 12)
                        .frame(minHeight: 44)
                        .submitLabel(.send)
                        .onSubmit(sendMessage)
                    KakaStageIconButton(title: call.sendingCallMessage ? "Sending message" : "Send message",
                                        artwork: "action-forward.png", accent: KakaTheme.accent, inRail: true,
                                        action: sendMessage)
                        .disabled(!canSend)
                        .opacity(canSend ? 1 : 0.48)
                }
                .background(KakaTheme.base, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                if call.sendingCallMessage {
                    Text("Sending…").font(.caption).foregroundStyle(KakaTheme.muted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
    @Environment(\.dynamicTypeSize) private var textSize
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
            audienceCover
            if !members.isEmpty { memberGallery }
            audienceStatus
            if error.isEmpty && (!loading || !members.isEmpty) {
                if nextPageToken != nil {
                    KakaRoomButton(title: loading ? "Loading…" : "Show more") { Task { await load() } }
                        .disabled(loading)
                } else if room.kind == .live, loaded {
                    KakaRoomButton(title: loading ? "Refreshing…" : "Refresh audience") { Task { await load() } }
                        .disabled(loading)
                }
            }
        }
        .modifier(KakaRoomUtilityPresentation())
        .task { await load() }
    }

    private var audienceCount: String? {
        if let count = liveViewerCount { return "\(count.formatted()) watching" }
        if members.count == 1 { return "1 participant shown" }
        if !members.isEmpty { return "\(members.count.formatted()) participants shown" }
        return nil
    }

    private var audienceCover: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return VStack(alignment: .leading, spacing: 5) {
            Text(room.title)
                .font(.title3.weight(.semibold))
                .lineLimit(textSize.isAccessibilitySize ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
            if let count = audienceCount {
                Text(count)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(room.kind == .live ? KakaTheme.liveAccent : KakaTheme.voiceAccent)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .bottomLeading)
        .background {
            GeometryReader { artwork in
                KakaNativeImage(asset: "room-audience-cover.jpg")
                    .scaledToFill()
                    .frame(width: artwork.size.width, height: artwork.size.height)
                    .clipped()
                    .overlay {
                        LinearGradient(colors: [KakaTheme.base.opacity(0.32), KakaTheme.base.opacity(0.80)],
                                       startPoint: .top, endPoint: .bottom)
                    }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .background(KakaTheme.surface)
        .clipShape(shape)
        .overlay { shape.strokeBorder(KakaTheme.line).allowsHitTesting(false) }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var memberGallery: some View {
        if textSize.isAccessibilitySize {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(members) { member in
                    HStack(spacing: 12) {
                        memberPortrait(member)
                            .frame(width: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                        Text(member.name)
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 13))
                }
            }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 150), spacing: 8, alignment: .top)],
                      alignment: .leading, spacing: 8) {
                ForEach(members) { member in
                    VStack(alignment: .leading, spacing: 0) {
                        memberPortrait(member)
                        Text(member.name)
                            .font(.footnote.weight(.semibold))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }
                    .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 13))
                    .clipShape(RoundedRectangle(cornerRadius: 13))
                }
            }
        }
    }

    @ViewBuilder
    private func memberPortrait(_ member: KakaRoomChat.AudienceMember) -> some View {
        if let portrait = member.portrait {
            KakaRoomArt(asset: "stage-people.png", remote: portrait, ratio: 1.25, cropAlignment: .top)
        } else {
            KakaNativeImage(asset: "stage-people.png")
                .scaledToFit()
                .padding(textSize.isAccessibilitySize ? 7 : 13)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .aspectRatio(1.25, contentMode: .fit)
                .background(KakaTheme.accent.opacity(0.08))
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var audienceStatus: some View {
        if !error.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(error).font(.subheadline).foregroundStyle(KakaTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                KakaRoomButton(title: "Try again") { Task { await load() } }
                    .disabled(loading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        } else if members.isEmpty {
            HStack(spacing: 12) {
                if loading || !loaded {
                    let title = room.kind == .live ? "Loading viewers…" : "Loading chat participants…"
                    KakaRhythmProgress(title: title).accessibilityHidden(true)
                    Text(title).font(.subheadline.weight(.medium))
                } else {
                    KakaNativeImage(asset: "stage-people.png")
                        .scaledToFit()
                        .frame(width: 47, height: 47)
                        .accessibilityHidden(true)
                    Text(nextPageToken == nil ? "No visible participants right now." : "No visible participants on this page.")
                        .font(.subheadline.weight(.medium))
                }
            }
            .foregroundStyle(KakaTheme.muted)
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        }
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
    private var audioLease: UUID?

    func start(bpm: Int, onBeat: @escaping @MainActor (Int) -> Void) throws {
        guard (60...180).contains(bpm),
              let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let downbeat = pulse(frequency: 1_420, format: format),
              let upbeat = pulse(frequency: 990, format: format) else {
            throw KakaAccountStore.Failure.unavailable
        }

        let audio = AVAudioSession.sharedInstance()
        let lease = UUID()
        try KakaRealtimeMedia.claimLocalAudio(id: lease) { [weak self] in self?.stop() }
        audioLease = lease
        try audio.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try audio.setActive(true)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()

        clockTask = Task { @MainActor [weak self] in
            let interval = UInt64(60_000_000_000 / Double(bpm))
            var next = DispatchTime.now().uptimeNanoseconds
            var beat = 0
            while let self, !Task.isCancelled {
                self.schedulePulse(beat == 0 ? downbeat : upbeat)
                onBeat(beat)
                beat = (beat + 1) % 4
                let now = DispatchTime.now().uptimeNanoseconds
                next = max(next + interval, now + 15_000_000)
                do { try await Task.sleep(nanoseconds: next - now) } catch { return }
            }
        }
    }

    private func schedulePulse(_ buffer: AVAudioPCMBuffer) {
        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    func stop() {
        clockTask?.cancel()
        clockTask = nil
        player.stop()
        engine.stop()
        if let audioLease {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            KakaRealtimeMedia.releaseLocalAudio(id: audioLease)
            self.audioLease = nil
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var textSize
    private let target: Target
    private let expectedAccount: String?
    private var fillsConversation = false
    private let liveOverlayHeight: CGFloat?
    private let onGifts: (() -> Void)?
    private let onGiftSelected: ((Int64) -> Void)?
    private let onRoomOptions: (() -> Void)?
    private let onMessageHost: (() -> Void)?
    private let showsQuickReplies: Bool
    private let isMinimized: Bool
    private let controlsSuspended: Bool
    private let stacksRoomDock: Bool
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
    @State private var photoPickerVisit: PhotoVisit?
    @State private var photoSelection: PhotoSelection?
    @State private var photoDraft: PhotoDraft?
    @State private var photoSendTask: Task<Void, Never>?
    @State private var voiceSendTask: Task<Void, Never>?
    @StateObject private var voice = KakaChatVoiceNote()
    @StateObject private var giftEffects = KakaRoomGiftEffects()

    private enum Target {
        case room(KakaNativeRoom, UUID)
        case direct(Int64, String)
        case support

        var service: String {
            switch self {
            case .room: return "roomChat"
            case .direct, .support: return "directChat"
            }
        }

        var limit: Int { service == "roomChat" ? 280 : 500 }
        var title: String { service == "roomChat" ? "Room chat" : "Messages" }
    }

    private struct ChatLine: Identifiable {
        let id: String
        let name: String
        let text: String
        let own: Bool
        let giftQuantity: Int?
        let giftImage: URL?
        let photoURL: URL?
        let voiceURL: URL?
        let voiceMilliseconds: Int?
    }

    private struct GiftVisit: Identifiable {
        let id: UUID
        let hostID: Int64
        let hostName: String
        let session: UUID
    }

    private struct PhotoVisit: Identifiable {
        let id = UUID()
        let visit: UUID
        let hostID: Int64
        let session: UUID
    }

    private struct PhotoSelection {
        let context: PhotoVisit
        let provider: NSItemProvider
    }

    private struct PhotoDraft {
        let context: PhotoVisit
        let photo: KakaChatPhoto
        let preview: UIImage
    }

    init(hostID: Int64, hostName: String = "this host", fillsConversation: Bool = false) {
        target = .direct(hostID, hostName)
        self.fillsConversation = fillsConversation
        expectedAccount = nil
        liveOverlayHeight = nil
        onGifts = nil
        onGiftSelected = nil
        onRoomOptions = nil
        onMessageHost = nil
        showsQuickReplies = false
        isMinimized = false
        controlsSuspended = false
        stacksRoomDock = false
        onMessageSent = nil
    }

    init() {
        target = .support
        expectedAccount = nil
        liveOverlayHeight = nil
        onGifts = nil
        onGiftSelected = nil
        onRoomOptions = nil
        onMessageHost = nil
        showsQuickReplies = false
        isMinimized = false
        controlsSuspended = false
        stacksRoomDock = false
        onMessageSent = nil
    }

    init(recipient: KakaRoomChat.InboxRecipient) {
        target = recipient.hostID.map { .direct($0, recipient.name) } ?? .support
        fillsConversation = true
        expectedAccount = recipient.id
        liveOverlayHeight = nil
        onGifts = nil
        onGiftSelected = nil
        onRoomOptions = nil
        onMessageHost = nil
        showsQuickReplies = false
        isMinimized = false
        controlsSuspended = false
        stacksRoomDock = false
        onMessageSent = nil
    }

    init(room: KakaNativeRoom, visit: UUID, liveOverlayHeight: CGFloat? = nil, onGifts: (() -> Void)? = nil,
         onGiftSelected: ((Int64) -> Void)? = nil, onRoomOptions: (() -> Void)? = nil,
         onMessageHost: (() -> Void)? = nil, showsQuickReplies: Bool = false, isMinimized: Bool = false,
         controlsSuspended: Bool = false, stacksRoomDock: Bool = false, onMessageSent: (() -> Void)? = nil) {
        target = .room(room, visit)
        expectedAccount = nil
        self.liveOverlayHeight = liveOverlayHeight
        self.onGifts = onGifts
        self.onGiftSelected = onGiftSelected
        self.onRoomOptions = onRoomOptions
        self.onMessageHost = onMessageHost
        self.showsQuickReplies = showsQuickReplies
        self.isMinimized = isMinimized
        self.controlsSuspended = controlsSuspended
        self.stacksRoomDock = stacksRoomDock
        self.onMessageSent = onMessageSent
    }

    private var acceptsGiftEffects: Bool {
        guard case .direct = target else { return false }
        return scenePhase == .active && connected && !reduceMotion && store.session != nil
    }

    private var showsGiftEffects: Bool { acceptsGiftEffects && giftVisit == nil }

    var body: some View {
        Group {
            if let liveOverlayHeight {
                liveOverlay(transcriptHeight: liveOverlayHeight)
            } else if fillsConversation {
                GeometryReader { viewport in
                    chatPanel(scrollsAccessories: viewport.size.height < 330 || textSize.isAccessibilitySize)
                }
            } else {
                chatPanel()
            }
        }
        .modifier(KakaRoomGiftEffectOverlay(effects: giftEffects, accepting: acceptsGiftEffects, presenting: showsGiftEffects))
        .task(id: retry) { await watch() }
        .task(id: photoSelection?.context.id) {
            if let selection = photoSelection { await preparePhoto(selection) }
        }
        .onChange(of: isMinimized) { minimized in
            if minimized { focused = false }
        }
        .onChange(of: controlsSuspended) { suspended in
            if suspended { focused = false }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background { close() }
            else if phase == .active && !connected { retry += 1 }
        }
        .onChange(of: store.session?.token) { _ in discardVoice() }
        .onChange(of: canSend) { allowed in
            if !allowed { discardVoice() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification).receive(on: RunLoop.main)) { notice in
            if notice.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue {
                voice.interrupt()
            }
        }
        .sheet(item: $giftVisit) { context in
            let chat = KakaNativeRoomRuntime.shared.directChat
            KakaPeerGiftSheet(recipientName: context.hostName, showsQuantity: false, loadCatalog: {
                try await chat.directGiftCatalog(hostID: context.hostID, visit: context.id, session: context.session)
            }, sendGift: { gift, quantity in
                try await chat.sendDirectGift(gift, quantity: quantity, hostID: context.hostID,
                                              visit: context.id, session: context.session)
            }, onGiftSent: { effect in
                guard acceptsGiftEffects, giftVisit?.id == context.id, visit == context.id,
                      store.session?.token == context.session else { return }
                giftEffects.enqueue(effect, time: Date().timeIntervalSince1970)
                giftVisit = nil
                store.notify("Gift sent.")
            })
        }
        .sheet(item: $photoPickerVisit) { context in
            KakaChatPhotoPicker { provider in
                guard photoPickerVisit?.id == context.id else { return }
                photoPickerVisit = nil
                if let provider, isCurrentPhotoVisit(context) {
                    photoSelection = PhotoSelection(context: context, provider: provider)
                }
            }
        }
        .onDisappear { close() }
    }

    private func chatPanel(scrollsAccessories: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if !fillsConversation {
                HStack(spacing: 8) {
                    Text(target.title).font(.headline).accessibilityAddTraits(.isHeader)
                    if case .direct(let hostID, let hostName) = target {
                        Spacer(minLength: 0)
                        directGiftButton(hostID: hostID, hostName: hostName)
                    }
                }
            }
            if fillsConversation || !transcript.isEmpty {
                messages(scrollsAccessories: scrollsAccessories)
            }
            if !scrollsAccessories {
                conversationAccessories
            }
            HStack(spacing: 4) {
                liveComposer
                if fillsConversation, case .direct(let hostID, let hostName) = target {
                    directGiftButton(hostID: hostID, hostName: hostName)
                }
            }
            .padding(4)
            .modifier(KakaStageChrome())
        }
        .padding(fillsConversation ? 0 : 12)
        .background(fillsConversation ? Color.clear : KakaTheme.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var conversationAccessories: some View {
        if !feedback.isEmpty {
            Text(feedback).font(.footnote).foregroundStyle(KakaTheme.muted)
        } else if !connected {
            Text("Connecting to chat…").font(.footnote).foregroundStyle(KakaTheme.muted)
        } else if !canSend {
            Text("Messaging is unavailable for this conversation.").font(.footnote).foregroundStyle(KakaTheme.muted)
        } else if transcript.isEmpty && !fillsConversation {
            Text("Start the conversation.").font(.footnote).foregroundStyle(KakaTheme.muted)
        }
        if !feedback.isEmpty, !connected {
            KakaRoomButton(title: "Retry chat") { retry += 1 }
        }
        if case .direct(let hostID, _) = target {
            attachmentComposer(hostID: hostID)
            if !voice.feedback.isEmpty {
                Text(voice.feedback).font(.footnote).foregroundStyle(KakaTheme.muted)
            }
        }
    }

    private func directGiftButton(hostID: Int64, hostName: String) -> some View {
        KakaStageIconButton(title: "Gifts for \(hostName)", artwork: "stage-gift.png",
                            accent: KakaTheme.actionFill) {
            guard canSend, let session = store.session?.token else { return }
            focused = false
            voice.stopAudio()
            giftVisit = GiftVisit(id: visit, hostID: hostID, hostName: hostName, session: session)
        }
        .disabled(!canSend || voice.recording || voice.requestingPermission)
    }

    @ViewBuilder
    private func attachmentComposer(hostID: Int64) -> some View {
        if let draft = photoDraft {
            Image(uiImage: draft.preview).resizable().scaledToFit()
                .frame(maxWidth: 220, maxHeight: 112, alignment: .leading)
                .accessibilityLabel("Photo to send")
            KakaRoomActionGroup {
                KakaRoomButton(title: sending ? "Sending…" : "Send photo") { submitPhoto(draft) }
                    .disabled(sending || !canSend)
                KakaRoomButton(title: "Remove photo") { photoDraft = nil }
                    .disabled(sending)
            }
        } else if let started = voice.recordingStarted {
            VStack(alignment: .leading, spacing: 6) {
                TimelineView(.periodic(from: started, by: 1)) { timeline in
                    let elapsed = min(KakaChatVoiceClip.recordingLimit, max(0, Int(timeline.date.timeIntervalSince(started))))
                    let duration = elapsed == 0 ? "0:00" : KakaChatVoiceClip.durationLabel(elapsed * 1_000)
                    Text("Recording… \(duration)").monospacedDigit()
                        .font(.footnote).foregroundStyle(KakaTheme.muted)
                }
                KakaRoomActionGroup {
                    KakaRoomButton(title: "Stop recording") { voice.finishRecording() }
                    KakaRoomButton(title: "Cancel recording") { voice.discard() }
                }
            }
        } else if let draft = voice.draft {
            VStack(alignment: .leading, spacing: 6) {
                Text("Voice message · \(KakaChatVoiceClip.durationLabel(Int(draft.milliseconds)))")
                    .font(.footnote).foregroundStyle(KakaTheme.muted)
                KakaRoomActionGroup {
                    KakaRoomButton(title: voice.playing == .draft ? "Stop preview" : "Preview") { voice.togglePreview() }
                        .disabled(sending || !canSend)
                    KakaRoomButton(title: sending ? "Sending…" : "Send voice message") { submitVoice(draft, hostID: hostID) }
                        .disabled(sending || !canSend)
                    KakaRoomButton(title: "Discard") { voice.discard() }
                        .accessibilityLabel("Discard the voice message")
                        .disabled(sending)
                }
            }
        } else {
            HStack(spacing: 6) {
                KakaStageIconButton(title: "Add photo", artwork: "room-chat-photo.png") {
                    guard let session = store.session?.token, canSend, !sending, scenePhase == .active else { return }
                    focused = false
                    feedback = ""
                    voice.discard()
                    photoPickerVisit = PhotoVisit(visit: visit, hostID: hostID, session: session)
                }
                .disabled(!canSend || sending || photoSelection != nil || voice.requestingPermission)
                KakaStageIconButton(title: "Record voice", artwork: "Dock-stage") {
                    guard let token = store.session?.token, scenePhase == .active else { return }
                    let id = visit
                    focused = false
                    feedback = ""
                    voice.startRecording { voiceAllowed(visit: id, session: token) }
                }
                .disabled(!canSend || sending || photoSelection != nil || voice.requestingPermission)
            }
            if photoSelection != nil || voice.requestingPermission {
                KakaRhythmProgress(title: photoSelection != nil ? "Preparing photo" : "Requesting microphone")
            }
        }
    }

    private func voiceAllowed(visit: UUID, session: UUID) -> Bool {
        guard case .direct = target else { return false }
        return self.visit == visit && store.session?.token == session && canSend && scenePhase != .background
    }

    private func submitVoice(_ draft: KakaChatVoiceClip, hostID: Int64) {
        guard !sending, scenePhase == .active, let token = store.session?.token,
              voiceAllowed(visit: visit, session: token) else { return }
        let id = visit
        sending = true
        feedback = ""
        voice.stopAudio()
        voiceSendTask = Task { @MainActor in
            defer {
                if visit == id {
                    sending = false
                    voiceSendTask = nil
                }
            }
            do {
                let result = try await KakaNativeRoomRuntime.shared.directChat.sendDirectVoice(draft,
                    hostID: hostID, visit: id, session: token, expectedAccount: expectedAccount)
                guard voiceAllowed(visit: id, session: token), !Task.isCancelled else { return }
                try consume(result, visit: id, session: token)
                voice.discard()
            } catch {
                guard voiceAllowed(visit: id, session: token), !Task.isCancelled else { return }
                store.expireIfNeeded(error)
                if (error as? KakaAccountStore.Failure) == .network {
                    voice.discard()
                    feedback = "Couldn’t confirm delivery. Check the conversation before recording another voice message."
                } else {
                    feedback = store.message(error)
                }
            }
        }
    }

    private func discardVoice() {
        voiceSendTask?.cancel()
        voiceSendTask = nil
        voice.discard()
    }

    private func isCurrentPhotoVisit(_ context: PhotoVisit) -> Bool {
        guard case .direct(let hostID, _) = target else { return false }
        return hostID == context.hostID && visit == context.visit && store.session?.token == context.session
            && scenePhase != .background
    }

    private func preparePhoto(_ selection: PhotoSelection) async {
        let context = selection.context
        defer { if photoSelection?.context.id == context.id { photoSelection = nil } }
        do {
            let photo = try await KakaChatPhoto.selected(from: selection.provider)
            guard !Task.isCancelled, photoSelection?.context.id == context.id, isCurrentPhotoVisit(context) else { return }
            guard let preview = UIImage(data: photo.jpeg) else { throw KakaAvatarUpload.Failure.image }
            photoDraft = PhotoDraft(context: context, photo: photo, preview: preview)
        } catch {
            guard !Task.isCancelled, isCurrentPhotoVisit(context) else { return }
            feedback = "Couldn’t prepare this photo. Choose another one."
        }
    }

    private func submitPhoto(_ draft: PhotoDraft) {
        let context = draft.context
        guard isCurrentPhotoVisit(context), scenePhase == .active, photoDraft?.context.id == context.id,
              canSend, !sending else { return }
        sending = true
        feedback = ""
        photoSendTask = Task { @MainActor in
            defer {
                if visit == context.visit {
                    sending = false
                    photoSendTask = nil
                }
            }
            do {
                let result = try await KakaNativeRoomRuntime.shared.directChat.sendDirectPhoto(draft.photo,
                    hostID: context.hostID, visit: context.visit, session: context.session, expectedAccount: expectedAccount)
                guard isCurrentPhotoVisit(context), !Task.isCancelled else { return }
                try consume(result, visit: context.visit, session: context.session)
                photoDraft = nil
            } catch {
                guard isCurrentPhotoVisit(context), !Task.isCancelled else { return }
                store.expireIfNeeded(error)
                if (error as? KakaAccountStore.Failure) == .network {
                    photoDraft = nil
                    feedback = "Couldn’t confirm photo delivery. Check the conversation before sending again."
                } else {
                    feedback = store.message(error)
                }
            }
        }
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
            liveInputDock
        }
    }

    private var liveInputDock: some View {
        Group {
            if stacksRoomDock || textSize >= .xxxLarge {
                VStack(alignment: .trailing, spacing: 6) {
                    liveToolStrip
                    liveComposer
                }
            } else {
                HStack(spacing: 3) {
                    liveComposer
                    liveToolStrip
                }
            }
        }
        .padding(4)
        .modifier(KakaStageChrome())
    }

    private var liveToolStrip: some View {
        HStack(spacing: 2) {
            if let onMessageHost {
                KakaStageIconButton(title: "Message the host", artwork: "stage-message.png", inRail: true) {
                    focused = false
                    onMessageHost()
                }
            }
            if let onGifts {
                KakaStageIconButton(title: "Gifts", artwork: "stage-gift.png",
                                    accent: KakaTheme.actionFill, inRail: true) {
                    focused = false
                    onGifts()
                }
            }
            if let onRoomOptions {
                KakaStageIconButton(title: "Room options", artwork: "stage-tools.png", inRail: true) {
                    focused = false
                    onRoomOptions()
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
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        return HStack(spacing: 2) {
            TextField("Write a message", text: $input,
                      prompt: Text("Write a message").foregroundColor(KakaTheme.muted))
                .font(.subheadline)
                .foregroundStyle(KakaTheme.ink)
                .tint(KakaTheme.accent)
                .textInputAutocapitalization(.sentences)
                .submitLabel(.send)
                .focused($focused)
                .padding(.leading, 12)
                .frame(minHeight: 44)
                .onSubmit { if !controlsSuspended { submit() } }
                .disabled(!canSend || controlsSuspended)
            Button { submit() } label: {
                KakaNativeImage(asset: "room-tool-share.png")
                    .scaledToFit()
                    .frame(width: 19, height: 19)
                    .frame(width: 44, height: 44)
                    .opacity(sending || !canSend || trimmed.isEmpty ? 0.45 : 1)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(sending ? "Sending message" : "Send message")
            .disabled(controlsSuspended || sending || !canSend || trimmed.isEmpty)
        }
        .background(KakaTheme.base.opacity(reduceTransparency ? 1 : 0.64), in: shape)
        .overlay {
            if focused {
                shape.strokeBorder(KakaTheme.accent.opacity(0.56)).allowsHitTesting(false)
            }
        }
    }

    private func messages(liveHeight: CGFloat? = nil, scrollsAccessories: Bool = false) -> some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if fillsConversation && transcript.isEmpty {
                        VStack(spacing: 8) {
                            KakaNativeImage(asset: "stage-message.png")
                                .scaledToFit()
                                .frame(width: 65, height: 65)
                                .accessibilityHidden(true)
                            if connected && canSend {
                                Text("Start the conversation.").font(.subheadline.weight(.medium))
                                    .foregroundStyle(KakaTheme.muted)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 135)
                    }
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
                            conversationBubble(line)
                        }
                    }
                    if scrollsAccessories { conversationAccessories }
                    Color.clear.frame(height: 1).id("chat-end")
                        .onAppear { nearBottom = true }
                        .onDisappear { nearBottom = false }
                }
                .frame(maxWidth: .infinity, minHeight: liveHeight, alignment: .bottomLeading)
            }
            .frame(minHeight: liveHeight ?? (fillsConversation ? 0 : 42),
                   maxHeight: liveHeight ?? (fillsConversation ? .infinity : 185))
            .clipped()
            .accessibilityHidden(liveHeight == 0)
            .allowsHitTesting(liveHeight != 0)
            .defaultScrollAnchorIfSupported()
            .task {
                guard liveHeight != nil || fillsConversation else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                reader.scrollTo("chat-end", anchor: .bottom)
            }
            .onChange(of: transcript.last?.id) { _ in
                if nearBottom { reader.scrollTo("chat-end", anchor: .bottom) }
            }
            .onChange(of: scrollsAccessories) { _ in
                if nearBottom { reader.scrollTo("chat-end", anchor: .bottom) }
            }
        }
    }

    private func conversationBubble(_ line: ChatLine) -> some View {
        HStack(spacing: 0) {
            if line.own { Spacer(minLength: 28) }
            VStack(alignment: .leading, spacing: 4) {
                if connected, let url = line.photoURL {
                    Text(line.name).font(.caption.weight(.semibold)).foregroundStyle(KakaTheme.muted)
                    KakaChatPhotoThumbnail(url: url, sender: line.name)
                } else if connected, let duration = line.voiceMilliseconds {
                    voiceMessage(line, duration: duration)
                } else {
                    Text(line.name).font(.caption.weight(.semibold)).foregroundStyle(KakaTheme.muted)
                    if let count = line.giftQuantity {
                        HStack(spacing: 8) {
                            KakaNativeImage(asset: "stage-gift.png", remote: line.giftImage)
                                .scaledToFit().frame(width: 33, height: 33)
                                .accessibilityHidden(true)
                            Text(count == 1 ? "Gift · \(line.text)" : "Gift · \(line.text) ×\(count)")
                                .font(.subheadline.weight(.semibold))
                        }
                    } else {
                        Text(line.text).font(.subheadline).textSelection(.enabled)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(line.own ? KakaTheme.actionFill.opacity(0.24) : KakaTheme.surface,
                        in: RoundedRectangle(cornerRadius: 14))
            if !line.own { Spacer(minLength: 28) }
        }
    }

    private func voiceMessage(_ line: ChatLine, duration: Int) -> some View {
        let label = KakaChatVoiceClip.durationLabel(duration)
        let selection = KakaChatVoiceNote.Playback.message(line.id)
        let title = voice.loading == selection ? "Cancel loading" : voice.playing == selection ? "Stop" : "Play"
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(line.name) · Voice message · \(label)")
                .font(.caption.weight(.semibold)).foregroundStyle(KakaTheme.muted)
            if let url = line.voiceURL {
                KakaRoomButton(title: title) {
                    guard let token = store.session?.token, scenePhase == .active else { return }
                    let id = visit
                    voice.toggleMessage(id: line.id, url: url) { voiceAllowed(visit: id, session: token) }
                }
                .accessibilityLabel("\(title) voice message from \(line.name)")
                .accessibilityValue(label)
                .disabled(!canSend || voice.recording || voice.requestingPermission)
            } else {
                Text("Playback unavailable").font(.footnote).foregroundStyle(KakaTheme.muted)
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
            if let expectedAccount { fields["expectedAccount"] = expectedAccount }
            return try await runtime.directChat.performDirect(operation: "directChat.\(operation)", input: fields, session: session)
        case .support:
            return try await runtime.directChat.performSupport(operation: operation, visit: visit, session: session,
                                                               text: text, expectedAccount: expectedAccount)
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
                let own = line["own"] as? Bool == true
                return ChatLine(id: id, name: own ? "You" : name, text: text, own: own,
                                giftQuantity: line["giftQuantity"] as? Int,
                                giftImage: (line["giftImage"] as? String).flatMap(URL.init(string:)),
                                photoURL: KakaChatAttachment.remoteURL(line["photoURL"] as? String),
                                voiceURL: KakaChatAttachment.remoteURL(line["voiceURL"] as? String),
                                voiceMilliseconds: (line["voiceMilliseconds"] as? Int).flatMap {
                                    (1...(KakaChatVoiceClip.playbackLimit * 1_000)).contains($0) ? $0 : nil
                                })
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
        photoPickerVisit = nil
        photoSelection = nil
        photoDraft = nil
        photoSendTask?.cancel()
        photoSendTask = nil
        discardVoice()
        giftEffects.clear()
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
    @Environment(\.dynamicTypeSize) private var textSize
    let recipientName: String
    let showsQuantity: Bool
    let loadCatalog: @MainActor () async throws -> KakaPeerGifts.Catalog
    let sendGift: @MainActor (KakaPeerGifts.Gift, Int) async throws -> KakaVoiceGifts.Delivery
    var onRecharge: (() -> Void)? = nil
    var onGiftSent: ((URL) -> Void)? = nil

    @State private var catalog: KakaPeerGifts.Catalog?
    @State private var selection: KakaPeerGifts.Gift?
    @State private var quantity = 1
    @State private var busy = false
    @State private var uncertain = false
    @State private var feedback = ""
    @State private var wallet = false
    @State private var visible = false

    var body: some View {
        KakaGiftTray(title: "Gifts for \(recipientName)", accent: KakaTheme.accent, locked: busy,
                     showsDock: catalog != nil || uncertain,
                     refresh: busy || uncertain || selection != nil ? nil : refreshCatalog) {
            if let selection {
                KakaGiftTrayReceipt(line: "\(quantity) × \(selection.name)", recipients: recipientName,
                                    total: cost(selection), artwork: selection.image, accent: KakaTheme.accent)
            } else if let catalog, !catalog.gifts.isEmpty {
                if showsQuantity {
                    KakaGiftTrayPresets(quantity: $quantity, amounts: [1, 5, 10, 99], accent: KakaTheme.accent)
                        .disabled(busy || uncertain)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: textSize.isAccessibilitySize ? 144 : 88), spacing: 8)],
                          spacing: 8) {
                    ForEach(catalog.gifts, id: \.id) { gift in
                        KakaGiftTrayTile(name: gift.name, price: cost(gift), picture: gift.image,
                                         accent: KakaTheme.accent, selected: false) { selection = gift }
                            .disabled(busy || uncertain || catalog.balance < gift.cost * Decimal(quantity))
                    }
                }
            } else if let catalog, catalog.gifts.isEmpty {
                KakaGiftTrayEmpty(title: feedback.isEmpty ? "No gifts available." : feedback)
            }
            if busy { KakaRhythmProgress(title: selection == nil ? "Loading gifts" : "Sending gift") }
            if !feedback.isEmpty, catalog?.gifts.isEmpty != true {
                KakaGiftTrayStatus(message: feedback)
            }
        } dock: {
            peerGiftDock
        }
        .interactiveDismissDisabled(busy)
        .task { await load() }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .sheet(isPresented: $wallet, onDismiss: { Task { await load() } }) { KakaStudioWalletView() }
    }

    private var peerGiftDock: some View {
        KakaRoomActionGroup {
            if let catalog {
                KakaGiftTrayBalance(amount: KakaLiveGifts.display(catalog.balance), action: openWallet)
                    .disabled(busy)
            }
            if let selection {
                KakaRoomButton(title: "Cancel") { self.selection = nil }
                    .disabled(busy || uncertain)
                KakaGiftTrayAction(title: "Send gift", accent: KakaTheme.accent, enabled: !busy && !uncertain,
                                   total: cost(selection)) {
                    Task { await send(selection, quantity: quantity) }
                }
            } else if uncertain {
                KakaGiftTrayAction(title: "Open wallet", accent: KakaTheme.accent, action: openWallet)
            }
        }
    }

    private func refreshCatalog() {
        Task { await load() }
    }

    private func openWallet() {
        selection = nil
        if let onRecharge { onRecharge() } else { wallet = true }
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
                else if let effect = gift.effect { onGiftSent?(effect) }
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

    @FocusState private var noteFocused: Bool
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
                noteForm
            case .report:
                reportForm
            case .hide:
                Text("This room will be removed from your lists. You can restore it from your profile.")
                    .font(.subheadline)
                    .foregroundStyle(KakaTheme.muted)
                formAction("Hide room", accent: KakaTheme.liveAccent, enabled: !working)
            }
            if !feedback.isEmpty {
                Text(feedback).font(.footnote).foregroundStyle(KakaTheme.muted)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .modifier(KakaRoomUtilityPresentation(fraction: mode == .hide ? 0.34 : 0.60))
        .interactiveDismissDisabled(working)
        .onAppear {
            if mode == .note {
                text = (store.record["notes"] as? [[String: Any]] ?? [])
                    .first { $0["roomID"] as? String == room.id }?["text"] as? String ?? ""
            }
        }
    }

    private var noteForm: some View {
        let count = text.utf16.count
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                KakaNativeImage(asset: "room-tool-info.png")
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
                Text(room.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
            }
            noteEditor
                .focused($noteFocused)
                .accessibilityLabel("Rehearsal note")
                .frame(minHeight: 144)
                .padding(7)
                .background(KakaTheme.surface, in: shape)
                .overlay {
                    shape.strokeBorder(noteFocused ? KakaTheme.accent.opacity(0.65) : KakaTheme.line)
                        .allowsHitTesting(false)
                }
            Text("\(count) of 480 characters")
                .font(.caption.monospacedDigit())
                .foregroundStyle(count > 480 ? KakaTheme.liveAccent : KakaTheme.muted)
                .frame(maxWidth: .infinity, alignment: .trailing)
            formAction("Save note", accent: KakaTheme.accent, enabled: count <= 480 && !working)
        }
    }

    @ViewBuilder
    private var noteEditor: some View {
        if #available(iOS 16.0, *) {
            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .disabled(working)
        } else {
            TextEditor(text: $text)
                .colorScheme(.dark)
                .disabled(working)
        }
    }

    private var reportForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Why are you reporting this room?")
                .font(.subheadline)
                .foregroundStyle(KakaTheme.muted)
            VStack(spacing: 2) {
                ForEach(reasons, id: \.code) { reason in
                    let selected = selectedReason == reason.code
                    Button { selectedReason = reason.code } label: {
                        HStack(spacing: 8) {
                            Text(reason.title)
                                .font(.subheadline.weight(.medium))
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 4)
                            if selected {
                                KakaNativeImage(asset: "action-check.png")
                                    .scaledToFit()
                                    .frame(width: 19, height: 19)
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .frame(minHeight: 44)
                        .background(selected ? KakaTheme.accent.opacity(0.13) : .clear,
                                    in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(KakaRoomCardPressStyle())
                    .disabled(working)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(4)
            .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            formAction("Send report", accent: KakaTheme.liveAccent, enabled: !selectedReason.isEmpty && !working)
        }
    }

    private func formAction(_ title: String, accent: Color, enabled: Bool) -> some View {
        Button {
            noteFocused = false
            perform()
        } label: {
            Text(working ? "Working…" : title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(enabled ? KakaTheme.base : KakaTheme.muted)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(enabled ? accent : KakaTheme.surface, in: RoundedRectangle(cornerRadius: 13))
                .contentShape(Rectangle())
        }
        .buttonStyle(KakaRoomCardPressStyle())
        .disabled(!enabled)
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
                    LazyHStack(alignment: .bottom, spacing: 4) {
                        ForEach(gifts) { gift in
                            Button { onSelect(gift.id) } label: {
                                VStack(spacing: 3) {
                                    ZStack {
                                        Color.clear
                                        gift.artwork(size: 36)
                                    }
                                    .frame(width: 36, height: 36)
                                    Text(gift.name)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(KakaTheme.ink)
                                        .lineLimit(1)
                                    Text(gift.cost)
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(KakaTheme.liveAccent)
                                }
                                .padding(.vertical, 5)
                                .padding(.horizontal, 5)
                                .frame(width: min(tileWidth, 150))
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(KakaRoomCardPressStyle())
                            .accessibilityLabel("\(gift.name), \(gift.cost) diamonds")
                            .accessibilityHint("Shows gift details")
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .padding(.vertical, 3)
                .modifier(KakaStageChrome())
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
private struct KakaVoiceExpressionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var textSize
    @EnvironmentObject private var store: KakaNativeStore
    let context: KakaVoiceManagementContext
    let seat: Int64
    @State private var groups: [KakaRoomChat.VoiceExpressionGroup] = []
    @State private var selected = 0
    @State private var loading = false
    @State private var sending = false
    @State private var error = ""

    var body: some View {
        KakaRoomSheet(title: "Expressions", locked: sending) {
            expressionCover
            if groups.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(groups) { group in
                            KakaRoomButton(title: group.name.isEmpty ? "Pack \(group.id + 1)" : group.name,
                                           selected: selected == group.id) { selected = group.id }
                        }
                    }
                }
            }
            if let group = groups.first(where: { $0.id == selected }) {
                expressionGrid(group)
            }
            if loading || sending { KakaRhythmProgress(title: sending ? "Sending expression" : "Loading expressions") }
            if !error.isEmpty {
                KakaGiftTrayStatus(message: error)
                if groups.isEmpty { KakaRoomButton(title: "Try again") { Task { await load() } } }
            } else if groups.isEmpty && !loading {
                Text("No expressions available.").font(.subheadline).foregroundStyle(KakaTheme.muted)
            }
        }
        .modifier(KakaRoomUtilityPresentation(fraction: 0.55))
        .interactiveDismissDisabled(sending)
        .task { await load() }
    }

    private var expressionCover: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return VStack(alignment: .leading, spacing: 5) {
            Text("Seat \(seat)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(KakaTheme.voiceAccent)
            Text("React from your mic seat")
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 94, alignment: .leading)
        .background {
            GeometryReader { artwork in
                KakaNativeImage(asset: "room-expressions-cover.jpg")
                    .scaledToFill()
                    .frame(width: artwork.size.width, height: artwork.size.height, alignment: .trailing)
                    .clipped()
                    .overlay {
                        LinearGradient(colors: [KakaTheme.base, KakaTheme.base.opacity(0.59), KakaTheme.base.opacity(0.11)],
                                       startPoint: .leading, endPoint: .trailing)
                    }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(KakaTheme.voiceAccent.opacity(0.24)).allowsHitTesting(false) }
    }

    private func expressionGrid(_ group: KakaRoomChat.VoiceExpressionGroup) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: textSize.isAccessibilitySize ? 132 : 76), spacing: 8)],
                  spacing: 8) {
            ForEach(group.choices.indices, id: \.self) { index in
                let choice = group.choices[index]
                let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
                Button { Task { await send(choice) } } label: {
                    VStack(spacing: 4) {
                        KakaNativeImage(asset: "Dock-voice", remote: choice.artwork)
                            .scaledToFit().frame(width: 48, height: 48)
                            .accessibilityHidden(true)
                        if !choice.name.isEmpty {
                            Text(choice.name).font(.caption.weight(.medium))
                                .lineLimit(textSize.isAccessibilitySize ? nil : 2)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, minHeight: 72)
                    .background(KakaTheme.surface, in: shape)
                    .overlay { shape.strokeBorder(KakaTheme.line).allowsHitTesting(false) }
                    .contentShape(shape)
                }
                .buttonStyle(KakaRoomCardPressStyle())
                .accessibilityLabel(choice.name.isEmpty ? "Send expression \(index + 1)" : "Send \(choice.name)")
                .disabled(sending)
            }
        }
    }

    private func load() async {
        guard !loading, context.state(in: store) != nil else { return }
        loading = true
        error = ""
        defer { loading = false }
        do {
            let result = try await KakaNativeRoomRuntime.shared.chat.voiceExpressions(roomID: context.roomID, session: context.session,
                                                                                     visit: context.visit, seat: seat)
            guard context.state(in: store) != nil else { return }
            groups = result
            selected = result.first?.id ?? 0
        } catch {
            show(error, fallback: "Couldn’t load expressions. Make sure you’re still seated.")
        }
    }

    private func send(_ choice: KakaRoomChat.VoiceExpression) async {
        guard !sending, context.state(in: store) != nil else { return }
        sending = true
        error = ""
        defer { sending = false }
        do {
            try await KakaNativeRoomRuntime.shared.chat.sendVoiceExpression(choice, roomID: context.roomID, session: context.session,
                                                                           visit: context.visit, seat: seat)
            if context.state(in: store) != nil { dismiss() }
        } catch {
            show(error, fallback: "Couldn’t send the expression. Make sure you’re still seated.")
        }
    }

    private func show(_ issue: Error, fallback: String) {
        guard context.state(in: store) != nil else { return }
        store.expireIfNeeded(issue)
        error = fallback
    }
}

private struct KakaVoiceExpressionArtwork: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let expression: KakaRoomChat.VoiceExpression
    @State private var animation: UIImage?

    var body: some View {
        Group {
            if !reduceMotion, let animation {
                Player(image: animation)
            } else {
                AsyncImage(url: expression.artwork) { phase in
                    if let image = phase.image { image.resizable().scaledToFit() }
                }
            }
        }
        .task(id: reduceMotion) {
            guard !reduceMotion else { return }
            let image = try? await Self.animatedImage(at: expression.animation)
            if !Task.isCancelled { animation = image }
        }
    }

    private struct Player: UIViewRepresentable {
        let image: UIImage

        func makeUIView(context: Context) -> UIImageView {
            let view = UIImageView()
            view.contentMode = .scaleAspectFit
            return view
        }

        func updateUIView(_ view: UIImageView, context: Context) {
            guard let first = image.images?.first, view.image !== first else { return }
            view.image = first
            view.animationImages = image.images
            view.animationDuration = image.duration
            view.startAnimating()
        }
    }

    private nonisolated static func animatedImage(at url: URL) async throws -> UIImage? {
        let limit = 2_000_000
        let (stream, response) = try await URLSession.shared.bytes(for: URLRequest(url: url, timeoutInterval: 4))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              http.url?.scheme?.lowercased() == "https", http.expectedContentLength <= Int64(limit) else { return nil }
        var data = Data()
        for try await byte in stream {
            guard data.count < limit else { return nil }
            data.append(byte)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source), type as String == "com.compuserve.gif" else { return nil }
        let frames = CGImageSourceGetCount(source)
        guard (2...70).contains(frames) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                       kCGImageSourceThumbnailMaxPixelSize: 156]
        var images: [UIImage] = []
        var duration: TimeInterval = 0
        for frame in 0..<frames {
            try Task.checkCancellation()
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, frame, options as CFDictionary) else { return nil }
            images.append(UIImage(cgImage: image))
            let values = CGImageSourceCopyPropertiesAtIndex(source, frame, nil) as? [CFString: Any]
            let gif = values?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0.1
            duration += delay.isFinite ? min(max(delay, 0.03), 0.5) : 0.1
        }
        return UIImage.animatedImage(with: images, duration: duration)
    }
}

@MainActor
private struct KakaGiftTray<Items: View, Dock: View>: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var textSize
    @EnvironmentObject private var store: KakaNativeStore
    @State private var sheetID = UUID()
    let title: String
    let accent: Color
    let locked: Bool
    let showsDock: Bool
    let refresh: (() -> Void)?
    @ViewBuilder let items: () -> Items
    @ViewBuilder let dock: () -> Dock

    var body: some View {
        GeometryReader { viewport in
            let pinsChrome = viewport.size.height >= 340 && !textSize.isAccessibilitySize
            VStack(spacing: 0) {
                if pinsChrome { header }
                ScrollView {
                    VStack(spacing: 0) {
                        if !pinsChrome { header }
                        VStack(alignment: .leading, spacing: 12) {
                            items()
                            if !pinsChrome && showsDock { dock() }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(maxWidth: 640)
                        .frame(maxWidth: .infinity)
                    }
                }
                if pinsChrome && showsDock {
                    dock()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(maxWidth: 640)
                        .frame(maxWidth: .infinity)
                        .background(KakaTheme.surface)
                        .overlay(alignment: .top) {
                            KakaTheme.line.frame(height: 1).allowsHitTesting(false)
                        }
                }
            }
        }
        .background(KakaTheme.base.ignoresSafeArea())
        .foregroundStyle(KakaTheme.ink)
        .modifier(KakaGiftTrayPresentation())
        .interactiveDismissDisabled(locked)
        .onAppear { store.setSheet(sheetID, presented: true) }
        .onDisappear { store.setSheet(sheetID, presented: false) }
    }

    private var header: some View {
        HStack(spacing: 7) {
            KakaNativeImage(asset: "stage-gift.png")
                .scaledToFit()
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
            Text(title)
                .font(.title3.weight(.bold))
                .layoutPriority(1)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if let refresh {
                Button(action: refresh) {
                    Text("Refresh")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 9)
                        .frame(minWidth: 44, minHeight: 44)
                        .background {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(KakaTheme.base.opacity(0.82))
                                .padding(.vertical, 7)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh gifts")
            }
            Button { dismiss() } label: {
                KakaNativeImage(asset: "action-close.png")
                    .scaledToFit()
                    .frame(width: 17, height: 17)
                    .background {
                        Circle().fill(KakaTheme.base.opacity(0.75)).frame(width: 30, height: 30)
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .disabled(locked)
            .accessibilityLabel("Close gifts")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .background {
            GeometryReader { artwork in
                KakaNativeImage(asset: "stage-gift-tray.jpg")
                    .scaledToFill()
                    .frame(width: artwork.size.width, height: artwork.size.height, alignment: .bottomTrailing)
                    .clipped()
                    .overlay {
                        LinearGradient(colors: [.clear, KakaTheme.base.opacity(0.20)],
                                       startPoint: .leading, endPoint: .trailing)
                    }
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            KakaTheme.line.frame(height: 1).allowsHitTesting(false)
        }
    }
}

private struct KakaGiftTrayPresentation: ViewModifier {
    @Environment(\.dynamicTypeSize) private var textSize

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            let tray = content
                .presentationDetents(textSize.isAccessibilitySize ? [.large] : [.fraction(0.54), .large])
                .presentationDragIndicator(.visible)
            if #available(iOS 16.4, *) {
                tray.presentationContentInteraction(.scrolls).presentationCornerRadius(26)
            } else {
                tray
            }
        } else {
            content
        }
    }
}

private struct KakaGiftTrayTile: View {
    @Environment(\.dynamicTypeSize) private var textSize
    @ScaledMetric(relativeTo: .caption) private var titleBand: CGFloat = 29
    let name: String
    let price: String
    let picture: URL?
    let accent: Color
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            VStack(spacing: 0) {
                KakaNativeImage(asset: "stage-gift.png", remote: picture)
                    .scaledToFit()
                    .frame(height: 54)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 5)
                    .frame(maxWidth: .infinity)
                    .background(selected ? accent.opacity(0.09) : KakaTheme.surface.opacity(0.45))
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            KakaNativeImage(asset: "action-check.png")
                                .scaledToFit()
                                .frame(width: 15, height: 15)
                                .padding(4)
                        }
                    }
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                VStack(spacing: 2) {
                    Text(name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(textSize.isAccessibilitySize ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: textSize.isAccessibilitySize ? nil : titleBand, alignment: .top)
                    Text("\(price) diamonds")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(KakaTheme.surface)
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(selected ? accent : KakaTheme.line, lineWidth: selected ? 1.25 : 1)
                    .allowsHitTesting(false)
            }
            .contentShape(shape)
        }
        .buttonStyle(KakaRoomCardPressStyle())
        .accessibilityLabel("\(name), \(price) diamonds")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct KakaGiftTrayEmpty: View {
    let title: String

    var body: some View {
        VStack(spacing: 7) {
            KakaNativeImage(asset: "stage-gift-empty.png")
                .scaledToFit()
                .frame(width: 140, height: 106)
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(KakaTheme.muted)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }
}

private struct KakaGiftTrayStatus: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.subheadline.weight(.medium))
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityAddTraits(.updatesFrequently)
    }
}

private struct KakaGiftTrayReceipt: View {
    let line: String
    let recipients: String
    let total: String
    let artwork: URL?
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                KakaNativeImage(asset: "stage-gift.png", remote: artwork)
                    .scaledToFit()
                    .frame(width: 65, height: 65)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Confirm gift").font(.headline).accessibilityAddTraits(.isHeader)
                    Text(line).font(.subheadline.weight(.semibold))
                    Text(recipients).font(.subheadline).foregroundStyle(KakaTheme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            KakaTheme.line.frame(height: 1).accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline) {
                Text("Total").font(.subheadline.weight(.semibold))
                Spacer(minLength: 12)
                Text("\(total) diamonds")
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(accent)
                    .multilineTextAlignment(.trailing)
            }
            .accessibilityElement(children: .combine)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
        .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct KakaGiftTrayBalance: View {
    let amount: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                KakaNativeImage(asset: "profile-card-wallet.png")
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(amount) diamonds").font(.subheadline.weight(.semibold).monospacedDigit())
                    Text("Recharge").font(.caption2).foregroundStyle(KakaTheme.muted)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 6)
            .frame(minWidth: 44, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Recharge, balance \(amount) diamonds")
    }
}

private struct KakaGiftTrayQuantity: View {
    @Binding var quantity: Int
    let limit: Int

    var body: some View {
        HStack(spacing: 0) {
            step("−", label: "Decrease quantity", disabled: quantity <= 1) { quantity -= 1 }
            Text(quantity.formatted())
                .font(.footnote.weight(.semibold).monospacedDigit())
                .frame(minWidth: 24)
                .accessibilityLabel("Quantity \(quantity)")
            step("+", label: "Increase quantity", disabled: quantity >= limit) { quantity += 1 }
        }
        .background(KakaTheme.base, in: RoundedRectangle(cornerRadius: 12))
    }

    private func step(_ title: String, label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(disabled ? KakaTheme.muted.opacity(0.45) : KakaTheme.ink)
                .frame(minWidth: 44, minHeight: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(label)
    }
}

private struct KakaGiftTrayPresets: View {
    @Binding var quantity: Int
    let amounts: [Int]
    let accent: Color

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(amounts, id: \.self) { amount in
                    Button { quantity = amount } label: {
                        Text("×\(amount.formatted())")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(amount == quantity ? accent : KakaTheme.muted)
                            .padding(.horizontal, 8)
                            .frame(minWidth: 44, minHeight: 44)
                            .background(KakaTheme.base.opacity(0.55), in: RoundedRectangle(cornerRadius: 11))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Quantity \(amount)")
                    .accessibilityAddTraits(quantity == amount ? .isSelected : [])
                }
            }
        }
        .accessibilityLabel("Gift quantity presets")
    }
}

private struct KakaGiftTrayAction: View {
    let title: String
    let accent: Color
    var enabled = true
    var total: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(title).font(.footnote.weight(.bold))
                if let total {
                    Text("\(total) diamonds").font(.caption2.weight(.semibold).monospacedDigit())
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(enabled ? KakaTheme.base : KakaTheme.muted)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .frame(minWidth: 88, minHeight: 48)
            .background(enabled ? accent : KakaTheme.base, in: RoundedRectangle(cornerRadius: 13))
            .contentShape(Rectangle())
        }
        .buttonStyle(KakaRoomCardPressStyle())
        .disabled(!enabled)
        .accessibilityLabel(total.map { "\(title), \($0) diamonds" } ?? title)
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
        KakaGiftTray(title: "Voice gifts", accent: KakaTheme.voiceAccent, locked: sending,
                     showsDock: review != nil || catalog != nil,
                     refresh: loading || review != nil ? nil : { Task { await load() } }) {
            if let review {
                checkout(review)
            } else if let catalog {
                peoplePicker
                if catalog.categories.isEmpty {
                    KakaGiftTrayEmpty(title: "No gifts available right now.")
                } else {
                    giftPicker(catalog)
                    if catalog.quantities.count > 1 {
                        KakaGiftTrayPresets(quantity: $quantity, amounts: catalog.quantities, accent: KakaTheme.voiceAccent)
                    }
                }
            } else if loading {
                KakaRhythmProgress(title: "Loading voice gifts")
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity)
            } else if !feedback.isEmpty {
                KakaGiftTrayStatus(message: feedback)
            }
        } dock: {
            if let review {
                checkoutActions(review)
            } else if let catalog {
                giftDock(catalog)
            }
        }
        .task { await load() }
        .sheet(isPresented: $showsWallet, onDismiss: { Task { await load() } }) { KakaStudioWalletView() }
    }

    private var peoplePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("People on mic").font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                if !selectedPeople.isEmpty {
                    Text("\(selectedPeople.count) selected")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(KakaTheme.voiceAccent)
                }
            }
            if recipients.isEmpty {
                Text("Gifts can be sent to people currently on mic.")
                    .font(.footnote).foregroundStyle(KakaTheme.muted)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 6) {
                        if recipients.count > 1 {
                            let limit = min(recipients.count, KakaVoiceGifts.recipientLimit)
                            let full = selectedPeople.count == limit
                            let title = full ? "Clear selection" : limit == recipients.count ? "Everyone" : "Select first \(limit)"
                            recipientChip(title: title, artwork: "stage-people.png", remote: nil, selected: full) {
                                selectedPeople = full ? [] : Set(recipients.prefix(limit).map(\.id))
                            }
                        }
                        ForEach(recipients) { person in
                            let selected = selectedPeople.contains(person.id)
                            recipientChip(title: person.name, artwork: "member-mark.jpg", remote: person.portrait, selected: selected) {
                                if selected { selectedPeople.remove(person.id) }
                                else { selectedPeople.insert(person.id) }
                            }
                            .disabled(!selected && selectedPeople.count >= KakaVoiceGifts.recipientLimit)
                        }
                    }
                }
            }
        }
    }

    private func recipientChip(title: String, artwork: String, remote: URL?, selected: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                KakaNativeImage(asset: artwork, remote: remote)
                    .scaledToFill()
                    .frame(width: 42, height: 42)
                    .background(KakaTheme.base, in: Circle())
                    .clipShape(Circle())
                    .overlay {
                        Circle().strokeBorder(selected ? KakaTheme.voiceAccent : KakaTheme.line, lineWidth: selected ? 2 : 1)
                            .allowsHitTesting(false)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if selected {
                            KakaNativeImage(asset: "action-check.png")
                                .scaledToFit()
                                .frame(width: 16, height: 16)
                                .background(KakaTheme.base, in: Circle())
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityHidden(true)
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(selected ? KakaTheme.voiceAccent : KakaTheme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 3)
            .frame(width: textSize.isAccessibilitySize ? 116 : 62, alignment: .top)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(KakaRoomCardPressStyle())
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func giftPicker(_ catalog: KakaVoiceGifts.Catalog) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if catalog.categories.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(catalog.categories) { category in
                            Button {
                                categoryID = category.id
                                giftID = nil
                            } label: {
                                Text(category.name)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(category.id == categoryID ? KakaTheme.voiceAccent : KakaTheme.muted)
                                    .padding(.horizontal, 8)
                                    .frame(minWidth: 44, minHeight: 44)
                                    .background(alignment: .bottom) {
                                        if category.id == categoryID {
                                            Capsule().fill(KakaTheme.voiceAccent).frame(height: 2).padding(.horizontal, 8)
                                        }
                                    }
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(category.id == categoryID ? .isSelected : [])
                        }
                    }
                }
                .accessibilityLabel("Gift categories")
            }
            if let category = catalog.categories.first(where: { $0.id == categoryID }) {
                if category.gifts.isEmpty {
                    KakaGiftTrayEmpty(title: "No gifts in this category.")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: textSize.isAccessibilitySize ? 142 : 74), spacing: 8)], spacing: 8) {
                        ForEach(category.gifts) { gift in
                            KakaGiftTrayTile(name: gift.name, price: KakaLiveGifts.display(gift.cost),
                                             picture: gift.image.flatMap { KakaRoomFields.url($0.absoluteString) },
                                             accent: KakaTheme.voiceAccent, selected: gift.id == giftID) {
                                giftID = gift.id
                            }
                        }
                    }
                }
            }
        }
    }

    private func giftDock(_ catalog: KakaVoiceGifts.Catalog) -> some View {
        let ready = selection.map { $0.total <= catalog.balance } ?? false
        return VStack(alignment: .leading, spacing: 3) {
            if let selection, selection.total > catalog.balance {
                Text("Your balance is too low for this selection.")
                    .font(.footnote).foregroundStyle(KakaTheme.muted)
            }
            KakaRoomActionGroup {
                KakaGiftTrayBalance(amount: KakaLiveGifts.display(catalog.balance)) { showsWallet = true }
                if catalog.categories.contains(where: { !$0.gifts.isEmpty }) {
                    KakaGiftTrayQuantity(quantity: $quantity, limit: KakaVoiceGifts.quantityLimit)
                        .accessibilityHint("Quantity per person")
                    KakaGiftTrayAction(title: "Review", accent: KakaTheme.voiceAccent, enabled: ready,
                                      total: selection.map { KakaLiveGifts.display($0.total) }) {
                        if let selection, selection.total <= catalog.balance { review = selection }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func checkout(_ review: Review) -> some View {
        KakaGiftTrayReceipt(line: "\(review.quantity) × \(review.gift.name) per person",
                            recipients: review.recipients.map(\.name).joined(separator: ", "),
                            total: KakaLiveGifts.display(review.total), artwork: review.gift.image,
                            accent: KakaTheme.voiceAccent)
    }

    private func checkoutActions(_ review: Review) -> some View {
        KakaRoomActionGroup {
            KakaRoomButton(title: "Back to gifts") { self.review = nil }.disabled(sending)
            KakaGiftTrayAction(title: sending ? "Sending…" : "Send gift", accent: KakaTheme.voiceAccent,
                              enabled: !sending) {
                guard !sending else { return }
                sending = true
                Task { await send(review) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
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
    @Environment(\.dynamicTypeSize) private var textSize
    let room: KakaNativeRoom
    let visit: UUID
    var initialGiftID: Int64? = nil
    var onSent: (() -> Void)? = nil
    @State private var gifts: [KakaLiveGift] = []
    @State private var balance = ""
    @State private var host = ""
    @State private var feedback = ""
    @State private var busy = false
    @State private var giftID: Int64?
    @State private var choice: KakaLiveGift?
    @State private var quantity = 1
    @State private var duelGift = false
    @State private var showsWallet = false
    @State private var hasCatalog = false

    private var selectedGift: KakaLiveGift? { gifts.first { $0.id == giftID } }
    private let presets = [1, 5, 10, 99]

    var body: some View {
        KakaGiftTray(title: duelGift ? "PK gifts" : "Live gifts", accent: KakaTheme.liveAccent, locked: busy,
                     showsDock: choice != nil || !balance.isEmpty || !gifts.isEmpty,
                     refresh: busy || choice != nil ? nil : { Task { await fetch() } }) {
            if let choice {
                giftConfirmation(choice)
            } else if busy {
                KakaRhythmProgress(title: "Updating gifts")
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity)
            } else {
                if !feedback.isEmpty {
                    KakaGiftTrayStatus(message: feedback)
                }
                if !gifts.isEmpty {
                    giftGallery
                    KakaGiftTrayPresets(quantity: $quantity, amounts: presets, accent: KakaTheme.liveAccent)
                } else if hasCatalog {
                    KakaGiftTrayEmpty(title: "No gifts available right now.")
                }
            }
        } dock: {
            if let choice {
                confirmationDock(choice)
            } else if !balance.isEmpty || !gifts.isEmpty {
                giftDock
            }
        }
        .task { await fetch(initial: true) }
        .sheet(isPresented: $showsWallet, onDismiss: { Task { await fetch() } }) { KakaStudioWalletView() }
    }

    private var giftGallery: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: textSize.isAccessibilitySize ? 142 : 74), spacing: 8)], spacing: 8) {
            ForEach(gifts) { gift in
                KakaGiftTrayTile(name: gift.name, price: gift.cost, picture: gift.image,
                                 accent: KakaTheme.liveAccent, selected: gift.id == giftID) {
                    giftID = gift.id
                }
            }
        }
    }

    private var giftDock: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let selectedGift, !canReview(selectedGift), !busy {
                Text("Your balance is too low for this selection.")
                    .font(.footnote).foregroundStyle(KakaTheme.muted)
            }
            KakaRoomActionGroup {
                if !balance.isEmpty {
                    KakaGiftTrayBalance(amount: balance) { showsWallet = true }.disabled(busy)
                }
                if !gifts.isEmpty {
                    KakaGiftTrayQuantity(quantity: $quantity, limit: presets.last ?? 99).disabled(busy)
                    KakaGiftTrayAction(title: "Review", accent: KakaTheme.liveAccent,
                                      enabled: selectedGift.map(canReview) ?? false,
                                      total: selectedGift.map { $0.total(for: quantity) }) {
                        if let selectedGift, canReview(selectedGift) { choice = selectedGift }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func giftConfirmation(_ gift: KakaLiveGift) -> some View {
        KakaGiftTrayReceipt(line: "\(quantity) × \(gift.name)", recipients: "To \(host)",
                            total: gift.total(for: quantity), artwork: gift.image,
                            accent: KakaTheme.liveAccent)
    }

    private func confirmationDock(_ gift: KakaLiveGift) -> some View {
        KakaRoomActionGroup {
            if !balance.isEmpty {
                KakaGiftTrayBalance(amount: balance) {
                    choice = nil
                    showsWallet = true
                }
                .disabled(busy)
            }
            KakaRoomButton(title: "Back") { choice = nil }.disabled(busy)
            KakaGiftTrayAction(title: busy ? "Sending…" : "Send gift", accent: KakaTheme.liveAccent,
                              enabled: canReview(gift)) {
                let count = quantity
                Task { await send(gift, quantity: count) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func canReview(_ gift: KakaLiveGift) -> Bool {
        let locale = Locale(identifier: "en_US_POSIX")
        guard !busy, gift.available,
              let cost = Decimal(string: gift.cost, locale: locale),
              let balance = Decimal(string: balance, locale: locale) else { return false }
        return cost * Decimal(quantity) <= balance
    }

    private func fetch(initial: Bool = false) async {
        guard !busy, let session = store.session?.token else { return }
        busy = true
        feedback = ""
        gifts = []
        hasCatalog = false
        defer { busy = false }
        do {
            let fields = try await liveRoomGiftRequest("gift.catalog", room: room, visit: visit, session: session)
            guard !Task.isCancelled, store.session?.token == session, KakaNativeRoomRuntime.shared.owns(visit) else { return }
            balance = fields["balance"] as? String ?? ""
            host = fields["host"] as? String ?? room.host?.name ?? "the host"
            duelGift = fields["duel"] as? Bool == true
            gifts = KakaLiveGift.catalog(fields)
            hasCatalog = true
            if selectedGift == nil { giftID = nil }
            if !gifts.isEmpty, initial, let initialGiftID {
                if let selected = gifts.first(where: { $0.id == initialGiftID && $0.available }) {
                    giftID = selected.id
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
        guard canReview(gift), gifts.contains(where: { $0.id == gift.id }),
              let session = store.session?.token else { return }
        busy = true
        feedback = ""
        gifts = []
        hasCatalog = false
        defer {
            busy = false
            giftID = nil
            choice = nil
        }
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
    var scrolls = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            if scrolls {
                ScrollView { panelBody }
            } else {
                panelBody.frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .background(KakaTheme.base.ignoresSafeArea())
        .foregroundStyle(KakaTheme.ink)
        .onAppear { store.setSheet(sheetID, presented: true) }
        .onDisappear { store.setSheet(sheetID, presented: false) }
    }

    private var panelBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(.title2.weight(.semibold))
                    .lineLimit(scrolls ? nil : 2)
                    .accessibilityAddTraits(.isHeader)
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

    private var featuredEntries: [Entry] {
        guard !textSize.isAccessibilitySize else { return [] }
        var leaders: [Entry] = []
        for entry in entries.prefix(3) {
            guard entry.rank == Int64(leaders.count + 1) else { break }
            leaders.append(entry)
        }
        return leaders
    }

    var body: some View {
        Group {
            if room != nil {
                rankingPanel.modifier(KakaRoomUtilityPresentation())
            } else {
                rankingPanel
            }
        }
        .task(id: selection) { await load(selection) }
    }

    private var rankingPanel: some View {
        KakaRoomSheet(title: duel != nil ? "PK contributions" : (room == nil ? "Rankings" : "Room rankings"), locked: false) {
            rankingFilters
            if loadedSelection != selection {
                rankingCover { KakaRhythmProgress(title: "Loading rankings") }
            } else if !loadError.isEmpty {
                rankingCover {
                    Text(loadError).font(.subheadline).foregroundStyle(KakaTheme.muted)
                    KakaRoomButton(title: "Try again") { Task { await load(selection) } }
                }
            } else if entries.isEmpty && ownEntry == nil {
                rankingCover {
                    Text(duel != nil ? "No contributions yet." : "No rankings for this period.")
                        .font(.headline)
                }
            } else {
                standings
            }
        }
    }

    private var rankingFilters: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !boards.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(boards, id: \.self) { board in
                            rankingChoice(board.title, selected: selection.board == board, board: true) {
                                selection.board = board
                            }
                        }
                    }
                }
                .background(alignment: .bottom) { KakaTheme.line.frame(height: 1) }
                .accessibilityLabel("Ranking category")
            }
            if duel == nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(periods, id: \.self) { period in
                            rankingChoice(period.title(liveRoom: room?.kind == .live), selected: selection.period == period, board: false) {
                                selection.period = period
                            }
                        }
                    }
                }
                .accessibilityLabel("Ranking period")
            }
        }
    }

    private func rankingChoice(_ title: String, selected: Bool, board: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(board ? .subheadline.weight(.semibold) : .footnote.weight(.semibold))
                .foregroundStyle(selected ? accent : KakaTheme.muted)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background {
                    if selected && !board { Capsule().fill(accent.opacity(0.14)) }
                }
                .frame(minWidth: 44, minHeight: 44)
                .background(alignment: .bottom) {
                    if selected && board { Capsule().fill(accent).frame(height: 2) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(KakaRoomCardPressStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var standings: some View {
        let leaders = featuredEntries
        let remaining = entries.dropFirst(leaders.count)
        return VStack(alignment: .leading, spacing: 12) {
            if let leader = leaders.first {
                rankingCover { rankedPortrait(leader, featured: true) }
                if leaders.count > 1 {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 8)], spacing: 8) {
                        ForEach(leaders.dropFirst()) { entry in
                            rankedPortrait(entry, featured: false)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 13))
                        }
                    }
                }
            }
            if !remaining.isEmpty {
                LazyVStack(spacing: 0) {
                    ForEach(remaining) { entry in
                        rankingRow(entry)
                        if entry.id != remaining.last?.id {
                            KakaTheme.line.frame(height: 1).padding(.horizontal, 11)
                        }
                    }
                }
                .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            }
            if let ownEntry {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your rank")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 11)
                        .padding(.top, 9)
                        .accessibilityAddTraits(.isHeader)
                    rankingRow(ownEntry)
                }
                .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
            } else if room == nil {
                Text("You aren’t ranked for this period.").font(.footnote).foregroundStyle(KakaTheme.muted)
            }
        }
    }

    private func rankingCover<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return VStack(alignment: .leading, spacing: 9, content: content)
            .frame(maxWidth: 233, alignment: .leading)
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 128, alignment: .leading)
            .background {
                GeometryReader { canvas in
                    KakaNativeImage(asset: "room-rank-cover.jpg")
                        .scaledToFill()
                        .frame(width: canvas.size.width, height: canvas.size.height, alignment: .trailing)
                        .clipped()
                        .overlay {
                            LinearGradient(colors: [KakaTheme.base.opacity(0.88), KakaTheme.base.opacity(0.68), .clear],
                                           startPoint: .leading, endPoint: .trailing)
                        }
                }
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(KakaTheme.line).allowsHitTesting(false) }
    }

    private func rankedPortrait(_ entry: Entry, featured: Bool) -> some View {
        HStack(spacing: 9) {
            rankingPortrait(entry, size: featured ? 56 : 38)
            VStack(alignment: .leading, spacing: 3) {
                if let rank = entry.rank {
                    Text("No. \(rank.formatted())")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(accent)
                        .accessibilityLabel("Rank \(rank.formatted())")
                }
                Text(entry.name.isEmpty ? "Member" : entry.name)
                    .font(featured ? .title3.weight(.semibold) : .subheadline.weight(.semibold))
                    .lineLimit(2)
                if !entry.score.isEmpty { rankingScore(entry.score) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func rankingPortrait(_ entry: Entry, size: CGFloat) -> some View {
        KakaNativeImage(asset: "stage-people.png", remote: entry.portrait)
            .scaledToFill()
            .frame(width: size, height: size)
            .background(KakaTheme.base)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(true)
    }

    private func rankingRow(_ entry: Entry) -> some View {
        HStack(spacing: 9) {
            if let rank = entry.rank {
                Text(rank.formatted())
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(accent)
                    .accessibilityLabel("Rank \(rank.formatted())")
                    .frame(minWidth: 25, alignment: .leading)
            }
            if !textSize.isAccessibilitySize {
                rankingPortrait(entry, size: 36)
            }
            if textSize.isAccessibilitySize || entry.score.count > 10 {
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
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(minHeight: 52)
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
            KakaGiftCollectionCover(name: host.name, portrait: host.portrait)
            giftDirection
            if loading || !loaded && loadError.isEmpty {
                KakaRhythmProgress(title: "Loading gift wall")
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
            } else if !loadError.isEmpty {
                KakaGiftTrayStatus(message: loadError)
                KakaRoomButton(title: "Try again") { Task { await load() } }
            } else {
                let gifts = received ? receivedGifts : sentGifts
                if gifts.isEmpty {
                    KakaGiftTrayEmpty(title: received ? "No gifts received yet." : "No gifts sent yet.")
                } else {
                    giftDisplay(gifts)
                }
            }
        }
        .task(id: host.id) { await load() }
    }

    private var giftDirection: some View {
        KakaRoomActionGroup {
            directionButton("Received", count: receivedGifts.count, showsReceived: true)
            directionButton("Sent", count: sentGifts.count, showsReceived: false)
        }
        .padding(4)
        .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Gift direction")
    }

    private func directionButton(_ title: String, count: Int, showsReceived: Bool) -> some View {
        let selected = received == showsReceived
        let showsCount = loaded && !loading && loadError.isEmpty
        let shape = RoundedRectangle(cornerRadius: 12)
        return Button { received = showsReceived } label: {
            VStack(spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(selected ? KakaTheme.ink : KakaTheme.muted)
                if showsCount {
                    Text(count.formatted())
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(selected ? KakaTheme.liveAccent : KakaTheme.muted)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(selected ? KakaTheme.accent.opacity(0.12) : .clear, in: shape)
            .overlay {
                if selected {
                    shape.strokeBorder(KakaTheme.accent.opacity(0.24)).allowsHitTesting(false)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(KakaRoomCardPressStyle())
        .accessibilityLabel(title)
        .accessibilityValue(showsCount ? (count == 1 ? "1 gift entry" : "\(count.formatted()) gift entries") : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func giftDisplay(_ gifts: [Gift]) -> some View {
        if textSize.isAccessibilitySize {
            LazyVStack(spacing: 10) {
                ForEach(gifts) { gift in giftCard(gift) }
            }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 98), spacing: 10, alignment: .top)], spacing: 10) {
                ForEach(gifts) { gift in giftCard(gift) }
            }
        }
    }

    private func giftCard(_ gift: Gift) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Group {
            if textSize.isAccessibilitySize {
                HStack(spacing: 12) {
                    giftArtwork(gift)
                        .frame(width: 65)
                    giftCaption(gift, alignment: .leading)
                }
                .padding(8)
            } else {
                VStack(spacing: 0) {
                    giftArtwork(gift)
                    giftCaption(gift, alignment: .center)
                }
            }
        }
        .background(KakaTheme.surface, in: shape)
        .clipShape(shape)
        .overlay { shape.strokeBorder(KakaTheme.line).allowsHitTesting(false) }
        .accessibilityElement(children: .combine)
    }

    private func giftArtwork(_ gift: Gift) -> some View {
        KakaNativeImage(asset: "stage-gift.png", remote: gift.art)
            .scaledToFit()
            .frame(height: 62)
            .padding(7)
            .frame(maxWidth: .infinity)
            .background(KakaTheme.base.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(true)
    }

    private func giftCaption(_ gift: Gift, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(gift.name)
                .font(.footnote.weight(.semibold))
                .lineLimit(textSize.isAccessibilitySize ? nil : 2)
                .multilineTextAlignment(alignment == .leading ? .leading : .center)
                .fixedSize(horizontal: false, vertical: true)
            if let quantity = gift.quantity {
                Text("×\(quantity.formatted())")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(KakaTheme.liveAccent)
                    .accessibilityLabel("Quantity \(quantity.formatted())")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 55, alignment: alignment == .leading ? .leading : .center)
    }

    private func load() async {
        guard !loading else { return }
        guard let session = store.session?.token else {
            loadError = "The gift wall is unavailable."
            return
        }
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
    @Environment(\.dynamicTypeSize) private var textSize
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
            KakaGiftCollectionCover(name: room.host?.name ?? room.title, portrait: room.host?.portrait ?? room.cover)
            if loading || !loaded && loadError.isEmpty {
                KakaRhythmProgress(title: "Loading gift wishes")
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
            } else if !loadError.isEmpty {
                KakaGiftTrayStatus(message: loadError)
                KakaRoomButton(title: "Try again") { Task { await load() } }
            } else if wishes.isEmpty {
                KakaGiftTrayEmpty(title: "The host hasn’t added any gift wishes.")
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(wishes) { wish in wishRow(wish) }
                }
            }
        }
        .task { await load() }
    }

    private func wishRow(_ wish: Wish) -> some View {
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        let art = KakaNativeImage(asset: "stage-gift.png", remote: wish.image)
            .scaledToFit()
            .frame(width: 62, height: 62)
            .padding(5)
            .background(KakaTheme.base, in: RoundedRectangle(cornerRadius: 11))
            .accessibilityHidden(true)
        return Group {
            if textSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    art
                    wishDetails(wish)
                }
            } else {
                HStack(spacing: 12) {
                    art
                    wishDetails(wish)
                }
            }
        }
        .padding(10)
        .background(KakaTheme.surface, in: shape)
        .overlay { shape.strokeBorder(KakaTheme.line).allowsHitTesting(false) }
        .accessibilityElement(children: .combine)
    }

    private func wishDetails(_ wish: Wish) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(wish.name)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let completed = wish.completed, let target = wish.target {
                Text("\(completed.formatted()) of \(target.formatted()) received")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(KakaTheme.muted)
                ProgressView(value: Double(min(completed, target)), total: Double(target))
                    .tint(KakaTheme.liveAccent)
                    .accessibilityHidden(true)
                if completed >= target {
                    HStack(spacing: 4) {
                        KakaNativeImage(asset: "action-check.png")
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                            .accessibilityHidden(true)
                        Text("Goal reached")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(KakaTheme.liveAccent)
                    }
                }
            } else if let completed = wish.completed {
                Text("\(completed.formatted()) received")
                    .font(.caption.monospacedDigit()).foregroundStyle(KakaTheme.muted)
            } else if let target = wish.target {
                Text("Goal: \(target.formatted())")
                    .font(.caption.monospacedDigit()).foregroundStyle(KakaTheme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

private struct KakaGiftCollectionCover: View {
    @Environment(\.dynamicTypeSize) private var textSize
    let name: String
    let portrait: URL?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 19, style: .continuous)
        HStack(spacing: 10) {
            if !textSize.isAccessibilitySize, let portrait {
                KakaNativeImage(asset: "stage-people.png", remote: portrait)
                    .scaledToFill()
                    .frame(width: 37, height: 37)
                    .clipShape(Circle())
                        .accessibilityHidden(true)
            }
            Text(name)
                .font(.title3.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .bottomLeading)
        .background {
            GeometryReader { geometry in
                KakaNativeImage(asset: "room-gift-wall.jpg")
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .trailing)
                    .clipped()
                    .overlay {
                        LinearGradient(colors: [KakaTheme.base.opacity(0.65), KakaTheme.base.opacity(0.50), .clear],
                                       startPoint: .bottomLeading, endPoint: .topTrailing)
                    }
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(KakaTheme.line).allowsHitTesting(false) }
    }
}
