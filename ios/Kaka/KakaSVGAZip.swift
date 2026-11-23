import Foundation
import zlib

/// Reads the stored and deflated entries used by legacy SVGA without writing archive contents to disk.
struct KakaSVGAZip {
    private enum Failure: Error { case invalidArchive }

    private struct Entry {
        let offset: Int
        let payload: Range<Int>
        let expanded: Int
        let checksum: UInt32
        let stored: Bool
    }

    private let bytes: Data
    private let entries: [String: Entry]

    static func matches(_ bytes: Data) -> Bool {
        bytes.count >= 4 && bytes.prefix(4).elementsEqual([0x50, 0x4b, 0x03, 0x04])
    }

    init(_ bytes: Data, expandedLimit: Int) throws {
        guard bytes.count >= 22 else { throw Failure.invalidArchive }
        let lowerBound = max(0, bytes.count - 65_535 - 22)
        guard let end = stride(from: bytes.count - 22, through: lowerBound, by: -1).first(where: {
            bytes.zip32($0) == 0x06054b50 && $0 + 22 + bytes.zip16($0 + 20) == bytes.count
        }) else { throw Failure.invalidArchive }
        let count = bytes.zip16(end + 10)
        let central = bytes.zip32(end + 16)
        guard bytes.zip16(end + 4) == 0, bytes.zip16(end + 6) == 0,
              bytes.zip16(end + 8) == count, (1...160).contains(count),
              central + bytes.zip32(end + 12) == end else { throw Failure.invalidArchive }

        var offset = central
        var expanded = 0
        var entries: [String: Entry] = [:]
        for _ in 0..<count {
            try Task.checkCancellation()
            guard offset + 46 <= end, bytes.zip32(offset) == 0x02014b50 else { throw Failure.invalidArchive }
            let flags = bytes.zip16(offset + 8)
            let method = bytes.zip16(offset + 10)
            let checksum = UInt32(bytes.zip32(offset + 16))
            let compressedSize = bytes.zip32(offset + 20)
            let size = bytes.zip32(offset + 24)
            let nameLength = bytes.zip16(offset + 28)
            let nameEnd = offset + 46 + nameLength
            let recordEnd = nameEnd + bytes.zip16(offset + 30) + bytes.zip16(offset + 32)
            let local = bytes.zip32(offset + 42)
            let type = (bytes.zip32(offset + 38) >> 16) & 0xf000
            guard flags & ~0x080e == 0, (method == 0 || method == 8),
                  method != 0 || compressedSize == size, (1...256).contains(nameLength),
                  size <= expandedLimit - expanded, recordEnd <= end,
                  bytes.zip16(offset + 34) == 0, [0, 0x4000, 0x8000].contains(type),
                  local + 30 <= central, bytes.zip32(local) == 0x04034b50,
                  bytes.zip16(local + 6) == flags, bytes.zip16(local + 8) == method,
                  bytes.zip16(local + 26) == nameLength else { throw Failure.invalidArchive }
            let payload = local + 30 + nameLength + bytes.zip16(local + 28)
            let payloadEnd = payload + compressedSize
            guard payloadEnd <= central else { throw Failure.invalidArchive }
            let nameData = bytes.zipSlice(offset + 46..<nameEnd)
            guard bytes.zipSlice(local + 30..<local + 30 + nameLength) == nameData,
                  let name = String(data: nameData, encoding: .utf8), Self.validName(name),
                  entries[name] == nil else { throw Failure.invalidArchive }
            if flags & 8 == 0 {
                guard UInt32(bytes.zip32(local + 14)) == checksum,
                      bytes.zip32(local + 18) == compressedSize,
                      bytes.zip32(local + 22) == size else { throw Failure.invalidArchive }
            }
            entries[name] = Entry(offset: local, payload: payload..<payloadEnd, expanded: size,
                                  checksum: checksum, stored: method == 0)
            expanded += size
            offset = recordEnd
        }
        guard offset == end else { throw Failure.invalidArchive }
        var previousEnd = 0
        for entry in entries.values.sorted(by: { $0.offset < $1.offset }) {
            guard entry.offset >= previousEnd else { throw Failure.invalidArchive }
            previousEnd = entry.payload.upperBound
        }
        self.bytes = bytes
        self.entries = entries
    }

    func member(_ name: String, sizeLimit: Int = .max) throws -> Data? {
        guard Self.validName(name), !name.hasSuffix("/"), let entry = entries[name] else { return nil }
        guard entry.expanded <= sizeLimit else { throw Failure.invalidArchive }
        try Task.checkCancellation()
        let compressed = bytes.zipSlice(entry.payload)
        let data = entry.stored ? compressed : try Self.inflateRaw(compressed, length: entry.expanded)
        let checksum = data.withUnsafeBytes {
            crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt($0.count))
        }
        guard UInt32(checksum) == entry.checksum else { throw Failure.invalidArchive }
        return data
    }

    private static func validName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        return components.dropLast().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
            && components.last != "." && components.last != ".."
    }

    private static func inflateRaw(_ data: Data, length: Int) throws -> Data {
        guard !data.isEmpty else { throw Failure.invalidArchive }
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw Failure.invalidArchive
        }
        defer { inflateEnd(&stream) }
        var result = Data(count: length + 1)
        let status = data.withUnsafeBytes { input in
            result.withUnsafeMutableBytes { output in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = output.bindMemory(to: UInt8.self).baseAddress
                stream.avail_out = uInt(output.count)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, Int(stream.total_in) == data.count,
              Int(stream.total_out) == length else { throw Failure.invalidArchive }
        result.removeLast()
        return result
    }
}

private extension Data {
    func zip16(_ offset: Int) -> Int {
        Int(self[startIndex + offset]) | (Int(self[startIndex + offset + 1]) << 8)
    }

    func zip32(_ offset: Int) -> Int {
        zip16(offset) | (zip16(offset + 2) << 16)
    }

    func zipSlice(_ range: Range<Int>) -> Data {
        subdata(in: (startIndex + range.lowerBound)..<(startIndex + range.upperBound))
    }
}
