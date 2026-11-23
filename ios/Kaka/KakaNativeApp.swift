import SwiftUI

struct KakaNativeApp: View {
    @ObservedObject var store: KakaNativeStore

    var body: some View {
        ZStack {
            KakaTheme.base.ignoresSafeArea()
            KakaNativePane {
                if store.restoring || store.startupError != nil {
                    KakaStartupView(error: store.restoring ? nil : store.startupError) {
                        Task { await store.restore() }
                    }
                } else if let session = store.session {
                    KakaWorkspaceView()
                        .id(session.token)
                } else {
                    KakaEntryView()
                }
            }
        }
        .environmentObject(store)
        .preferredColorScheme(.dark)
        .task {
            if store.restoring { await store.restore() }
        }
    }
}

private struct KakaNativePane<Content: View>: View {
    @Environment(\.layoutDirection) private var layoutDirection
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(iOS 27.1, *) {
            GeometryReader { geometry in
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(paneInsets(for: geometry))
            }
        } else {
            content()
        }
    }

    @available(iOS 27.1, *)
    private func paneInsets(for geometry: GeometryProxy) -> EdgeInsets {
        let container = CGRect(origin: .zero, size: geometry.size)
        var pane = container
        for region in geometry.reservedRegions(kind: .division, layoutDirectionBehavior: .fixed) where region.isActive {
            let cut = pane.intersection(region.frame)
            guard !cut.isNull, !cut.isEmpty else { continue }
            if cut.width >= pane.width * 0.6 && cut.width >= cut.height {
                let above = cut.minY - pane.minY
                let below = pane.maxY - cut.maxY
                if above >= below {
                    pane.size.height = above
                } else {
                    pane.origin.y = cut.maxY
                    pane.size.height = below
                }
            } else if cut.height >= pane.height * 0.6 {
                let left = cut.minX - pane.minX
                let right = pane.maxX - cut.maxX
                if left >= right {
                    pane.size.width = left
                } else {
                    pane.origin.x = cut.maxX
                    pane.size.width = right
                }
            }
        }
        // System safe areas handle edge hardware. Account for wider obstructions only when they still overlap the pane.
        for region in geometry.reservedRegions(kind: .occlusion, layoutDirectionBehavior: .fixed) where region.isActive {
            let cut = pane.intersection(region.frame)
            guard !cut.isNull, !cut.isEmpty, cut.width >= pane.width * 0.6 else { continue }
            if cut.minY <= pane.minY {
                pane.size.height = pane.maxY - cut.maxY
                pane.origin.y = cut.maxY
            } else if cut.maxY >= pane.maxY {
                pane.size.height = cut.minY - pane.minY
            }
        }
        guard pane.width > 0, pane.height > 0 else { return .init() }
        let left = pane.minX
        let right = container.maxX - pane.maxX
        return EdgeInsets(
            top: pane.minY, leading: layoutDirection == .rightToLeft ? right : left,
            bottom: container.maxY - pane.maxY, trailing: layoutDirection == .rightToLeft ? left : right
        )
    }
}

private struct KakaWorkspaceView: View {
    @EnvironmentObject private var store: KakaNativeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var notifications = KakaPushNotifications.shared
    @Namespace private var dockSelection
    @State private var visited: Set<KakaNativeTab> = [.live, .voice]
    @State private var minimizedLiveRoom: KakaNativeRoom?
    @State private var incomingCall: KakaLivePrivateCall?
    @State private var callListeningSession: UUID?
    @State private var receivingCalls = false
    @State private var callWorkspaceInForeground = false
    @State private var publicGiftChat = KakaRoomChat { _, _ in nil }
    @State private var publicGift: KakaRoomChat.PublicGift?
    @State private var showingCallHistory = false

    private struct NotificationRouteTask: Equatable {
        let tap: String?
        let canNavigate: Bool
    }

    private let tabs: [KakaNativeTab] = [.live, .voice, .write, .profile]
    private let dockItemHeight: CGFloat = 48
    private let dockInnerPadding: CGFloat = 5
    private let dockOuterPadding: CGFloat = 4

    private var routedLiveRoom: KakaNativeRoom? {
        guard case .room(let room)? = store.route, room.kind == .live else { return nil }
        return room
    }

    private var presentedLiveRoom: KakaNativeRoom? {
        if case .room? = store.route { return routedLiveRoom }
        return minimizedLiveRoom
    }

