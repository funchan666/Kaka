import CoreFoundation
import Foundation
import ImageIO
import SwiftUI
import UIKit
import zlib

// Renders the supplied raster and vector tracks in the public SVGA formats.
struct KakaSVGAGift: Sendable {
    private enum Failure: Error { case format, size }
    private static let canvasLimit: CGFloat = 4096
    private static let compressedLimit = 8 * 1024 * 1024
    private static let expandedLimit = 24 * 1024 * 1024

    struct Keyframe: @unchecked Sendable {
        let bounds: CGRect
        let transform: CGAffineTransform
        let opacity: Float
        let clip: CGPath?
        let vectors: [Vector]

        init(bounds: CGRect, transform: CGAffineTransform, opacity: Float, clip: CGPath?, vectors: [Vector]) {
            self.bounds = bounds
            self.transform = transform
            self.opacity = opacity
            self.clip = clip
            self.vectors = vectors
        }

        init(_ data: Data, previousVectors: [Vector], geometryBudget: inout Int) throws {
            var input = Proto(data)
            var opacity: Float = 0
            var bounds = CGRect.zero
            var transform = CGAffineTransform.identity
            var clip: CGPath?
            var vectors: [Vector] = []
            var keep = false
            while let field = try input.next() {
                switch field {
                case .float(1, let value): opacity = value
                case .bytes(2, let layout):
                    let values = try Proto.floats(layout, count: 4)
                    guard values[2] >= 0, values[3] >= 0 else { throw Failure.format }
                    bounds = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
                case .bytes(3, let matrix):
                    transform = try Proto.transform(matrix)
                case .bytes(4, let data) where !data.isEmpty:
                    try Self.useGeometry(data, budget: &geometryBudget)
                    clip = try KakaSVGAPath.decode(data)
                case .bytes(5, let data):
                    guard !keep, vectors.count < 16 else { throw Failure.size }
                    try Self.useGeometry(data, budget: &geometryBudget)
                    if let vector = try Vector.decode(data) { vectors.append(vector) }
                    else if vectors.isEmpty { keep = true }
                    else { throw Failure.format }
                default: continue
                }
            }
            guard opacity.isFinite, (0...1).contains(opacity) else { throw Failure.format }
            self.bounds = bounds
            self.transform = transform
            self.opacity = opacity
            self.clip = clip
            self.vectors = keep ? previousVectors : vectors
        }

        fileprivate static func useGeometry(_ data: Data, budget: inout Int) throws {
            try useGeometry(data.count, budget: &budget)
        }

        fileprivate static func useGeometry(_ count: Int, budget: inout Int) throws {
            guard count <= budget else { throw Failure.size }
            budget -= count
        }
    }

    struct Vector: @unchecked Sendable {
        let path: CGPath
        let fill: CGColor?
        let stroke: CGColor?
        let lineWidth: CGFloat
        let lineCap: CAShapeLayerLineCap
        let lineJoin: CAShapeLayerLineJoin
        let miterLimit: CGFloat
        let dash: [NSNumber]?
        let dashPhase: CGFloat
        let transform: CGAffineTransform

        fileprivate static func decode(_ data: Data) throws -> Vector? {
            var input = Proto(data)
            var type: UInt64 = 0
            var geometry: (field: Int, data: Data)?
            var style: Data?
            var transform = CGAffineTransform.identity
            while let field = try input.next() {
                switch field {
                case .integer(1, let value): type = value
                case .bytes(let number, let data) where (2...4).contains(number): geometry = (number, data)
                case .bytes(10, let data): style = data
                case .bytes(11, let data): transform = try Proto.transform(data)
                default: continue
                }
            }
            if type == 3 { return nil }
            guard let geometry, (0...2).contains(type), geometry.field == Int(type) + 2 else { throw Failure.format }
            let path = try decodePath(type: type, geometry: geometry.data)
            var fill: CGColor? = CGColor(gray: 0, alpha: 1)
            var stroke: CGColor?
            var joins: UInt64 = 0
            var caps: UInt64 = 0
            var values = Array(repeating: CGFloat.zero, count: 10)
            values[2] = 1
            values[5] = 10
            if let style {
                fill = nil
                values = try Proto.floats(style, count: 10)
                var input = Proto(style)
                while let field = try input.next() {
                    switch field {
                    case .bytes(1, let data): fill = try color(data)
                    case .bytes(2, let data): stroke = try color(data)
                    case .integer(4, let value): caps = value
                    case .integer(5, let value): joins = value
                    default: continue
                    }
                }
            }
            guard caps <= 2, joins <= 2, values[2] >= 0, values[5] >= 0,
                  values[6] >= 0, values[7] >= 0 else { throw Failure.format }
            let lineCap: CAShapeLayerLineCap = [.butt, .round, .square][Int(caps)]
            let lineJoin: CAShapeLayerLineJoin = [.miter, .round, .bevel][Int(joins)]
            let dash = values[6] > 0 || values[7] > 0
                ? [NSNumber(value: Double(max(1, values[6]))), NSNumber(value: Double(max(0.1, values[7])))] : nil
            return Vector(path: path, fill: fill, stroke: stroke, lineWidth: values[2], lineCap: lineCap,
                          lineJoin: lineJoin, miterLimit: values[5], dash: dash, dashPhase: values[8], transform: transform)
        }

