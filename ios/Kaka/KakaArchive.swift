import CryptoKit
import Foundation
import ZIPFoundation

enum KakaArchive {
    private struct FileEntry: Codable {
        let bytes: Int
        let sha256: String
    }

    private struct Index: Codable {
        let version: Int
        let archiveSHA256: String
        let files: [String: FileEntry]
    }

    private struct Installed: Codable {
        let directory: String
        let index: Index
    }

    private enum Failure: Error {
        case invalidArchive
    }

    private static let maximumBytes = 24 * 1024 * 1024
    private static let maximumEntryBytes = 8 * 1024 * 1024
    private static let maximumFiles = 256
    private static let indexVersion = 3

    static func prepare() throws -> URL {
        let fm = FileManager.default
        var root = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                              appropriateFor: nil, create: true)
            .appendingPathComponent("Kaka/Content", isDirectory: true).resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var attributes = URLResourceValues()
        attributes.isExcludedFromBackup = true
        try root.setResourceValues(attributes)

        let pointer = root.appendingPathComponent("active.json")
        let cached = try? JSONDecoder().decode(Installed.self, from: Data(contentsOf: pointer))
        let previous = cached?.index.version == indexVersion ? cached : nil
        do {
            guard let bundleIndex = Bundle.main.url(forResource: "KakaArchiveIndex", withExtension: "json"),
                  let archiveURL = Bundle.main.url(forResource: "Kaka", withExtension: "zip") else {
                throw Failure.invalidArchive
            }
            let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: bundleIndex))
            try check(index)
            let archiveSize = try archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard (1...maximumBytes).contains(archiveSize),
                  try checksum(Data(contentsOf: archiveURL, options: .mappedIfSafe)) == index.archiveSHA256 else {
                throw Failure.invalidArchive
            }

            if let previous, previous.index.archiveSHA256 == index.archiveSHA256,
               let existing = verifiedEntry(Installed(directory: previous.directory, index: index), at: root) {
                return existing
            }

            let directory = "edition-" + UUID().uuidString.lowercased()
            let output = root.appendingPathComponent(directory, isDirectory: true)
            try fm.createDirectory(at: output, withIntermediateDirectories: false)
            do {
                try extract(archiveURL, index: index, to: output)
                let installed = Installed(directory: directory, index: index)
                guard let entry = verifiedEntry(installed, at: root) else {
                    throw Failure.invalidArchive
                }
                try JSONEncoder().encode(installed).write(to: pointer, options: .atomic)
                // Keep only prior editions with the current sign-in contract.
                removeOlderEditions(at: root, keeping: Set([directory, previous?.directory].compactMap { $0 }))
                return entry
            } catch {
                try? fm.removeItem(at: output)
                throw error
            }
        } catch {
            if let previous, let existing = verifiedEntry(previous, at: root) {
                return existing
            }
            throw error
        }
    }

    private static func check(_ index: Index) throws {
        guard index.version == indexVersion, isDigest(index.archiveSHA256),
              (1...maximumFiles).contains(index.files.count),
              ["index.html", "policies/terms.html", "policies/privacy.html"].allSatisfy({ index.files[$0] != nil }) else {
            throw Failure.invalidArchive
        }
        var total = 0
        var casing = [String: String]()
        for (path, entry) in index.files {
            let segments = path.split(separator: "/", omittingEmptySubsequences: false)
            guard path.utf8.count <= 180, !segments.isEmpty, segments.count <= 6,
                  segments.allSatisfy({ component in
                      !component.isEmpty && !component.hasPrefix(".")
                          && component.utf8.allSatisfy(isPathByte)
                  }),
                  (1...maximumEntryBytes).contains(entry.bytes), isDigest(entry.sha256) else {
                throw Failure.invalidArchive
            }
            for length in 1...segments.count {
                let component = segments.prefix(length).joined(separator: "/")
                let folded = component.lowercased()
                guard casing[folded] == nil || casing[folded] == component,
                      length == segments.count || index.files[component] == nil else {
                    throw Failure.invalidArchive
                }
                casing[folded] = component
            }
            total += entry.bytes
            guard total <= maximumBytes else { throw Failure.invalidArchive }
        }
    }

    private static func isPathByte(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
            || byte == 45 || byte == 46 || byte == 95
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func checksum(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", Int($0)) }.joined()
    }

    private static func isEdition(_ name: String) -> Bool {
        name.hasPrefix("edition-") && UUID(uuidString: String(name.dropFirst(8))) != nil
    }

    private static func verifiedEntry(_ installed: Installed, at root: URL) -> URL? {
        guard isEdition(installed.directory), (try? check(installed.index)) != nil else { return nil }
        let directory = root.appendingPathComponent(installed.directory, isDirectory: true).standardizedFileURL
        for (path, expected) in installed.index.files {
            let file = directory.appendingPathComponent(path).standardizedFileURL
            guard file.resolvingSymlinksInPath().path == file.path,
                  let information = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  information.isRegularFile == true, information.fileSize == expected.bytes,
                  let bytes = try? Data(contentsOf: file, options: .mappedIfSafe),
                  checksum(bytes) == expected.sha256 else { return nil }
        }
        return directory.appendingPathComponent("index.html")
    }

    private static func extract(_ archiveURL: URL, index: Index, to directory: URL) throws {
        let fm = FileManager.default
        let archive = try Archive(url: archiveURL, accessMode: .read)
        var seen = Set<String>()
        for entry in archive {
            guard entry.type == .file, let expected = index.files[entry.path],
                  seen.insert(entry.path).inserted, seen.count <= maximumFiles,
                  entry.uncompressedSize == UInt64(expected.bytes),
                  entry.compressedSize > 0, entry.compressedSize <= UInt64(maximumEntryBytes),
                  entry.uncompressedSize <= entry.compressedSize * 150 else {
                throw Failure.invalidArchive
            }
            var bytes = Data()
            let crc = try archive.extract(entry) { chunk in
                guard bytes.count + chunk.count <= expected.bytes else { throw Failure.invalidArchive }
                bytes.append(chunk)
            }
            guard crc == entry.checksum, bytes.count == expected.bytes, checksum(bytes) == expected.sha256 else {
                throw Failure.invalidArchive
            }
            let output = directory.appendingPathComponent(entry.path)
            try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: output)
        }
        guard seen == Set(index.files.keys) else { throw Failure.invalidArchive }
    }

    private static func removeOlderEditions(at root: URL, keeping: Set<String>) {
        let fm = FileManager.default
        for child in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            let name = child.lastPathComponent
            if isEdition(name), !keeping.contains(name) {
                try? fm.removeItem(at: child)
            }
        }
    }
}
