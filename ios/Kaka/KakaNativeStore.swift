import SwiftUI
import UIKit

enum KakaNativeTab: String, CaseIterable {
    case live, voice, write, profile
}

enum KakaNativeRoute: Equatable {
    case room(KakaNativeRoom)
    case host(KakaNativeHost)
}

@MainActor
final class KakaNativeStore: ObservableObject {
    @Published private(set) var session: KakaAccountStore.Session?
    @Published private(set) var restoring = true
    @Published private(set) var busy = false
    @Published var error: String?
    @Published private(set) var startupError: String?
    @Published var tab: KakaNativeTab = .live
    @Published private(set) var route: KakaNativeRoute?
    @Published private(set) var notice: String?
    @Published private(set) var record: [String: Any] = [:]
    @Published private(set) var knownRooms: [String: KakaNativeRoom] = [:]
    @Published private(set) var following: [KakaNativeHost] = []
    @Published var verseRoom: KakaNativeRoom?
    @Published var verseDraftID: String?
    @Published var practiceScore: [String: Any]?

    private var recordRevision = 0
    private var recordTail: Task<Void, Never>?
    private var followingLoad: Task<[KakaNativeHost], Error>?
    private(set) var followingLoaded = false
    private var followChanges: Set<Int64> = []
    private var noticeTimer: Task<Void, Never>?
    private var history: [KakaNativeRoute] = []
    private var liveRoomOrder: [String] = []
    private var restoreAttempt = false

    var followedIDs: Set<Int64> { Set(following.map(\.id)) }
    var recentVoiceRoomIDs: [String] { record["recentVoiceRoomIDs"] as? [String] ?? [] }

    func restore() async {
        guard !restoreAttempt, session == nil else { return }
        restoreAttempt = true
        restoring = true
        startupError = nil
        defer {
            restoreAttempt = false
            restoring = false
        }
        do {
            guard case .session(let stored) = try await KakaAccountStore.shared.perform(.session) else {
                throw KakaAccountStore.Failure.storage
            }
            if let stored { try await activate(stored) }
        } catch {
            startupError = message(error)
        }
    }

    func authenticate(email: String, password: String, name: String?, accepted: Bool) async {
        guard !busy, session == nil else { return }
        error = nil
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let stageName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard accepted else {
            error = "Agree to the Terms of Use and Privacy Policy to continue."
            return
        }
        guard address.utf8.count <= 254,
              address.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil,
              ((stageName == nil ? 6 : 8)...64).contains(password.count), password.utf8.count <= 512,
              stageName.map({ (1...24).contains($0.utf16.count) && $0.utf8.count <= 96 }) ?? true else {
            error = "Check your account details and try again."
            return
        }

        busy = true
        defer { busy = false }
        let request: KakaAccountStore.Request
        if let stageName {
            request = .register(name: stageName, email: address, password: password)
        } else {
            request = .login(email: address, password: password)
        }
        do {
            guard case .session(let account?) = try await KakaAccountStore.shared.perform(request) else {
                throw KakaAccountStore.Failure.authRejected
            }
            try await activate(account)
        } catch {
            self.error = message(error)
        }
    }

    private func activate(_ account: KakaAccountStore.Session) async throws {
        let result = try await KakaAccountStore.shared.perform(.read(account.token))
        guard case .record(let snapshot) = result else { throw KakaAccountStore.Failure.storage }
        if let serialized = snapshot.recordJSON {
            guard var saved = try JSONSerialization.jsonObject(with: Data(serialized.utf8)) as? [String: Any] else {
                throw KakaAccountStore.Failure.storage
            }
            if saved["following"] == nil { saved["following"] = [String]() }
            record = saved
        } else {
            record = [
                "schema": 1,
                "profile": ["name": String(account.name.prefix(24)), "bio": "", "style": ""],
                "favorites": [String](), "following": [String](),
                "notes": [[String: Any]](), "scores": [[String: Any]](), "reports": [[String: Any]](),
            ]
        }
        recordRevision = snapshot.revision
        tab = .live
        session = account
        Task { await KakaCommerce.shared.resume(session: account.token) }
    }

    func select(_ tab: KakaNativeTab) {
        self.tab = tab
        history.removeAll()
        route = nil
        practiceScore = nil
    }

    func open(_ route: KakaNativeRoute) {
        if route == self.route { return }
        if let current = self.route { history.append(current) }
        if case .room(let room) = route, practiceScore?["roomID"] as? String != room.id {
            practiceScore = nil
        }
        self.route = route
    }

    func openLive(_ room: KakaNativeRoom, lineup: [KakaNativeRoom]) {
        liveRoomOrder = lineup.flatMap { $0.kind == .live ? [$0.id] : [] }
        open(.room(room))
    }