        private static func color(_ data: Data) throws -> CGColor {
            let rgba = try Proto.floats(data, count: 4)
            guard rgba.allSatisfy({ (0...1).contains($0) }) else { throw Failure.format }
            return CGColor(red: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
        }

        private static func decodePath(type: UInt64, geometry: Data) throws -> CGPath {
            if type == 0 {
                var input = Proto(geometry)
                while let field = try input.next() {
                    if case .bytes(1, let path) = field { return try KakaSVGAPath.decode(path) }
                }
                throw Failure.format
            }
            let values = try Proto.floats(geometry, count: 5)
            return try primitive(rectangle: type == 1, values: values)
        }

        fileprivate static func primitive(rectangle: Bool, values: [CGFloat]) throws -> CGPath {
            guard values[2] >= 0, values[3] >= 0, values[4] >= 0 else { throw Failure.format }
            if rectangle {
                let rect = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
                let corner = min(values[4], values[2] / 2, values[3] / 2)
                return CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
            }
            let rect = CGRect(x: values[0] - values[2], y: values[1] - values[3], width: values[2] * 2, height: values[3] * 2)
            return CGPath(ellipseIn: rect, transform: nil)
        }
    }

    struct Layer: @unchecked Sendable {
        let key: String
        let matteKey: String?
        let image: CGImage?
        let keyframes: [Keyframe]

        var isMatte: Bool { key.hasSuffix(".matte") }
    }

    let size: CGSize
    let fps: Int
    let frames: Int
    let layers: [Layer]
    private typealias Track = (key: String, matteKey: String?, keyframes: [Keyframe])

    static func matches(_ data: Data) -> Bool {
        if KakaSVGAZip.matches(data) { return true }
        guard data.count >= 6 else { return false }
        let compression = Int(data[data.startIndex])
        let flags = Int(data[data.startIndex + 1])
        return compression & 0x0f == 8 && compression >> 4 <= 7 && flags & 0x20 == 0
            && ((compression << 8) | flags).isMultiple(of: 31)
    }

    static func load(_ data: Data) async throws -> KakaSVGAGift {
        let decode = Task.detached(priority: .userInitiated) { try KakaSVGAGift(data) }
        return try await withTaskCancellationHandler {
            try await decode.value
        } onCancel: {
            decode.cancel()
        }
    }

    private init(_ data: Data) throws {
        guard Self.matches(data), data.count <= Self.compressedLimit else { throw Failure.format }
        if KakaSVGAZip.matches(data) {
            let archive = try KakaSVGAZip(data, expandedLimit: Self.expandedLimit)
            if let binary = try archive.member("movie.binary") {
                try self.init(proto: binary, archive: archive)
            } else {
                try self.init(legacy: archive)
            }
        } else {
            try self.init(proto: Self.inflate(data), archive: nil)
        }
    }

    private init(proto: Data, archive: KakaSVGAZip?) throws {
        var input = Proto(proto)
        var parameters: Data?
        var entries: [String: Data] = [:]
        var sprites: [Data] = []
        while let field = try input.next() {
            try Task.checkCancellation()
            switch field {
            case .bytes(1, let version):
                if !version.isEmpty {
                    let value = try Self.name(version)
                    guard value.hasPrefix("2.") || (archive != nil && value.hasPrefix("1.")) else {
                        throw Failure.format
                    }
                }
            case .bytes(2, let data): parameters = data
            case .bytes(3, let pair):
                let (key, image) = try Self.imageEntry(pair)
                guard entries.count < 128, entries[key] == nil else { throw Failure.size }
                entries[key] = image
            case .bytes(4, let sprite):
                guard sprites.count < 128 else { throw Failure.size }
                sprites.append(sprite)
            default: continue
            }
        }
        guard let parameters, !sprites.isEmpty else { throw Failure.format }
        let (size, fps, frames) = try Self.movieParameters(parameters)
        var geometryBudget = 512 * 1024
        let tracks = try sprites.map { try Self.timeline($0, maxFrames: frames, geometryBudget: &geometryBudget) }
        try self.init(size: size, fps: fps, frames: frames, tracks: tracks) { bitmapKey, key in
            guard let bytes = entries[bitmapKey] ?? entries[key] else { return nil }
            if let archive, let filename = try? Self.name(bytes) {
                return try archive.member(filename + ".png") ?? archive.member(filename)
            }
            return bytes
        }
    }

