import CoreFoundation
import Foundation

@MainActor
final class KakaLiveGifts {
    static let shared = KakaLiveGifts()

    enum Failure: String, Error {
        case unavailable = "gift-unavailable"
        case refresh = "gift-refresh"
        case busy = "gift-busy"
        case balance = "gift-balance"
    }

    typealias Audience = @MainActor (Int64?, String?) -> Bool

    private struct Host: Equatable {
        let id: Int64
        let relay: String
        let channel: String
        let name: String
    }

    private struct Gift: Equatable {
        let id: Int64
        let name: String
        let cost: Decimal
        let image: String
    }

    private struct Duel: Equatable {
        let id: String
        let opponent: Int64
        let channel: String
    }

    private struct Offer {
        let session: UUID
        let room: Int64
        let host: Host
        let gifts: [Gift]
        let balance: Decimal
        let duel: Duel?
        let expires: Date
    }

    private var offer: Offer?
    fileprivate static var checkoutActive = false

    func preview(roomID: Int64, session: UUID, isAudience: Audience) async throws -> Data {
        guard roomID > 0, isAudience(nil, nil) else { throw Failure.unavailable }
        let current = try await quote(roomID: roomID, session: session, isAudience: isAudience)
        return try catalogPayload(current)
    }

    func perform(operation: String, roomID: Int64, giftID: Int64?, quantity: Int, session: UUID,
                 isAudience: @escaping Audience) async throws -> Data {
        guard !Self.checkoutActive else { throw Failure.busy }
        guard roomID > 0, isAudience(nil, nil) else { throw Failure.unavailable }
        Self.checkoutActive = true
        defer { Self.checkoutActive = false }

        switch operation {
        case "gift.catalog" where giftID == nil:
            offer = nil
            let current = try await quote(roomID: roomID, session: session, isAudience: isAudience)
            offer = current
            return try catalogPayload(current)
        case "gift.send":
            guard (1...9_999).contains(quantity), let giftID, let previous = offer,
                  previous.session == session, previous.room == roomID,
                  previous.expires > Date(), let chosen = previous.gifts.first(where: { $0.id == giftID }),
                  isAudience(previous.host.id, previous.host.channel) else { throw Failure.refresh }
            offer = nil
            let latest = try await quote(roomID: roomID, session: session, isAudience: isAudience)
            guard latest.host == previous.host, latest.duel == previous.duel,
                  let current = latest.gifts.first(where: { $0.id == giftID }),
                  current.name == chosen.name, current.cost == chosen.cost else { throw Failure.refresh }
            guard latest.balance >= current.cost * Decimal(quantity) else { throw Failure.balance }
            return try await send(current, quantity: quantity, room: latest, isAudience: isAudience)
        default:
            throw Failure.unavailable
        }
    }

    private func catalogPayload(_ offer: Offer) throws -> Data {
        let gifts: [[String: Any]] = offer.gifts.map { gift in
            ["id": String(gift.id), "name": gift.name, "cost": Self.display(gift.cost),
             "image": gift.image, "available": offer.balance >= gift.cost]
        }
        return try KakaRemoteClient.json(["host": offer.host.name, "gifts": gifts,
                                          "balance": Self.display(offer.balance), "duel": offer.duel != nil])
    }

