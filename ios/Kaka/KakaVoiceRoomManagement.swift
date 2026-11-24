import SwiftUI

struct KakaVoiceManagementContext: Equatable {
    let roomID: Int64
    let visit: UUID
    let session: UUID

    enum Failure: LocalizedError {
        case permission, layoutChanged, staleSeatRequest

        var errorDescription: String? {
            switch self {
            case .permission: return "Room settings are available to the owner and administrators."
            case .layoutChanged: return "The room layout changed. Reopen room settings to try again."
            case .staleSeatRequest: return "This seat request changed. Refresh the list to review it."
            }
        }
    }

    enum Change {
        case announcement(String)
        case lock(Bool, password: String)
        case seatApproval(Bool)
        case background(KakaVoiceCreation.Background)
        case seatRequest(SeatRequest, approve: Bool)
    }

    struct SeatRequest: Identifiable {
        let id: Int64
        let name: String
        let portrait: URL?
        let seat: Int64

        init?(_ fields: [String: Any]) {
            guard let id = KakaRoomFields.id(fields, keys: ["userId"]) else { return nil }
            self.id = id
            let label = KakaRoomFields.text(fields, "nickname", "nickName")
            name = label.isEmpty ? "Member \(id)" : String(label.prefix(80))
            portrait = KakaRoomFields.url(KakaRoomFields.text(fields, "avatar", "icon"))
            seat = KakaRemoteClient.userID(fields["seatIndex"]) ?? 0
        }
    }

    struct MemberRole {
        let userID: Int64
        let value: Int64?
        let platformAdmin: Bool

        var canManage: Bool { value == 1 || value == 2 || platformAdmin }
        var canAssignAdministrators: Bool { value == 1 || platformAdmin }
        var isProtected: Bool { value == nil || value == 1 || platformAdmin }
        var isRoomAdmin: Bool { value == 2 }
    }

    @MainActor
    func state(in store: KakaNativeStore) -> KakaRealtimeMedia.VoiceManagementState? {
        let runtime = KakaNativeRoomRuntime.shared
        guard !Task.isCancelled, store.session?.token == session, runtime.owns(visit) else { return nil }
        return runtime.media.voiceManagementState(roomID: roomID, session: session)
    }

    @MainActor @discardableResult
    func requirePermission(in store: KakaNativeStore) async throws -> MemberRole {
        guard state(in: store) != nil else { throw CancellationError() }
        let user = try await KakaAccountStore.shared.remoteUserID(session: session)
        let role = try await roomRole(for: user, in: store)
        guard role.canManage else { throw Failure.permission }
        return role
    }

    @MainActor
    func roomRole(for user: Int64, in store: KakaNativeStore) async throws -> MemberRole {
        guard state(in: store) != nil else { throw CancellationError() }
        let result = try await store.request("voice.management.role", ["roomId": roomID, "userId": user])
        guard state(in: store) != nil else { throw CancellationError() }
        guard let card = result as? [String: Any] else { throw KakaRemoteClient.Fault.response }
        if let reportedRoom = KakaRoomFields.id(card, keys: ["roomId"]), reportedRoom != roomID {
            throw KakaRemoteClient.Fault.response
        }
        if let reportedUser = KakaRoomFields.id(card, keys: ["userId"]), reportedUser != user {
            throw KakaRemoteClient.Fault.response
        }
        return MemberRole(userID: user, value: KakaRemoteClient.userID(card["roomRoleType"]),
                          platformAdmin: Self.flag(card, "isPlatformAdmin") == true)
    }

    @MainActor
    func loadAnnouncement(in store: KakaNativeStore) async throws -> String {
        try await requirePermission(in: store)
        let result = try await store.request("voice.management.announcement", ["roomId": roomID])
        guard state(in: store) != nil else { throw CancellationError() }
        if let text = result as? String { return text }
        if let fields = result as? [String: Any] { return KakaRoomFields.text(fields, "announcement") }
        if result is NSNull { return "" }
        throw KakaRemoteClient.Fault.response
    }

