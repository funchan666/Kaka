import Foundation

@MainActor
enum KakaServiceBridge {
    private struct Route {
        let path: String
        let required: Set<String>
        let optional: Set<String>

        init(_ path: String, _ required: Set<String> = [], optional: Set<String> = []) {
            self.path = path
            self.required = required
            self.optional = optional
        }

        func accepts(_ fields: Set<String>) -> Bool {
            required.isSubset(of: fields) && fields.isSubset(of: required.union(optional))
        }
    }

    private static let routes: [String: Route] = [
        "listLiveRooms": Route("/nebula/broadcast/reels", ["stagePage", "folioScale", "desertSector"]),
        "getLiveRoom": Route("/nebula/studio/retrieve", ["habitatTag"]),
        "listVoiceRooms": Route("/sapi/weidou/v1/client/party/room/list", ["pageSize", "languageCode", "version"]),
        "voice.creation.eligibility": Route("/sapi/weidou/v1/client/party/room/getCreateRoomConditions"),
        "voice.creation.languages": Route("/sapi/weidou/v1/client/party/room/language/list"),
        "voice.creation.backgrounds": Route("/sapi/weidou/v1/client/party/room/getBgImages", ["pageSize", "offset"]),
        "voice.creation.layouts": Route("/sapi/weidou/v1/client/party/room/getRoomTempList", ["type"]),
        "voice.creation.ownedRoom": Route("/sapi/weidou/v1/client/party/room/getMyRoomAndFamilyInfo"),
        "voice.creation.submit": Route("/sapi/weidou/v1/client/party/room/create",
                                      ["roomName", "greetingMessage", "roomAvatar", "roomLanguage", "roomTempId"],
                                      optional: ["bgImgId"]),
        "voice.management.role": Route("/sapi/weidou/v1/client/party/room/getRoomInfoCard", ["roomId", "userId"]),
        "voice.management.announcement": Route("/sapi/weidou/v1/client/party/room/getAnnouncement", ["roomId"]),
        "voice.management.setAnnouncement": Route("/sapi/weidou/v1/client/party/room/editAnnouncement", ["roomId", "announcement"]),
        "voice.management.setLock": Route("/sapi/weidou/v1/client/party/room/lockRoom", ["roomId", "lockRoomFlag"], optional: ["password"]),
        "voice.management.setSeatApproval": Route("/sapi/weidou/v1/client/party/room/updateOnSeatEnable", ["roomId", "enable"]),
        "voice.management.setBackground": Route("/sapi/weidou/v1/client/party/room/setBgImages", ["roomId", "yxRoomId", "roomTempId", "bgImgId"]),
        "voice.management.seatQueue": Route("/sapi/weidou/v1/client/party/seat/getQueueSeatList", ["roomId"]),
        "voice.management.approveSeat": Route("/sapi/weidou/v1/client/party/seat/agreeSeat",
                                             ["roomId", "yxRoomId", "roomTempId", "targetUserId", "seatIndex", "operatorType"]),
        "voice.management.declineSeat": Route("/sapi/weidou/v1/client/party/seat/refuseQueueSeat",
                                             ["roomId", "yxRoomId", "roomTempId", "targetUserId"]),
        "voice.management.members": Route("/sapi/weidou/v1/client/party/room/getViewers", ["roomId", "pageNum", "pageSize"]),
        "voice.management.blocklist": Route("/sapi/weidou/v1/client/party/room/getKickOutBlacklist", ["roomId"]),
        "voice.management.administrator": Route("/sapi/weidou/v1/client/party/room/setAdmin",
                                                ["roomId", "yxRoomId", "roomTempId", "userId", "operateType"]),
        "voice.management.kick": Route("/sapi/weidou/v1/client/party/room/kickOutRoom",
                                      ["roomId", "yxRoomId", "roomTempId", "targetUserId", "seatIndex", "banType"]),
        "voice.management.unblock": Route("/sapi/weidou/v1/client/party/room/removeKickOutBlacklist",
                                          ["roomId", "yxRoomId", "roomTempId", "userId"]),
        "voice.management.lockSeat": Route("/sapi/weidou/v1/client/party/seat/lockSeat",
                                           ["roomId", "yxRoomId", "roomTempId", "seatIndex", "operatorType"]),
        "voice.management.removeOccupant": Route("/sapi/weidou/v1/client/party/seat/holdSeat",
                                                 ["roomId", "yxRoomId", "roomTempId", "seatIndex", "targetUserId", "operatorType"]),
        "listFollowing": Route("/r2/voyager/constellation", ["signalKind"]),
        "getHost": Route("/r2/voyager/identity-slate", ["voyagerBadge"]),
        "setRelationship": Route("/r2/voyager/track/traveler", ["fanHandle", "supportMode"]),
        "reportUser": Route("/nebula/echo/archive", ["castEmblem", "reviewMode"], optional: ["habitatTag", "astralAdvice"]),
        "profile.read": Route("/r2/voyager/brief"),
        "profile.update": Route("/r2/voyager/refresh", ["nickname", "cipherSeal"]),
        "support.faq": Route("/r2/voyager/liaison/anomalies"),
        "ranking.directory": Route("/horizon/nexus/grade", ["stageFormat", "orbitCycle"]),
        "ranking.liveRoom": Route("/nebula/broadcast/standing", ["habitatTag", "orbitGrade"]),
        "ranking.liveDuel": Route("/nebula/duel/ladder", ["cometMarker", "hostBadge"]),
        "ranking.voice.contribution": Route("/sapi/weidou/v1/client/party/room/rank/getContributionRanks", ["roomId", "rankType"]),
        "ranking.voice.charm": Route("/sapi/weidou/v1/client/party/room/rank/getCharmRanks", ["roomId", "rankType"]),
        "ranking.voice.room": Route("/sapi/weidou/v1/client/party/room/rank/getRoomRanks", ["roomId", "rankType"]),
        "ranking.voice.wealth": Route("/sapi/weidou/v1/client/party/room/rank/getUserRichRanks", ["roomId", "rankType"]),
        "ranking.voice.family": Route("/sapi/weidou/v1/client/party/room/rank/getPartyRichRanks", ["roomId", "rankType"]),
        "audience.live": Route("/v2/scan/stream/assembly", ["habitatTag"]),
        "directory.campaigns": Route("/beacon/bulletin/gallery", ["cosmicModes"]),
        "live.wishlist": Route("/nebula/fan/requests", ["habitatTag"]),
    ]