    private func quote(roomID: Int64, session: UUID, isAudience: Audience) async throws -> Offer {
        let payer = try await KakaAccountStore.shared.remoteUserID(session: session)
        let data = try await request("/nebula/studio/retrieve", fields: ["habitatTag": roomID], session: session)
        let result = try KakaRemoteClient.object(data)
        let room = (result["venueBrief"] as? [String: Any]).flatMap {
            Self.identifier($0, ["habitatTag", "orbitMark"]) == roomID ? $0 : nil
        } ?? result
        guard Self.identifier(room, ["habitatTag", "orbitMark"]) == roomID else { throw Failure.unavailable }
        let rawDuel = result["beaconCondition"] ?? room["beaconCondition"]
        let phase = rawDuel == nil || rawDuel is NSNull ? 0 : KakaRemoteClient.userID(rawDuel)
        guard let phase, (0...10).contains(phase),
              ![room["onstage"], result["onstage"]].contains(where: { Self.flag($0) == false }) else {
            throw Failure.unavailable
        }
        let rawHost = (room["anchor"] as? [String: Any]) ?? (room["anchorInfo"] as? [String: Any]) ?? room
        let profile = (rawHost["venueBrief"] as? [String: Any]) ?? (rawHost["astralPortrait"] as? [String: Any])
            ?? (rawHost["user"] as? [String: Any]) ?? rawHost
        guard let hostID = Self.identifier(profile, ["voyagerBadge", "orbitMark"])
                ?? Self.identifier(room, ["voyagerBadge"]), hostID != payer else { throw Failure.unavailable }
        let channel = Self.first(room, ["studioRoute", "venueKey"])
        let relay = Self.first(profile, ["relayCode"])
        let name = Self.first(profile, ["nickname", "castMoniker"])
        guard !channel.isEmpty, !relay.isEmpty, !name.isEmpty,
              isAudience(hostID, channel) else { throw Failure.unavailable }

        let catalogData = try await request("/comet/offering/fourth-array", fields: ["horizon": "LIVE", "hostBadge": hostID],
                                            session: session)
        let catalog = try KakaRemoteClient.object(catalogData)
        guard isAudience(hostID, channel) else { throw Failure.unavailable }
        let identity = Host(id: hostID, relay: relay, channel: channel, name: name)
        let gifts = Self.gifts(in: catalog)
        let summary = catalog["signalBrief"] as? [String: Any]
        let balance: Decimal
        if let amount = Self.number(catalog["userDiamond"] ?? summary?["rehearsalCopy"]), amount >= 0 {
            balance = amount
        } else {
            balance = try await wallet(session: session)
        }
        let duel = try await duelContext(phase: phase, roomID: roomID, host: identity, session: session)
        guard isAudience(hostID, channel) else { throw Failure.unavailable }
        return Offer(session: session, room: roomID, host: identity, gifts: gifts, balance: balance,
                     duel: duel, expires: Date().addingTimeInterval(120))
    }

    private func duelContext(phase: Int64, roomID: Int64, host: Host, session: UUID) async throws -> Duel? {
        guard [3, 4, 5, 6, 7, 8, 10].contains(phase) else { return nil }
        let data = try await request("/nebula/duel/brief", fields: ["habitatTag": roomID], session: session)
        let detail = try KakaRemoteClient.object(data)
        for (key, expected) in [("habitatTag", roomID), ("fanBadge", host.id)] {
            guard let value = detail[key], !(value is NSNull), (value as? String) != "" else { continue }
            guard let id = KakaRemoteClient.userID(value), id == 0 || id == expected else { throw Failure.refresh }
        }
        let curtain = Self.first(detail, ["curtainRelay"])
        guard curtain.isEmpty || curtain == host.channel,
              let status = KakaRemoteClient.userID(detail["beaconCondition"]), (0...10).contains(status) else {
            throw Failure.refresh
        }
        guard [7, 8].contains(status) else { return nil }
        let id = Self.first(detail, ["cometMarker"])
        let channel = Self.first(detail, ["flankRelayId"])
        guard KakaRealtimeMedia.LiveDuel.Ranking.validID(id),
              let opponent = Self.identifier(detail, ["flankPilotTag"]), opponent != host.id,
              !channel.isEmpty, channel != host.channel, channel.utf8.count <= 64 else { throw Failure.refresh }
        return Duel(id: id, opponent: opponent, channel: channel)
    }

