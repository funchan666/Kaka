import AVFoundation
import Combine
import CoreFoundation
import Foundation
import UIKit

enum KakaCallPreferences {
    static let incomingEnabled = "kaka.incomingVideoCalls.enabled"
}

@MainActor
final class KakaLivePrivateCall: ObservableObject {
    struct Quote: Equatable {
        let hostID: Int64
        let account: String
        let entryCost: Decimal
        let entryMinutes: Int
        let minuteCost: Decimal
    }

    enum Phase: Equatable { case offer, incoming, contacting, ringing, connecting, active, waiting, ending, finished }

    struct IncomingCaller {
        let name: String?
        let portrait: URL?
    }

    struct CallMessage: Identifiable {
        let id = UUID()
        let text: String
        let isLocal: Bool
    }

    private enum Failure: LocalizedError, Equatable {
        case unavailable, priceChanged, funds, permission, timeOut, receipt, waitExpired, waitReporting

        var errorDescription: String? {
            switch self {
            case .unavailable: return "This host is unavailable for a private video call."
            case .priceChanged: return "The price changed. Review the current offer and try again."
            case .funds: return "There aren’t enough diamonds for this call."
            case .permission: return "Allow camera and microphone access to make a video call."
            case .timeOut: return "The host didn’t answer in time."
            case .receipt: return "Payment could not be confirmed. Check your balance before calling again."
            case .waitExpired: return "Time to add diamonds expired. The call ended."
            case .waitReporting: return "The service couldn’t confirm the call pause. The call ended."
            }
        }
    }

    @Published private(set) var phase: Phase = .offer
    @Published private(set) var quote: Quote?
    @Published private(set) var feedback = ""
    @Published private(set) var checking = false
    @Published private(set) var secondsRemaining: Int?
    @Published private(set) var rechargeSecondsRemaining: Int?
    @Published private(set) var checkingRecharge = false
    @Published private(set) var resumingRecharge = false
    @Published private(set) var incomingCaller: IncomingCaller?
    @Published private(set) var callMessages: [CallMessage] = []
    @Published private(set) var sendingCallMessage = false
    @Published private(set) var callMessageFeedback = ""
    let media = KakaRealtimeMedia()
    private let signal = KakaLiveCallSignal.shared
    private let signalOwner = UUID()
    private var incomingInvitation: KakaLiveCallSignal.Invitation?
    private var incomingAnswer: Int?
    private var incomingGiftIsFromLive: Bool?
    private var generation = UUID()
    private var session: UUID?
    private var channel = ""
    private var inviteSent = false
    private var accepted = false
    private var hasRemoteFrame = false
    private var beganBilling = false
    private var billing: Task<Void, Never>?
    private var pendingDebit: Task<[String: Any]?, Error>?
    private var billingWalletBusy = false
    private var pendingCallGift: Task<KakaVoiceGifts.Delivery, Error>?
    private var rechargeWait: RechargeWait?
    private var rechargeRegistration: Task<Void, Error>?
    private var rechargeReport: RechargeReport?
    private var endRechargeObservation: (@MainActor () -> Void)?
    private var rechargeWalletVisible = false
    private var timeout: Task<Void, Never>?
    private var callTextSetup: Task<Void, Error>?
    private var endCallTextObservation: (@MainActor () -> Void)?
    private var callTextSince: Date?

    private struct RechargeWait {
        let id = UUID()
        let session: UUID
        let channel: String
        let minimum: Decimal
        let start: TimeInterval
        let deadline: TimeInterval
        var authorized = false
        var acknowledged = 0
        var frozenAt: TimeInterval?
        var reportUncertain = false

        func pendingSeconds(at instant: TimeInterval) -> Int {
            let elapsed = min(instant, frozenAt ?? instant, deadline) - start
            return max(0, Int(floor(elapsed)) - acknowledged)
        }
    }

    private struct RechargeReport {
        let id = UUID()
        let waitID: UUID
        let seconds: Int
        let task: Task<Void, Error>
    }

