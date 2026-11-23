import Foundation
import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct KakaChatPhoto: Sendable {
    let jpeg: Data
    let width: Int32
    let height: Int32

    private init(jpeg: Data, width: Int32, height: Int32) {
        self.jpeg = jpeg
        self.width = width
        self.height = height
    }

    @MainActor
    static func selected(from provider: NSItemProvider) async throws -> Self {
        let jpeg = try await KakaAvatarUpload.image(from: provider, square: false, maxSourceBytes: 40 * 1_024 * 1_024)
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int32Value,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int32Value,
              (1...1_100).contains(width), (1...1_100).contains(height) else { throw KakaAvatarUpload.Failure.image }
        return Self(jpeg: jpeg, width: width, height: height)
    }

    static func remoteURL(_ value: String?) -> URL? {
        guard let value, value.utf8.count <= 4096, let url = URL(string: value),
              url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), host.contains("."),
              host.contains(where: \.isLetter), !host.hasSuffix(".local"), !host.hasSuffix(".localhost"),
              url.port == nil || url.port == 443, url.user == nil, url.password == nil, url.fragment == nil else { return nil }
        return url
    }

    static func thumbnail(from url: URL) async throws -> Data {
        guard remoteURL(url.absoluteString) != nil else { throw KakaAvatarUpload.Failure.image }
        let (stream, response) = try await network.bytes(from: url)
        let limit = 8 * 1_024 * 1_024
        guard let http = response as? HTTPURLResponse, http.url == url, (200...299).contains(http.statusCode),
              http.expectedContentLength <= Int64(limit) else { throw KakaAvatarUpload.Failure.image }
        var data = Data()
        for try await byte in stream {
            guard data.count < limit else { throw KakaAvatarUpload.Failure.image }
            data.append(byte)
        }
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source), UTType(type as String)?.conforms(to: .image) == true else {
            throw KakaAvatarUpload.Failure.image
        }
        return try KakaAvatarUpload.photoJPEG(source, square: false, constrainDimensions: true)
    }

    private static let network: URLSession = {
        let options = URLSessionConfiguration.ephemeral
        options.httpShouldSetCookies = false
        options.httpCookieStorage = nil
        options.urlCredentialStorage = nil
        options.urlCache = nil
        options.timeoutIntervalForRequest = 12
        options.timeoutIntervalForResource = 20
        options.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: options, delegate: NoRedirects(), delegateQueue: nil)
    }()

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

@MainActor
struct KakaChatPhotoPicker: UIViewControllerRepresentable {
    let selected: (NSItemProvider?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(selected: selected) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: PHPickerViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let selected: (NSItemProvider?) -> Void

        init(selected: @escaping (NSItemProvider?) -> Void) { self.selected = selected }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            selected(results.first?.itemProvider)
        }
    }
}

@MainActor
struct KakaChatPhotoThumbnail: View {
    let url: URL
    let sender: String
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .accessibilityLabel("Photo from \(sender)")
            } else {
                Text(failed ? "Photo unavailable" : "Loading photo…")
                    .font(.footnote).foregroundStyle(KakaTheme.muted)
            }
        }
        .frame(maxWidth: 220, maxHeight: 126, alignment: .leading)
        .task(id: url) {
            image = nil
            failed = false
            do {
                let jpeg = try await KakaChatPhoto.thumbnail(from: url)
                guard !Task.isCancelled else { return }
                image = UIImage(data: jpeg)
                failed = image == nil
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
    }
}