    private func send(_ gift: Gift, quantity: Int, room: Offer, isAudience: Audience) async throws -> Data {
        guard isAudience(room.host.id, room.host.channel) else { throw Failure.unavailable }
        let status: String
        var receiptBalance: Decimal?
        do {
            let data = try await request("/nebula/cheer/transmit", fields: [
                "habitatTag": room.room, "studioCipher": room.host.relay, "nebulaCondition": room.duel == nil ? 0 : 1,
                "beaconMark": gift.id, "tally": quantity
            ], session: room.session)
            let receipt = try KakaRemoteClient.object(data)
            if Self.flag(receipt["spotlightWin"]) == true {
                status = "sent"
                receiptBalance = Self.number(receipt["freshCredit"] ?? receipt["userDiamond"] ?? receipt["starGem"])
            } else {
                status = Self.flag(receipt["spotlightWin"]) == false ? "declined" : "uncertain"
            }
        } catch let sessionError as KakaAccountStore.Failure where sessionError == .expired || sessionError == .sessionChanged {
            throw sessionError
        } catch {
            // The server may have received the debit. Never repeat it to recover a response.
            status = "uncertain"
        }
        var result: [String: Any] = ["status": status]
        let refreshed = try? await wallet(session: room.session)
        if let balance = receiptBalance ?? refreshed, balance >= 0 {
            result["balance"] = Self.display(balance)
        }
        return try KakaRemoteClient.json(result)
    }

    private func wallet(session: UUID) async throws -> Decimal {
        let data = try await request("/r2/voyager/brief", fields: [:], session: session)
        let profile = try KakaRemoteClient.object(data)
        guard let amount = Self.number(profile["starGems"]), amount >= 0 else { throw Failure.balance }
        return amount
    }

    private func request(_ path: String, fields: [String: Any], session: UUID) async throws -> Data {
        let body = try KakaRemoteClient.json(fields)
        return try await KakaAccountStore.shared.call(path: path, body: body, session: session)
    }

    private static func gifts(in catalog: [String: Any]) -> [Gift] {
        guard let sections = catalog["panels"] as? [[String: Any]] else { return [] }
        let summary = catalog["signalBrief"] as? [String: Any]
        let level = KakaRemoteClient.userID(summary?["orbitTier"]) ?? 0
        var seen = Set<Int64>()
        var result: [Gift] = []
        for section in sections.prefix(40) {
            let category = first(section, ["panelGlyph", "showGenre"])
            guard ordinary(category), ordinary(first(section, ["panelTitle"])),
                  let entries = section["stardustTokens"] as? [[String: Any]] else { continue }
            for entry in entries.prefix(100) {
                let genre = first(entry, ["showGenre", "panelGlyph"])
                guard let id = identifier(entry, ["beaconMark", "orbitMark"]),
                      let cost = number(entry["signalCost"] ?? entry["stardustCost"] ?? entry["starGem"]), cost >= 0,
                      ordinary(genre), flag(entry["beaconProof"]) == true, flag(entry["guardianOnly"]) != true,
                      (KakaRemoteClient.userID(entry["beaconTier"]) ?? 0) <= 0 else { continue }
                let badges = ["EXCLUSIVE", "VIP", "SVIP"]
                let gated = badges.contains(genre.uppercased()) || badges.contains(category.uppercased())
                let minimum = KakaRemoteClient.userID(entry["orbitTier"] ?? entry["unlockLevel"]) ?? 0
                if gated && (flag(entry["gateOpen"]) != true || level < minimum) { continue }
                let scope = first(entry, ["orbitScope"]).split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                }
                if !scope.isEmpty && !scope.contains("1") && !scope.contains("LIVE_ROOM_BOTTOM") { continue }
                let label = first(entry, ["voyagerLabel", "marquee"])
                guard !label.isEmpty, seen.insert(id).inserted else { continue }
                let art = first(entry, ["nebulaTile", "orbitGlyph", "nebulaCanvas", "cometGlyph", "relayLink"])
                result.append(Gift(id: id, name: label, cost: cost, image: art))
                if result.count >= 100 { return result }
            }
        }
        return result
    }

    fileprivate static func first(_ fields: [String: Any], _ aliases: [String]) -> String {
        for name in aliases {
            if let value = fields[name] as? String, !value.isEmpty { return value }
        }
        return ""
    }

    fileprivate static func identifier(_ fields: [String: Any], _ aliases: [String]) -> Int64? {
        for name in aliases {
            if let id = KakaRemoteClient.userID(fields[name]), id > 0 { return id }
        }
        return nil
    }

    fileprivate static func flag(_ value: Any?) -> Bool? {
        if let text = value as? String {
            switch text.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        }
        if let number = value as? NSNumber {
            if number == 1 { return true }
            if number == 0 { return false }
        }
        return nil
    }

    fileprivate static func number(_ value: Any?) -> Decimal? {
        let text: String
        if let value = value as? String {
            text = value
        } else if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
            text = value.stringValue
        } else {
            return nil
        }
        guard text.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil else { return nil }
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
    }

    fileprivate static func ordinary(_ value: String) -> Bool {
        let tag = value.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().filter { $0.isLetter || $0.isNumber }
        return !["lucky", "luckygift", "guardian", "guardiangift", "named", "namegift", "namedgift"].contains(tag)
    }

    static func display(_ number: Decimal) -> String { NSDecimalNumber(decimal: number).stringValue }
}