    var holdsRoom: Bool { [.incoming, .contacting, .ringing, .connecting, .active, .waiting, .ending].contains(phase) }

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
            try await signal.connect(session: session)
            try verify(attempt)
            try signal.reserveCall(owner: signalOwner, session: session)
            let current = try await readQuote(room: room, session: session)
            try verify(attempt)
            guard ownsRoom() else { throw Failure.unavailable }
            guard current == agreed else {
                signal.releaseCall(owner: signalOwner)
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
            if let badge = created["guestBadge"], !(badge is NSNull), KakaRemoteClient.userID(badge) != agreed.hostID {
                throw Failure.unavailable
            }
            if let code = created["guestCode"], !(code is NSNull), (code as? String) != agreed.account {
                throw Failure.unavailable
            }
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
            try signal.bind(callID: callID, channel: createdChannel, peerID: agreed.hostID, owner: signalOwner) { [weak self] action in
                self?.receiveSignal(action, attempt: attempt)
            }
            phase = .ringing
            inviteSent = true
            setTimeout(30, attempt: attempt)
            try await signal.publish(.invite, owner: signalOwner)
            try verify(attempt)
        } catch {
            guard generation == attempt else { return }
            await finish(reason: 10, message: error.localizedDescription)
        }
    }

    func receiveIncoming(_ invite: KakaLiveCallSignal.Invitation, session: UUID) throws {
        guard phase == .offer else { throw Failure.unavailable }
        try signal.reserveCall(owner: signalOwner, session: session)
        let attempt = generation
        do {
            try signal.bind(invite, owner: signalOwner) { [weak self] action in
                self?.receiveSignal(action, attempt: attempt)
            }
        } catch {
            signal.releaseCall(owner: signalOwner)
            throw error
        }
        self.session = session
        channel = invite.channel
        incomingInvitation = invite
        phase = .incoming
        let remaining = invite.receivedAt.addingTimeInterval(30).timeIntervalSinceNow
        setTimeout(UInt64(max(1, ceil(remaining))), attempt: attempt)
    }

    func loadIncomingOffer() async {
        guard phase == .incoming, !checking, let invitation = incomingInvitation, let session else { return }
        let attempt = generation
        checking = true
        feedback = ""
        defer { if generation == attempt { checking = false } }
        do {
            let details = try await request("/voyager/dock", fields: ["venueKey": invitation.channel], session: session)
            try verify(attempt)
            guard phase == .incoming, (details["venueKey"] as? String) == invitation.channel,
                  let account = details["hostSignal"] as? String, !account.isEmpty, account.utf8.count <= 128,
                  let rate = Self.amount(details["holoFare"]) else { throw Failure.unavailable }
            try verifyIncomingCaller(details["hostToken"], invitation: invitation)
            let blocked = try await KakaRoomChat.isBlocked(userID: invitation.peerID, session: session)
            try verify(attempt)
            guard !blocked else {
                await finish(reason: 2, message: Failure.unavailable.localizedDescription)
                return
            }
            quote = Quote(hostID: invitation.peerID, account: account, entryCost: rate, entryMinutes: 0, minuteCost: rate)
            let name = (details["hostAlias"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let portrait = (details["hostPortrait"] as? String).flatMap(URL.init(string:)).flatMap { url in
                url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil ? url : nil
            }
            incomingCaller = IncomingCaller(name: name.flatMap { $0.isEmpty ? nil : String($0.prefix(80)) },
                                            portrait: portrait)
        } catch {
            guard generation == attempt, phase == .incoming, !Task.isCancelled else { return }
            if let failure = error as? KakaAccountStore.Failure, [.sessionChanged, .expired].contains(failure) {
                await finish(reason: 2, message: Failure.unavailable.localizedDescription, notifyPeer: false, serverEnded: true)
            } else {
                feedback = error.localizedDescription
            }
        }
    }

    func acceptIncoming(stillActive: @escaping () -> Bool, suspendRoom: @escaping () async -> Void) async {
        guard phase == .incoming, let session, let invitation = incomingInvitation, let quote, stillActive() else { return }
        phase = .contacting
        feedback = ""
        let attempt = generation
        do {
            let current = try await request("/voyager/dock", fields: ["venueKey": invitation.channel], session: session)
            try verify(attempt)
            guard (current["venueKey"] as? String) == invitation.channel,
                  (current["hostSignal"] as? String) == quote.account,
                  Self.amount(current["holoFare"]) == quote.minuteCost else { throw Failure.priceChanged }
            try verifyIncomingCaller(current["hostToken"], invitation: invitation)
            incomingGiftIsFromLive = Self.incomingGiftOrigin(current["beaconOrigin"], callType: invitation.callType)
            let local = try await KakaAccountStore.shared.remoteUserID(session: session)
            guard local != invitation.peerID, let peer = UInt(exactly: invitation.peerID),
                  try await walletBalance(session: session) >= quote.entryCost else { throw Failure.funds }
            try verify(attempt)
            guard stillActive(), await AVCaptureDevice.requestAccess(for: .video),
                  await AVCaptureDevice.requestAccess(for: .audio) else { throw Failure.permission }
            try verify(attempt)
            guard stillActive() else { throw Failure.unavailable }
            let token = try await request("/nebula/relay/identity-pass", session: session)
            try verify(attempt)
            guard let credential = token["relayPass"] as? String, !credential.isEmpty,
                  let listener = UInt(exactly: KakaRemoteClient.userID(token["starBadge"]) ?? local),
                  listener != peer, (token["venueKey"] as? String).map({ $0.isEmpty || $0 == invitation.channel }) ?? true else {
                throw Failure.unavailable
            }
            guard stillActive() else { throw Failure.unavailable }
            await suspendRoom()
            try verify(attempt)
            phase = .connecting
            media.onPrivateVideoEvent = { [weak self] event in self?.receiveMedia(event, attempt: attempt) }
            try await media.joinPrivateVideo(channel: invitation.channel, credential: credential,
                                             listener: listener, peer: peer, session: session)
            try verify(attempt)
            guard stillActive() else { throw Failure.unavailable }
            try await signal.publish(.accepted, owner: signalOwner)
            try verify(attempt)
            accepted = true
            try media.publishPrivateVideo()
            if hasRemoteFrame { beginBillingIfReady(attempt: attempt) }
            else { setTimeout(15, attempt: attempt) }
            await reportIncomingAnswer(1, session: session, invitation: invitation)
        } catch {
            guard generation == attempt else { return }
            if (error as? Failure) == .funds || (error as? Failure) == .permission || (error as? Failure) == .priceChanged {
                phase = .incoming
                feedback = error.localizedDescription
                if (error as? Failure) == .priceChanged { self.quote = nil }
            } else {
                await finish(reason: 10, message: error.localizedDescription)
            }
        }
    }

    private func verifyIncomingCaller(_ marker: Any?, invitation: KakaLiveCallSignal.Invitation) throws {
        guard let marker, !(marker is NSNull) else { return }
        guard let id = KakaRemoteClient.userID(marker), id == 0 || id == invitation.peerID else {
            throw Failure.unavailable
        }
    }

    private static func incomingGiftOrigin(_ source: Any?, callType: Int) -> Bool? {
        let origin: String
        if let source, !(source is NSNull) {
            guard let value = source as? String else { return nil }
            origin = value
        } else {
            origin = ""
        }
        switch (callType, origin) {
        case (4, "liveCall"): return true
        case (1, ""), (1, "directCall"): return false
        default: return nil
        }
    }

    func hangUp() async {
        guard holdsRoom else { return }
        await finish(reason: 1)
    }

    private var giftIsFromLive: Bool? { incomingInvitation == nil ? true : incomingGiftIsFromLive }

    var canOpenCallGifts: Bool { phase == .active && giftIsFromLive != nil }

    func callGiftCatalog() async throws -> KakaPeerGifts.Catalog {
        guard canOpenCallGifts, let session, let quote, !channel.isEmpty else { throw KakaLiveGifts.Failure.unavailable }
        let attempt = generation
        let target = channel
        return try await KakaPeerGifts.catalog(scene: "CALL", peerID: quote.hostID, session: session) {
            self.canOpenCallGifts && self.generation == attempt && self.channel == target
        }
    }

    func sendCallGift(_ gift: KakaPeerGifts.Gift, quantity: Int) async throws -> KakaVoiceGifts.Delivery {
        guard canOpenCallGifts, let fromLive = giftIsFromLive, let session, let quote,
              !channel.isEmpty else { throw KakaLiveGifts.Failure.unavailable }
        guard pendingCallGift == nil, !billingWalletBusy else { throw KakaLiveGifts.Failure.busy }
        let attempt = generation
        let target = channel
        let operation = Task { @MainActor in
            if self.incomingInvitation != nil,
               try await KakaRoomChat.isBlocked(userID: quote.hostID, expectedAccount: quote.account, session: session) {
                throw KakaLiveGifts.Failure.unavailable
            }
            return try await KakaPeerGifts.send(gift, quantity: quantity,
                                                destination: .call(channel: target, account: quote.account, fromLive: fromLive),
                                                peerID: quote.hostID, session: session) {
                self.canOpenCallGifts && self.generation == attempt && self.channel == target
                    && self.quote == quote && self.giftIsFromLive == fromLive
                    && UIApplication.shared.applicationState == .active
            }
        }
        pendingCallGift = operation
        defer { pendingCallGift = nil }
        return try await operation.value
    }

    @discardableResult
    func sendCallMessage(_ text: String) async -> Bool {
        guard phase == .active, !sendingCallMessage, let session, let quote else { return false }
        let attempt = generation
        let target = channel
        sendingCallMessage = true
        callMessageFeedback = ""
        defer { if generation == attempt { sendingCallMessage = false } }
        do {
            try await prepareCallText(session: session, quote: quote, channel: target, attempt: attempt)
            let sent = try await KakaRoomChat.sendCallText(text, session: session, peerID: quote.hostID,
                                                          account: quote.account, channel: target) {
                self.generation == attempt && self.phase == .active && self.channel == target
                    && UIApplication.shared.applicationState == .active
            }
            guard generation == attempt, phase == .active || phase == .waiting else { return false }
            appendCallMessage(sent, isLocal: true)
            return true
        } catch {
            guard generation == attempt, phase == .active || phase == .waiting, !Task.isCancelled else { return false }
            if (error as? KakaAccountStore.Failure) == .invalidInput {
                callMessageFeedback = "Enter a message of up to 280 characters."
            } else {
                callMessageFeedback = "Message delivery could not be confirmed."
            }
            return false
        }
    }

    private func prepareCallText(session: UUID, quote: Quote, channel: String, attempt: UUID) async throws {
        try verify(attempt)
        if endCallTextObservation != nil { return }
        if let callTextSetup {
            try await callTextSetup.value
            return
        }
        guard let callTextSince else { throw Failure.unavailable }
        let setup = Task { @MainActor in
            let observation = try await KakaRoomChat.observeCallText(session: session, peerID: quote.hostID,
                account: quote.account, channel: channel, since: callTextSince) { [weak self] text in
                guard let self, generation == attempt, self.channel == channel,
                      phase == .active || phase == .waiting else { return }
                appendCallMessage(text, isLocal: false)
            }
            do { try verify(attempt) } catch { observation(); throw error }
            endCallTextObservation = observation
        }
        callTextSetup = setup
        defer { if generation == attempt { callTextSetup = nil } }
        try await setup.value
    }

    private func appendCallMessage(_ text: String, isLocal: Bool) {
        callMessages.append(CallMessage(text: text, isLocal: isLocal))
        if callMessages.count > 30 { callMessages.removeFirst() }
    }

    private func readQuote(room: KakaNativeRoom, session: UUID) async throws -> Quote {
        let result = try await request("/nebula/studio/retrieve", fields: ["habitatTag": room.serverID], session: session)
        let fields = result["venueBrief"] as? [String: Any] ?? result
        let rawHost = fields["anchor"] as? [String: Any] ?? fields["anchorInfo"] as? [String: Any] ?? fields
        let host = rawHost["venueBrief"] as? [String: Any] ?? rawHost["astralPortrait"] as? [String: Any]
            ?? rawHost["user"] as? [String: Any] ?? rawHost
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
            let message = action == .declined ? "The host declined the call." : "The other person ended the call."
            Task { await finish(reason: 2, message: message, notifyPeer: false, answerOutcome: action == .cancelled ? 4 : nil) }
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
        callTextSince = Date()
        let callChannel = channel
        Task { @MainActor [weak self] in
            try? await self?.prepareCallText(session: session, quote: quote, channel: callChannel, attempt: attempt)
        }
        billing = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { billingWalletBusy = false }
            var first = true
            var nextCost = quote.entryCost
            do {
                while generation == attempt && !Task.isCancelled {
                    if let pendingCallGift { _ = try? await pendingCallGift.value }
                    try verify(attempt)
                    billingWalletBusy = true
                    let balance = try await walletBalance(session: session)
                    try verify(attempt)
                    if balance < nextCost {
                        guard !first, incomingInvitation == nil else { throw Failure.funds }
                        try await waitForRecharge(quote: quote, minimum: nextCost, session: session, attempt: attempt)
                        try verify(attempt)
                    }
                    if phase == .waiting, !canResumeRecharge { throw Failure.waitExpired }
                    let path = first ? "/voyager/ignition" : "/voyager/debit"
                    let target = channel
                    let debit = Task { @MainActor in
                        try verify(attempt)
                        if phase == .waiting, !canResumeRecharge { throw Failure.waitExpired }
                        return try await debitReceipt(path, channel: target, session: session)
                    }
                    pendingDebit = debit
                    let result = try await debit.value
                    pendingDebit = nil
                    try verify(attempt)
                    if (result == nil && !first) || Self.flag(result?["cheerShortfall"]) == true {
                        Task { await finish(reason: 5, message: Failure.funds.localizedDescription,
                                            notifyPeer: false, serverEnded: true) }
                        return
                    }
                    guard let receipt = result, !receipt.isEmpty,
                          (receipt["venueKey"] as? String).map({ $0.isEmpty || $0 == target }) ?? true else {
                        throw Failure.receipt
                    }
                    let marker = receipt["starMarker"]
                    let interval: Int64? = marker == nil || marker is NSNull ? 0 : KakaRemoteClient.userID(marker)
                    guard let interval, (0...86400).contains(interval) else { throw Failure.receipt }
                    if phase == .waiting {
                        guard canResumeRecharge else { throw Failure.waitExpired }
                        try media.publishPrivateVideo()
                        clearRechargeWait()
                        feedback = ""
                    }
                    phase = .active
                    billingWalletBusy = false
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
                let failure = error as? Failure ?? .receipt
                let reason = failure == .waitExpired || failure == .funds ? 5 : 8
                Task { await finish(reason: reason, message: failure.localizedDescription) }
            }
        }
    }

    @discardableResult
    func setRechargeWalletVisible(_ visible: Bool) -> Bool {
        if visible, phase != .waiting || resumingRecharge { return false }
        rechargeWalletVisible = visible
        return true
    }

    private var canResumeRecharge: Bool {
        phase == .waiting && rechargeWait?.authorized == true
            && !rechargeWalletVisible && UIApplication.shared.applicationState == .active
    }

    func refreshRechargeStatus() async {
        guard phase == .waiting, !checkingRecharge, let wait = rechargeWait, wait.frozenAt == nil else { return }
        checkingRecharge = true
        defer { checkingRecharge = false }
        do {
            let balance = try await walletBalance(session: wait.session)
            guard phase == .waiting, let current = rechargeWait, current.id == wait.id,
                  current.frozenAt == nil else { return }
            if balance < current.minimum {
                feedback = Failure.funds.localizedDescription
            } else {
                feedback = current.authorized ? "Checking whether your call can resume…" : "Waiting for the recharge confirmation."
            }
        } catch {
            if phase == .waiting, rechargeWait?.id == wait.id {
                feedback = "The balance couldn’t be refreshed. Try checking again."
            }
        }
    }

    private func waitForRecharge(quote: Quote, minimum: Decimal, session: UUID, attempt: UUID) async throws {
        guard phase == .active, !channel.isEmpty else { throw Failure.funds }
        let started = ProcessInfo.processInfo.systemUptime
        let noticeSince = Date()
        media.pausePrivateVideo()
        let target = channel
        let settings = try await request("/console/core-laws", session: session)["studioSetup"] as? [String: Any]
        try verify(attempt)
        guard let settings, Self.flag(settings["transitReady"]) == true else { throw Failure.funds }
        let duration = Self.positiveSeconds(settings["countdownTicks"], fallback: 60)
        let cadence = Self.positiveSeconds(settings["signalPulseSpan"], fallback: 30)
        let wait = RechargeWait(session: session, channel: target, minimum: minimum, start: started,
                                deadline: started + Double(duration))
        rechargeWait = wait
        phase = .waiting
        secondsRemaining = nil
        rechargeSecondsRemaining = min(duration, max(0, Int(ceil(wait.deadline - ProcessInfo.processInfo.systemUptime))))
        feedback = "Add diamonds to resume this call."

        let observation = try await KakaRoomChat.observeCallRecharge(session: session, channel: target, since: noticeSince) { [weak self] in
            guard let self, generation == attempt, phase == .waiting, rechargeWait?.id == wait.id,
                  ProcessInfo.processInfo.systemUptime < wait.deadline else { return }
            rechargeWait?.authorized = true
        }
        do { try verify(attempt) } catch { observation(); throw error }
        endRechargeObservation = observation

        let registration = Task { @MainActor in
            try await self.postRecharge("/voyager/transit/await", fields: ["venueKey": target, "hostBadge": quote.hostID],
                                        session: session, requiresConfirmation: true)
        }
        rechargeRegistration = registration
        do { try await registration.value } catch { throw Failure.waitReporting }
        try verify(attempt)

        var nextWalletCheck = started
        while phase == .waiting {
            try verify(attempt)
            let now = ProcessInfo.processInfo.systemUptime
            let remaining = max(0, Int(ceil(wait.deadline - now)))
            rechargeSecondsRemaining = remaining
            guard remaining > 0, let current = rechargeWait, current.id == wait.id else { throw Failure.waitExpired }

            if current.pendingSeconds(at: now) >= cadence {
                try await flushRechargeWait(at: now)
                try verify(attempt)
            }

            if canResumeRecharge, now >= nextWalletCheck, !checkingRecharge {
                nextWalletCheck = now + 2
                let balance = try? await walletBalance(session: session)
                try verify(attempt)
                let resumeAt = ProcessInfo.processInfo.systemUptime
                guard resumeAt < wait.deadline else { throw Failure.waitExpired }
                if let balance, balance >= minimum, canResumeRecharge {
                    resumingRecharge = true
                    rechargeWait?.frozenAt = resumeAt
                    try await flushRechargeWait(at: resumeAt)
                    try verify(attempt)
                    guard ProcessInfo.processInfo.systemUptime < wait.deadline else { throw Failure.waitExpired }
                    if canResumeRecharge { return }
                    rechargeWait?.frozenAt = nil
                    resumingRecharge = false
                }
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw CancellationError()
    }

    private func flushRechargeWait(at instant: TimeInterval, closing: Bool = false) async throws {
        if let pending = rechargeReport { try await settleRechargeReport(pending) }
        guard phase == (closing ? .ending : .waiting), let wait = rechargeWait else { return }
        guard !wait.reportUncertain else { throw Failure.waitReporting }
        let delta = wait.pendingSeconds(at: instant)
        guard delta > 0 else { return }
        let report = RechargeReport(waitID: wait.id, seconds: delta, task: Task { @MainActor in
            try await self.postRecharge("/voyager/transit/ticks", fields: ["venueKey": wait.channel, "launchMoment": delta],
                                        session: wait.session, requiresConfirmation: false)
        })
        rechargeReport = report
        try await settleRechargeReport(report)
    }

    private func settleRechargeReport(_ report: RechargeReport) async throws {
        do {
            try await report.task.value
            if rechargeReport?.id == report.id {
                rechargeReport = nil
                if rechargeWait?.id == report.waitID { rechargeWait?.acknowledged += report.seconds }
            }
        } catch {
            if rechargeReport?.id == report.id {
                rechargeReport = nil
                // This endpoint increments on the server. An unknown result must not be replayed.
                if rechargeWait?.id == report.waitID { rechargeWait?.reportUncertain = true }
            }
            throw Failure.waitReporting
        }
    }

    private func settleRechargeWaitAtEnd(at instant: TimeInterval) async {
        endRechargeObservation?()
        endRechargeObservation = nil
        defer { clearRechargeWait() }
        guard let registration = rechargeRegistration else { return }
        do {
            try await registration.value
            try await flushRechargeWait(at: instant, closing: true)
        } catch {
            // The call still has to close if the wait could not be accounted for.
        }
    }

    private func clearRechargeWait() {
        endRechargeObservation?()
        endRechargeObservation = nil
        rechargeWait = nil
        rechargeRegistration = nil
        rechargeReport = nil
        rechargeSecondsRemaining = nil
        rechargeWalletVisible = false
        resumingRecharge = false
    }

    private func postRecharge(_ path: String, fields: [String: Any], session: UUID, requiresConfirmation: Bool) async throws {
        let data = try await KakaAccountStore.shared.call(path: path, body: try KakaRemoteClient.json(fields), session: session)
        let acknowledgement = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let confirmed = Self.flag(acknowledgement)
        guard confirmed == true || (!requiresConfirmation && acknowledgement is NSNull) else {
            throw Failure.waitReporting
        }
    }

    private static func positiveSeconds(_ value: Any?, fallback: Int) -> Int {
        guard let seconds = KakaRemoteClient.userID(value), (1...3600).contains(seconds) else { return fallback }
        return Int(seconds)
    }

    private func setTimeout(_ duration: UInt64, attempt: UUID) {
        timeout?.cancel()
        timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: duration * 1_000_000_000)
            guard !Task.isCancelled, let self, generation == attempt else { return }
            let message = incomingInvitation != nil && !accepted ? "The incoming call expired." : Failure.timeOut.localizedDescription
            Task { await finish(reason: 4, message: message, answerOutcome: 3) }
        }
    }

    private func finish(reason: Int, message: String = "", notifyPeer: Bool = true, serverEnded: Bool = false,
                        answerOutcome: Int? = nil) async {
        guard holdsRoom, phase != .ending else { return }
        let established = accepted || beganBilling
        let closingChannel = channel
        let closingSession = session
        let closingWaitAt = ProcessInfo.processInfo.systemUptime
        let settlingDebit = pendingDebit
        let settlingGift = pendingCallGift
        phase = .ending
        generation = UUID()
        callTextSetup?.cancel()
        callTextSetup = nil
        endCallTextObservation?()
        endCallTextObservation = nil
        callTextSince = nil
        callMessages.removeAll()
        sendingCallMessage = false
        callMessageFeedback = ""
        billing?.cancel()
        timeout?.cancel()
        media.onPrivateVideoEvent = nil
        media.pausePrivateVideo()
        await media.leave()
        if notifyPeer {
            if established { _ = try? await signal.publish(.ended, owner: signalOwner) }
            else if incomingInvitation != nil { _ = try? await signal.publish(.declined, owner: signalOwner) }
            else if inviteSent { _ = try? await signal.publish(.cancelled, owner: signalOwner) }
        }
        signal.releaseCall(owner: signalOwner)
        if !serverEnded, let closingSession, let invitation = incomingInvitation, !established {
            await reportIncomingAnswer(answerOutcome ?? 2, session: closingSession, invitation: invitation)
        }
        _ = try? await settlingDebit?.value
        _ = try? await settlingGift?.value
        pendingDebit = nil
        await settleRechargeWaitAtEnd(at: closingWaitAt)
        if !serverEnded, (incomingInvitation == nil || established), !closingChannel.isEmpty, let closingSession {
            let path = established ? "/voyager/closure" : "/voyager/lapse"
            let cause: Int
            if established {
                cause = reason == 5 ? 3 : (incomingInvitation != nil ? 2 : 1)
            } else {
                cause = reason == 4 ? 2 : 7
            }
            let fields: [String: Any] = ["venueKey": closingChannel, established ? "closureCause" : "encoreCause": cause]
            _ = try? await request(path, fields: fields, session: closingSession)
        }
        secondsRemaining = nil
        feedback = message
        phase = .finished
    }

    private func reportIncomingAnswer(_ outcome: Int, session: UUID, invitation: KakaLiveCallSignal.Invitation) async {
        guard incomingAnswer == nil else { return }
        incomingAnswer = outcome
        let elapsed = outcome == 2 ? 0 : max(0, min(60, Date().timeIntervalSince(invitation.receivedAt)))
        _ = try? await request("/voyager/voice/ratio", fields: ["venueKey": invitation.channel, "stageMode": 1,
            "showGenre": outcome, "replyMoment": elapsed, "sceneDrift": 0, "signalLedger": "ios"], session: session)
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

    private func debitReceipt(_ path: String, channel: String, session: UUID) async throws -> [String: Any]? {
        let body = try KakaRemoteClient.json(["venueKey": channel])
        let data = try await KakaAccountStore.shared.call(path: path, body: body, session: session)
        let result = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if result is NSNull { return nil }
        guard let fields = result as? [String: Any] else { throw Failure.receipt }
        return fields
    }

    private static func amount(_ value: Any?) -> Decimal? {
        let raw: String
        if let text = value as? String {
            raw = text
        } else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            raw = number.stringValue
        } else {
            return nil
        }
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