    private init(size: CGSize, fps: Int, frames: Int, tracks: [Track],
                 bitmap: (String, String) throws -> Data?) throws {
        self.size = size
        self.fps = fps
        self.frames = frames
        var images: [String: CGImage] = [:]
        var availablePixels = Self.expandedLimit / 4
        var result: [Layer] = []
        var mattes: Set<String> = []
        for (key, matteKey, keyframes) in tracks {
            try Task.checkCancellation()
            let bitmapKey = (key as NSString).deletingPathExtension
            if key.hasSuffix(".matte"), !mattes.insert(key).inserted { throw Failure.format }
            if !key.hasSuffix(".vector"), images[bitmapKey] == nil, let bytes = try bitmap(bitmapKey, key) {
                images[bitmapKey] = try Self.image(bytes, availablePixels: &availablePixels)
            }
            let image = key.hasSuffix(".vector") ? nil : images[bitmapKey]
            guard image != nil || keyframes.contains(where: { !$0.vectors.isEmpty }) else { throw Failure.format }
            result.append(Layer(key: key, matteKey: matteKey, image: image, keyframes: keyframes))
        }
        guard result.allSatisfy({ $0.matteKey.map(mattes.contains) ?? true }),
              result.contains(where: { layer in
                  !layer.isMatte && layer.keyframes.contains {
                      $0.opacity > 0 && (!$0.vectors.isEmpty || (layer.image != nil && $0.bounds.width > 0 && $0.bounds.height > 0))
                  }
              }) else { throw Failure.format }
        layers = result
    }

    private static func movieParameters(_ data: Data) throws -> (CGSize, Int, Int) {
        var width: CGFloat = 0
        var height: CGFloat = 0
        var fps: UInt64 = 0
        var frames: UInt64 = 0
        var input = Proto(data)
        while let field = try input.next() {
            switch field {
            case .float(1, let value): width = CGFloat(value)
            case .float(2, let value): height = CGFloat(value)
            case .integer(3, let value): fps = value
            case .integer(4, let value): frames = value
            default: continue
            }
        }
        guard (1...canvasLimit).contains(width), (1...canvasLimit).contains(height),
              (1...60).contains(fps), (2...(fps * 9)).contains(frames) else { throw Failure.size }
        return (CGSize(width: width, height: height), Int(fps), Int(frames))
    }

    private static func imageEntry(_ data: Data) throws -> (String, Data) {
        var input = Proto(data)
        var key: String?
        var bytes: Data?
        while let field = try input.next() {
            switch field {
            case .bytes(1, let data): key = try name(data)
            case .bytes(2, let data): bytes = data
            default: continue
            }
        }
        guard let key, let bytes, !bytes.isEmpty else { throw Failure.format }
        return (key, bytes)
    }

    private static func timeline(_ data: Data, maxFrames: Int, geometryBudget: inout Int) throws -> Track {
        var input = Proto(data)
        var key: String?
        var matteKey: String?
        var timeline: [Keyframe] = []
        while let field = try input.next() {
            switch field {
            case .bytes(1, let data): key = try name(data)
            case .bytes(2, let data):
                try Task.checkCancellation()
                guard timeline.count < maxFrames else { throw Failure.size }
                let previous = timeline.last?.vectors ?? []
                timeline.append(try Keyframe(data, previousVectors: previous, geometryBudget: &geometryBudget))
            case .bytes(3, let data) where !data.isEmpty: matteKey = try name(data)
            default: continue
            }
        }
        guard let key, !timeline.isEmpty, matteKey == nil || !key.hasSuffix(".matte") else {
            throw Failure.format
        }
        return (key, matteKey, timeline)
    }

    private static func image(_ data: Data, availablePixels: inout Int) throws -> CGImage {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let type = CGImageSourceGetType(source), ["public.png", "public.jpeg"].contains(type as String),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, (1...4096).contains(width),
              let height = properties[kCGImagePropertyPixelHeight] as? Int, (1...4096).contains(height),
              (properties[kCGImagePropertyDepth] as? Int ?? 8) <= 8,
              width * height <= availablePixels,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == width, image.height == height else { throw Failure.size }
        availablePixels -= width * height
        return image
    }

    private static func name(_ data: Data) throws -> String {
        guard (1...128).contains(data.count), let value = String(data: data, encoding: .utf8),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw Failure.format }
        return value
    }