@MainActor
enum KakaPeerGifts {
    struct Gift: Identifiable, Equatable {
        let id: Int64
        let name: String
        let cost: Decimal
        let image: URL?
        let effect: URL?
        fileprivate let eligibility: [String]
    }

    struct Catalog {
        let gifts: [Gift]
        let balance: Decimal
    }

    enum Destination {
        case message(account: String)
        case call(channel: String, account: String, fromLive: Bool)

        var scene: String {
            switch self {
            case .message: return "IM"
            case .call: return "CALL"
            }
        }
    }

    static func catalog(scene: String, peerID: Int64, session: UUID,
                        stillValid: @MainActor () -> Bool) async throws -> Catalog {
        guard ["IM", "CALL"].contains(scene), peerID > 0, stillValid() else { throw KakaLiveGifts.Failure.unavailable }
        let payer = try await KakaAccountStore.shared.remoteUserID(session: session)
        guard peerID != payer, stillValid() else { throw KakaLiveGifts.Failure.unavailable }
        let payload = try await request("/comet/offering/third-array", fields: ["horizon": scene, "hostBadge": peerID],
                                        session: session)
        let summary = payload["signalBrief"] as? [String: Any]
        let info = payload["info"] as? [String: Any]
        let level = KakaRemoteClient.userID(summary?["orbitTier"] ?? info?["level"]) ?? 0
        let balance: Decimal
        if let value = KakaLiveGifts.number(payload["userDiamond"] ?? summary?["rehearsalCopy"] ?? info?["draft"]) {
            balance = value
        } else {
            balance = try await wallet(session: session)
        }
        try Task.checkCancellation()
        guard stillValid() else { throw KakaLiveGifts.Failure.unavailable }
        let list = payload["stardustArray"] as? [String: Any]
        let rows = payload["stardustArray"] as? [[String: Any]]
            ?? ["gridBands", "rows", "records", "data"].lazy.compactMap { list?[$0] as? [[String: Any]] }.first
            ?? []
        var seen = Set<Int64>()
        let gifts = rows.prefix(200).compactMap { row -> Gift? in
            let category = KakaLiveGifts.first(row, ["showGenre", "panelGlyph", "catalogSection"])
            let minimumLevel = KakaRemoteClient.userID(row["orbitTier"] ?? row["unlockLevel"]) ?? 0
            let unlocked = KakaLiveGifts.flag(row["gateOpen"])
            let gated = ["EXCLUSIVE", "VIP", "SVIP"].contains(category.uppercased())
            guard let id = KakaLiveGifts.identifier(row, ["beaconMark", "orbitMark"]),
                  let cost = KakaLiveGifts.number(row["signalCost"] ?? row["stardustCost"] ?? row["starGem"]),
                  KakaLiveGifts.ordinary(category), KakaLiveGifts.flag(row["beaconProof"]) == true,
                  KakaLiveGifts.flag(row["guardianOnly"]) != true,
                  (KakaRemoteClient.userID(row["beaconTier"]) ?? 0) <= 0,
                  !gated || (unlocked == true && level >= minimumLevel) else { return nil }
            let name = KakaLiveGifts.first(row, ["voyagerLabel", "marquee"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.utf8.count <= 240, seen.insert(id).inserted else { return nil }
            let art = KakaLiveGifts.first(row, ["nebulaTile", "orbitGlyph", "nebulaCanvas", "cometGlyph", "relayLink"])
            let image = URL(string: art).flatMap { url in
                url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil ? url : nil
            }
            let effectURLs = ["signalMotion", "giftAnimation", "animUrl", "svgaUrl", "mp4Url", "nebulaCanvas"]
                .compactMap { key -> URL? in
                    guard let source = row[key] as? String, source.utf8.count <= 2_048 else { return nil }
                    return URL(string: source)
                }
            let effect = KakaRoomGiftEffects.preferredURL(effectURLs)
            return Gift(id: id, name: name, cost: cost, image: image, effect: effect,
                        eligibility: [category, String(minimumLevel), unlocked.map { String($0) } ?? ""])
        }
        return Catalog(gifts: gifts, balance: balance)
    }

    static func send(_ gift: Gift, quantity: Int, destination: Destination, peerID: Int64, session: UUID,
                     stillValid: @MainActor () -> Bool) async throws -> KakaVoiceGifts.Delivery {
        guard !KakaLiveGifts.checkoutActive else { throw KakaLiveGifts.Failure.busy }
        guard (1...9_999).contains(quantity), stillValid() else { throw KakaLiveGifts.Failure.unavailable }
        KakaLiveGifts.checkoutActive = true
        defer { KakaLiveGifts.checkoutActive = false }
        let path: String
        let routing: [String: Any]
        let peer: String
        switch destination {
        case .message(let account):
            path = "/horizon/comms/tribute"
            routing = ["relayCode": account, "venueKey": ""]
            peer = account
        case .call(let channel, let account, let fromLive):
            guard !channel.isEmpty, channel.utf8.count <= 64 else { throw KakaLiveGifts.Failure.unavailable }
            path = "/voyager/tribute"
            routing = ["venueKey": channel, "guestCode": account, "horizon": fromLive ? "LIVE_VIDEO" : "VIDEO"]
            peer = account
        }
        let identity = try await KakaAccountStore.shared.roomMessagingIdentity(session: session)
        guard !peer.isEmpty, peer.utf8.count <= 128, peer != identity.account else { throw KakaLiveGifts.Failure.unavailable }
        let latest = try await catalog(scene: destination.scene, peerID: peerID, session: session, stillValid: stillValid)
        guard let offered = latest.gifts.first(where: { $0.id == gift.id }),
              gift.name == offered.name, gift.cost == offered.cost, gift.eligibility == offered.eligibility else {
            throw KakaLiveGifts.Failure.refresh
        }
        let total = offered.cost * Decimal(quantity)
        guard !total.isNaN else { throw KakaLiveGifts.Failure.refresh }
        let balance = try await wallet(session: session)
        guard balance >= total else { throw KakaLiveGifts.Failure.balance }
        try Task.checkCancellation()
        guard stillValid() else { throw KakaLiveGifts.Failure.unavailable }
        var fields = routing
        fields["beaconMark"] = offered.id
        fields["tally"] = quantity
        do {
            let receipt = try await request(path, fields: fields, session: session)
            guard let acknowledged = KakaLiveGifts.flag(receipt["spotlightWin"]) else { return .uncertain }
            guard acknowledged else { return .declined }
            if let refreshed = KakaLiveGifts.number(receipt["freshCredit"] ?? receipt["userDiamond"] ?? receipt["starGem"]) {
                return .sent(balance: refreshed)
            }
            return .sent(balance: try? await wallet(session: session))
        } catch {
            // A dispatched gift may have charged the wallet even when its reply is lost.
            return .uncertain
        }
    }

    private static func wallet(session: UUID) async throws -> Decimal {
        let fields = try await request("/r2/voyager/brief", fields: [:], session: session)
        guard let value = KakaLiveGifts.number(fields["starGems"]) else { throw KakaLiveGifts.Failure.balance }
        return value
    }

    private static func request(_ path: String, fields: [String: Any], session: UUID) async throws -> [String: Any] {
        let data = try await KakaAccountStore.shared.call(path: path, body: try KakaRemoteClient.json(fields), session: session)
        return try KakaRemoteClient.object(data)
    }
}

@MainActor
enum KakaVoiceGifts {
    static let recipientLimit = 20
    static let quantityLimit = 9_999

    struct Recipient: Identifiable {
        let id: Int64
        let account: String
        let name: String
        let portrait: URL?
    }

    struct Gift: Identifiable {
        let id: Int64
        let name: String
        let cost: Decimal
        let image: URL?
        fileprivate let eligibility: [String]
    }

    struct Category: Identifiable {
        let id: Int
        let name: String
        let preferred: Bool
        let gifts: [Gift]
    }

    struct Catalog {
        let categories: [Category]
        let quantities: [Int]
        let balance: Decimal
    }

    enum Delivery {
        case sent(balance: Decimal?)
        case declined
        case uncertain
    }

    enum Failure: LocalizedError {
        case changedRecipients
        case unavailable

        var errorDescription: String? {
            switch self {
            case .changedRecipients: return "People on mic have changed. Refresh to choose recipients again."
            case .unavailable: return "Gifts are unavailable in this voice room."
            }
        }
    }

    static func catalog(roomID: Int64, session: UUID, isAudience: @MainActor () -> Bool) async throws -> Catalog {
        guard roomID > 0, isAudience() else { throw Failure.unavailable }
        let data = try await request("gift/getPartyRoomGift", fields: ["roomId": roomID], session: session)
        let payload = try KakaRemoteClient.object(data)
        let walletInfo = payload["info"] as? [String: Any]
        let balance: Decimal
        if let amount = KakaLiveGifts.number(payload["userDiamond"] ?? walletInfo?["draft"]) {
            balance = amount
        } else {
            let wallet = try await KakaAccountStore.shared.call(path: "/r2/voyager/brief", body: Data("{}".utf8), session: session)
            guard let amount = KakaLiveGifts.number(try KakaRemoteClient.object(wallet)["starGems"]) else {
                throw Failure.unavailable
            }
            balance = amount
        }
        guard isAudience() else { throw Failure.unavailable }
        try Task.checkCancellation()
        var quantities: Set<Int> = [1]
        for value in (payload["sendGiftConfig"] as? [Any] ?? []).prefix(40) {
            if let amount = KakaRemoteClient.userID(value), (1...Int64(quantityLimit)).contains(amount) {
                quantities.insert(Int(amount))
            }
        }
        return Catalog(categories: categories(payload), quantities: quantities.sorted(), balance: balance)
    }

    static func send(_ gift: Gift, quantity: Int, recipients: [Recipient], roomID: Int64, session: UUID,
                     media: KakaRealtimeMedia, isAudience: @MainActor () -> Bool) async throws -> Delivery {
        guard !KakaLiveGifts.checkoutActive else { throw KakaLiveGifts.Failure.busy }
        guard (1...quantityLimit).contains(quantity), !recipients.isEmpty, recipients.count <= recipientLimit,
              Set(recipients.map(\.id)).count == recipients.count,
              Set(recipients.map(\.account)).count == recipients.count else { throw Failure.changedRecipients }
        KakaLiveGifts.checkoutActive = true
        defer { KakaLiveGifts.checkoutActive = false }

        let latest = try await catalog(roomID: roomID, session: session, isAudience: isAudience)
        guard let offered = latest.categories.lazy.flatMap(\.gifts).first(where: { $0.id == gift.id }),
              offered.name == gift.name, offered.cost == gift.cost,
              offered.eligibility == gift.eligibility else { throw KakaLiveGifts.Failure.refresh }
        guard latest.balance >= offered.cost * Decimal(quantity * recipients.count) else { throw KakaLiveGifts.Failure.balance }
        let available = try await media.voiceGiftRecipients(roomID: roomID, session: session)
        guard recipients.allSatisfy({ selected in available.contains { $0.id == selected.id && $0.account == selected.account } }) else {
            throw Failure.changedRecipients
        }
        guard isAudience() else { throw Failure.unavailable }
        try Task.checkCancellation()

        do {
            let data = try await request("gift/sendGift", fields: ["roomId": roomID, "giftId": offered.id,
                                                                  "num": quantity, "yxAccidList": recipients.map(\.account)], session: session)
            let payload = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            if payload is NSNull { return .sent(balance: nil) }
            guard let receipt = payload as? [String: Any] else { return .uncertain }
            if let success = receipt["success"] {
                guard let acknowledged = KakaLiveGifts.flag(success) else { return .uncertain }
                guard acknowledged else { return .declined }
            }
            let balance = KakaLiveGifts.number(receipt["newBalance"] ?? receipt["userDiamond"] ?? receipt["diamond"])
            return .sent(balance: balance)
        } catch {
            // Transport errors may occur after the service charged the account.
            return .uncertain
        }
    }

    private static func categories(_ payload: [String: Any]) -> [Category] {
        var seen = Set<Int64>()
        return (payload["giftInfoDtoList"] as? [[String: Any]] ?? []).prefix(40).enumerated().compactMap { id, group in
            let code = KakaLiveGifts.first(group, ["tabCode", "category"])
            let title = KakaLiveGifts.first(group, ["tabName"])
            guard KakaLiveGifts.ordinary(code), KakaLiveGifts.ordinary(title) else { return nil }
            let gifts: [Gift] = (group["giftVoList"] as? [[String: Any]] ?? []).prefix(100).compactMap { entry in
                let category = KakaLiveGifts.first(entry, ["category"])
                let name = KakaLiveGifts.first(entry, ["giftName", "name"]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let giftID = KakaLiveGifts.identifier(entry, ["giftId", "id"]), !name.isEmpty,
                      let price = KakaLiveGifts.number(entry["giftPrice"] ?? entry["price"] ?? entry["diamond"]),
                      KakaLiveGifts.ordinary(category), KakaLiveGifts.flag(entry["guardianOnly"]) != true,
                      (KakaRemoteClient.userID(entry["guardianLevel"]) ?? 0) == 0,
                      KakaLiveGifts.flag(entry["vaild"]) != false, KakaLiveGifts.flag(entry["unlock"]) != false,
                      seen.insert(giftID).inserted else { return nil }
                let image = KakaLiveGifts.first(entry, ["giftSmallImg", "giftIcon", "giftImg", "icon", "url"])
                let eligibility = [code, category, KakaLiveGifts.first(entry, ["tabCode"]),
                                   KakaLiveGifts.flag(entry["vaild"]).map { String($0) } ?? "",
                                   KakaLiveGifts.flag(entry["unlock"]).map { String($0) } ?? ""]
                return Gift(id: giftID, name: String(name.prefix(100)), cost: price, image: URL(string: image), eligibility: eligibility)
            }
            guard !gifts.isEmpty else { return nil }
            return Category(id: id, name: title.isEmpty ? "Gifts" : String(title.prefix(50)),
                            preferred: KakaLiveGifts.flag(group["isDefault"]) == true, gifts: gifts)
        }
    }

    private static func request(_ action: String, fields: [String: Any], session: UUID) async throws -> Data {
        try await KakaAccountStore.shared.call(path: "/sapi/weidou/v1/client/party/" + action,
                                               body: KakaRemoteClient.json(fields), session: session)
    }
}