    func adjacentLiveRoom(to room: KakaNativeRoom, forward: Bool) -> KakaNativeRoom? {
        guard room.kind == .live, let position = liveRoomOrder.firstIndex(of: room.id) else { return nil }
        let candidates = forward ? Array(liveRoomOrder.dropFirst(position + 1)) : Array(liveRoomOrder.prefix(position).reversed())
        return candidates.lazy.compactMap { id in
            isHidden(id) ? nil : knownRooms[id]
        }.first
    }

    func switchLiveRoom(from room: KakaNativeRoom, forward: Bool) {
        guard case .room(let current) = route, current.id == room.id,
              let next = adjacentLiveRoom(to: room, forward: forward) else { return }
        route = .room(next)
    }

    func back() {
        route = history.popLast()
        if route == nil { practiceScore = nil }
    }

    func openVerse(_ room: KakaNativeRoom) {
        verseDraftID = nil
        verseRoom = room
        select(.write)
    }

    func openDraft(_ id: String) {
        verseRoom = nil
        verseDraftID = id
        select(.write)
    }

    func rehearse(_ score: [String: Any], in room: KakaNativeRoom) {
        guard room.kind == .voice, !isHidden(room.id) else { return }
        select(.voice)
        var copy = score
        copy["roomID"] = room.id
        practiceScore = copy
        open(.room(room))
    }

    func remember(_ rooms: [KakaNativeRoom]) {
        for room in rooms { knownRooms[room.id] = room }
    }

    func recordVoiceRoomVisit(_ room: KakaNativeRoom) {
        guard room.kind == .voice, let token = session?.token else { return }
        let id = room.id
        enqueueRecordUpdate(session: token) { record in
            var recent = record["recentVoiceRoomIDs"] as? [String] ?? []
            recent.removeAll { $0 == id }
            recent.insert(id, at: 0)
            record["recentVoiceRoomIDs"] = Array(recent.prefix(KakaRecordStore.recentVoiceRoomLimit))
        }
    }

    func isHidden(_ roomID: String) -> Bool {
        (record["reports"] as? [[String: Any]] ?? []).contains { $0["roomID"] as? String == roomID }
    }

    func updateRecord(_ change: @escaping (inout [String: Any]) throws -> Void) async throws {
        guard let token = session?.token else { throw KakaAccountStore.Failure.sessionChanged }
        let next = enqueueRecordUpdate(session: token, change)
        do {
            try await next.value
        } catch {
            if session?.token == token { expireIfNeeded(error) }
            throw error
        }
    }

    @discardableResult
    private func enqueueRecordUpdate(session token: UUID,
                                     _ change: @escaping (inout [String: Any]) throws -> Void) -> Task<Void, Error> {
        let previous = recordTail
        let next = Task { @MainActor in
            await previous?.value
            guard self.session?.token == token else { throw KakaAccountStore.Failure.sessionChanged }
            var draft = self.record
            try change(&draft)
            guard JSONSerialization.isValidJSONObject(draft) else { throw KakaRecordStore.Failure.invalidRecord }
            let data = try JSONSerialization.data(withJSONObject: draft, options: [.sortedKeys])
            let result = try await KakaAccountStore.shared.perform(
                .write(token, revision: self.recordRevision, record: String(decoding: data, as: UTF8.self))
            )
            guard self.session?.token == token, case .record(let saved) = result else {
                throw KakaAccountStore.Failure.sessionChanged
            }
            self.recordRevision = saved.revision
            self.record = draft
        }
        recordTail = Task { _ = try? await next.value }
        return next
    }

    func request(_ operation: String, _ input: [String: Any] = [:]) async throws -> Any {
        guard let token = session?.token else { throw KakaAccountStore.Failure.sessionChanged }
        do {
            let result: Any
            if operation == "creator.blocked" || operation == "creator.block" {
                guard let id = input["userID"] as? Int64, id > 0, let route else {
                    throw KakaAccountStore.Failure.invalidInput
                }
                let currentHostID: Int64?
                switch route {
                case .host(let host):
                    currentHostID = host.id
                case .room(let room) where operation == "creator.blocked":
                    currentHostID = room.host?.id ?? knownRooms[room.id]?.host?.id
                default:
                    currentHostID = nil
                }
                guard currentHostID == id else { throw KakaAccountStore.Failure.invalidInput }
                if operation == "creator.block" {
                    guard input.count == 2, let blocked = input["blocked"] as? Bool else {
                        throw KakaAccountStore.Failure.invalidInput
                    }
                    try await KakaRoomChat.setBlocked(userID: id, blocked: blocked, session: token)
                    result = blocked
                } else {
                    guard input.count == 1 else { throw KakaAccountStore.Failure.invalidInput }
                    result = try await KakaRoomChat.isBlocked(userID: id, session: token)
                }
            } else {
                let data = try await KakaServiceBridge.perform(operation: operation, input: input, session: token)
                result = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            }
            guard session?.token == token else { throw CancellationError() }
            try Task.checkCancellation()
            return result
        } catch {
            if session?.token == token { expireIfNeeded(error) }
            throw error
        }
    }

