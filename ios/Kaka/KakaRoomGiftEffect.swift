import AVFoundation
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import CoreVideo
import ImageIO
import SwiftUI
import UIKit

@MainActor
struct KakaRoomGiftEffectOverlay: ViewModifier {
    @ObservedObject var effects: KakaRoomGiftEffects
    let accepting: Bool
    let presenting: Bool

    func body(content: Content) -> some View {
        content
            .overlay {
                if presenting, let effect = effects.current {
                    KakaRoomGiftEffect(url: effect.url) { effects.finished(effect.id) }
                        .id(effect.id)
                }
            }
            .onAppear(perform: update)
            .onChange(of: accepting) { _ in update() }
            .onChange(of: presenting) { _ in update() }
    }

    private func update() {
        effects.update(accepting: accepting, presenting: presenting)
    }
}

@MainActor
final class KakaRoomGiftEffects: ObservableObject {
    struct Clip: Identifiable {
        let id = UUID()
        let url: URL
        let time: TimeInterval
        let expires: TimeInterval
    }

    @Published private(set) var current: Clip?
    private var pending: [Clip] = []
    private var accepting = false
    private var presenting = false

    static func accepts(_ url: URL) -> Bool { KakaRoomGiftEffectSource.allows(url) }

    static func preferredURL(_ urls: [URL]) -> URL? {
        let supported = urls.filter { accepts($0) }
        guard let first = supported.first else { return nil }
        guard first.pathExtension.lowercased() == "svga" else { return first }
        return supported.first { ["mp4", "mov", "gif", "apng"].contains($0.pathExtension.lowercased()) } ?? first
    }

    func enqueue(_ url: URL, time: TimeInterval) {
        guard accepting, Self.accepts(url) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        pending.removeAll { $0.expires <= now }
        guard pending.count < 4,
              current?.url != url || current?.time != time,
              !pending.contains(where: { $0.url == url && $0.time == time }) else { return }
        pending.append(Clip(url: url, time: time, expires: now + 15))
        advance()
    }

    func update(accepting: Bool, presenting: Bool) {
        self.accepting = accepting
        self.presenting = accepting && presenting
        if !accepting { clear() }
        else if presenting { advance() }
        else { current = nil }
    }

    func finished(_ id: UUID) {
        guard current?.id == id else { return }
        current = nil
        advance()
    }

    func clear() {
        accepting = false
        presenting = false
        current = nil
        pending.removeAll()
    }

    private func advance() {
        guard presenting, current == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        pending.removeAll { $0.expires <= now }
        if !pending.isEmpty { current = pending.removeFirst() }
    }
}

@MainActor
struct KakaRoomGiftEffect: View {
    let url: URL
    let onFinish: () -> Void
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var svga: KakaSVGAGift?
    @State private var svgaFrame = 0