    @MainActor
    func backgrounds(in store: KakaNativeStore) async throws -> [KakaVoiceCreation.Background] {
        try await requirePermission(in: store)
        let result = try await store.request("voice.creation.backgrounds", ["pageSize": 100, "offset": 0])
        guard state(in: store) != nil else { throw CancellationError() }
        guard result is [String: Any] || result is [[String: Any]] else { throw KakaRemoteClient.Fault.response }
        return KakaVoiceCreation.backgrounds(KakaRoomFields.rows(result, keys: ["rows", "records", "list", "data", "result", "items"]))
    }

    @MainActor
    func loadQueue(in store: KakaNativeStore) async throws -> [SeatRequest] {
        try await requirePermission(in: store)
        return try await queue(in: store)
    }

    @MainActor
    private func queue(in store: KakaNativeStore) async throws -> [SeatRequest] {
        guard state(in: store) != nil else { throw CancellationError() }
        let result = try await store.request("voice.management.seatQueue", ["roomId": roomID])
        guard state(in: store) != nil else { throw CancellationError() }
        guard result is [String: Any] || result is [[String: Any]] else { throw KakaRemoteClient.Fault.response }
        var seen = Set<Int64>()
        return KakaRoomFields.rows(result, keys: ["rows", "records", "list", "data", "result", "items", "seats", "roomSeatList", "seatList"])
            .compactMap(SeatRequest.init)
            .filter { seen.insert($0.id).inserted }
    }

    @MainActor
    func apply(_ change: Change, in store: KakaNativeStore) async throws {
        try await requirePermission(in: store)
        guard let state = state(in: store) else { throw CancellationError() }
        var fields: [String: Any] = ["roomId": roomID]
        let operation: String
        switch change {
        case .announcement(let value):
            operation = "voice.management.setAnnouncement"
            fields["announcement"] = value
        case .lock(let locked, let password):
            operation = "voice.management.setLock"
            fields["lockRoomFlag"] = locked ? 1 : 0
            if locked { fields["password"] = password }
        case .seatApproval(let enabled):
            operation = "voice.management.setSeatApproval"
            fields["enable"] = enabled ? 1 : 0
        case .background(let background):
            guard state.hasRoomIdentity else { throw Failure.layoutChanged }
            operation = "voice.management.setBackground"
            fields["bgImgId"] = background.id
            fields["yxRoomId"] = state.messagingRoom
            fields["roomTempId"] = state.templateID
        case .seatRequest(let request, let approve):
            let pending = try await queue(in: store)
            guard let latest = pending.first(where: { $0.id == request.id }), latest.seat == request.seat else {
                throw Failure.staleSeatRequest
            }
            guard let current = self.state(in: store) else { throw CancellationError() }
            guard state.hasRoomIdentity, state.sameRoom(as: current) else { throw Failure.layoutChanged }
            operation = approve ? "voice.management.approveSeat" : "voice.management.declineSeat"
            fields["targetUserId"] = latest.id
            fields["yxRoomId"] = state.messagingRoom
            fields["roomTempId"] = state.templateID
            if approve {
                fields["seatIndex"] = latest.seat
                fields["operatorType"] = 1
            }
        }
        _ = try await store.request(operation, fields)
        guard let current = self.state(in: store) else { throw CancellationError() }
        let media = KakaNativeRoomRuntime.shared.media
        switch change {
        case .announcement(let value):
            media.updateVoiceManagementState(roomID: roomID, session: session, announcement: value)
        case .lock(let locked, _):
            media.updateVoiceManagementState(roomID: roomID, session: session, locked: locked)
        case .seatApproval(let enabled):
            media.updateVoiceManagementState(roomID: roomID, session: session, seatApproval: enabled)
        case .background(let background):
            guard state.sameRoom(as: current) else { return }
            media.updateVoiceManagementState(roomID: roomID, session: session, background: background.image)
        case .seatRequest:
            break
        }
    }

    static func validPassword(_ password: String) -> Bool {
        password.count == 4 && password.allSatisfy(\.isNumber)
    }