    func loadFollowing(force: Bool = false) async throws {
        if followingLoaded && !force { return }
        if let followingLoad {
            _ = try await followingLoad.value
            return
        }
        guard let token = session?.token else { throw KakaAccountStore.Failure.sessionChanged }
        let load = Task { @MainActor in
            let response = try await self.request("listFollowing", ["signalKind": 3])
            guard self.session?.token == token else { throw CancellationError() }
            var ids: Set<Int64> = []
            let hosts = Self.followingRows(response).compactMap { KakaNativeHost.parse($0) }
                .filter { ids.insert($0.id).inserted }
            self.following = hosts
            self.followingLoaded = true
            return hosts
        }
        followingLoad = load
        defer { if session?.token == token { followingLoad = nil } }
        _ = try await load.value
    }

    private static func followingRows(_ value: Any) -> [[String: Any]] {
        if let list = value as? [[String: Any]] { return list }
        guard let container = value as? [String: Any] else { return [] }
        for key in ["gridBands", "records", "roster", "data", "result", "nebulaPieces"] {
            if let child = container[key], child is [Any] || child is [String: Any] {
                return followingRows(child)
            }
        }
        return []
    }

    func toggleFollow(_ host: KakaNativeHost) async throws {
        guard let token = session?.token else { throw KakaAccountStore.Failure.sessionChanged }
        guard followChanges.insert(host.id).inserted else { return }
        defer { if session?.token == token { followChanges.remove(host.id) } }
        try await loadFollowing()
        let follow = !followedIDs.contains(host.id)
        _ = try await request("setRelationship", ["fanHandle": host.id, "supportMode": follow ? 1 : 2])
        guard session?.token == token else { throw CancellationError() }
        if follow { following.append(host) }
        else { following.removeAll { $0.id == host.id } }
    }

    func signOut(deleting: Bool = false) async throws {
        guard let token = session?.token else { return }
        await recordTail?.value
        guard session?.token == token else { return }
        _ = try await KakaAccountStore.shared.perform(deleting ? .delete(token) : .signOut(token))
        guard session?.token == token else { return }
        clearSession()
        await KakaRoomChat.signOut(session: token)
    }

    func expireIfNeeded(_ error: Error) {
        guard let token = session?.token, let failure = error as? KakaAccountStore.Failure,
              failure == .expired || failure == .sessionChanged else { return }
        clearSession()
        self.error = "Your session ended. Please log in again."
        Task { await KakaRoomChat.signOut(session: token) }
    }

    private func clearSession() {
        session = nil
        error = nil
        noticeTimer?.cancel()
        notice = nil
        record = [:]
        recordRevision = 0
        recordTail = nil
        knownRooms = [:]
        liveRoomOrder = []
        followingLoad?.cancel()
        followingLoad = nil
        followingLoaded = false
        following.removeAll()
        followChanges.removeAll()
        verseRoom = nil
        verseDraftID = nil
        select(.live)
    }

    func notify(_ text: String) {
        noticeTimer?.cancel()
        notice = text
        noticeTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            if !Task.isCancelled { self?.notice = nil }
        }
    }

    func message(_ error: Error) -> String {
        let code: String
        switch error {
        case let failure as KakaAccountStore.Failure: code = failure.rawValue
        case let failure as KakaRealtimeMedia.Failure: code = failure.rawValue
        case let failure as KakaAvatarUpload.Failure: code = failure.rawValue
        case let failure as KakaLiveGifts.Failure: code = failure.rawValue
        case let detail as LocalizedError:
            return detail.errorDescription ?? "The request could not be completed. Try again."
        default:
            return "The request could not be completed. Try again."
        }
        return Self.messages[code] ?? "The service couldn’t complete the request. Try again."
    }

    private static let messages = [
        "auth-input": "Check your account details and try again.",
        "auth-duplicate": "An account already uses this email. Log in to continue.",
        "auth-rejected": "That email or password was rejected. Check your details and try again.",
        "service-unconfigured": "The service connection has not been configured.",
        "service-network": "Couldn’t reach the service. Check your connection and try again.",
        "service-unavailable": "This service isn’t available right now.",
        "service-session-expired": "Your session ended. Please log in again.",
        "session-changed": "Your session ended. Please log in again.",
        "storage-error": "Couldn’t open your saved work. Try again.",
        "media-unavailable": "Room audio and video aren’t available in this build.",
        "media-invalid-room": "This room is no longer available.",
        "media-busy": "Another room connection is in progress.",
        "media-connection": "Couldn’t connect to the room. Try joining again.",
        "media-timeout": "The room took too long to respond. Try joining again.",
        "media-cancelled": "The room connection ended.",
        "media-permission": "Allow microphone access in Settings to speak in a voice room.",
        "media-seat": "That seat is no longer available. Try another seat.",
        "media-heartbeat": "Your microphone connection ended. Join the seat again to speak.",
        "avatar-busy": "A profile photo is already being updated.",
        "avatar-presentation": "Couldn’t open your photos. Try again.",
        "avatar-image": "That photo couldn’t be opened. Choose another photo.",
        "avatar-upload": "Couldn’t upload the photo. Check your connection and try again.",
        "avatar-response": "The profile service couldn’t save that photo.",
        "gift-unavailable": "Gifts aren’t available in this live room.",
        "gift-refresh": "The gift or its price changed. Refresh the list to review it again.",
        "gift-busy": "Another gift request is in progress.",
        "gift-balance": "Your balance is too low for this gift.",
    ]
}