    var body: some View {
        ZStack {
            if let player {
                VideoSurface(player: player)
            } else if let svga {
                KakaSVGAGiftSurface(movie: svga, frame: svgaFrame)
            } else if let image {
                Image(uiImage: image).resizable().scaledToFit()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task { await play() }
    }

    private func play() async {
        defer { if !Task.isCancelled { onFinish() } }
        do {
            let data = try await KakaRoomGiftEffectSource.download(url)
            try Task.checkCancellation()
            if KakaSVGAGift.matches(data) {
                try await playSVGA(data)
            } else if let movie = try KakaRoomGiftEffectSource.movie(data) {
                try await playMovie(data, format: movie)
            } else {
                let frames = try await KakaRoomGiftEffectSource.frames(data)
                for frame in frames {
                    try Task.checkCancellation()
                    image = UIImage(cgImage: frame.image)
                    try await Task.sleep(nanoseconds: UInt64(frame.delay * 1_000_000_000))
                }
            }
        } catch {
            // A room gift still has its regular banner if its effect is unavailable.
        }
    }

    private func playSVGA(_ data: Data) async throws {
        let movie = try await KakaSVGAGift.load(data)
        try Task.checkCancellation()
        svga = movie
        let started = ProcessInfo.processInfo.systemUptime
        let fps = Double(movie.fps)
        let stride = max(1, (movie.fps + 29) / 30)
        while true {
            try Task.checkCancellation()
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            let frame = Int(elapsed * fps)
            guard frame < movie.frames else { return }
            svgaFrame = frame / stride * stride
            let next = min(movie.frames, svgaFrame + stride)
            let delay = max(0, Double(next) / fps - elapsed)
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private func playMovie(_ data: Data, format: KakaRoomGiftEffectSource.Movie) async throws {
        let file = try await KakaRoomGiftEffectSource.movieFile(data, isMOV: url.pathExtension.lowercased() == "mov")
        defer { try? FileManager.default.removeItem(at: file) }
        if case .packed(let layout) = format {
            for try await frame in KakaRoomGiftEffectSource.packedFrames(file, layout: layout, origin: url) {
                try Task.checkCancellation()
                image = UIImage(cgImage: frame)
            }
            return
        }
        let asset = KakaRoomGiftEffectSource.localAsset(file)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, duration <= 9, try await asset.load(.isPlayable) else { return }
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1, let track = tracks.first else { return }
        guard try await KakaRoomGiftEffectSource.validDimensions(track) else { return }
        try Task.checkCancellation()
        let playback = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        playback.isMuted = true
        playback.preventsDisplaySleepDuringVideoPlayback = false
        player = playback
        defer {
            playback.pause()
            playback.replaceCurrentItem(with: nil)
        }
        playback.play()
        try await Task.sleep(nanoseconds: UInt64((duration + 0.25) * 1_000_000_000))
    }

    private struct VideoSurface: UIViewRepresentable {
        let player: AVPlayer

        func makeUIView(context: Context) -> Surface {
            let view = Surface()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
            view.playerLayer.videoGravity = .resizeAspect
            view.playerLayer.player = player
            return view
        }

        func updateUIView(_ view: Surface, context: Context) {}

        static func dismantleUIView(_ view: Surface, coordinator: ()) {
            view.playerLayer.player?.pause()
            view.playerLayer.player = nil
        }

        final class Surface: UIView {
            override class var layerClass: AnyClass { AVPlayerLayer.self }
            var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        }
    }
}

private enum KakaRoomGiftEffectSource {
    struct Frame: @unchecked Sendable {
        let image: CGImage
        var delay: TimeInterval
    }

    private enum Failure: Error { case response, size, format }
    private static let supported = ["", "gif", "png", "apng", "mp4", "mov", "svga"]

    enum Movie {
        case regular
        case packed(PackedAlpha)
    }

    struct PackedAlpha: Sendable {
        let width: Int
        let height: Int
        let color: CGRect
        let alpha: CGRect
        let canvas: CGSize
        let fusion: Fusion?

        init(_ data: Data) throws {
            let fields = try KakaRemoteClient.object(data)
            guard let info = fields["info"] as? [String: Any],
                  let version = KakaRemoteClient.userID(info["v"]), (1...2).contains(version),
                  let width = KakaRemoteClient.userID(info["videoW"]), (1...2160).contains(width),
                  let height = KakaRemoteClient.userID(info["videoH"]), (1...2160).contains(height),
                  let color = Self.rect(info["rgbFrame"], width: width, height: height),
                  let alpha = Self.rect(info["aFrame"], width: width, height: height),
                  !color.intersects(alpha) else { throw Failure.format }
            let fused = KakaRemoteClient.userID(info["isVapx"])
            guard info["isVapx"] == nil || fused == 0 || fused == 1 else { throw Failure.format }
            self.width = Int(width)
            self.height = Int(height)
            self.color = color
            self.alpha = alpha
            if fused == 1, let outputWidth = KakaRemoteClient.userID(info["w"]), (1...2160).contains(outputWidth),
               let outputHeight = KakaRemoteClient.userID(info["h"]), (1...2160).contains(outputHeight) {
                canvas = CGSize(width: CGFloat(outputWidth), height: CGFloat(outputHeight))
                fusion = Fusion(fields, sourceWidth: width, sourceHeight: height, outputWidth: outputWidth, outputHeight: outputHeight)
            } else {
                canvas = color.size
                fusion = nil
            }
        }

        static func rect(_ raw: Any?, width: Int64, height: Int64) -> CGRect? {
            guard let fields = raw as? [Any], fields.count == 4 else { return nil }
            let values = fields.compactMap { KakaRemoteClient.userID($0) }
            guard values.count == 4, values[0] >= 0, values[0] < width, values[1] >= 0, values[1] < height,
                  (1...(width - values[0])).contains(values[2]), (1...(height - values[1])).contains(values[3]) else {
                return nil
            }
            return CGRect(x: CGFloat(values[0]), y: CGFloat(height - values[1] - values[3]),
                          width: CGFloat(values[2]), height: CGFloat(values[3]))
        }
    }

    struct Fusion: Sendable {
        struct Texture: Sendable {
            enum Fit: String, Sendable { case fitXY, centerFull, centerCrop }
            let url: URL
            let size: CGSize
            let fit: Fit
        }

        struct Overlay: Sendable {
            let texture: String
            let placement: CGRect
            let mask: CGRect
        }

        let textures: [String: Texture]
        let frames: [Int: [Overlay]]

        init?(_ fields: [String: Any], sourceWidth: Int64, sourceHeight: Int64, outputWidth: Int64, outputHeight: Int64) {
            guard let sources = fields["src"] as? [[String: Any]], (1...16).contains(sources.count),
                  let rows = fields["frame"] as? [[String: Any]], (1...540).contains(rows.count) else { return nil }
            var textures: [String: Texture] = [:]
            for source in sources {
                guard source["srcType"] as? String == "img", source["loadType"] as? String == "net",
                      let id = source["srcId"] as? String, (1...64).contains(id.utf8.count), textures[id] == nil,
                      let tag = source["srcTag"] as? String, tag.utf8.count <= 2048, let url = URL(string: tag),
                      let width = KakaRemoteClient.userID(source["w"]), (1...2160).contains(width),
                      let height = KakaRemoteClient.userID(source["h"]), (1...2160).contains(height),
                      let fit = Texture.Fit(rawValue: source["fitType"] as? String ?? "fitXY") else { continue }
                textures[id] = Texture(url: url, size: CGSize(width: CGFloat(width), height: CGFloat(height)), fit: fit)
            }
            guard !textures.isEmpty else { return nil }

            var frames: [Int: [Overlay]] = [:]
            var used = Set<String>()
            for row in rows {
                guard let index = KakaRemoteClient.userID(row["i"]), (0..<540).contains(index), frames[Int(index)] == nil,
                      let items = row["obj"] as? [[String: Any]], items.count <= 12 else { continue }
                let layers: [(order: Int64, overlay: Overlay)] = items.compactMap { item in
                    guard let id = item["srcId"] as? String, textures[id] != nil,
                          item["mt"] == nil || KakaRemoteClient.userID(item["mt"]) == 0,
                          let placement = Self.placement(item["frame"], width: outputWidth, height: outputHeight),
                          let mask = PackedAlpha.rect(item["mFrame"], width: sourceWidth, height: sourceHeight) else { return nil }
                    used.insert(id)
                    return (KakaRemoteClient.userID(item["z"]) ?? 0, Overlay(texture: id, placement: placement, mask: mask))
                }
                frames[Int(index)] = layers.sorted { $0.order < $1.order }.map { $0.overlay }
            }
            guard !used.isEmpty else { return nil }
            self.textures = textures.filter { used.contains($0.key) }
            self.frames = frames
        }

        private static func placement(_ raw: Any?, width: Int64, height: Int64) -> CGRect? {
            guard let fields = raw as? [Any], fields.count == 4 else { return nil }
            let values = fields.compactMap { KakaRemoteClient.userID($0) }
            guard values.count == 4, (-width..<width).contains(values[0]), (-height..<height).contains(values[1]),
                  (1...(width * 2)).contains(values[2]), (1...(height * 2)).contains(values[3]),
                  values[0] + values[2] > 0, values[1] + values[3] > 0 else { return nil }
            return CGRect(x: CGFloat(values[0]), y: CGFloat(height - values[1] - values[3]),
                          width: CGFloat(values[2]), height: CGFloat(values[3]))
        }
    }

    static func allows(_ url: URL) -> Bool {
        guard url.absoluteString.utf8.count <= 2048, url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), host.contains("."), !host.hasSuffix(".local"),
              !host.hasSuffix(".localhost"), url.user == nil, url.password == nil, url.fragment == nil,
              url.port == nil || url.port == 443,
              supported.contains(url.pathExtension.lowercased()) else { return false }
        return host.contains(where: \.isLetter)
    }

    static func download(_ url: URL) async throws -> Data {
        guard allows(url) else { throw Failure.format }
        let movieOrUnknown = ["", "mp4", "mov"].contains(url.pathExtension.lowercased())
        return try await download(url, limit: (movieOrUnknown ? 24 : 8) * 1_024 * 1_024, timeout: 9)
    }

    private static func download(_ url: URL, limit: Int, timeout: TimeInterval) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = min(5, timeout)
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url == url, http.expectedContentLength <= Int64(limit) else { throw Failure.response }
        var data = Data()
        if http.expectedContentLength > 0 { data.reserveCapacity(Int(http.expectedContentLength)) }
        for try await byte in bytes {
            guard data.count < limit else { throw Failure.size }
            data.append(byte)
        }
        try Task.checkCancellation()
        guard !data.isEmpty else { throw Failure.response }
        return data
    }

    static func movie(_ data: Data) throws -> Movie? {
        var offset = 0
        var hasMetadata = false
        var hasMedia = false
        var packed: PackedAlpha?
        while offset < data.count {
            let remaining = data.count - offset
            guard remaining >= 8 else { return nil }
            let type = data[(offset + 4)..<(offset + 8)]
            var boxSize = data[offset..<(offset + 4)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let header = boxSize == 1 ? 16 : 8
            guard remaining >= header else { return nil }
            if header == 16 {
                boxSize = data[(offset + 8)..<(offset + 16)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            } else if boxSize == 0 {
                boxSize = UInt64(remaining)
            }
            guard boxSize >= UInt64(header), boxSize <= UInt64(remaining) else { return nil }
            if type.elementsEqual("vapc".utf8) {
                guard packed == nil, boxSize <= 256 * 1_024 else { throw Failure.format }
                packed = try PackedAlpha(data.subdata(in: (offset + header)..<(offset + Int(boxSize))))
            }
            hasMetadata = hasMetadata || type.elementsEqual("moov".utf8)
            hasMedia = hasMedia || type.elementsEqual("mdat".utf8)
            offset += Int(boxSize)
        }
        guard hasMetadata, hasMedia else { return nil }
        return packed.map(Movie.packed) ?? .regular
    }

    static func localAsset(_ file: URL) -> AVURLAsset {
        AVURLAsset(url: file, options: [
            AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue)
        ])
    }

    static func validDimensions(_ track: AVAssetTrack, layout: PackedAlpha? = nil) async throws -> Bool {
        let formats = try await track.load(.formatDescriptions)
        return !formats.isEmpty && formats.allSatisfy { format in
            let size = CMVideoFormatDescriptionGetDimensions(format)
            if let layout { return size.width == Int32(layout.width) && size.height == Int32(layout.height) }
            return (1...2160).contains(size.width) && (1...2160).contains(size.height)
        }
    }

    static func packedFrames(_ file: URL, layout: PackedAlpha, origin: URL) -> AsyncThrowingStream<CGImage, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { stream in
            let decode = Task.detached(priority: .userInitiated) {
                do {
                    try await decodePackedFrames(file, layout: layout, origin: origin, into: stream)
                    stream.finish()
                } catch {
                    stream.finish(throwing: error)
                }
            }
            stream.onTermination = { _ in decode.cancel() }
        }
    }

    private static func decodePackedFrames(_ file: URL, layout: PackedAlpha, origin: URL,
                                           into stream: AsyncThrowingStream<CGImage, Error>.Continuation) async throws {
        let asset = localAsset(file)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard duration.isFinite, duration > 0, duration <= 9, tracks.count == 1, let track = tracks.first,
              try await validDimensions(track, layout: layout) else {
            throw Failure.format
        }
        let textures = await loadTextures(layout.fusion, origin: origin)
        try Task.checkCancellation()
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure.format }
        reader.add(output)
        try Task.checkCancellation()
        guard reader.startReading() else { throw Failure.format }
        defer { if reader.status == .reading { reader.cancelReading() } }
        let context = CIContext(options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])
        let filter = CIFilter.blendWithRedMask()
        let overlayFilter = CIFilter.blendWithRedMask()
        let starts = ProcessInfo.processInfo.systemUptime
        let size = layout.canvas
        let scale = min(1, 720 / max(size.width, size.height))
        let bounds = CGRect(origin: .zero, size: CGSize(width: floor(size.width * scale), height: floor(size.height * scale)))
        guard !bounds.isEmpty else { throw Failure.format }
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
        filter.backgroundImage = clear.cropped(to: bounds)
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        var firstTime: TimeInterval?
        var lastFrame = -Double.infinity
        for frameIndex in 0..<540 {
            try Task.checkCancellation()
            guard let sample = output.copyNextSampleBuffer() else { break }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard time.isFinite else { continue }
            if firstTime == nil { firstTime = time }
            let elapsed = time - (firstTime ?? time)
            let wall = ProcessInfo.processInfo.systemUptime - starts
            guard wall < 10, elapsed <= duration + 0.03 else { break }
            guard elapsed - lastFrame >= 1 / 30.0 - 0.002 else { continue }
            guard let pixels = CMSampleBufferGetImageBuffer(sample), CVPixelBufferGetWidth(pixels) == layout.width,
                  CVPixelBufferGetHeight(pixels) == layout.height else { throw Failure.format }
            let frame: CGImage? = autoreleasepool {
                let packed = CIImage(cvPixelBuffer: pixels)
                filter.inputImage = resized(packed, cropping: layout.color, to: bounds.size)
                filter.maskImage = resized(packed, cropping: layout.alpha, to: bounds.size)
                guard var canvas = filter.outputImage else { return nil }
                if let fusion = layout.fusion, let overlays = fusion.frames[frameIndex] {
                    for overlay in overlays {
                        guard let texture = textures[overlay.texture], let design = fusion.textures[overlay.texture] else { continue }
                        let placement = overlay.placement.applying(CGAffineTransform(scaleX: bounds.width / size.width,
                                                                                     y: bounds.height / size.height))
                        let translation = CGAffineTransform(translationX: placement.minX, y: placement.minY)
                        let crop = overlayCrop(texture, design: design, placement: overlay.placement.size)
                        overlayFilter.inputImage = resized(texture, cropping: crop, to: placement.size).transformed(by: translation)
                        overlayFilter.maskImage = resized(packed, cropping: overlay.mask, to: placement.size).transformed(by: translation)
                        overlayFilter.backgroundImage = clear.cropped(to: placement)
                        if let content = overlayFilter.outputImage {
                            canvas = content.cropped(to: placement.intersection(bounds)).composited(over: canvas)
                        }
                    }
                }
                return context.createCGImage(canvas, from: bounds, format: .RGBA8, colorSpace: space)
            }
            guard let frame else { throw Failure.format }
            let wait = elapsed - (ProcessInfo.processInfo.systemUptime - starts)
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            try Task.checkCancellation()
            stream.yield(frame)
            lastFrame = elapsed
        }
        guard lastFrame.isFinite, reader.status != .failed else { throw Failure.format }
        let tail = min(0.25, duration - (ProcessInfo.processInfo.systemUptime - starts))
        if tail > 0 { try await Task.sleep(nanoseconds: UInt64(tail * 1_000_000_000)) }
    }