    private static let commerceOperations: Set<String> = [
        "commerce.catalog", "commerce.purchase", "commerce.restore", "commerce.wallet",
        "commerce.rewards", "commerce.claimReward", "commerce.level",
    ]

    static func perform(operation: String, input: [String: Any], session: UUID) async throws -> Data {
        if commerceOperations.contains(operation) {
            let productID = input["productID"] as? String
            if operation == "commerce.purchase" {
                guard input.count == 1, let productID, !productID.isEmpty, productID.utf8.count <= 180 else {
                    throw KakaAccountStore.Failure.invalidInput
                }
            } else if !input.isEmpty {
                throw KakaAccountStore.Failure.invalidInput
            }
            return try await KakaCommerce.shared.perform(operation, productID: productID, session: session)
        }
        let route: Route?
        if operation == "verse.generate" {
            guard let topic = input["topic"] as? String, !topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  topic.utf16.count <= 32, let style = input["style"] as? String,
                  ["story", "freestyle", "punch"].contains(style), let bpm = input["bpm"] as? Int,
                  (60...180).contains(bpm), let length = input["length"] as? Int, [4, 8, 16].contains(length),
                  let scheme = input["scheme"] as? String, ["AABB", "ABAB"].contains(scheme),
                  input["roomID"] == nil || input["roomID"] is NSNull || ((input["roomID"] as? String)?.utf8.count ?? Int.max) <= 64 else {
                throw KakaAccountStore.Failure.invalidInput
            }
            guard let path = configuration["versePath"], path.hasPrefix("/kaka/"),
                  path.dropFirst().split(separator: "/").allSatisfy({
                      !$0.isEmpty && $0.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
                  }) else { throw KakaAccountStore.Failure.unavailable }
            route = Route(path, ["topic", "style", "bpm", "length", "scheme"], optional: ["roomID"])
        } else {
            route = routes[operation]
        }
        if operation == "profile.update" {
            guard let name = input["nickname"] as? String, (1...24).contains(name.utf16.count),
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let bio = input["cipherSeal"] as? String, bio.utf16.count <= 120 else {
                throw KakaAccountStore.Failure.invalidInput
            }
        }
        if operation == "voice.creation.submit" {
            guard let name = input["roomName"] as? String, KakaVoiceRoomText.valid(name, limit: 20),
                  let greeting = input["greetingMessage"] as? String, KakaVoiceRoomText.valid(greeting, limit: 60),
                  let cover = input["roomAvatar"] as? String, cover.isEmpty || KakaRoomFields.url(cover) != nil,
                  let language = input["roomLanguage"] as? String, language.utf8.count <= 64,
                  let template = input["roomTempId"] as? Int64, template > 0,
                  input["bgImgId"].map({ ($0 as? Int64 ?? 0) > 0 }) ?? true else {
                throw KakaAccountStore.Failure.invalidInput
            }
        }
        guard let route, route.accepts(Set(input.keys)), JSONSerialization.isValidJSONObject(input) else {
            throw KakaAccountStore.Failure.invalidInput
        }
        switch operation {
        case let management where management.hasPrefix("voice.management."):
            try validateVoiceManagement(management, input: input)
        case "ranking.directory":
            guard let board = input["stageFormat"] as? String, ["wealth", "anchor"].contains(board),
                  let period = input["orbitCycle"] as? String, ["day", "week", "month"].contains(period) else {
                throw KakaAccountStore.Failure.invalidInput
            }
        case "ranking.liveDuel":
            guard let duel = input["cometMarker"] as? String, KakaRealtimeMedia.LiveDuel.Ranking.validID(duel),
                  let host = KakaRemoteClient.userID(input["hostBadge"]), host > 0 else {
                throw KakaAccountStore.Failure.invalidInput
            }
        case "ranking.liveRoom", "audience.live", "live.wishlist":
            guard let room = KakaRemoteClient.userID(input["habitatTag"]), room > 0 else {
                throw KakaAccountStore.Failure.invalidInput
            }
            if operation == "ranking.liveRoom" {
                guard let period = input["orbitGrade"] as? String, ["now", "today", "week"].contains(period) else {
                    throw KakaAccountStore.Failure.invalidInput
                }
            }
        case let ranking where ranking.hasPrefix("ranking.voice."):
            guard let room = KakaRemoteClient.userID(input["roomId"]), room > 0,
                  let period = input["rankType"] as? String, ["day", "week", "month"].contains(period) else {
                throw KakaAccountStore.Failure.invalidInput
            }
        case "directory.campaigns":
            guard let items = input["cosmicModes"] as? [Int], items == [2] else {
                throw KakaAccountStore.Failure.invalidInput
            }
        default:
            break
        }
        let body = try JSONSerialization.data(withJSONObject: input)
        guard body.count <= 16 * 1024 else { throw KakaAccountStore.Failure.invalidInput }
        return try await KakaAccountStore.shared.call(path: route.path, body: body, session: session)
    }

