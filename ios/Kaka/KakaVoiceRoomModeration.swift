import SwiftUI

extension KakaVoiceManagementContext {
    enum ModerationSection: String, CaseIterable {
        case members = "Members"
        case blocklist = "Blocklist"
    }

    enum ModerationAction: Equatable {
        case administrator(Bool)
        case kick
        case block
        case unblock

        var title: String {
            switch self {
            case .administrator(let add): return add ? "Make administrator" : "Remove administrator"
            case .kick: return "Remove from room"
            case .block: return "Block from room"
            case .unblock: return "Unblock"
            }
        }
    }

    struct ModerationMember: Identifiable {
        let id: Int64
        let name: String
        let portrait: URL?
        let seat: Int64
        let page: Int

        init?(_ fields: [String: Any], page: Int) {
            guard let id = KakaRoomFields.id(fields, keys: ["userId"]) else { return nil }
            self.id = id
            self.page = page
            let name = KakaRoomFields.text(fields, "nickname", "nickName", "name")
            self.name = name.isEmpty ? "Member \(id)" : String(name.prefix(80))
            self.portrait = KakaRoomFields.url(KakaRoomFields.text(fields, "avatar", "icon"))
            self.seat = max(-1, KakaRemoteClient.userID(fields["seatIndex"]) ?? -1)
        }
    }

    enum ModerationFailure: LocalizedError {
        case targetChanged, seatChanged

        var errorDescription: String? {
            switch self {
            case .targetChanged: return "This member’s room status changed. Refresh the list and try again."
            case .seatChanged: return "This mic seat changed. Refresh the list and try again."
            }
        }
    }

    enum SeatAction: Equatable {
        case lock(Bool)
        case removeOccupant

        var title: String {
            switch self {
            case .lock(let locked): return locked ? "Lock seat" : "Unlock seat"
            case .removeOccupant: return "Remove from seat"
            }
        }
    }

    @MainActor
    func loadManagedSeats(in store: KakaNativeStore) async throws -> [KakaRealtimeMedia.VoiceStageSeat] {
        try await requirePermission(in: store)
        return try await currentSeats(in: store)
    }

    @MainActor
    func seatAction(for expected: KakaRealtimeMedia.VoiceStageSeat, in store: KakaNativeStore) async throws -> SeatAction {
        let actor = try await requirePermission(in: store)
        return try await verifiedSeatAction(for: expected, actor: actor, in: store)
    }

    @MainActor
    func changeSeat(_ expected: KakaRealtimeMedia.VoiceStageSeat, action: SeatAction, in store: KakaNativeStore) async throws {
        let actor = try await requirePermission(in: store)
        guard let entered = state(in: store) else { throw CancellationError() }
        let latest = try await verifiedSeatAction(for: expected, actor: actor, in: store)
        guard latest == action else { throw ModerationFailure.seatChanged }
        guard let room = state(in: store) else { throw CancellationError() }
        guard room.hasRoomIdentity, entered.sameRoom(as: room) else { throw Failure.layoutChanged }
        var fields: [String: Any] = ["roomId": roomID, "yxRoomId": room.messagingRoom,
                                     "roomTempId": room.templateID, "seatIndex": expected.index]
        let operation: String
        switch action {
        case .lock(let locked):
            operation = "voice.management.lockSeat"
            fields["operatorType"] = locked ? 8 : 9
        case .removeOccupant:
            guard let userID = expected.occupant else { throw ModerationFailure.seatChanged }
            operation = "voice.management.removeOccupant"
            fields["targetUserId"] = userID
            fields["operatorType"] = 3
        }
        _ = try await store.request(operation, fields)
        guard state(in: store) != nil else { throw CancellationError() }
    }

    @MainActor
    private func verifiedSeatAction(for expected: KakaRealtimeMedia.VoiceStageSeat, actor: MemberRole,
                                    in store: KakaNativeStore) async throws -> SeatAction {
        let seats = try await currentSeats(in: store)
        guard let seat = seats.first(where: { $0.index == expected.index }),
              seat.occupant == expected.occupant, seat.locked == expected.locked else {
            throw ModerationFailure.seatChanged
        }
        guard let userID = seat.occupant, userID != actor.userID else { return .lock(!seat.locked) }
        let target = try await roomRole(for: userID, in: store)
        guard !target.isProtected else { throw Failure.permission }
        return .removeOccupant
    }