    private static func inflate(_ data: Data) throws -> Data {
        var capacity = min(expandedLimit, max(32_768, data.count * 2))
        while true {
            try Task.checkCancellation()
            var output = Data(count: capacity)
            var written = uLongf(capacity)
            var consumed = uLong(data.count)
            let status: Int32 = output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
                data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                    guard let destination = destination.bindMemory(to: UInt8.self).baseAddress,
                          let source = source.bindMemory(to: UInt8.self).baseAddress else { return Z_DATA_ERROR }
                    return uncompress2(destination, &written, source, &consumed)
                }
            }
            if status == Z_BUF_ERROR, capacity < expandedLimit {
                capacity = min(expandedLimit, capacity * 2)
                continue
            }
            guard status == Z_OK, consumed == data.count, written > 0 else { throw Failure.format }
            output.removeSubrange(Int(written)..<output.count)
            return output
        }
    }

    private struct Proto {
        enum Field {
            case integer(Int, UInt64)
            case float(Int, Float)
            case bytes(Int, Data)
            case skipped
        }

        let data: Data
        var index: Int
        var remainingFields = 4096

        init(_ data: Data) {
            self.data = data
            index = data.startIndex
        }

        mutating func next() throws -> Field? {
            if index == data.endIndex { return nil }
            guard remainingFields > 0 else { throw Failure.size }
            remainingFields -= 1
            let tag = try varint()
            guard tag <= UInt64(UInt32.max), tag >> 3 > 0 else { throw Failure.format }
            let field = Int(tag >> 3)
            switch tag & 7 {
            case 0: return .integer(field, try varint())
            case 1: _ = try read(8); return .skipped
            case 2:
                let count = try varint()
                guard count <= UInt64(data.endIndex - index) else { throw Failure.format }
                return .bytes(field, try read(Int(count)))
            case 5:
                let bytes = try read(4)
                let bits = bytes.reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                return .float(field, Float(bitPattern: bits))
            default: throw Failure.format
            }
        }

        private mutating func read(_ count: Int) throws -> Data {
            guard count <= data.endIndex - index else { throw Failure.format }
            let start = index
            index += count
            return data[start..<index]
        }

        private mutating func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard index < data.endIndex else { throw Failure.format }
                let byte = data[index]
                index += 1
                if shift == 63, byte > 1 { throw Failure.format }
                value |= UInt64(byte & 0x7f) << shift
                if byte < 0x80 { return value }
            }
            throw Failure.format
        }

        static func floats(_ data: Data, count: Int) throws -> [CGFloat] {
            var values = Array(repeating: CGFloat.zero, count: count)
            var input = Proto(data)
            while let value = try input.next() {
                if case .float(let index, let value) = value, (1...count).contains(index) {
                    guard value.isFinite, abs(value) <= 32_768 else { throw Failure.format }
                    values[index - 1] = CGFloat(value)
                }
            }
            return values
        }

        static func transform(_ data: Data) throws -> CGAffineTransform {
            let values = try floats(data, count: 6)
            return CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
        }
    }
}

private extension KakaSVGAGift {
    typealias JSON = [String: Any]

    init(legacy archive: KakaSVGAZip) throws {
        guard let specification = try archive.member("movie.spec", sizeLimit: Self.compressedLimit),
              let root = try JSONSerialization.jsonObject(with: specification) as? JSON,
              let movie = root["movie"] as? JSON,
              let sprites = root["sprites"] as? [JSON], (1...128).contains(sprites.count) else {
            throw Failure.format
        }
        let viewBox = movie["viewBox"] as? JSON ?? [:]
        let width = try Self.number(viewBox["width"], fallback: 100)
        let height = try Self.number(viewBox["height"], fallback: 100)
        let rate = try Self.number(movie["fps"], fallback: 20)
        let count = try Self.number(movie["frames"])
        guard (1...Self.canvasLimit).contains(width), (1...Self.canvasLimit).contains(height),
              (1...60).contains(rate), rate.rounded(.towardZero) == rate,
              (2...(rate * 9)).contains(count), count.rounded(.towardZero) == count else {
            throw Failure.size
        }
        let filenames = root["images"] as? [String: String] ?? [:]
        guard filenames.count <= 128 else { throw Failure.size }
        var entries: [String: String] = [:]
        for (key, value) in filenames {
            let verifiedKey = try Self.name(Data(key.utf8))
            let basename = (verifiedKey as NSString).deletingPathExtension
            guard entries[basename] == nil else { throw Failure.format }
            entries[basename] = try Self.name(Data(value.utf8))
        }
        var geometryBudget = 512 * 1024
        let tracks = try sprites.map { sprite -> Track in
            guard let imageKey = sprite["imageKey"] as? String,
                  let source = sprite["frames"] as? [JSON], (1...Int(count)).contains(source.count) else {
                throw Failure.format
            }
            let key = try Self.name(Data(imageKey.utf8))
            let matteKey: String? = try (sprite["matteKey"] as? String).flatMap { value in
                value.isEmpty ? nil : try Self.name(Data(value.utf8))
            }
            guard matteKey == nil || !key.hasSuffix(".matte") else { throw Failure.format }
            var timeline: [Keyframe] = []
            for frame in source {
                try Task.checkCancellation()
                timeline.append(try Self.legacyFrame(frame, previous: timeline.last?.vectors ?? [],
                                                     budget: &geometryBudget))
            }
            return (key, matteKey, timeline)
        }
        try self.init(size: CGSize(width: width, height: height), fps: Int(rate), frames: Int(count),
                      tracks: tracks) { bitmapKey, _ in
            guard let filename = entries[bitmapKey] else { return nil }
            return try archive.member(filename + ".png")
        }
    }