    private static func validateVoiceManagement(_ operation: String, input: [String: Any]) throws {
        guard let room = KakaRemoteClient.userID(input["roomId"]), room > 0 else {
            throw KakaAccountStore.Failure.invalidInput
        }
        switch operation {
        case "voice.management.role":
            guard let user = KakaRemoteClient.userID(input["userId"]), user > 0 else {
                throw KakaAccountStore.Failure.invalidInput
            }
        case "voice.management.setAnnouncement":
            guard input["announcement"] is String else { throw KakaAccountStore.Failure.invalidInput }
        case "voice.management.setLock":
            let locked = KakaRemoteClient.userID(input["lockRoomFlag"])
            let password = input["password"] as? String
            guard (locked == 0 && input["password"] == nil)
                    || (locked == 1 && password.map(KakaVoiceManagementContext.validPassword) == true) else {
                throw KakaAccountStore.Failure.invalidInput
            }
        case "voice.management.setSeatApproval":
            guard let enabled = KakaRemoteClient.userID(input["enable"]), (0...1).contains(enabled) else {
                throw KakaAccountStore.Failure.invalidInput
            }
        case "voice.management.members":
            guard let page = KakaRemoteClient.userID(input["pageNum"]), page > 0,
                  KakaRemoteClient.userID(input["pageSize"]) == 20 else {
                throw KakaAccountStore.Failure.invalidInput
            }
        case "voice.management.lockSeat", "voice.management.removeOccupant":
            guard let chatroom = input["yxRoomId"] as? String, !chatroom.isEmpty, chatroom.utf8.count <= 128,
                  let template = KakaRemoteClient.userID(input["roomTempId"]), template > 0,
                  let seat = KakaRemoteClient.userID(input["seatIndex"]), seat > 0,
                  let type = KakaRemoteClient.userID(input["operatorType"]) else {
                throw KakaAccountStore.Failure.invalidInput
            }
            if operation == "voice.management.lockSeat" {
                guard type == 8 || type == 9 else { throw KakaAccountStore.Failure.invalidInput }
            } else {
                guard type == 3, let user = KakaRemoteClient.userID(input["targetUserId"]), user > 0 else {
                    throw KakaAccountStore.Failure.invalidInput
                }
            }
        case "voice.management.setBackground", "voice.management.approveSeat", "voice.management.declineSeat",
             "voice.management.administrator", "voice.management.kick", "voice.management.unblock":
            guard let chatroom = input["yxRoomId"] as? String, !chatroom.isEmpty, chatroom.utf8.count <= 128,
                  let template = KakaRemoteClient.userID(input["roomTempId"]), template > 0 else {
                throw KakaAccountStore.Failure.invalidInput
            }
            let target: String
            switch operation {
            case "voice.management.setBackground": target = "bgImgId"
            case "voice.management.administrator", "voice.management.unblock": target = "userId"
            default: target = "targetUserId"
            }
            guard let targetID = KakaRemoteClient.userID(input[target]), targetID > 0 else {
                throw KakaAccountStore.Failure.invalidInput
            }
            if operation == "voice.management.approveSeat" {
                guard let seat = KakaRemoteClient.userID(input["seatIndex"]), seat >= 0,
                      KakaRemoteClient.userID(input["operatorType"]) == 1 else {
                    throw KakaAccountStore.Failure.invalidInput
                }
            } else if operation == "voice.management.administrator" {
                guard let type = KakaRemoteClient.userID(input["operateType"]), (1...2).contains(type) else {
                    throw KakaAccountStore.Failure.invalidInput
                }
            } else if operation == "voice.management.kick" {
                guard let seat = KakaRemoteClient.userID(input["seatIndex"]), seat == -1 || seat > 0,
                      let ban = KakaRemoteClient.userID(input["banType"]), (0...1).contains(ban) else {
                    throw KakaAccountStore.Failure.invalidInput
                }
            }
        default:
            break
        }
    }

    static let configuration: [String: String] = {
        guard let url = Bundle.main.url(forResource: "KakaService.private", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return values
    }()
}