    @MainActor
    private func currentSeats(in store: KakaNativeStore) async throws -> [KakaRealtimeMedia.VoiceStageSeat] {
        guard state(in: store) != nil else { throw CancellationError() }
        let seats = try await KakaNativeRoomRuntime.shared.media.voiceModerationSeats(roomID: roomID, session: session)
        guard state(in: store) != nil else { throw CancellationError() }
        return seats
    }

    @MainActor
    func loadModerationPage(_ section: ModerationSection, page: Int, in store: KakaNativeStore)
        async throws -> (members: [ModerationMember], hasMore: Bool) {
        let manager = try await requirePermission(in: store)
        return try await moderationPage(section, page: page, excluding: manager.userID, in: store)
    }

    @MainActor
    func moderationActions(for member: ModerationMember, in section: ModerationSection,
                           store: KakaNativeStore) async throws -> [ModerationAction] {
        let manager = try await requirePermission(in: store)
        guard member.id != manager.userID else { throw Failure.permission }
        if section == .blocklist { return [.unblock] }
        let target = try await roomRole(for: member.id, in: store)
        guard !target.isProtected else { return [] }
        if manager.canAssignAdministrators { return [.administrator(!target.isRoomAdmin), .kick, .block] }
        return [.kick, .block]
    }

    @MainActor
    func moderate(_ action: ModerationAction, member: ModerationMember, section: ModerationSection,
                  in store: KakaNativeStore) async throws {
        let manager = try await requirePermission(in: store)
        guard let entered = state(in: store) else { throw CancellationError() }
        let roster = try await moderationPage(section, page: member.page, excluding: manager.userID, in: store)
        guard let latest = roster.members.first(where: { $0.id == member.id }) else {
            throw ModerationFailure.targetChanged
        }
        if section == .members {
            let target = try await roomRole(for: latest.id, in: store)
            guard !target.isProtected else { throw Failure.permission }
            if case .administrator(let add) = action {
                guard manager.canAssignAdministrators else { throw Failure.permission }
                guard add != target.isRoomAdmin else { throw ModerationFailure.targetChanged }
            }
        }
        guard let current = state(in: store) else { throw CancellationError() }
        guard entered.hasRoomIdentity, entered.sameRoom(as: current) else { throw Failure.layoutChanged }
        let operation: String
        var fields: [String: Any] = ["roomId": roomID, "yxRoomId": current.messagingRoom, "roomTempId": current.templateID]
        switch (section, action) {
        case (.members, .administrator(let add)):
            operation = "voice.management.administrator"
            fields["userId"] = latest.id
            fields["operateType"] = add ? 1 : 2
        case (.members, .kick), (.members, .block):
            operation = "voice.management.kick"
            fields["targetUserId"] = latest.id
            fields["seatIndex"] = latest.seat > 0 ? latest.seat : -1
            fields["banType"] = action == .block ? 1 : 0
        case (.blocklist, .unblock):
            operation = "voice.management.unblock"
            fields["userId"] = latest.id
        default:
            throw Failure.permission
        }
        _ = try await store.request(operation, fields)
        guard state(in: store) != nil else { throw CancellationError() }
    }

    @MainActor
    private func moderationPage(_ section: ModerationSection, page: Int, excluding user: Int64, in store: KakaNativeStore)
        async throws -> (members: [ModerationMember], hasMore: Bool) {
        guard state(in: store) != nil else { throw CancellationError() }
        let operation = section == .members ? "voice.management.members" : "voice.management.blocklist"
        var input: [String: Any] = ["roomId": roomID]
        if section == .members {
            input["pageNum"] = page
            input["pageSize"] = 20
        }
        let source = try await store.request(operation, input)
        guard state(in: store) != nil else { throw CancellationError() }
        guard source is [[String: Any]] || source is [String: Any] else { throw KakaRemoteClient.Fault.response }
        let rows = KakaRoomFields.rows(source, keys: ["rows", "records", "list", "data", "result", "items", "viewers"])
        var seen = Set<Int64>()
        let members = rows.compactMap { ModerationMember($0, page: page) }
            .filter { $0.id != user && seen.insert($0.id).inserted }
        return (members, section == .members && rows.count >= 20)
    }
}

