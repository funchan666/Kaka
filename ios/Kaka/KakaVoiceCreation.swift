import SwiftUI
import UIKit

enum KakaVoiceRoomText {
    private static let restricted = [
        "casino", "cashapp", "whatsapp", "telegram", "underage", "nudity", "nude", "sexual", "escort",
        "minor", "hookup", "crypto", "betting", "gambling", "lottery", "withdraw", "porn", "onlyfans", "adult only",
    ]

    static func valid(_ text: String, limit: Int) -> Bool {
        guard (1...limit).contains(text.count), text == text.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        let plain = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let scalars = plain.unicodeScalars.filter { ![0x200B, 0x200C, 0x200D, 0xFEFF].contains($0.value) }
        let normalized = String(String.UnicodeScalarView(scalars))
        return !restricted.contains(where: normalized.contains)
    }
}

@MainActor
struct KakaVoiceCreation: View {
    @EnvironmentObject private var store: KakaNativeStore
    @Environment(\.dynamicTypeSize) private var textSize
    @StateObject private var presenter = KakaStudioPresenter()

    let onOpen: (KakaNativeRoom) -> Void

    @State private var eligibility: Eligibility?
    @State private var layouts: [Layout] = []
    @State private var languages: [Language] = []
    @State private var backgrounds: [Background] = []
    @State private var ownedRoom: KakaNativeRoom?
    @State private var selectedLayout: Int64?
    @State private var selectedLanguage = ""
    @State private var selectedBackground: Int64?
    @State private var name = ""
    @State private var greeting = ""
    @State private var profileName = ""
    @State private var profileCover: URL?
    @State private var coverData: Data?
    @State private var uploadedCover: String?
    @State private var loading = false
    @State private var pickingCover = false
    @State private var creating = false
    @State private var verifying = false
    @State private var unconfirmedCreation: PendingCreation?
    @State private var error = ""

    private struct Eligibility {
        let allowed: Bool
        let exempt: Bool
        let level: Int64
        let minimumLevel: Int64

        func unlocks(_ layout: Layout) -> Bool { exempt || level >= layout.minimumLevel }
    }

    private struct Layout: Identifiable {
        let id: Int64
        let name: String
        let seats: Int64
        let minimumLevel: Int64
        let image: URL?
    }

    private struct Language: Identifiable {
        let id: String
        let name: String
    }

    struct Background: Identifiable {
        let id: Int64
        let name: String
        let image: URL
    }

    private struct PendingCreation {
        let title: String
        let previousRoomID: String?
    }

    private enum CreationFailure: Error {
        case options, unconfirmed
    }

    private static let listKeys = ["rows", "records", "list", "data", "result", "items"]

    init(onOpen: @escaping (KakaNativeRoom) -> Void) {
        self.onOpen = onOpen
    }

    var body: some View {
        KakaRoomSheet(title: "Create a voice room", locked: creating || verifying) {
            if let ownedRoom {
                KakaRoomButton(title: "Open my room", asset: "room-listen.png") { onOpen(ownedRoom) }
                    .disabled(creating || verifying)
            }

            if let eligibility {
                if !eligibility.allowed {
                    Text(eligibility.minimumLevel > 0 ? "Hosting unlocks at level \(eligibility.minimumLevel)." : "Room hosting is unavailable for this account.")
                        .font(.subheadline)
                        .foregroundStyle(KakaTheme.muted)
                } else {
                    form(eligibility)
                }
            } else if error.isEmpty {
                KakaRhythmProgress(title: "Loading room options")
            } else {
                KakaRoomButton(title: "Reload room options") { Task { await load() } }
                    .disabled(loading)
            }

            if !error.isEmpty {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(KakaTheme.muted)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .background(KakaStudioPresenterAnchor(presenter: presenter).allowsHitTesting(false).accessibilityHidden(true))
        .interactiveDismissDisabled(creating || verifying)
        .task { await load() }
        .onChange(of: name) { if $0.count > 20 { name = String($0.prefix(20)) } }
        .onChange(of: greeting) { if $0.count > 60 { greeting = String($0.prefix(60)) } }
    }

    private func form(_ eligibility: Eligibility) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            coverField
            VStack(alignment: .leading, spacing: 8) {
                fieldHeading("Room name", count: name.count, limit: 20)
                TextField("Name your room", text: $name)
                    .accessibilityLabel("Room name")
                    .padding(.horizontal, 12)
                    .frame(minHeight: 46)
                    .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 8) {
                fieldHeading("Welcome message", count: greeting.count, limit: 60)
                TextField("Say hello to guests", text: $greeting)
                    .accessibilityLabel("Welcome message")
                    .padding(.horizontal, 12)
                    .frame(minHeight: 46)
                    .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            }
            if !languages.isEmpty { languageChoices }
            layoutChoices(eligibility)
            if !backgrounds.isEmpty { backgroundChoices }
            if unconfirmedCreation != nil {
                KakaRoomButton(title: verifying ? "Checking…" : "Check my room", selected: true) {
                    Task { await verifyCreation() }
                }
                .disabled(verifying)
            } else {
                KakaRoomButton(title: creating ? "Creating…" : "Create room", asset: "room-listen.png", selected: true) {
                    Task { await create() }
                }
                .disabled(!canCreate)
                .opacity(canCreate || creating ? 1 : 0.55)
            }
        }
        .disabled(creating || verifying)
    }

