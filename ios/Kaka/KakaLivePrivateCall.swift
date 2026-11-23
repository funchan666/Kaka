import AVFoundation
import Combine
import Foundation

@MainActor
final class KakaLivePrivateCall: ObservableObject {
    struct Quote: Equatable {
        let hostID: Int64
        let account: String
        let entryCost: Decimal
        let entryMinutes: Int
        let minuteCost: Decimal
    }

    enum Phase { case offer, contacting, ringing, connecting, active, ending, finished }

    private enum Failure: LocalizedError {
        case unavailable, priceChanged, funds, permission, timeOut, receipt

        var errorDescription: String? {
            switch self {
            case .unavailable: return "This host is unavailable for a private video call."
            case .priceChanged: return "The price changed. Review the current offer and try again."
            case .funds: return "There aren’t enough diamonds for this call."
            case .permission: return "Allow camera and microphone access to make a video call."
            case .timeOut: return "The host didn’t answer in time."
            case .receipt: return "Payment could not be confirmed. Check your balance before calling again."
            }
        }
    }

    @Published private(set) var phase: Phase = .offer
    @Published private(set) var quote: Quote?
    @Published private(set) var feedback = ""
    @Published private(set) var checking = false
    @Published private(set) var secondsRemaining: Int?
    let media = KakaRealtimeMedia()
    private let signal = KakaLiveCallSignal()
    private var generation = UUID()
    private var session: UUID?
    private var channel = ""
    private var inviteSent = false
    private var accepted = false
    private var hasRemoteFrame = false
    private var beganBilling = false
    private var billing: Task<Void, Never>?
    private var timeout: Task<Void, Never>?

    var holdsRoom: Bool { [.contacting, .ringing, .connecting, .active, .ending].contains(phase) }

    func loadOffer(room: KakaNativeRoom, session: UUID, ownsRoom: () -> Bool) async {
        guard phase == .offer, !checking, ownsRoom() else { return }
        feedback = ""
        checking = true
        defer { checking = false }
        do {
            let loaded = try await readQuote(room: room, session: session)
            guard !Task.isCancelled, ownsRoom(), phase == .offer else { return }
            quote = loaded
        } catch {
            if !Task.isCancelled, ownsRoom(), phase == .offer { feedback = error.localizedDescription }
        }
    }