enum KakaTheme {
    static let base = Color(red: 0.063, green: 0.043, blue: 0.102)
    static let surface = Color(red: 0.118, green: 0.086, blue: 0.169)
    static let ink = Color(red: 0.986, green: 0.983, blue: 1)
    static let muted = Color(red: 0.793, green: 0.751, blue: 0.853)
    static let accent = Color(red: 0.847, green: 0.753, blue: 1)
    static let liveAccent = Color(red: 0.99, green: 0.68, blue: 0.53)
    static let voiceAccent = Color(red: 0.48, green: 0.89, blue: 0.92)
    static let actionFill = Color(red: 0.443, green: 0.231, blue: 0.796)
    static let line = accent.opacity(0.16)
}

struct KakaGlass: ViewModifier {
    var interactive = false
    var radius: CGFloat = 20
    var tint: Color? = nil
    var clear = false

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if reduceTransparency {
            content.background(KakaTheme.surface, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.22), lineWidth: 1).allowsHitTesting(false))
        } else if #available(iOS 26.0, *) {
            let material: Glass = clear ? .clear : .regular
            content.glassEffect(material.tint(tint).interactive(interactive), in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.24), lineWidth: 1).allowsHitTesting(false))
        }
    }
}

struct KakaNativeImage: View {
    let asset: String
    var remote: URL? = nil

    @ViewBuilder
    var body: some View {
        if let remote, remote.scheme?.lowercased() == "https", remote.host != nil,
           remote.user == nil, remote.password == nil {
            AsyncImage(url: remote) { phase in
                if let image = phase.image { image.resizable() }
                else { local }
            }
        } else {
            local
        }
    }

    @ViewBuilder
    private var local: some View {
        if let image = Self.bundled(asset) {
            Image(uiImage: image).resizable()
        } else if let image = UIImage(named: asset) {
            Image(uiImage: image).resizable()
        } else {
            KakaTheme.surface
        }
    }

    private static let cache = NSCache<NSString, UIImage>()

    private static func bundled(_ name: String) -> UIImage? {
        if let cached = cache.object(forKey: name as NSString) { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "images"),
              let image = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(image, forKey: name as NSString)
        return image
    }
}

enum KakaNativePolicy: String, Identifiable {
    case terms, privacy

    var id: String { rawValue }
    var title: String { self == .terms ? "Terms of Use" : "Privacy Policy" }

    @MainActor var published: URL? {
        let key = self == .terms ? "KakaTermsURL" : "KakaPrivacyURL"
        let values = [Bundle.main.object(forInfoDictionaryKey: key) as? String,
                      KakaServiceBridge.configuration[rawValue + "URL"]]
        for case let value? in values {
            if let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
               url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
               url.user == nil, url.password == nil {
                return url
            }
        }
        return nil
    }
}

struct KakaNativePolicyView: View {
    let policy: KakaNativePolicy
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 44)
                        .modifier(KakaGlass(interactive: true, radius: 22))
                }
                Text(policy.title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                if let url = policy.published {
                    Link("Read \(policy.title)", destination: url)
                        .foregroundStyle(KakaTheme.accent)
                        .frame(minHeight: 44)
                } else {
                    Text("The \(policy.title) will be available here once published.")
                        .foregroundStyle(KakaTheme.muted)
                }
            }
            .frame(maxWidth: 540)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .foregroundStyle(KakaTheme.ink)
        .background(KakaTheme.base.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}