    var body: some View {
        GeometryReader { viewport in
            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    ForEach(tabs, id: \.self) { tab in
                        if visited.contains(tab) || tab == store.tab {
                            tabContent(tab)
                                .opacity(tab == store.tab ? 1 : 0)
                                .allowsHitTesting(tab == store.tab)
                                .accessibilityHidden(tab != store.tab)
                        }
                    }
                }
                .background { workspaceBackdrop }
                .safeAreaInset(edge: .bottom, spacing: 0) { dock }
                .allowsHitTesting(store.route == nil)
                .accessibilityHidden(store.route != nil)

                if let route = store.route, routedLiveRoom == nil {
                    ZStack {
                        KakaTheme.base.ignoresSafeArea()
                        detailContent(route)
                    }
                    .accessibilityAction(.escape) { store.back() }
                }

                if let room = presentedLiveRoom {
                    livePlayer(room, viewport: viewport.size)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .allowsHitTesting(incomingCall == nil)
        .accessibilityHidden(incomingCall != nil)
        .onAppear {
            visited.insert(store.tab)
            receivingCalls = scenePhase == .active
            callWorkspaceInForeground = scenePhase != .background
        }
        .onChange(of: store.tab) { tab in
            visited.insert(tab)
            publicGift = nil
        }
        .onChange(of: store.route) { route in
            publicGift = nil
            if case .room? = route { minimizedLiveRoom = nil }
        }
        .overlay(alignment: .top) {
            if let notice = store.notice {
                Text(notice)
                    .font(.callout)
                    .foregroundColor(KakaTheme.ink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .modifier(KakaGlass(radius: 18))
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .allowsHitTesting(false)
                    .accessibilityAddTraits(.updatesFrequently)
            } else if let gift = publicGift, showsPublicGifts {
                HStack(spacing: 8) {
                    if let artwork = gift.artwork {
                        AsyncImage(url: artwork) { phase in
                            if let image = phase.image { image.resizable().scaledToFit() }
                        }
                        .frame(width: 28, height: 28)
                        .accessibilityHidden(true)
                    }
                    Text(verbatim: gift.label).font(.callout.weight(.semibold))
                }
                .foregroundStyle(KakaTheme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .modifier(KakaGlass(radius: 18))
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .allowsHitTesting(false)
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .overlay {
            if let call = incomingCall {
                KakaIncomingCallPane(call: call, stillActive: {
                    callWorkspaceInForeground && callListeningSession == store.session?.token && incomingCall === call
                }, suspendRoom: {
                    minimizedLiveRoom = nil
                    if store.route != nil { store.select(store.tab) }
                    await KakaNativeRoomRuntime.shared.leaveForCall()
                }, dismiss: {
                    if incomingCall === call { incomingCall = nil }
                })
            }
        }
        .task(id: store.session?.token) {
            if let token = store.session?.token { await listenForCalls(session: token) }
        }
        .task(id: scenePhase == .active) {
            if scenePhase == .active, let token = store.session?.token { await notifications.activate(token) }
        }
        .task(id: NotificationRouteTask(tap: notifications.pendingTap?.id, canNavigate: canOpenPushDestination)) {
            if canOpenPushDestination, let tap = notifications.pendingTap { await openNotification(tap) }
        }
        .sheet(isPresented: $showingCallHistory) { KakaPrivateCallHistoryScreen() }
        .task(id: scenePhase == .background) {
            guard scenePhase != .background, let token = store.session?.token else { return }
            await publicGiftChat.watchPublicGifts(session: token) { gift in
                guard store.session?.token == token, showsPublicGifts else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { publicGift = gift }
            }
        }
        .task(id: publicGift?.id) {
            guard let id = publicGift?.id else { return }
            do { try await Task.sleep(nanoseconds: 3_600_000_000) } catch { return }
            if publicGift?.id == id {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { publicGift = nil }
            }
        }
        .onChange(of: scenePhase) { phase in
            receivingCalls = phase == .active
            callWorkspaceInForeground = phase != .background
            if phase == .background { publicGift = nil }
            if phase == .background, let call = incomingCall, call.phase != .waiting {
                Task { await call.hangUp() }
            }
        }
        .onDisappear {
            receivingCalls = false
            callWorkspaceInForeground = false
            guard let token = callListeningSession else { return }
            let call = incomingCall
            Task { @MainActor in
                if let call { await call.hangUp() }
                KakaLiveCallSignal.shared.disconnect(session: token)
            }
        }
    }

    private var showsPublicGifts: Bool {
        guard scenePhase == .active, incomingCall == nil, !store.hasOpenSheet else { return false }
        if case .room? = store.route { return false }
        return store.route == nil && (store.tab == .live || store.tab == .voice)
    }

    private var canOpenPushDestination: Bool {
        scenePhase == .active && incomingCall == nil && !store.hasOpenSheet && !showingCallHistory
    }

    private func openNotification(_ tap: KakaPushNotifications.Tap) async {
        guard let session = store.session?.token else { return }
        defer { if !Task.isCancelled { notifications.consume(tap) } }
        guard Date().timeIntervalSince(tap.receivedAt) <= 300,
              tap.appID == nil || tap.appID == KakaServiceBridge.configuration["appId"] else { return }
        do {
            let user = try await KakaAccountStore.shared.remoteUserID(session: session)
            guard tap.recipient == nil || tap.recipient == user, pushRouteIsCurrent(tap, session: session) else { return }
            switch tap.destination {
            case .calls:
                showingCallHistory = true
            case .room(let id, let voice):
                let room = try await resolveNotificationRoom(id: id, voice: voice)
                guard pushRouteIsCurrent(tap, session: session) else { return }
                guard let room, !store.isHidden(room.id) else {
                    store.notify("This room is unavailable.")
                    return
                }
                store.remember([room])
                store.select(voice ? .voice : .live)
                if voice { store.open(.room(room)) }
                else { store.openLive(room, lineup: [room]) }
            case .host(let id):
                let data = try await store.request("getHost", ["voyagerBadge": id])
                guard pushRouteIsCurrent(tap, session: session) else { return }
                guard let fields = data as? [String: Any], let host = KakaNativeHost.parse(fields), host.id == id else {
                    store.notify("This profile is unavailable.")
                    return
                }
                store.open(.host(host))
            }
        } catch {
            guard pushRouteIsCurrent(tap, session: session) else { return }
            store.expireIfNeeded(error)
            if store.session?.token == session { store.notify(store.message(error)) }
        }
    }

    private func pushRouteIsCurrent(_ tap: KakaPushNotifications.Tap, session: UUID) -> Bool {
        !Task.isCancelled && store.session?.token == session && notifications.pendingTap?.id == tap.id && canOpenPushDestination
    }

    private func resolveNotificationRoom(id: Int64, voice: Bool) async throws -> KakaNativeRoom? {
        if voice {
            if let known = store.knownRooms["party-\(id)"] { return known }
            let list = try await store.request("listVoiceRooms", ["pageSize": 20, "languageCode": "", "version": "v2"])
            return KakaRoomFields.rows(list, keys: ["rows", "records", "list", "data", "result", "items"])
                .compactMap { KakaNativeRoom.parse($0, kind: .voice) }.first { $0.serverID == id }
        }
        let data = try await store.request("getLiveRoom", ["habitatTag": id])
        guard let fields = data as? [String: Any] else { return nil }
        return [fields, fields["venueBrief"] as? [String: Any]].compactMap { $0 }
            .compactMap { KakaNativeRoom.parse($0, kind: .live) }.first { $0.serverID == id }
    }

    @MainActor
    private func listenForCalls(session: UUID) async {
        let signal = KakaLiveCallSignal.shared
        callListeningSession = session
        while !Task.isCancelled, store.session?.token == session {
            do {
                try await signal.connect(session: session)
                guard !Task.isCancelled, store.session?.token == session else { return }
                signal.onInvitation = { invite in
                    let enabled = UserDefaults.standard.object(forKey: KakaCallPreferences.incomingEnabled) as? Bool ?? true
                    if receivingCalls, enabled, !store.hasOpenSheet, incomingCall == nil, store.session?.token == session {
                        let call = KakaLivePrivateCall()
                        if (try? call.receiveIncoming(invite, session: session)) != nil {
                            incomingCall = call
                            return
                        }
                    }
                    Task { try? await signal.decline(invite) }
                }
                try await Task.sleep(nanoseconds: 24_000_000_000)
            } catch {
                do { try await Task.sleep(nanoseconds: 12_000_000_000) } catch { return }
            }
        }
    }

    private func livePlayer(_ room: KakaNativeRoom, viewport: CGSize) -> some View {
        let minimized = routedLiveRoom == nil
        let horizontalInset: CGFloat = 12
        let dockSpace = dockItemHeight + 2 * (dockInnerPadding + dockOuterPadding)
        let roomAboveDock = viewport.height - dockSpace >= 112
        let bottomInset = (store.route == nil && roomAboveDock ? dockSpace : 0) + 8
        let miniWidth = min(210, max(164, viewport.width * 0.38), max(0, viewport.width - 2 * horizontalInset))
        let miniHeight = min(136, max(104, miniWidth * 0.66), max(0, viewport.height - bottomInset - 8))
        return KakaNativeRoomView(room: room, isMinimized: minimized, onMinimize: {
            guard routedLiveRoom?.id == room.id else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
                minimizedLiveRoom = room
                store.back()
            }
        }, onRestore: {
            guard minimizedLiveRoom?.id == room.id else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
                store.open(.room(room))
                minimizedLiveRoom = nil
            }
        }, onClose: {
            closeLivePlayer(room)
        })
        .id(room.id)
        .frame(width: minimized ? miniWidth : viewport.width, height: minimized ? miniHeight : viewport.height)
        .padding(.trailing, minimized ? horizontalInset : 0)
        .padding(.bottom, minimized ? bottomInset : 0)
        .accessibilityAction(.escape) { closeLivePlayer(room) }
    }

    private func closeLivePlayer(_ room: KakaNativeRoom) {
        if minimizedLiveRoom?.id == room.id { minimizedLiveRoom = nil }
        if routedLiveRoom?.id == room.id { store.back() }
    }

    private var workspaceBackdrop: some View {
        GeometryReader { geometry in
            let height = min(184, geometry.size.height * 0.42)
            Image("WorkspaceStudioLight")
                .resizable()
                .scaledToFill()
                .frame(width: geometry.size.width, height: height, alignment: .top)
                .clipped()
                .overlay {
                    LinearGradient(stops: [
                        .init(color: KakaTheme.base.opacity(0.52), location: 0),
                        .init(color: KakaTheme.base.opacity(0.67), location: 0.38),
                        .init(color: KakaTheme.base, location: 0.94),
                    ], startPoint: .top, endPoint: .bottom)
                }
        }
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func tabContent(_ tab: KakaNativeTab) -> some View {
        switch tab {
        case .live: KakaNativeDirectoryView(kind: .live)
        case .voice: KakaNativeDirectoryView(kind: .voice)
        case .write: KakaNativeNotebookView()
        case .profile: KakaNativeProfileView()
        }
    }

    @ViewBuilder
    private func detailContent(_ route: KakaNativeRoute) -> some View {
        switch route {
        case .room(let room): KakaNativeRoomView(room: room).id(room.id)
        case .host(let host):
            KakaNativeHostView(host: host).id(host.id)
                .safeAreaInset(edge: .top, spacing: 4) { backBar }
        }
    }

    private var backBar: some View {
        HStack {
            Button("Back") { store.back() }
                .buttonStyle(KakaEntryButtonStyle())
                .accessibilityLabel("Go back")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private var dock: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.self) { tab in
                let (title, image) = dockLabel(for: tab)
                let selected = tab == store.tab
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.24)) { store.select(tab) }
                } label: {
                    Image(image)
                        .resizable()
                        .renderingMode(.original)
                        .scaledToFit()
                        .frame(width: 28, height: 28)
                        .frame(minWidth: 44, maxWidth: .infinity, minHeight: dockItemHeight)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(KakaTheme.accent.opacity(0.22))
                                    .overlay(Capsule().strokeBorder(KakaTheme.ink.opacity(0.15), lineWidth: 1))
                                    .matchedGeometryEffect(id: "selected-tab", in: dockSelection)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(dockInnerPadding)
        .frame(maxWidth: 312)
        .modifier(KakaGlass(radius: 31))
        .padding(.horizontal, 12)
        .padding(.vertical, dockOuterPadding)
    }

    private func dockLabel(for tab: KakaNativeTab) -> (String, String) {
        switch tab {
        case .live: return ("Live", "Dock-stage")
        case .voice: return ("Voice", "Dock-voice")
        case .write: return ("Write", "Dock-notebook")
        case .profile: return ("Profile", "Dock-crate")
        }
    }
}

private struct KakaStartupView: View {
    let error: String?
    let retry: () -> Void

    var body: some View {
        Group {
            if let error {
                VStack(spacing: 18) {
                    Text(error)
                        .font(.callout)
                        .foregroundColor(KakaTheme.muted)
                        .multilineTextAlignment(.center)
                    Button("Try again", action: retry)
                        .buttonStyle(KakaEntryButtonStyle())
                }
                .frame(maxWidth: 320)
                .padding(20)
            } else {
                GeometryReader { geometry in
                    let side = min(96, geometry.size.width * 0.48, geometry.size.height * 0.4)
                    ZStack {
                        Image("KakaBrand")
                            .resizable()
                            .scaledToFit()
                            .frame(width: side, height: side)
                            .accessibilityHidden(true)
                        KakaRhythmProgress(title: "Loading Kaka")
                            .scaleEffect(min(1, side / 64))
                            .offset(y: side / 2 + 26)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 23.0 / 255, green: 21.0 / 255, blue: 51.0 / 255).ignoresSafeArea())
    }
}

struct KakaRhythmProgress: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.16, paused: reduceMotion)) { context in
            let beat = Int(context.date.timeIntervalSinceReferenceDate * 6) % 4
            HStack(spacing: 0) {
                ForEach(0..<4) { index in
                    Image("StartupRhythm")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 64, height: 24)
                        .offset(x: CGFloat(24 - index * 16))
                        .frame(width: 16, height: 24)
                        .clipped()
                        .opacity(reduceMotion || index == beat ? 1 : 0.56)
                }
            }
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

private enum KakaEntryPage: Equatable {
    case welcome, login, register

    var artwork: String {
        switch self {
        case .welcome: return "entry-cypher-portrait.jpg"
        case .login: return "entry-reunion.jpg"
        case .register: return "entry-writing-table.jpg"
        }
    }

    var title: String { self == .register ? "Create account" : "Log in" }
}

private struct KakaEntryView: View {
    @EnvironmentObject private var store: KakaNativeStore
    @Environment(\.dynamicTypeSize) private var dynamicType
    @FocusState private var focused: Field?
    @State private var page: KakaEntryPage = .welcome
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var showsPassword = false
    @State private var accepted = false
    @State private var policy: KakaNativePolicy?

    private enum Field: Hashable { case name, email, password }

    var body: some View {
        ZStack {
            artwork
                .ignoresSafeArea()

            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if page == .welcome {
                            welcome
                                .frame(maxWidth: 460, alignment: .leading)
                        } else {
                            Button("Back") { go(.welcome) }
                                .buttonStyle(KakaEntryButtonStyle())
                                .accessibilityLabel("Back to welcome")
                            Spacer(minLength: 12)
                            form.frame(maxWidth: 436)
                        }
                    }
                    .padding(.horizontal, geometry.size.width < 300 ? 12 : 22)
                    .padding(.vertical, 14)
                    .frame(minHeight: geometry.size.height, alignment: .bottom)
                    .frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(store.busy)
            .allowsHitTesting(!store.busy)

            if store.busy && page != .welcome {
                KakaTheme.base.opacity(0.62).ignoresSafeArea()
                VStack(spacing: 6) {
                    KakaRhythmProgress(title: page == .login ? "Signing in…" : "Creating your account…")
                    Text(page == .login ? "Signing in…" : "Creating your account…")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                }
                .foregroundColor(KakaTheme.ink)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .modifier(KakaGlass(radius: 24))
                .padding(16)
            }
        }
        .sheet(item: $policy) { KakaNativePolicyView(policy: $0) }
    }

    private var artwork: some View {
        GeometryReader { geometry in
            KakaNativeImage(asset: page.artwork)
                .scaledToFill()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .overlay {
                    LinearGradient(
                        stops: [
                            .init(color: KakaTheme.base.opacity(0.19), location: 0),
                            .init(color: .clear, location: 0.28),
                            .init(color: KakaTheme.base.opacity(0.8), location: 0.78),
                            .init(color: KakaTheme.base, location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pull up a chair.")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Text("Explore rap rooms, follow hosts, and write your next verse.")
                .font(.body)
                .foregroundColor(KakaTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            authError
            Button("Create account") { go(.register) }
                .buttonStyle(KakaEntryButtonStyle(expands: true))
                .padding(.top, 4)
            Button("Log in") { go(.login) }
                .buttonStyle(KakaEntryLinkStyle())
                .frame(maxWidth: .infinity)
        }
        .foregroundColor(KakaTheme.ink)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(page.title)
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .accessibilityAddTraits(.isHeader)
            fields

            if page == .register {
                Text("Use at least 8 characters for your password.")
                    .font(.footnote)
                    .foregroundColor(KakaTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            authError

            Button(page.title, action: submit)
                .buttonStyle(KakaEntryButtonStyle(expands: true))
            consent
            Button(page == .register ? "Log in instead" : "Create an account instead") {
                go(page == .register ? .login : .register)
            }
            .buttonStyle(KakaEntryLinkStyle())
            .frame(maxWidth: .infinity)
        }
        .foregroundColor(KakaTheme.ink)
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    @ViewBuilder
    private var authError: some View {
        if let error = store.error {
            Text(error)
                .font(.callout)
                .foregroundColor(Color(red: 1, green: 0.72, blue: 0.78))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 0) {
            if page == .register {
                field("Stage name") {
                    TextField("", text: $name, prompt: Text("Your stage name"))
                        .textContentType(.nickname)
                        .submitLabel(.next)
                        .focused($focused, equals: .name)
                        .onSubmit { focused = .email }
                        .accessibilityLabel("Stage name")
                }
                Divider()
            }
            field("Email") {
                TextField("", text: $email, prompt: Text("you@example.com"))
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                    .submitLabel(.next)
                    .focused($focused, equals: .email)
                    .onSubmit { focused = .password }
                    .accessibilityLabel("Email")
            }
            Divider()
            field("Password") {
                HStack(spacing: 8) {
                    Group {
                        if showsPassword {
                            TextField("", text: $password, prompt: Text("Password"))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } else {
                            SecureField("", text: $password, prompt: Text("Password"))
                        }
                    }
                    .textContentType(page == .register ? .newPassword : .password)
                    .submitLabel(.go)
                    .focused($focused, equals: .password)
                    .onSubmit(submit)
                    .accessibilityLabel("Password")
                    Button(showsPassword ? "Hide" : "Show") { showsPassword.toggle() }
                        .buttonStyle(KakaEntryLinkStyle())
                        .accessibilityLabel(showsPassword ? "Hide password" : "Show password")
                }
            }
        }
        .padding(.horizontal, 12)
        .background(KakaTheme.base.opacity(0.34), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.caption.weight(.semibold)).foregroundColor(KakaTheme.muted)
            content().font(.body).frame(minHeight: 44)
        }
        .padding(.top, 9)
    }

    private var consent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(accepted ? "Agreed to terms and privacy" : "Agree to terms and privacy") { accepted.toggle() }
                .buttonStyle(KakaEntryButtonStyle())
                .accessibilityLabel("Agree to the Terms of Use and Privacy Policy")
                .accessibilityAddTraits(accepted ? .isSelected : [])
            if dynamicType.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 0) { policyLinks }
            } else {
                HStack(spacing: 10) { policyLinks }
            }
        }
    }

    @ViewBuilder
    private var policyLinks: some View {
        Button("Terms of Use") { showPolicy(.terms) }
            .buttonStyle(KakaEntryLinkStyle())
        Button("Privacy Policy") { showPolicy(.privacy) }
            .buttonStyle(KakaEntryLinkStyle())
    }

    private func showPolicy(_ document: KakaNativePolicy) {
        focused = nil
        policy = document
    }

    private func go(_ next: KakaEntryPage) {
        focused = nil
        password = ""
        showsPassword = false
        accepted = false
        store.error = nil
        page = next
    }

    private func submit() {
        guard !store.busy else { return }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let stageName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard accepted else {
            store.error = "Agree to the Terms of Use and Privacy Policy to continue."
            focused = nil
            return
        }
        if page == .register && !(1...24).contains(stageName.utf16.count) {
            store.error = "Enter a stage name of up to 24 characters."
            focused = .name
            return
        }
        if address.utf8.count > 254 || address.range(of: #"^[^@\s]+@[^@\s.]+(?:\.[^@\s.]+)+$"#, options: .regularExpression) == nil {
            store.error = "Enter a valid email address."
            focused = .email
            return
        }
        let passwordLength = page == .register ? (8...64) : (6...64)
        if password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !passwordLength.contains(password.count) {
            store.error = page == .register ? "Use 8 to 64 characters." : "Enter a password with 6 to 64 characters."
            focused = .password
            return
        }
        let submittedPassword = password
        let submittedName = page == .register ? stageName : nil
        focused = nil
        Task {
            await store.authenticate(email: address, password: submittedPassword, name: submittedName, accepted: true)
        }
    }
}

private struct KakaEntryButtonStyle: ButtonStyle {
    var expands = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundColor(KakaTheme.ink)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 15)
            .padding(.vertical, 8)
            .frame(maxWidth: expands ? .infinity : nil, minHeight: expands ? 50 : 44)
            .modifier(KakaGlass(interactive: true, radius: 25))
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

private struct KakaEntryLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundColor(KakaTheme.accent)
            .multilineTextAlignment(.center)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}