@MainActor
struct KakaVoiceRoomModeration: View {
    @EnvironmentObject private var store: KakaNativeStore
    let context: KakaVoiceManagementContext

    @State private var section: KakaVoiceManagementContext.ModerationSection = .members
    @State private var members: [KakaVoiceManagementContext.ModerationMember] = []
    @State private var selected: KakaVoiceManagementContext.ModerationMember?
    @State private var actions: [KakaVoiceManagementContext.ModerationAction] = []
    @State private var confirming: KakaVoiceManagementContext.ModerationAction?
    @State private var page = 1
    @State private var hasMore = false
    @State private var busy = false
    @State private var feedback = ""

    var body: some View {
        KakaRoomSheet(title: selected?.name ?? "Manage members", locked: busy) {
            if busy { KakaRhythmProgress(title: "Updating room members") }
            if !feedback.isEmpty {
                Text(feedback).font(.subheadline).foregroundStyle(KakaTheme.muted)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if let selected {
                memberActions(selected)
            } else {
                roster
            }
        }
        .interactiveDismissDisabled(busy)
        .task(id: section) { await load(reset: true) }
    }

    private var roster: some View {
        VStack(alignment: .leading, spacing: 10) {
            KakaRoomActionGroup {
                ForEach(KakaVoiceManagementContext.ModerationSection.allCases, id: \.self) { tab in
                    KakaRoomButton(title: tab.rawValue, selected: section == tab) {
                        guard section != tab else { return }
                        members = []
                        hasMore = false
                        feedback = ""
                        section = tab
                    }
                    .disabled(busy)
                }
            }
            if !busy, members.isEmpty, feedback.isEmpty {
                Text(section == .members ? "No members to manage." : "The room blocklist is empty.")
                    .font(.subheadline).foregroundStyle(KakaTheme.muted)
            }
            ForEach(members) { member in
                Button {
                    Task { await inspect(member) }
                } label: {
                    HStack(spacing: 8) {
                        if let portrait = member.portrait {
                            KakaNativeImage(asset: "member-mark.jpg", remote: portrait)
                                .scaledToFill().frame(width: 38, height: 38)
                                .clipShape(RoundedRectangle(cornerRadius: 9))
                                .accessibilityHidden(true)
                        }
                        Text(member.name).font(.subheadline.weight(.semibold))
                        Spacer(minLength: 4)
                        KakaNativeImage(asset: "action-forward.png")
                            .frame(width: 18, height: 18)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 44)
                    .padding(8)
                    .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }
            if hasMore {
                KakaRoomButton(title: "Show more") { Task { await load(reset: false) } }.disabled(busy)
            }
            KakaRoomButton(title: "Refresh") { Task { await load(reset: true) } }.disabled(busy)
        }
    }

    @ViewBuilder
    private func memberActions(_ member: KakaVoiceManagementContext.ModerationMember) -> some View {
        if let confirming {
            Text("\(confirming.title) for \(member.name)?").font(.subheadline.weight(.semibold))
            KakaRoomActionGroup {
                KakaRoomButton(title: confirming.title) { Task { await execute(confirming, member: member) } }
                    .disabled(busy)
                KakaRoomButton(title: "Cancel") { self.confirming = nil }.disabled(busy)
            }
        } else {
            if actions.isEmpty, !busy, feedback.isEmpty {
                Text("No actions available for this member.").font(.subheadline).foregroundStyle(KakaTheme.muted)
            }
            ForEach(actions.indices, id: \.self) { index in
                KakaRoomButton(title: actions[index].title) { confirming = actions[index] }.disabled(busy)
            }
            KakaRoomButton(title: "Back to list") {
                selected = nil
                feedback = ""
            }
            .disabled(busy)
        }
    }

    private func load(reset: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        feedback = ""
        let requested = reset ? 1 : page + 1
        do {
            let result = try await context.loadModerationPage(section, page: requested, in: store)
            if reset { members = [] }
            var seen = Set(members.map(\.id))
            members += result.members.filter { seen.insert($0.id).inserted }
            hasMore = result.hasMore
            page = requested
        } catch is CancellationError {
            return
        } catch {
            feedback = store.message(error)
        }
    }

    private func inspect(_ member: KakaVoiceManagementContext.ModerationMember) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        feedback = ""
        selected = member
        actions = []
        do {
            actions = try await context.moderationActions(for: member, in: section, store: store)
        } catch is CancellationError {
            return
        } catch {
            feedback = store.message(error)
        }
    }

    private func execute(_ action: KakaVoiceManagementContext.ModerationAction,
                         member: KakaVoiceManagementContext.ModerationMember) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        feedback = ""
        do {
            try await context.moderate(action, member: member, section: section, in: store)
            switch action {
            case .administrator: break
            case .kick, .block, .unblock: members.removeAll { $0.id == member.id }
            }
            selected = nil
            feedback = "Room updated."
        } catch is CancellationError {
            return
        } catch {
            feedback = store.message(error)
        }
        confirming = nil
    }
}