    static func flag(_ fields: [String: Any], _ keys: String...) -> Bool? {
        for key in keys {
            let value = (fields[key] as? NSNumber)?.stringValue ?? (fields[key] as? String)
            switch value?.lowercased() {
            case "1", "true": return true
            case "0", "false": return false
            default: continue
            }
        }
        return nil
    }
}

@MainActor
struct KakaVoiceManagementOption: View {
    @EnvironmentObject private var store: KakaNativeStore
    @State private var authorizedContext: KakaVoiceManagementContext?
    let context: KakaVoiceManagementContext
    let action: () -> Void

    var body: some View {
        Group {
            if authorizedContext == context, context.state(in: store) != nil {
                KakaRoomButton(title: "Room settings", asset: "action-tune.png", action: action)
            }
        }
        .task(id: context.visit) {
            do {
                try await context.requirePermission(in: store)
                authorizedContext = context
            } catch {
                if context.state(in: store) != nil { store.expireIfNeeded(error) }
            }
        }
    }
}

struct KakaVoiceControlArtwork: View {
    let asset: String

    var body: some View {
        ZStack(alignment: .leading) {
            KakaNativeImage(asset: "room-control-cover.jpg")
                .scaledToFill()
                .frame(height: 104)
                .frame(maxWidth: .infinity)
                .clipped()
            KakaNativeImage(asset: asset)
                .scaledToFit()
                .frame(width: 34, height: 34)
                .frame(width: 54, height: 54)
                .modifier(KakaGlass(radius: 17, tint: KakaTheme.voiceAccent.opacity(0.18)))
                .padding(.leading, 16)
        }
        .modifier(KakaVoiceControlSurface(radius: 20))
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct KakaVoiceControlSurface: ViewModifier {
    var radius: CGFloat = 16

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content.background(KakaTheme.surface, in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(KakaTheme.line).allowsHitTesting(false))
    }
}

struct KakaVoiceControlNotice: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.subheadline)
            .foregroundStyle(KakaTheme.muted)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(KakaVoiceControlSurface())
            .accessibilityAddTraits(.updatesFrequently)
    }
}

