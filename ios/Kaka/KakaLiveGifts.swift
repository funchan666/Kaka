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

    private struct Offer {
        let session: UUID
        let room: Int64
        let host: Host
        let gifts: [Gift]
        let balance: Decimal
        let expires: Date
    }

    private var offer: Offer?
    private var active = false

    func perform(operation: String, roomID: Int64, giftID: Int64?, session: UUID,
                 isAudience: @escaping Audience) async throws -> Data {
        guard !active else { throw Failure.busy }
        guard roomID > 0, isAudience(nil, nil) else { throw Failure.unavailable }
        active = true
        defer { active = false }

        switch operation {
        case "gift.catalog" where giftID == nil:
            offer = nil
            let current = try await quote(roomID: roomID, session: session, isAudience: isAudience)
            offer = current
            let gifts: [[String: Any]] = current.gifts.map { gift in
                ["id": String(gift.id), "name": gift.name, "cost": Self.display(gift.cost),
                 "image": gift.image, "available": current.balance >= gift.cost]
            }
            return try KakaRemoteClient.json(["host": current.host.name, "gifts": gifts,
                                               "balance": Self.display(current.balance)])
        case "gift.send":
            guard let giftID, let previous = offer, previous.session == session, previous.room == roomID,
                  previous.expires > Date(), let chosen = previous.gifts.first(where: { $0.id == giftID }),
                  isAudience(previous.host.id, previous.host.channel) else { throw Failure.refresh }
            offer = nil
            let latest = try await quote(roomID: roomID, session: session, isAudience: isAudience)
            guard latest.host == previous.host, let current = latest.gifts.first(where: { $0.id == giftID }),
                  current.name == chosen.name, current.cost == chosen.cost else { throw Failure.refresh }
            guard latest.balance >= current.cost else { throw Failure.balance }
            return try await send(current, room: latest, isAudience: isAudience)
        default:
            throw Failure.unavailable
        }
    }

    private func quote(roomID: Int64, session: UUID, isAudience: Audience) async throws -> Offer {
        let payer = try await KakaAccountStore.shared.remoteUserID(session: session)
        let data = try await request("/nebula/studio/retrieve", fields: ["habitatTag": roomID], session: session)
        let result = try KakaRemoteClient.object(data)
        let room = (result["venueBrief"] as? [String: Any]).flatMap {
            Self.identifier($0, ["habitatTag", "orbitMark"]) == roomID ? $0 : nil
        } ?? result
        guard Self.identifier(room, ["habitatTag", "orbitMark"]) == roomID else { throw Failure.unavailable }
        let rawDuel = room["beaconCondition"] ?? result["beaconCondition"]
        let duel = rawDuel == nil || rawDuel is NSNull ? 0 : KakaRemoteClient.userID(rawDuel)
        guard let duel, [0, 1, 2].contains(duel),
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
        guard isAudience(hostID, channel) else { throw Failure.unavailable }
        return Offer(session: session, room: roomID, host: identity, gifts: gifts, balance: balance,
                     expires: Date().addingTimeInterval(120))
    }

    private func send(_ gift: Gift, room: Offer, isAudience: Audience) async throws -> Data {
        guard isAudience(room.host.id, room.host.channel) else { throw Failure.unavailable }
        let status: String
        var receiptBalance: Decimal?
        do {
            let data = try await request("/nebula/cheer/transmit", fields: [
                "habitatTag": room.room, "studioCipher": room.host.relay, "nebulaCondition": 0,
                "beaconMark": gift.id, "tally": 1
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

    private static func first(_ fields: [String: Any], _ aliases: [String]) -> String {
        for name in aliases {
            if let value = fields[name] as? String, !value.isEmpty { return value }
        }
        return ""
    }

    private static func identifier(_ fields: [String: Any], _ aliases: [String]) -> Int64? {
        for name in aliases {
            if let id = KakaRemoteClient.userID(fields[name]), id > 0 { return id }
        }
        return nil
    }

    private static func flag(_ value: Any?) -> Bool? {
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

    private static func number(_ value: Any?) -> Decimal? {
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

    private static func ordinary(_ value: String) -> Bool {
        let tag = value.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().filter { $0.isLetter || $0.isNumber }
        return !["lucky", "luckygift", "guardian", "guardiangift", "named", "namegift", "namedgift"].contains(tag)
    }

    private static func display(_ number: Decimal) -> String { NSDecimalNumber(decimal: number).stringValue }
}