@MainActor
struct KakaVoiceRoomSeatControls: View {
    private typealias Seat = KakaRealtimeMedia.VoiceStageSeat
    private typealias Action = KakaVoiceManagementContext.SeatAction

    @EnvironmentObject private var store: KakaNativeStore
    let context: KakaVoiceManagementContext

    @State private var seats: [Seat] = []
    @State private var pending: (Seat, Action)?
    @State private var busy = false
    @State private var loaded = false
    @State private var feedback = ""

    var body: some View {
        KakaRoomSheet(title: "Manage mic seats", locked: busy) {
            if busy { KakaRhythmProgress(title: "Updating mic seats") }
            if !feedback.isEmpty {
                Text(feedback).font(.subheadline).foregroundStyle(KakaTheme.muted)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if let (seat, action) = pending {
                Text("\(action.title) \(seat.index)?").font(.headline)
                if let name = occupantName(seat) {
                    Text(name).font(.subheadline).foregroundStyle(KakaTheme.muted)
                }
                KakaRoomActionGroup {
                    KakaRoomButton(title: action.title) { Task { await commit(seat, action: action) } }
                    KakaRoomButton(title: "Cancel") { pending = nil }
                }
                .disabled(busy)
            } else {
                if loaded, seats.isEmpty {
                    Text("No mic seats available.").font(.subheadline).foregroundStyle(KakaTheme.muted)
                }
                ForEach(seats) { seat in
                    KakaRoomActionGroup {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Seat \(seat.index)").font(.subheadline.weight(.semibold))
                            Text(occupantName(seat) ?? (seat.locked ? "Locked" : "Open"))
                                .font(.caption).foregroundStyle(KakaTheme.muted)
                        }
                        KakaRoomButton(title: "Manage") { Task { await select(seat) } }
                            .accessibilityLabel("Manage seat \(seat.index)")
                            .disabled(busy)
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                }
                KakaRoomButton(title: "Refresh seats") { Task { await load() } }.disabled(busy)
            }
        }
        .interactiveDismissDisabled(busy)
        .task { await load() }
    }

    private func occupantName(_ seat: Seat) -> String? {
        guard let userID = seat.occupant else { return nil }
        return seat.name.isEmpty ? "Member \(userID)" : seat.name
    }

    private func load() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        feedback = ""
        do {
            seats = try await context.loadManagedSeats(in: store)
            loaded = true
        } catch is CancellationError {
            return
        } catch {
            feedback = store.message(error)
        }
    }

    private func select(_ seat: Seat) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        feedback = ""
        do {
            let action = try await context.seatAction(for: seat, in: store)
            pending = (seat, action)
        } catch is CancellationError {
            return
        } catch {
            feedback = store.message(error)
        }
    }

    private func commit(_ seat: Seat, action: Action) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        feedback = ""
        pending = nil
        do {
            try await context.changeSeat(seat, action: action, in: store)
            seats.removeAll { $0.index == seat.index }
            do {
                seats = try await context.loadManagedSeats(in: store)
                feedback = "Mic seat updated."
            } catch is CancellationError {
                return
            } catch {
                feedback = "Mic seat updated. Refresh to see the latest seat list."
            }
        } catch is CancellationError {
            return
        } catch {
            feedback = store.message(error)
        }
    }
}