struct KakaVoiceControlIdentity: View {
    let name: String
    let portrait: URL?
    var subtitle: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            KakaNativeImage(asset: "member-mark.jpg", remote: portrait)
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.subheadline.weight(.semibold))
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(KakaTheme.muted) }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct KakaVoiceControlDestination: View {
    let title: String
    let asset: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                KakaNativeImage(asset: asset)
                    .scaledToFit()
                    .frame(width: 25, height: 25)
                    .frame(width: 42, height: 42)
                    .modifier(KakaGlass(radius: 12, tint: KakaTheme.voiceAccent.opacity(0.13)))
                    .accessibilityHidden(true)
                Text(title).font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                KakaNativeImage(asset: "action-forward.png")
                    .frame(width: 17, height: 17)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

@MainActor
struct KakaVoiceRoomManagementSheet: View {
    @EnvironmentObject private var store: KakaNativeStore
    @Environment(\.dynamicTypeSize) private var textSize
    let context: KakaVoiceManagementContext
    let onLockChange: (Bool) -> Void

    @State private var roomSettings: KakaRealtimeMedia.VoiceManagementState?
    @State private var announcement = ""
    @State private var savedAnnouncement = ""
    @State private var password = ""
    @State private var backgrounds: [KakaVoiceCreation.Background]?
    @State private var seatRequests: [KakaVoiceManagementContext.SeatRequest]?
    @State private var managementPanel: ManagementPanel?
    @State private var feedback = ""
    @State private var loading = true
    @State private var writing = false

    private enum ManagementPanel: String, Identifiable {
        case members, seats, layouts
        var id: Self { self }
    }

    var body: some View {
        KakaRoomSheet(title: "Room settings", locked: writing) {
            KakaVoiceControlArtwork(asset: "action-tune.png")
            if !feedback.isEmpty {
                KakaVoiceControlNotice(message: feedback)
            }
            if loading {
                KakaRhythmProgress(title: "Loading room settings")
            } else if let roomSettings {
                if roomSettings.hasRoomIdentity { managementDestinations }
                announcementField
                if let locked = roomSettings.locked { lockControls(locked: locked) }
                if let approval = roomSettings.seatApproval { seatApprovalControl(enabled: approval) }
                if roomSettings.hasRoomIdentity {
                    seatQueue
                    backgroundControls
                }
            } else {
                KakaRoomButton(title: "Try again", asset: "action-forward.png") { Task { await load() } }
            }
        }
        .interactiveDismissDisabled(writing)
        .sheet(item: $managementPanel) { panel in
            switch panel {
            case .members: KakaVoiceRoomModeration(context: context)
            case .seats: KakaVoiceRoomSeatControls(context: context)
            case .layouts: KakaVoiceRoomLayoutSheet(context: context)
            }
        }
        .task { await load() }
    }

    private var managementDestinations: some View {
        VStack(spacing: 0) {
            KakaVoiceControlDestination(title: "Manage mic seats", asset: "action-seat.png") { managementPanel = .seats }
            Divider().background(KakaTheme.line).padding(.horizontal, 12)
            KakaVoiceControlDestination(title: "Manage members", asset: "stage-people.png") { managementPanel = .members }
            Divider().background(KakaTheme.line).padding(.horizontal, 12)
            KakaVoiceControlDestination(title: "Mic seat layout", asset: "stage-tools.png") { managementPanel = .layouts }
        }
        .modifier(KakaVoiceControlSurface())
        .disabled(writing)
    }

    private var announcementField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Announcement").font(.headline).accessibilityAddTraits(.isHeader)
            TextEditor(text: $announcement)
                .frame(minHeight: textSize.isAccessibilitySize ? 110 : 75)
                .padding(8)
                .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Room announcement")
                .disabled(writing)
            KakaRoomButton(title: "Save announcement", asset: "action-check.png") {
                Task { await apply(.announcement(announcement), success: "Announcement saved.") }
            }
            .disabled(writing || announcement == savedAnnouncement)
        }
        .padding(14)
        .modifier(KakaVoiceControlSurface())
    }

    private func lockControls(locked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Room access").font(.headline).accessibilityAddTraits(.isHeader)
            Text(locked ? "Locked" : "Open").font(.subheadline).foregroundStyle(KakaTheme.muted)
            SecureField(locked ? "New four-digit password" : "Four-digit password", text: $password)
                .keyboardType(.numberPad)
                .textContentType(.password)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                .disabled(writing)
            KakaRoomButton(title: locked ? "Change password" : "Lock room") {
                Task { await apply(.lock(true, password: password), success: locked ? "Password updated." : "Room locked.") }
            }
            .disabled(writing || !KakaVoiceManagementContext.validPassword(password))
            if locked {
                KakaRoomButton(title: "Unlock room") {
                    Task { await apply(.lock(false, password: ""), success: "Room unlocked.") }
                }
                .disabled(writing)
            }
        }
        .padding(14)
        .modifier(KakaVoiceControlSurface())
    }

    private func seatApprovalControl(enabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Seat requests").font(.headline).accessibilityAddTraits(.isHeader)
            Text(enabled ? "Approval required" : "Open seats can be joined directly")
                .font(.subheadline).foregroundStyle(KakaTheme.muted)
            KakaRoomButton(title: enabled ? "Turn off seat approval" : "Require seat approval") {
                Task { await apply(.seatApproval(!enabled), success: "Seat settings saved.") }
            }
            .disabled(writing)
        }
        .padding(14)
        .modifier(KakaVoiceControlSurface())
    }

    private var seatQueue: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let seatRequests {
                if seatRequests.isEmpty {
                    KakaVoiceControlNotice(message: "No pending seat requests.")
                }
                ForEach(seatRequests) { request in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 8) {
                            if let portrait = request.portrait {
                                KakaNativeImage(asset: "member-mark.jpg", remote: portrait)
                                    .scaledToFill()
                                    .frame(width: 36, height: 36)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .accessibilityHidden(true)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(request.name).font(.subheadline.weight(.semibold))
                                if request.seat > 0 {
                                    Text("Seat \(request.seat)").font(.caption).foregroundStyle(KakaTheme.muted)
                                }
                            }
                        }
                        KakaRoomActionGroup { seatQueueActions(request) }
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            KakaRoomButton(title: seatRequests == nil ? "Review seat requests" : "Refresh seat requests") {
                Task { await loadQueue() }
            }
            .disabled(writing)
        }
    }

    @ViewBuilder
    private func seatQueueActions(_ request: KakaVoiceManagementContext.SeatRequest) -> some View {
        KakaRoomButton(title: "Approve", asset: "action-check.png") {
            Task { await apply(.seatRequest(request, approve: true), success: "Seat request approved.") }
        }
        .disabled(writing || request.seat < 0)
        .accessibilityLabel("Approve seat request from \(request.name)")
        KakaRoomButton(title: "Decline", asset: "action-close.png") {
            Task { await apply(.seatRequest(request, approve: false), success: "Seat request declined.") }
        }
        .disabled(writing)
        .accessibilityLabel("Decline seat request from \(request.name)")
    }

    @ViewBuilder
    private var backgroundControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Background").font(.headline).accessibilityAddTraits(.isHeader)
            if let backgrounds {
                if backgrounds.isEmpty {
                    KakaVoiceControlNotice(message: "No room backgrounds available.")
                }
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(backgrounds) { background in
                        Button {
                            Task { await apply(.background(background), success: "Background updated.") }
                        } label: {
                            HStack(spacing: 10) {
                                KakaNativeImage(asset: "voice-deck.jpg", remote: background.image)
                                    .scaledToFill()
                                    .frame(width: 72, height: 45)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .accessibilityHidden(true)
                                Text(background.name).font(.subheadline.weight(.semibold))
                                Spacer(minLength: 0)
                            }
                            .padding(8)
                            .modifier(KakaVoiceControlSurface())
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Applies this room background")
                        .disabled(writing)
                    }
                }
            } else {
                KakaRoomButton(title: "Choose a background") { Task { await loadBackgrounds() } }
                    .disabled(writing)
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        feedback = ""
        do {
            let value = try await context.loadAnnouncement(in: store)
            guard let state = context.state(in: store) else { return }
            roomSettings = state
            announcement = value
            savedAnnouncement = value
        } catch is CancellationError {
            return
        } catch {
            feedback = store.message(error)
        }
    }

    private func loadBackgrounds() async {
        guard !writing else { return }
        writing = true
        defer { writing = false }
        feedback = ""
        do {
            let options = try await context.backgrounds(in: store)
            guard context.state(in: store) != nil else { return }
            backgrounds = options
        } catch is CancellationError {
            return
        } catch {
            feedback = store.message(error)
        }
    }

    private func loadQueue() async {
        guard !writing else { return }
        writing = true
        defer { writing = false }
        feedback = ""
        do {
            seatRequests = try await context.loadQueue(in: store)
        } catch is CancellationError {
            return
        } catch {
            feedback = store.message(error)
        }
    }

    private func apply(_ change: KakaVoiceManagementContext.Change, success: String) async {
        guard !writing else { return }
        writing = true
        defer { writing = false }
        feedback = ""
        do {
            try await context.apply(change, in: store)
            guard let state = context.state(in: store) else { return }
            roomSettings = state
            switch change {
            case .announcement(let value): savedAnnouncement = value
            case .lock(let locked, _):
                password = ""
                onLockChange(locked)
            case .seatApproval, .background: break
            case .seatRequest(let request, _):
                seatRequests?.removeAll { $0.id == request.id }
            }
            feedback = success
        } catch is CancellationError {
            return
        } catch {
            feedback = store.message(error)
        }
    }
}