    private struct LoadedTexture: @unchecked Sendable {
        let id: String
        let image: CGImage
    }

    private static func loadTextures(_ fusion: Fusion?, origin: URL) async -> [String: CIImage] {
        guard let fusion else { return [:] }
        // VAPX tags are application placeholders. This player only resolves explicit image URLs on the effect host.
        let candidates = fusion.textures.sorted { $0.key < $1.key }.filter { _, texture in
            let url = texture.url
            return url.scheme?.lowercased() == "https" && url.host?.lowercased() == origin.host?.lowercased()
                && (url.port ?? 443) == (origin.port ?? 443) && url.user == nil && url.password == nil && url.fragment == nil
                && ["png", "jpg", "jpeg", "webp"].contains(url.pathExtension.lowercased())
        }.prefix(4)
        return await withTaskGroup(of: LoadedTexture?.self) { group in
            for (id, texture) in candidates {
                group.addTask {
                    guard let data = try? await download(texture.url, limit: 2 * 1_024 * 1_024, timeout: 2.5),
                          let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                          CGImageSourceGetCount(source) == 1, let type = CGImageSourceGetType(source),
                          ["public.png", "public.jpeg", "org.webmproject.webp"].contains(type as String),
                          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let width = properties[kCGImagePropertyPixelWidth] as? Int, (1...4096).contains(width),
                          let height = properties[kCGImagePropertyPixelHeight] as? Int, (1...4096).contains(height) else { return nil }
                    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                    kCGImageSourceCreateThumbnailWithTransform: true,
                                                    kCGImageSourceThumbnailMaxPixelSize: 720,
                                                    kCGImageSourceShouldCacheImmediately: true]
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { LoadedTexture(id: id, image: $0) }
                }
            }
            var loaded: [String: CIImage] = [:]
            for await result in group {
                if let result { loaded[result.id] = CIImage(cgImage: result.image) }
            }
            return loaded
        }
    }

    private static func overlayCrop(_ texture: CIImage, design: Fusion.Texture, placement: CGSize) -> CGRect {
        let extent = texture.extent
        guard design.fit != .fitXY else { return extent }
        let scaleToFill = max(placement.width / design.size.width, placement.height / design.size.height)
        let scale = design.fit == .centerFull ? max(1, scaleToFill) : scaleToFill
        let width = min(extent.width, extent.width * placement.width / (design.size.width * scale))
        let height = min(extent.height, extent.height * placement.height / (design.size.height * scale))
        return CGRect(x: extent.midX - width / 2, y: extent.midY - height / 2, width: width, height: height)
    }

    private static func resized(_ image: CIImage, cropping rect: CGRect, to size: CGSize) -> CIImage {
        image.cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            .transformed(by: CGAffineTransform(scaleX: size.width / rect.width, y: size.height / rect.height))
    }

    static func movieFile(_ data: Data, isMOV: Bool) async throws -> URL {
        try Task.checkCancellation()
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaka-gift-" + UUID().uuidString)
            .appendingPathExtension(isMOV ? "mov" : "mp4")
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        return file
    }

    static func frames(_ data: Data) async throws -> [Frame] {
        guard data.count <= 8 * 1_024 * 1_024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let rawType = CGImageSourceGetType(source) else { throw Failure.format }
        let type = rawType as String
        guard type == "com.compuserve.gif" || type == "public.png",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, (1...3072).contains(width),
              let height = properties[kCGImagePropertyPixelHeight] as? Int, (1...3072).contains(height) else { throw Failure.format }
        let count = CGImageSourceGetCount(source)
        guard (2...240).contains(count) else { throw Failure.format }
        let step = max(1, (count + 47) / 48)
        let samples = (count + step - 1) / step
        let maxSide = min(960, Int(sqrt(Double(24 * 1_024 * 1_024 / (samples * 4)))))
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                       kCGImageSourceThumbnailMaxPixelSize: maxSide,
                                       kCGImageSourceShouldCacheImmediately: true]
        var result: [Frame] = []
        var elapsed: TimeInterval = 0
        for index in 0..<count where elapsed < 9 {
            try Task.checkCancellation()
            let delay = min(frameDelay(source, at: index, gif: type == "com.compuserve.gif"), 9 - elapsed)
            if index % step == 0 {
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
                    throw Failure.format
                }
                result.append(Frame(image: image, delay: delay))
            } else {
                result[result.count - 1].delay += delay
            }
            elapsed += delay
        }
        return result
    }

    private static func frameDelay(_ source: CGImageSource, at index: Int, gif: Bool) -> TimeInterval {
        let details = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let record = details?[gif ? kCGImagePropertyGIFDictionary : kCGImagePropertyPNGDictionary] as? [CFString: Any]
        let unclamped = gif ? kCGImagePropertyGIFUnclampedDelayTime : kCGImagePropertyAPNGUnclampedDelayTime
        let clamped = gif ? kCGImagePropertyGIFDelayTime : kCGImagePropertyAPNGDelayTime
        let delay = record?[unclamped] as? Double ?? record?[clamped] as? Double ?? 0.1
        return delay.isFinite ? min(max(0.034, delay), 1) : 0.1
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
