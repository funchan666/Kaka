import Foundation

enum KakaRecordStore {
    struct Snapshot: Codable, Sendable {
        let revision: Int
        let recordJSON: String?
    }

    enum Failure: Error {
        case invalidRecord
        case writeConflict
    }

    private static let limit = 512 * 1024

    static func read(accountID: UUID?) throws -> Snapshot {
        let file = try recordURL(accountID)
        do {
            guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 2 * limit else { throw Failure.invalidRecord }
            let data = try Data(contentsOf: file)
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            guard snapshot.revision > 0, let recordJSON = snapshot.recordJSON else {
                throw Failure.invalidRecord
            }
            try validate(recordJSON)
            return snapshot
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return Snapshot(revision: 0, recordJSON: nil)
        }
    }

    static func write(_ recordJSON: String, ifRevision revision: Int, accountID: UUID?) throws -> Snapshot {
        try validate(recordJSON)
        let previous = try read(accountID: accountID)
        guard previous.revision == revision, revision < Int.max else {
            throw Failure.writeConflict
        }
        let updated = Snapshot(revision: revision + 1, recordJSON: recordJSON)
        let data = try JSONEncoder().encode(updated)
        guard data.count <= 2 * limit else { throw Failure.invalidRecord }
        try data.write(to: recordURL(accountID), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return updated
    }

    static func remove(accountID: UUID) throws {
        do {
            try FileManager.default.removeItem(at: recordURL(accountID))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }

    private static func recordURL(_ accountID: UUID?) throws -> URL {
        let fm = FileManager.default
        var root = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                              appropriateFor: nil, create: true)
            .appendingPathComponent("Kaka/State", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var attributes = URLResourceValues()
        attributes.isExcludedFromBackup = true
        try root.setResourceValues(attributes)
        let file = accountID.map { "studio-v1-\($0.uuidString.lowercased()).json" } ?? "studio-v1.json"
        return root.appendingPathComponent(file)
    }

    private static func validate(_ recordJSON: String) throws {
        guard recordJSON.utf8.count <= limit,
              let object = try JSONSerialization.jsonObject(with: Data(recordJSON.utf8)) as? [String: Any],
              Self.validKeys(Set(object.keys)),
              object["schema"] as? Int == 1,
              let profile = object["profile"] as? [String: String],
              Set(profile.keys) == Set(["name", "bio", "style"]),
              (1...24).contains(profile["name"]?.count ?? 0),
              (profile["bio"]?.count ?? 121) <= 120,
              (profile["style"]?.count ?? 21) <= 20,
              let favorites = object["favorites"] as? [String], favorites.count <= 64,
              let following = (object["following"] ?? [String]()) as? [String], following.count <= 64,
              let notes = object["notes"] as? [[String: Any]], notes.count <= 64,
              let scores = object["scores"] as? [[String: Any]], scores.count <= 40,
              let reports = object["reports"] as? [[String: Any]], reports.count <= 64 else {
            throw Failure.invalidRecord
        }
    }

    private static func validKeys(_ keys: Set<String>) -> Bool {
        let original = Set(["schema", "profile", "favorites", "notes", "scores", "reports"])
        return keys == original || keys == original.union(["following"])
    }
}