extension KakaVoiceManagementContext {
    struct InviteCandidate: Identifiable {
        let id: Int64
        let name: String
        let portrait: URL?

        init?(_ fields: [String: Any]) {
            guard let id = KakaRoomFields.id(fields, keys: ["userId"]) else { return nil }
            self.id = id
            let label = KakaRoomFields.text(fields, "nickname", "nickName", "name")
            name = label.isEmpty ? "Member \(id)" : String(label.prefix(80))
            portrait = KakaRoomFields.url(KakaRoomFields.text(fields, "avatar", "icon"))
        }
    }

    struct InvitationUnavailable: LocalizedError {
        var errorDescription: String? { "This person is no longer available to invite. Refresh the list to continue." }
    }

    @MainActor
    func invitationCandidates(in store: KakaNativeStore) async throws -> [InviteCandidate] {
        guard state(in: store) != nil else { throw CancellationError() }
        let currentUser = try await KakaAccountStore.shared.remoteUserID(session: session)
        guard state(in: store) != nil else { throw CancellationError() }
        let result = try await store.request("voice.invitation.candidates", ["roomId": roomID])
        guard state(in: store) != nil else { throw CancellationError() }
        if result is NSNull { return [] }
        guard result is [String: Any] || result is [[String: Any]] else { throw KakaRemoteClient.Fault.response }
        let rows = KakaRoomFields.rows(result, keys: ["rows", "records", "list", "data", "result", "items", "viewers"])
        var seen = Set<Int64>()
        return rows.compactMap(InviteCandidate.init).filter { $0.id != currentUser && seen.insert($0.id).inserted }
    }