    func start(room: KakaNativeRoom, session: UUID, ownsRoom: @escaping () -> Bool,
               suspendRoom: @escaping () async -> Void) async {
        guard phase == .offer, let agreed = quote, ownsRoom() else { return }
        phase = .contacting
        feedback = ""
        self.session = session
        let attempt = generation
        do {
            let current = try await readQuote(room: room, session: session)
            try verify(attempt)
            guard ownsRoom() else { throw Failure.unavailable }
            guard current == agreed else {
                quote = current
                phase = .offer
                feedback = Failure.priceChanged.localizedDescription
                return
            }
            let localID = try await KakaAccountStore.shared.remoteUserID(session: session)
            guard localID != agreed.hostID, let peer = UInt(exactly: agreed.hostID), peer > 0,
                  !(try await KakaRoomChat.isBlocked(userID: agreed.hostID, session: session)) else {
                throw Failure.unavailable
            }
            try await ensureContactAllowed(agreed, session: session)
            guard try await walletBalance(session: session) >= agreed.entryCost else { throw Failure.funds }
            try verify(attempt)
            guard ownsRoom(), await AVCaptureDevice.requestAccess(for: .video),
                  await AVCaptureDevice.requestAccess(for: .audio) else { throw Failure.permission }
            try verify(attempt)
            try await signal.connect(session: session)
            try verify(attempt)
            guard ownsRoom() else { throw Failure.unavailable }
            await suspendRoom()
            try verify(attempt)

            let created = try await request("/voyager/forge", fields: [
                "guestCode": agreed.account, "stageMode": 4, "portalOrigin": "iosLive",
            ], session: session)
            guard let createdChannel = created["venueKey"] as? String, !createdChannel.isEmpty,
                  createdChannel.utf8.count <= 64 else { throw Failure.unavailable }
            guard generation == attempt else {
                _ = try? await request("/voyager/lapse", fields: ["venueKey": createdChannel, "encoreCause": 3], session: session)
                return
            }
            channel = createdChannel
            if let newPrice = Self.amount(created["holoFare"]), newPrice > agreed.minuteCost {
                throw Failure.priceChanged
            }
            let callID = (created["studioTrace"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? createdChannel
            let token = try await request("/nebula/relay/identity-pass", session: session)
            try verify(attempt)
            guard let credential = token["relayPass"] as? String, !credential.isEmpty,
                  let listenerID = UInt(exactly: KakaRemoteClient.userID(token["starBadge"]) ?? localID),
                  listenerID > 0, listenerID != peer,
                  (token["venueKey"] as? String).map({ $0.isEmpty || $0 == createdChannel }) ?? true else {
                throw Failure.unavailable
            }
            media.onPrivateVideoEvent = { [weak self] event in self?.receiveMedia(event, attempt: attempt) }
            try await media.joinPrivateVideo(channel: createdChannel, credential: credential,
                                             listener: listenerID, peer: peer, session: session)
            try verify(attempt)
            try signal.bind(callID: callID, channel: createdChannel, peerID: agreed.hostID) { [weak self] action in
                self?.receiveSignal(action, attempt: attempt)
            }
            phase = .ringing
            inviteSent = true
            setTimeout(30, attempt: attempt)
            try await signal.publish(.invite)
            try verify(attempt)
        } catch {
            guard generation == attempt else { return }
            await finish(reason: 10, message: error.localizedDescription)
        }
    }

    func hangUp() async {
        guard holdsRoom else { return }
        await finish(reason: 1)
    }

    private func readQuote(room: KakaNativeRoom, session: UUID) async throws -> Quote {
        let result = try await request("/nebula/studio/retrieve", fields: ["habitatTag": room.serverID], session: session)
        let fields = result["venueBrief"] as? [String: Any] ?? result
        let host = fields["anchor"] as? [String: Any] ?? fields["anchorInfo"] as? [String: Any] ?? fields
        let hostID = KakaRemoteClient.userID(host["voyagerBadge"] ?? host["orbitMark"] ?? fields["voyagerBadge"])
        let route = (fields["studioRoute"] ?? fields["venueKey"]) as? String
        guard let hostID, hostID > 0, room.host?.id == hostID, !room.channel.isEmpty, route == room.channel,
              KakaRemoteClient.userID(fields["habitatTag"] ?? fields["orbitMark"]) == room.serverID,
              Self.flag(result["cipherAccess"] ?? fields["cipherAccess"]) == true,
              Self.flag(result["onstage"] ?? fields["onstage"]) != false,
              let contact = host["relayCode"] as? String, !contact.isEmpty, contact.utf8.count <= 128,
              let rate = Self.amount(result["tariffRate"] ?? fields["tariffRate"]) else { throw Failure.unavailable }
        let entry = Self.amount(result["signalCost"] ?? fields["signalCost"]) ?? rate
        let duration = KakaRemoteClient.userID(result["orbitWindow"] ?? fields["orbitWindow"]) ?? 0
        guard (0...1440).contains(duration) else { throw Failure.unavailable }
        return Quote(hostID: hostID, account: contact, entryCost: entry, entryMinutes: Int(duration), minuteCost: rate)
    }

    private func ensureContactAllowed(_ quote: Quote, session: UUID) async throws {
        let fields: [String: Any] = ["voyagerBadge": quote.hostID, "relayCode": quote.account]
        async let theirs = request("/r2/voyager/veil/beacon-scan", fields: fields, session: session)
        async let mine = request("/r2/voyager/veil/self-scan", fields: fields, session: session)
        let restrictions = try await (theirs, mine)
        guard Self.flag(restrictions.0["curtainLocked"]) == false,
              Self.flag(restrictions.1["curtainLocked"]) == false else { throw Failure.unavailable }
    }

    private func receiveSignal(_ action: KakaLiveCallSignal.Action, attempt: UUID) {
        guard attempt == generation else { return }
        switch action {
        case .accepted where phase == .ringing:
            accepted = true
            phase = .connecting
            do {
                try media.publishPrivateVideo()
                if hasRemoteFrame { beginBillingIfReady(attempt: attempt) }
                else { setTimeout(15, attempt: attempt) }
            } catch {
                Task { await finish(reason: 10, message: error.localizedDescription) }
            }
        case .declined, .cancelled, .ended:
            let message = action == .declined ? "The host declined the call." : "The host ended the call."
            Task { await finish(reason: 2, message: message, notifyPeer: false) }
        default:
            break
        }
    }

    private func receiveMedia(_ event: KakaRealtimeMedia.PrivateVideoEvent, attempt: UUID) {
        guard attempt == generation else { return }
        switch event {
        case .remoteFrame:
            hasRemoteFrame = true
            beginBillingIfReady(attempt: attempt)
        case .ended:
            Task { await finish(reason: 2, message: "The video connection ended.", notifyPeer: false) }
        }
    }

    private func beginBillingIfReady(attempt: UUID) {
        guard accepted, hasRemoteFrame, !beganBilling, let session, let quote else { return }
        beganBilling = true
        timeout?.cancel()
        phase = .active
        billing = Task { @MainActor [weak self] in
            guard let self else { return }
            var first = true
            var nextCost = quote.entryCost
            do {
                while generation == attempt && !Task.isCancelled {
                    guard try await walletBalance(session: session) >= nextCost else { throw Failure.funds }
                    try verify(attempt)
                    let receipt = try await request(first ? "/voyager/ignition" : "/voyager/debit",
                                                    fields: ["venueKey": channel], session: session)
                    try verify(attempt)
                    if Self.flag(receipt["cheerShortfall"]) == true { throw Failure.funds }
                    guard let interval = KakaRemoteClient.userID(receipt["starMarker"]), (0...86400).contains(interval) else {
                        throw Failure.receipt
                    }
                    if interval == 0 { secondsRemaining = nil; return }
                    nextCost = Self.amount(receipt["transitDebit"]) ?? quote.minuteCost
                    guard nextCost <= quote.minuteCost else { throw Failure.priceChanged }
                    let deadline = ProcessInfo.processInfo.systemUptime + Double(interval)
                    while generation == attempt {
                        let remaining = Int(ceil(deadline - ProcessInfo.processInfo.systemUptime))
                        secondsRemaining = max(0, remaining)
                        if remaining <= 0 { break }
                        try await Task.sleep(nanoseconds: 250_000_000)
                    }
                    first = false
                }
            } catch {
                guard generation == attempt, !Task.isCancelled else { return }
                // A dispatched debit can have succeeded even without a reply.
                Task { await finish(reason: 8, message: (error as? Failure ?? .receipt).localizedDescription) }
            }
        }
    }

    private func setTimeout(_ duration: UInt64, attempt: UUID) {
        timeout?.cancel()
        timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: duration * 1_000_000_000)
            guard !Task.isCancelled, let self, generation == attempt else { return }
            Task { await finish(reason: 4, message: Failure.timeOut.localizedDescription) }
        }
    }