    private var coverField: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("Room cover")
            HStack(spacing: 12) {
                Group {
                    if let coverData, let image = UIImage(data: coverData) {
                        Image(uiImage: image).resizable()
                    } else {
                        KakaNativeImage(asset: "voice-deck.jpg", remote: profileCover)
                    }
                }
                .scaledToFill()
                .frame(width: textSize.isAccessibilitySize ? 54 : 72, height: textSize.isAccessibilitySize ? 54 : 72)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    KakaRoomButton(title: pickingCover ? "Opening photos…" : "Choose cover") {
                        Task { await chooseCover() }
                    }
                    .disabled(pickingCover)
                    if coverData != nil {
                        KakaRoomButton(title: "Remove cover") {
                            coverData = nil
                            uploadedCover = nil
                        }
                    }
                }
            }
        }
    }

    private var languageChoices: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("Language")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    KakaRoomButton(title: "All languages", selected: selectedLanguage.isEmpty) { selectedLanguage = "" }
                    ForEach(languages) { language in
                        KakaRoomButton(title: language.name, selected: selectedLanguage == language.id) {
                            selectedLanguage = language.id
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
        }
    }

    private func layoutChoices(_ eligibility: Eligibility) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("Seat layout")
            if layouts.isEmpty {
                Text("No voice layouts are available.").font(.subheadline).foregroundStyle(KakaTheme.muted)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(layouts) { layout in
                            let available = eligibility.unlocks(layout)
                            let detail: String? = available
                                ? (layout.seats > 0 ? "\(layout.seats) seats" : nil)
                                : "Unlocks at level \(layout.minimumLevel)"
                            option(name: layout.name, detail: detail, image: layout.image, selected: selectedLayout == layout.id) {
                                selectedLayout = layout.id
                            }
                            .disabled(!available)
                        }
                    }
                }
            }
        }
    }

    private var backgroundChoices: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("Background")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8) {
                    option(name: "Default", detail: nil, image: nil, selected: selectedBackground == nil) {
                        selectedBackground = nil
                    }
                    ForEach(backgrounds) { background in
                        option(name: background.name, detail: nil, image: background.image, selected: selectedBackground == background.id) {
                            selectedBackground = background.id
                        }
                    }
                }
            }
        }
    }

    private func option(name: String, detail: String?, image: URL?, selected: Bool, choose: @escaping () -> Void) -> some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 5) {
                if let image {
                    KakaNativeImage(asset: "voice-deck.jpg", remote: image)
                        .scaledToFill()
                        .frame(width: 108, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)
                }
                Text(name).font(.subheadline.weight(.semibold))
                if let detail { Text(detail).font(.caption).foregroundStyle(KakaTheme.muted) }
            }
            .multilineTextAlignment(.leading)
            .frame(width: 108, alignment: .leading)
            .frame(minHeight: 44)
            .padding(8)
            .background(KakaTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? KakaTheme.voiceAccent : KakaTheme.line))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
    }

    private func fieldHeading(_ title: String, count: Int, limit: Int) -> some View {
        HStack {
            heading(title)
            Spacer(minLength: 6)
            Text("\(count)/\(limit)").font(.caption.monospacedDigit()).foregroundStyle(KakaTheme.muted)
        }
    }

    private var canCreate: Bool {
        guard !pickingCover, !creating, unconfirmedCreation == nil, let eligibility, eligibility.allowed,
              let selectedLayout, layouts.contains(where: { $0.id == selectedLayout && eligibility.unlocks($0) }) else { return false }
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !greeting.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func load() async {
        guard !loading, let token = store.session?.token else { return }
        loading = true
        error = ""
        defer { loading = false }
        do {
            async let conditions = KakaServiceBridge.perform(operation: "voice.creation.eligibility", input: [:], session: token)
            async let templates = KakaServiceBridge.perform(operation: "voice.creation.layouts", input: ["type": 1], session: token)
            async let languageOptions = KakaServiceBridge.perform(operation: "voice.creation.languages", input: [:], session: token)
            async let scenery = KakaServiceBridge.perform(operation: "voice.creation.backgrounds", input: ["pageSize": 100, "offset": 0], session: token)
            async let profile = KakaServiceBridge.perform(operation: "profile.read", input: [:], session: token)
            async let currentRoom = try? fetchOwnedRoom(session: token)
            let options = try await (conditions, templates, languageOptions, scenery, profile)
            let previous = await currentRoom
            let account = try await KakaAccountStore.shared.remoteUserID(session: token)
            guard !Task.isCancelled, store.session?.token == token else { return }
            let condition = try KakaRemoteClient.object(options.0)
            let person = try KakaRemoteClient.object(options.4)
            if let reportedAccount = KakaRoomFields.id(person, keys: ["voyagerBadge"]), reportedAccount != account {
                throw CreationFailure.options
            }
            let exempt = KakaRoomFields.flag(condition["isWithlist"])
            guard condition["canCreateRoom"] != nil || condition["isWithlist"] != nil else { throw CreationFailure.options }
            let entry = Eligibility(allowed: exempt || KakaRoomFields.flag(condition["canCreateRoom"]), exempt: exempt,
                                    level: Self.number(person, "voyagerRank", "orbitTier", "beaconGrade"),
                                    minimumLevel: Self.number(condition, "createRoomLevel"))
            var layoutIDs = Set<Int64>()
            let allowedLayouts = try Self.rows(options.1).compactMap(Self.layout).filter { layoutIDs.insert($0.id).inserted }
            let languageRows = try Self.rows(options.2)
            let backgroundRows = try Self.rows(options.3)
            eligibility = entry
            layouts = allowedLayouts
            languages = Self.languages(languageRows)
            backgrounds = Self.backgrounds(backgroundRows)
            ownedRoom = previous
            selectedLayout = allowedLayouts.first(where: entry.unlocks)?.id
            profileCover = KakaRoomFields.url(KakaRoomFields.text(person, "cometGlyph", "spotlightFace", "icon", "avatar"))
            profileName = KakaRoomFields.text(person, "nickname", "castMoniker")
            if name.isEmpty, !profileName.isEmpty { name = String("\(profileName)’s Room".prefix(20)) }
        } catch {
            guard !Task.isCancelled, store.session?.token == token else { return }
            store.expireIfNeeded(error)
            self.error = error is CreationFailure ? "The service did not return room creation options." : store.message(error)
        }
    }

    private func chooseCover() async {
        guard let controller = presenter.controller, let token = store.session?.token, !pickingCover else { return }
        pickingCover = true
        error = ""
        defer { pickingCover = false }
        do {
            if let data = try await KakaAvatarUpload.shared.pickRoomCover(from: controller), store.session?.token == token {
                uploadedCover = nil
                coverData = data
            }
        } catch {
            if store.session?.token == token { self.error = store.message(error) }
        }
    }

    private func create() async {
        guard canCreate, let token = store.session?.token, let selectedLayout else { return }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let welcome = greeting.trimmingCharacters(in: .whitespacesAndNewlines)
        guard KakaVoiceRoomText.valid(title, limit: 20), KakaVoiceRoomText.valid(welcome, limit: 60) else {
            error = "Choose a room name and welcome message suitable for a public room."
            return
        }
        creating = true
        error = ""
        let previousRoomID = ownedRoom?.id
        var sentCreationRequest = false
        defer { creating = false }
        do {
            let account = try await KakaAccountStore.shared.remoteUserID(session: token)
            if let coverData, uploadedCover == nil {
                uploadedCover = try await KakaAvatarUpload.shared.uploadRoomCover(coverData, session: token)
            }
            let cover = uploadedCover ?? profileCover?.absoluteString ?? ""
            guard !Task.isCancelled, store.session?.token == token else { return }
            var fields: [String: Any] = ["roomName": title, "greetingMessage": welcome, "roomAvatar": cover,
                                         "roomLanguage": selectedLanguage, "roomTempId": selectedLayout]
            if let selectedBackground { fields["bgImgId"] = selectedBackground }
            sentCreationRequest = true
            let result = try await store.request("voice.creation.submit", fields) as? [String: Any] ?? [:]
            guard store.session?.token == token else { return }
            guard let id = KakaRoomFields.id(result, keys: ["id"]) else { throw CreationFailure.unconfirmed }
            var details = fields.merging(result.filter { !($0.value is NSNull) }) { _, remote in remote }
            details["id"] = id
            details["ownerId"] = account
            if !profileName.isEmpty { details["ownerName"] = profileName }
            guard let room = KakaNativeRoom.parse(details, kind: .voice) else { throw CreationFailure.unconfirmed }
            onOpen(room)
        } catch {
            guard store.session?.token == token else { return }
            let accountFailure = error as? KakaAccountStore.Failure
            if sentCreationRequest && (accountFailure == .network || accountFailure == .unavailable || error is CreationFailure) {
                unconfirmedCreation = PendingCreation(title: title, previousRoomID: previousRoomID)
                errorForUnconfirmedCreation()
                await verifyCreation()
            } else {
                self.error = store.message(error)
            }
        }
    }

    private func verifyCreation() async {
        guard !verifying, let unconfirmedCreation, let token = store.session?.token else { return }
        verifying = true
        defer { verifying = false }
        do {
            let candidate = try await fetchOwnedRoom(session: token)
            guard store.session?.token == token else { return }
            if let candidate, candidate.id != unconfirmedCreation.previousRoomID, candidate.title == unconfirmedCreation.title {
                onOpen(candidate)
            } else {
                ownedRoom = candidate
                errorForUnconfirmedCreation()
            }
        } catch {
            if store.session?.token == token { errorForUnconfirmedCreation() }
        }
    }

    private func errorForUnconfirmedCreation() {
        error = "The service has not confirmed creation. Check My Room before trying again."
    }

    private func fetchOwnedRoom(session: UUID) async throws -> KakaNativeRoom? {
        let account = try await KakaAccountStore.shared.remoteUserID(session: session)
        guard let value = try await store.request("voice.creation.ownedRoom") as? [String: Any], store.session?.token == session,
              let fields = value["myRoom"] as? [String: Any] else { return nil }
        if let owner = KakaRoomFields.id(fields, keys: ["ownerId"]), owner != account { return nil }
        return KakaNativeRoom.parse(fields, kind: .voice)
    }

    private static func rows(_ data: Data) throws -> [[String: Any]] {
        KakaRoomFields.rows(try JSONSerialization.jsonObject(with: data), keys: listKeys)
    }

    private static func number(_ fields: [String: Any], _ keys: String...) -> Int64 {
        keys.lazy.compactMap { KakaRemoteClient.userID(fields[$0]) }.first ?? 0
    }

    private static func layout(_ fields: [String: Any]) -> Layout? {
        guard let id = KakaRoomFields.id(fields, keys: ["roomTempId"]), number(fields, "videoMicNum") <= 0,
              number(fields, "videoNum") <= 0, number(fields, "roomTempType") != 2 else { return nil }
        let seats = max(number(fields, "audioMicNum"), number(fields, "voiceNum"), number(fields, "totalSeatNum"))
        let name = KakaRoomFields.text(fields, "tempName")
        return Layout(id: id, name: name.isEmpty ? (seats > 0 ? "\(seats) seats" : "Voice layout") : name,
                      seats: seats, minimumLevel: number(fields, "createRoomLevel"),
                      image: KakaRoomFields.url(KakaRoomFields.text(fields, "imgUrl")))
    }

    private static func languages(_ rows: [[String: Any]]) -> [Language] {
        var seen = Set<String>()
        return rows.compactMap { fields in
            let code = KakaRoomFields.text(fields, "languageCode")
            guard !code.isEmpty, code.utf8.count <= 64, seen.insert(code).inserted else { return nil }
            return Language(id: code, name: KakaRoomFields.text(fields, "languageName", "languageCode"))
        }
    }

    static func backgrounds(_ rows: [[String: Any]]) -> [Background] {
        var seen = Set<Int64>()
        return rows.compactMap { fields in
            guard let id = KakaRoomFields.id(fields, keys: ["id"]), seen.insert(id).inserted,
                  let image = KakaRoomFields.url(KakaRoomFields.text(fields, "bigImgUrl", "imgUrl")) else { return nil }
            let name = KakaRoomFields.text(fields, "bgImgName")
            return Background(id: id, name: name.isEmpty ? "Background \(id)" : name, image: image)
        }
    }
}