    @MainActor
    func invite(_ candidate: InviteCandidate, in store: KakaNativeStore) async throws {
        guard let entered = state(in: store) else { throw CancellationError() }
        guard entered.hasRoomIdentity else { throw Failure.layoutChanged }
        let current = try await invitationCandidates(in: store)
        guard current.contains(where: { $0.id == candidate.id }) else { throw InvitationUnavailable() }
        guard let room = state(in: store) else { throw CancellationError() }
        guard entered.sameRoom(as: room) else { throw Failure.layoutChanged }
        _ = try await store.request("voice.invitation.send", ["roomId": roomID, "yxRoomId": room.messagingRoom,
                                                             "roomTempId": room.templateID, "userId": candidate.id])
        guard state(in: store) != nil else { throw CancellationError() }
    }
}

@MainActor
struct KakaVoiceRoomInviteSheet: View {
    private typealias Candidate = KakaVoiceManagementContext.InviteCandidate
    @EnvironmentObject private var store: KakaNativeStore
    let context: KakaVoiceManagementContext

    @State private var candidates: [Candidate] = []
    @State private var pending: Candidate?
    @State private var sent = Set<Int64>()
    @State private var loaded = false
    @State private var loading = true
    @State private var sending = false
    @State private var feedback = ""

    var body: some View {
        KakaRoomSheet(title: "Invite people", locked: sending) {
            if pending == nil { KakaVoiceControlArtwork(asset: "stage-people.png") }
            if !feedback.isEmpty {
                KakaVoiceControlNotice(message: feedback)
            }
            if let pending {
                VStack(alignment: .leading, spacing: 12) {
                    KakaVoiceControlIdentity(name: pending.name, portrait: pending.portrait, subtitle: "Send a voice room invitation?")
                    if sending { KakaRhythmProgress(title: "Sending invitation") }
                    KakaRoomActionGroup {
                        KakaRoomButton(title: "Send invitation", asset: "stage-message.png") { Task { await send(pending) } }
                        KakaRoomButton(title: "Cancel") { self.pending = nil }
                    }
                    .disabled(sending)
                }
                .padding(14)
                .modifier(KakaVoiceControlSurface())
            } else if loading {
                KakaRhythmProgress(title: "Finding people to invite")
            } else {
                if loaded, candidates.isEmpty {
                    KakaVoiceControlNotice(message: "No suggested people right now.")
                }
                ForEach(candidates) { candidate in
                    let invited = sent.contains(candidate.id)
                    HStack(spacing: 8) {
                        KakaVoiceControlIdentity(name: candidate.name, portrait: candidate.portrait, subtitle: invited ? "Invited" : nil)
                        Spacer(minLength: 0)
                        KakaStageIconButton(title: invited ? "\(candidate.name) invited" : "Invite \(candidate.name)",
                                            artwork: invited ? "action-check.png" : "stage-message.png", accent: KakaTheme.voiceAccent) {
                            feedback = ""
                            pending = candidate
                        }
                        .disabled(invited)
                    }
                    .padding(10)
                    .modifier(KakaVoiceControlSurface())
                }
                KakaRoomButton(title: "Refresh suggestions") { Task { await load() } }
            }
        }
        .interactiveDismissDisabled(sending)
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        feedback = ""
        do {
            candidates = try await context.invitationCandidates(in: store)
            loaded = true
        } catch is CancellationError {
            return
        } catch {
            feedback = store.message(error)
        }
    }