    private func finish(reason: Int, message: String = "", notifyPeer: Bool = true) async {
        guard holdsRoom, phase != .ending else { return }
        let established = accepted || beganBilling
        let closingChannel = channel
        let closingSession = session
        phase = .ending
        generation = UUID()
        billing?.cancel()
        timeout?.cancel()
        media.onPrivateVideoEvent = nil
        media.pausePrivateVideo()
        if notifyPeer, inviteSent { _ = try? await signal.publish(established ? .ended : .cancelled) }
        signal.close()
        await media.leave()
        if !closingChannel.isEmpty, let closingSession {
            let path = established ? "/voyager/closure" : "/voyager/lapse"
            let cause = established ? reason : (reason == 4 ? 2 : 7)
            let fields: [String: Any] = ["venueKey": closingChannel, established ? "closureCause" : "encoreCause": cause]
            _ = try? await request(path, fields: fields, session: closingSession)
        }
        secondsRemaining = nil
        feedback = message
        phase = .finished
    }

    private func verify(_ attempt: UUID) throws {
        guard generation == attempt, holdsRoom, phase != .ending, !Task.isCancelled else { throw CancellationError() }
    }

    private func walletBalance(session: UUID) async throws -> Decimal {
        let profile = try await request("/r2/voyager/brief", session: session)
        guard let balance = Self.amount(profile["starGems"]) else { throw Failure.receipt }
        return balance
    }

    private func request(_ path: String, fields: [String: Any] = [:], session: UUID) async throws -> [String: Any] {
        let data = try await KakaAccountStore.shared.call(path: path, body: try KakaRemoteClient.json(fields), session: session)
        return try KakaRemoteClient.object(data)
    }

    private static func amount(_ value: Any?) -> Decimal? {
        let raw = value as? String ?? (value as? NSNumber)?.stringValue ?? ""
        guard raw.range(of: #"^[0-9]{1,14}(\.[0-9]{1,6})?$"#, options: .regularExpression) != nil else { return nil }
        return Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func flag(_ value: Any?) -> Bool? {
        let raw = value as? String ?? (value as? NSNumber)?.stringValue ?? ""
        if ["true", "1"].contains(raw.lowercased()) { return true }
        if ["false", "0"].contains(raw.lowercased()) { return false }
        return nil
    }
}