    static func legacyFrame(_ frame: JSON, previous: [Vector], budget: inout Int) throws -> Keyframe {
        let opacity = try number(frame["alpha"], fallback: 0)
        guard (0...1).contains(opacity) else { throw Failure.format }
        var bounds = CGRect.zero
        if let layout = frame["layout"] as? JSON {
            let values = try ["x", "y", "width", "height"].map { try number(layout[$0]) }
            guard values[2] >= 0, values[3] >= 0 else { throw Failure.format }
            bounds = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        }
        var clip: CGPath?
        if let path = frame["clipPath"] as? String, !path.isEmpty {
            let bytes = Data(path.utf8)
            try Keyframe.useGeometry(bytes, budget: &budget)
            clip = try KakaSVGAPath.decode(bytes)
        }
        let shapes = frame["shapes"] as? [JSON] ?? []
        guard shapes.count <= 16 else { throw Failure.size }
        let isKeepFrame = shapes.first?["type"] as? String == "keep"
        let vectors = isKeepFrame ? previous : try shapes.map { try legacyVector($0, budget: &budget) }
        return try Keyframe(bounds: bounds, transform: legacyTransform(frame["transform"]), opacity: Float(opacity),
                            clip: clip, vectors: vectors)
    }

    static func legacyVector(_ shape: JSON, budget: inout Int) throws -> Vector {
        try Keyframe.useGeometry(64, budget: &budget)
        guard let type = shape["type"] as? String, let args = shape["args"] as? JSON else { throw Failure.format }
        let path: CGPath
        switch type {
        case "shape":
            guard let value = args["d"] as? String else { throw Failure.format }
            let data = Data(value.utf8)
            try Keyframe.useGeometry(data, budget: &budget)
            path = try KakaSVGAPath.decode(data)
        case "rect":
            let values = try ["x", "y", "width", "height", "cornerRadius"].map { try number(args[$0]) }
            path = try Vector.primitive(rectangle: true, values: values)
        case "ellipse":
            var values = try ["x", "y", "radiusX", "radiusY"].map { try number(args[$0]) }
            values.append(0)
            path = try Vector.primitive(rectangle: false, values: values)
        default: throw Failure.format
        }
        let style = shape["styles"] as? JSON
        let fill: CGColor? = style == nil ? CGColor(gray: 0, alpha: 1) : try legacyColor(style?["fill"])
        let stroke = try legacyColor(style?["stroke"])
        let width = try number(style?["strokeWidth"], fallback: 1)
        let miter = try number(style?["miterLimit"], fallback: 10)
        guard width >= 0, miter >= 0 else { throw Failure.format }
        let cap = CAShapeLayerLineCap(rawValue: style?["lineCap"] as? String ?? CAShapeLayerLineCap.butt.rawValue)
        let join = CAShapeLayerLineJoin(rawValue: style?["lineJoin"] as? String ?? CAShapeLayerLineJoin.miter.rawValue)
        guard [CAShapeLayerLineCap.butt, .round, .square].contains(cap),
              [CAShapeLayerLineJoin.miter, .round, .bevel].contains(join) else { throw Failure.format }
        var pattern: [NSNumber]?
        var phase: CGFloat = 0
        if let dash = style?["lineDash"] as? [Any], !dash.isEmpty {
            guard dash.count == 3 else { throw Failure.format }
            let values = try dash.map { try number($0) }
            phase = values[2]
            pattern = [NSNumber(value: Double(max(1, values[0]))), NSNumber(value: Double(max(0.1, values[1])))]
        }
        return try Vector(path: path, fill: fill, stroke: stroke, lineWidth: width, lineCap: cap,
                          lineJoin: join, miterLimit: miter, dash: pattern, dashPhase: phase,
                          transform: legacyTransform(shape["transform"]))
    }