    private func send(_ candidate: Candidate) async {
        guard !sending, !sent.contains(candidate.id) else { return }
        sending = true
        defer { sending = false }
        do {
            try await context.invite(candidate, in: store)
            sent.insert(candidate.id)
            pending = nil
            feedback = "Invitation sent to \(candidate.name)."
        } catch is CancellationError {
            return
        } catch {
            if error is KakaVoiceManagementContext.InvitationUnavailable { pending = nil }
            feedback = store.message(error)
        }
    }
}

extension KakaVoiceManagementContext {
    struct LayoutOptions {
        let templates: [KakaVoiceCreation.Layout]
        let level: Int64
        let currentID: Int64
    }

    struct LayoutUnavailable: LocalizedError {
        var errorDescription: String? { "This mic layout is no longer available for your account. Refresh the layout list." }
    }

    @MainActor
    func availableLayouts(in store: KakaNativeStore) async throws -> LayoutOptions {
        try await requirePermission(in: store)
        return try await readLayouts(in: store)
    }

    @MainActor
    private func readLayouts(in store: KakaNativeStore) async throws -> LayoutOptions {
        guard state(in: store) != nil else { throw CancellationError() }
        let user = try await KakaAccountStore.shared.remoteUserID(session: session)
        guard state(in: store) != nil else { throw CancellationError() }
        let result = try await store.request("voice.creation.layouts", ["type": 1])
        guard state(in: store) != nil else { throw CancellationError() }
        let profile = try await store.request("profile.read")
        guard let room = state(in: store) else { throw CancellationError() }
        guard let person = profile as? [String: Any] else { throw KakaRemoteClient.Fault.response }
        if let reported = KakaRoomFields.id(person, keys: ["voyagerBadge"]), reported != user {
            throw KakaRemoteClient.Fault.response
        }
        let level = ["voyagerRank", "orbitTier", "beaconGrade"].lazy.compactMap { KakaRemoteClient.userID(person[$0]) }.first ?? 0
        let rows = KakaRoomFields.rows(result, keys: ["rows", "records", "list", "data", "result", "items"])
        return LayoutOptions(templates: KakaVoiceCreation.layouts(rows), level: max(0, level), currentID: room.templateID)
    }

    @MainActor
    func switchLayout(to template: KakaVoiceCreation.Layout, in store: KakaNativeStore) async throws -> Bool {
        guard let previous = state(in: store) else { throw CancellationError() }
        guard previous.hasRoomIdentity else { throw Failure.layoutChanged }
        let latest = try await readLayouts(in: store)
        guard latest.templates.contains(where: { $0.id == template.id && $0.minimumLevel <= latest.level }) else {
            throw LayoutUnavailable()
        }
        try await requirePermission(in: store)
        guard let room = state(in: store) else { throw CancellationError() }
        guard room.sameRoom(as: previous) else { throw Failure.layoutChanged }
        try await KakaNativeRoomRuntime.shared.media.switchVoiceLayout(to: template.id, replacing: room,
                                                                      roomID: roomID, session: session)
        guard let confirmed = state(in: store) else { throw CancellationError() }
        return confirmed.templateID == template.id
    }
}

