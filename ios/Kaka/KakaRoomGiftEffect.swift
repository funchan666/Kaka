import AVFoundation
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

    var body: some View {
        ZStack {
            if let player {
                VideoSurface(player: player)
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
            if KakaRoomGiftEffectSource.isMovie(data) {
                try await playMovie(data)
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

    private func playMovie(_ data: Data) async throws {
        let file = try await KakaRoomGiftEffectSource.movieFile(data, isMOV: url.pathExtension.lowercased() == "mov")
        defer { try? FileManager.default.removeItem(at: file) }
        let asset = AVURLAsset(url: file, options: [
            AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue)
        ])
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, duration <= 9, try await asset.load(.isPlayable) else { return }
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1, let track = tracks.first else { return }
        let size = try await track.load(.naturalSize)
        guard size.width > 0, size.height > 0, size.width <= 2160, size.height <= 2160 else { return }
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
    private static let supported = ["", "gif", "png", "apng", "mp4", "mov"]

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
        let limit = (movieOrUnknown ? 24 : 8) * 1_024 * 1_024
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 9
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

    static func isMovie(_ data: Data) -> Bool {
        var offset = 0
        var hasMetadata = false
        var hasMedia = false
        while offset < data.count {
            let remaining = data.count - offset
            guard remaining >= 8 else { return false }
            let type = data[(offset + 4)..<(offset + 8)]
            // VAP stores its packed color and alpha layout in a top-level vapc box.
            guard !type.elementsEqual("vapc".utf8) else { return false }
            var boxSize = data[offset..<(offset + 4)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let header = boxSize == 1 ? 16 : 8
            guard remaining >= header else { return false }
            if header == 16 {
                boxSize = data[(offset + 8)..<(offset + 16)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            } else if boxSize == 0 {
                boxSize = UInt64(remaining)
            }
            guard boxSize >= UInt64(header), boxSize <= UInt64(remaining) else { return false }
            hasMetadata = hasMetadata || type.elementsEqual("moov".utf8)
            hasMedia = hasMedia || type.elementsEqual("mdat".utf8)
            offset += Int(boxSize)
        }
        return hasMetadata && hasMedia
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