    static func legacyColor(_ value: Any?) throws -> CGColor? {
        guard let value, !(value is NSNull) else { return nil }
        guard let components = value as? [Any], components.count == 4 else { throw Failure.format }
        let values = try components.map { try number($0) }
        guard values.allSatisfy({ (0...1).contains($0) }) else { throw Failure.format }
        return CGColor(red: values[0], green: values[1], blue: values[2], alpha: values[3])
    }

    static func legacyTransform(_ value: Any?) throws -> CGAffineTransform {
        guard let value = value as? JSON else { return .identity }
        let values = try ["a", "b", "c", "d", "tx", "ty"].map { try number(value[$0]) }
        return CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
    }

    static func number(_ value: Any?, fallback: CGFloat? = nil) throws -> CGFloat {
        if let fallback, value == nil || value is NSNull { return fallback }
        guard let numeric = value as? NSNumber, CFGetTypeID(numeric) != CFBooleanGetTypeID() else { throw Failure.format }
        let result = CGFloat(numeric.doubleValue)
        guard result.isFinite, abs(result) <= 32_768 else { throw Failure.format }
        return result
    }
}

struct KakaSVGAGiftSurface: UIViewRepresentable {
    let movie: KakaSVGAGift
    let frame: Int

    func makeUIView(context: Context) -> Surface { Surface(movie: movie) }

    func updateUIView(_ view: Surface, context: Context) { view.show(frame) }

    final class Surface: UIView {
        private let movie: KakaSVGAGift
        private let canvas = CALayer()
        private var sprites: [[SpriteSurface]] = []

        init(movie: KakaSVGAGift) {
            self.movie = movie
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            canvas.anchorPoint = .zero
            canvas.bounds = CGRect(origin: .zero, size: movie.size)
            canvas.masksToBounds = true
            layer.addSublayer(canvas)
            sprites = Array(repeating: [], count: movie.layers.count)
            let mattes = Dictionary(uniqueKeysWithValues: movie.layers.enumerated().compactMap { index, sprite in
                sprite.isMatte ? (sprite.key, index) : nil
            })
            var lastMatte: String?
            var group = canvas
            for (index, sprite) in movie.layers.enumerated() where !sprite.isMatte {
                if sprite.matteKey != lastMatte {
                    group = canvas
                    if let matte = sprite.matteKey, let maskIndex = mattes[matte] {
                        let host = CALayer()
                        host.frame = canvas.bounds
                        let mask = spriteLayer(for: maskIndex)
                        host.mask = mask
                        canvas.addSublayer(host)
                        group = host
                    }
                    lastMatte = sprite.matteKey
                }
                group.addSublayer(spriteLayer(for: index))
            }
        }

        required init?(coder: NSCoder) { return nil }

        private func spriteLayer(for index: Int) -> CALayer {
            let item = SpriteSurface(image: movie.layers[index].image)
            sprites[index].append(item)
            return item.layer
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let scale = min(bounds.width / movie.size.width, bounds.height / movie.size.height)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            canvas.position = CGPoint(x: bounds.midX - movie.size.width * scale / 2,
                                      y: bounds.midY - movie.size.height * scale / 2)
            canvas.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
            CATransaction.commit()
        }

        func show(_ frame: Int) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (layers, sprite) in zip(sprites, movie.layers) {
                let keyframe = sprite.keyframes.indices.contains(frame) ? sprite.keyframes[frame] : nil
                for layer in layers { layer.show(keyframe) }
            }
            CATransaction.commit()
        }
    }

    private final class SpriteSurface {
        let layer = CALayer()
        private let clip = CAShapeLayer()
        private let image: CGImage?
        private var shapes: [CAShapeLayer] = []

        init(image: CGImage?) {
            self.image = image
            layer.isHidden = true
            layer.anchorPoint = .zero
            layer.contents = image
            layer.contentsGravity = .resize
        }

        func show(_ keyframe: KakaSVGAGift.Keyframe?) {
            guard let keyframe, keyframe.opacity > 0,
                  !keyframe.vectors.isEmpty || (image != nil && keyframe.bounds.width > 0 && keyframe.bounds.height > 0) else {
                layer.isHidden = true
                return
            }
            layer.isHidden = false
            layer.opacity = keyframe.opacity
            layer.bounds = CGRect(origin: .zero, size: keyframe.bounds.size)
            layer.position = keyframe.bounds.origin.applying(keyframe.transform)
            var transform = keyframe.transform
            transform.tx = 0
            transform.ty = 0
            layer.setAffineTransform(transform)
            if let path = keyframe.clip {
                clip.frame = layer.bounds
                clip.path = path
                layer.mask = clip
            } else if layer.mask != nil {
                layer.mask = nil
            }
            showVectors(keyframe.vectors)
        }

        private func showVectors(_ vectors: [KakaSVGAGift.Vector]) {
            while shapes.count < vectors.count {
                let shape = CAShapeLayer()
                shape.anchorPoint = .zero
                layer.addSublayer(shape)
                shapes.append(shape)
            }
            for (index, shape) in shapes.enumerated() {
                guard vectors.indices.contains(index) else {
                    shape.isHidden = true
                    continue
                }
                let vector = vectors[index]
                shape.isHidden = false
                shape.bounds = layer.bounds
                shape.path = vector.path
                shape.fillColor = vector.fill
                shape.strokeColor = vector.stroke
                shape.lineWidth = vector.lineWidth
                shape.lineCap = vector.lineCap
                shape.lineJoin = vector.lineJoin
                shape.miterLimit = vector.miterLimit
                shape.lineDashPattern = vector.dash
                shape.lineDashPhase = vector.dashPhase
                var transform = vector.transform
                shape.position = CGPoint(x: transform.tx, y: transform.ty)
                transform.tx = 0
                transform.ty = 0
                shape.setAffineTransform(transform)
            }
        }
    }
}