@MainActor
private struct KakaVoiceRoomLayoutSheet: View {
    @EnvironmentObject private var store: KakaNativeStore
    let context: KakaVoiceManagementContext

    @State private var options: KakaVoiceManagementContext.LayoutOptions?
    @State private var pending: KakaVoiceCreation.Layout?
    @State private var changing = false
    @State private var loading = true
    @State private var feedback = ""

    var body: some View {
        KakaRoomSheet(title: "Mic seat layout", locked: changing) {
            if pending == nil { KakaVoiceControlArtwork(asset: "stage-tools.png") }
            if !feedback.isEmpty {
                KakaVoiceControlNotice(message: feedback)
            }
            if let pending {
                Text("Switch to \(pending.name)?").font(.headline)
                KakaVoiceControlNotice(message: "Changing the layout can move or close occupied mic seats.")
                if changing { KakaRhythmProgress(title: "Switching mic layout") }
                KakaRoomActionGroup {
                    KakaRoomButton(title: "Switch layout", asset: "action-check.png") { Task { await apply(pending) } }
                    KakaRoomButton(title: "Cancel") { self.pending = nil }
                }
                .disabled(changing)
            } else if loading {
                KakaRhythmProgress(title: "Loading mic seat layouts")
            } else {
                if let options {
                    if options.templates.isEmpty {
                        KakaVoiceControlNotice(message: "No audio layouts are available.")
                    }
                    ForEach(options.templates) { template in
                        layoutOption(template, options: options)
                    }
                }
                KakaRoomButton(title: "Refresh layouts") { Task { await load() } }
            }
        }
        .interactiveDismissDisabled(changing)
        .task { await load() }
    }

    private func layoutOption(_ template: KakaVoiceCreation.Layout,
                              options: KakaVoiceManagementContext.LayoutOptions) -> some View {
        let isCurrent = options.currentID == template.id
        let isLocked = template.minimumLevel > options.level
        return HStack(spacing: 10) {
            HStack(spacing: 9) {
                KakaNativeImage(asset: "room-control-cover.jpg", remote: template.image)
                    .scaledToFill().frame(width: 62, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(template.name).font(.subheadline.weight(.semibold))
                    if isCurrent {
                        Text("Current layout").font(.caption).foregroundStyle(KakaTheme.voiceAccent)
                    } else if isLocked {
                        Text("Level \(template.minimumLevel) required").font(.caption).foregroundStyle(KakaTheme.muted)
                    } else if template.seats > 0 {
                        Text("\(template.seats) mic seats").font(.caption).foregroundStyle(KakaTheme.muted)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            KakaStageIconButton(title: isCurrent ? "\(template.name), current layout" : "Select \(template.name)",
                                artwork: isCurrent ? "action-check.png" : "action-forward.png", accent: KakaTheme.voiceAccent) {
                feedback = ""
                pending = template
            }
            .disabled(isCurrent || isLocked || options.currentID <= 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(KakaVoiceControlSurface())
    }

    private func load() async {
        loading = true
        defer { loading = false }
        feedback = ""
        do {
            options = try await context.availableLayouts(in: store)
        } catch is CancellationError {
            return
        } catch {
            feedback = store.message(error)
        }
    }

    private func apply(_ template: KakaVoiceCreation.Layout) async {
        guard !changing else { return }
        changing = true
        defer { changing = false }
        feedback = ""
        do {
            let confirmed = try await context.switchLayout(to: template, in: store)
            if let options {
                self.options = KakaVoiceManagementContext.LayoutOptions(
                    templates: options.templates, level: options.level, currentID: confirmed ? template.id : 0
                )
            }
            pending = nil
            feedback = confirmed ? "Mic layout updated." : "Layout change accepted. The mic seats will refresh shortly."
        } catch is CancellationError {
            return
        } catch {
            pending = nil
            feedback = store.message(error)
        }
    }
}