private struct KakaSVGAPath {
    private enum Command: UInt8 {
        case move = 77, line = 76, horizontal = 72, vertical = 86, close = 90
        case cubic = 67, smoothCubic = 83, quadratic = 81, smoothQuadratic = 84, arc = 65
    }

    private enum Failure: Error { case unsupportedPath }

    private static let maximumCoordinate: CGFloat = 262_144
    private let bytes: [UInt8]
    private var cursor = 0

    static func decode(_ data: Data) throws -> CGPath {
        guard (1...16_384).contains(data.count) else { throw Failure.unsupportedPath }
        var parser = KakaSVGAPath(bytes: Array(data))
        return try parser.path()
    }

    private mutating func path() throws -> CGPath {
        let path = CGMutablePath()
        var command: Command?
        var relative = false
        var current = CGPoint.zero
        var start: CGPoint?
        var lastCubic: CGPoint?
        var lastQuad: CGPoint?
        for _ in 0..<768 {
            skipSeparators()
            guard cursor < bytes.count else {
                guard !path.isEmpty, let result = path.copy() else { throw Failure.unsupportedPath }
                return result
            }
            let byte = bytes[cursor]
            if (65...90).contains(byte) || (97...122).contains(byte) {
                relative = byte >= 97
                command = Command(rawValue: relative ? byte - 32 : byte)
                cursor += 1
            }
            guard let operation = command, operation == .move || start != nil else { throw Failure.unsupportedPath }
            let origin = relative ? current : .zero
            var cubic: CGPoint?
            var quad: CGPoint?
            switch operation {
            case .move:
                current = try point(origin)
                start = current
                path.move(to: current)
                command = .line
            case .line:
                current = try point(origin)
                path.addLine(to: current)
            case .horizontal:
                current = try Self.checked(CGPoint(x: origin.x + number(), y: current.y))
                path.addLine(to: current)
            case .vertical:
                current = try Self.checked(CGPoint(x: current.x, y: origin.y + number()))
                path.addLine(to: current)
            case .cubic, .smoothCubic:
                let first = operation == .cubic ? try point(origin) : try Self.reflected(lastCubic, from: current)
                let second = try point(origin)
                current = try point(origin)
                path.addCurve(to: current, control1: first, control2: second)
                cubic = second
            case .quadratic, .smoothQuadratic:
                let control = operation == .quadratic ? try point(origin) : try Self.reflected(lastQuad, from: current)
                current = try point(origin)
                path.addQuadCurve(to: current, control: control)
                quad = control
            case .arc:
                let radiusX = abs(try number())
                let radiusY = abs(try number())
                let rotation = try number()
                let large = try arcFlag()
                let sweep = try arcFlag()
                let end = try point(origin)
                try Self.appendArc(to: path, from: current, end: end, radii: CGSize(width: radiusX, height: radiusY),
                                   rotation: rotation, large: large, sweep: sweep)
                current = end
            case .close:
                path.closeSubpath()
                current = start ?? .zero
                command = nil
            }
            lastCubic = cubic
            lastQuad = quad
        }
        throw Failure.unsupportedPath
    }

    private mutating func point(_ origin: CGPoint) throws -> CGPoint {
        let x = try number()
        let y = try number()
        return try Self.checked(CGPoint(x: origin.x + x, y: origin.y + y))
    }

    private static func reflected(_ control: CGPoint?, from current: CGPoint) throws -> CGPoint {
        guard let control else { return current }
        return try checked(CGPoint(x: current.x * 2 - control.x, y: current.y * 2 - control.y))
    }

    private static func checked(_ point: CGPoint) throws -> CGPoint {
        guard abs(point.x) <= maximumCoordinate, abs(point.y) <= maximumCoordinate else { throw Failure.unsupportedPath }
        return point
    }

    private mutating func arcFlag() throws -> Bool {
        skipSeparators()
        guard cursor < bytes.count, bytes[cursor] == 48 || bytes[cursor] == 49 else { throw Failure.unsupportedPath }
        let enabled = bytes[cursor] == 49
        cursor += 1
        return enabled
    }

    private static func appendArc(to path: CGMutablePath, from start: CGPoint, end: CGPoint, radii: CGSize,
                                  rotation: CGFloat, large: Bool, sweep: Bool) throws {
        guard start != end else { return }
        guard radii.width > 0, radii.height > 0 else {
            path.addLine(to: end)
            return
        }

        // Convert the SVG endpoint arguments into a transformed unit circle.
        let angle = rotation.truncatingRemainder(dividingBy: 360) * .pi / 180
        let cosine = cos(angle)
        let sine = sin(angle)
        let halfX = (start.x - end.x) / 2
        let halfY = (start.y - end.y) / 2
        let unitX = (cosine * halfX + sine * halfY) / radii.width
        let unitY = (cosine * halfY - sine * halfX) / radii.height
        let distance = hypot(unitX, unitY)
        guard distance.isFinite, distance > 0 else { throw Failure.unsupportedPath }

        let correction = max(1, distance)
        let radiusX = radii.width * correction
        let radiusY = radii.height * correction
        guard radiusX <= maximumCoordinate, radiusY <= maximumCoordinate else { throw Failure.unsupportedPath }
        let chord = min(1, distance)
        let centerSide: CGFloat = large == sweep ? -1 : 1
        let centerOffset = centerSide * sqrt(max(0, 1 - chord * chord))
        let centerX = unitY / distance * centerOffset
        let centerY = -unitX / distance * centerOffset
        let center = CGPoint(x: radiusX * centerX, y: radiusY * centerY)
            .applying(CGAffineTransform(rotationAngle: angle))
        let ellipse = CGAffineTransform(a: cosine * radiusX, b: sine * radiusX,
                                        c: -sine * radiusY, d: cosine * radiusY,
                                        tx: (start.x + end.x) / 2 + center.x, ty: (start.y + end.y) / 2 + center.y)
        let startAngle = atan2(unitY / correction - centerY, unitX / correction - centerX)
        let minorSpan = 2 * asin(chord)
        let span = large ? 2 * .pi - minorSpan : minorSpan
        let count = max(1, Int(ceil(span / (.pi / 2))))
        let step = span / CGFloat(count) * (sweep ? 1 : -1)
        let tangent = 4 * tan(step / 4) / 3
        for segment in 0..<count {
            let first = startAngle + CGFloat(segment) * step
            let next = first + step
            let startUnit = CGPoint(x: cos(first), y: sin(first))
            let endUnit = CGPoint(x: cos(next), y: sin(next))
            let firstControl = CGPoint(x: startUnit.x - tangent * startUnit.y, y: startUnit.y + tangent * startUnit.x)
            let secondControl = CGPoint(x: endUnit.x + tangent * endUnit.y, y: endUnit.y - tangent * endUnit.x)
            let destination = segment + 1 == count ? end : try checked(endUnit.applying(ellipse))
            path.addCurve(to: destination, control1: try checked(firstControl.applying(ellipse)),
                          control2: try checked(secondControl.applying(ellipse)))
        }
    }

    private mutating func number() throws -> CGFloat {
        skipSeparators()
        let start = cursor
        takeSign()
        var digits = takeDigits()
        if cursor < bytes.count, bytes[cursor] == 46 {
            cursor += 1
            digits += takeDigits()
        }
        guard digits > 0 else { throw Failure.unsupportedPath }
        if cursor < bytes.count, [69, 101].contains(bytes[cursor]) {
            cursor += 1
            takeSign()
            guard takeDigits() > 0 else { throw Failure.unsupportedPath }
        }
        guard cursor - start <= 32, let value = Double(String(decoding: bytes[start..<cursor], as: UTF8.self)),
              abs(value) <= 32_768 else { throw Failure.unsupportedPath }
        return CGFloat(value)
    }

    private mutating func takeSign() {
        if cursor < bytes.count, [43, 45].contains(bytes[cursor]) { cursor += 1 }
    }

    private mutating func takeDigits() -> Int {
        let start = cursor
        while cursor < bytes.count, (48...57).contains(bytes[cursor]) { cursor += 1 }
        return cursor - start
    }

    private mutating func skipSeparators() {
        while cursor < bytes.count, [9, 10, 13, 32, 44].contains(bytes[cursor]) { cursor += 1 }
    }
}
