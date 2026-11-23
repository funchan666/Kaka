import Foundation
import ImageIO
import PhotosUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class KakaAvatarUpload: NSObject, PHPickerViewControllerDelegate, UIAdaptivePresentationControllerDelegate {
    static let shared = KakaAvatarUpload()

    enum Failure: String, Error {
        case busy = "avatar-busy"
        case presentation = "avatar-presentation"
        case image = "avatar-image"
        case upload = "avatar-upload"
        case response = "avatar-response"
    }

    private struct Permit {
        let destination: URL
        let publicBase: URL
        let fields: [(String, String)]

        init(_ value: [String: Any]) throws {
            guard let host = value["voyagerGuide"] as? String, let target = Self.httpsURL(host),
                  let id = Self.formField(value["stageKey"]),
                  let policy = Self.formField(value["consoleProtocol"]),
                  let sig = Self.formField(value["cipherSeal"]) else { throw Failure.response }
            let publicAddress = (value["encoreStream"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? host
            guard let publicBase = Self.httpsURL(publicAddress), publicBase.query == nil else { throw Failure.response }
            destination = target
            self.publicBase = publicBase
            fields = [("OSSAccessKeyId", id), ("policy", policy), ("Signature", sig), ("success_action_status", "200")]
        }

        private static func formField(_ value: Any?) -> String? {
            guard let value = value as? String, !value.isEmpty, value.utf8.count <= 64 * 1024,
                  !value.contains("\r"), !value.contains("\n") else { return nil }
            return value
        }

        private static func httpsURL(_ address: String) -> URL? {
            guard let url = URL(string: address), url.scheme?.lowercased() == "https",
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
                  url.fragment == nil else { return nil }
            return url
        }
    }

    private var active = false
    private var selection: CheckedContinuation<NSItemProvider?, Never>?

    func pick(from presenter: UIViewController, session: UUID) async throws -> Data {
        guard !active else { throw Failure.busy }
        active = true
        defer { active = false }

        let account = try await KakaAccountStore.shared.remoteUserID(session: session)
        guard let jpeg = try await chooseJPEG(from: presenter, square: true) else { return Data("null".utf8) }
        let fileURL = try await storePhoto(jpeg, account: account, session: session)
        let change = try KakaRemoteClient.json(["cometGlyph": fileURL.absoluteString])
        _ = try await KakaAccountStore.shared.call(path: "/r2/voyager/refresh", body: change, session: session)
        return try KakaRemoteClient.json(["portrait": fileURL.absoluteString])
    }

    func pickRoomCover(from presenter: UIViewController) async throws -> Data? {
        guard !active else { throw Failure.busy }
        active = true
        defer { active = false }
        return try await chooseJPEG(from: presenter, square: false)
    }

    func uploadRoomCover(_ jpeg: Data, session: UUID) async throws -> String {
        let account = try await KakaAccountStore.shared.remoteUserID(session: session)
        let address = try await storePhoto(jpeg, account: account, session: session)
        return address.absoluteString
    }

    private func chooseJPEG(from presenter: UIViewController, square: Bool) async throws -> Data? {
        guard presenter.isViewLoaded, presenter.view.window != nil,
              !(presenter.isBeingDismissed || presenter.isBeingPresented),
              presenter.presentedViewController == nil else { throw Failure.presentation }
        guard let provider = await select(from: presenter) else { return nil }
        try Task.checkCancellation()
        let jpeg = try await image(from: provider, square: square)
        try Task.checkCancellation()
        return jpeg
    }

    private func storePhoto(_ jpeg: Data, account: Int64, session: UUID) async throws -> URL {
        try await storeMedia(jpeg, suffix: "jpg", contentType: "image/jpeg", limit: 4 * 1024 * 1024,
                             account: account, session: session)
    }

    func storeMedia(_ data: Data, suffix: String, contentType: String, limit: Int,
                    account: Int64, session: UUID, stillValid: () -> Bool = { true }) async throws -> URL {
        guard account > 0, !data.isEmpty, data.count <= limit,
              suffix.range(of: #"^[a-z0-9]{1,8}$"#, options: .regularExpression) != nil,
              contentType.range(of: #"^[a-z0-9]+/[a-z0-9.+-]+$"#, options: .regularExpression) != nil else { throw Failure.image }
        guard stillValid() else { throw CancellationError() }
        let credentials = try await KakaAccountStore.shared.call(
            path: "/r2/voyager/storage-vector", body: Data("{}".utf8), session: session
        )
        let permit = try Permit(KakaRemoteClient.object(credentials))
        let ownerFolder = String(account)
        let file = UUID().uuidString.lowercased() + "." + suffix
        let fileURL = permit.publicBase.appendingPathComponent(ownerFolder, isDirectory: true)
            .appendingPathComponent(file, isDirectory: false)
        guard try await KakaAccountStore.shared.remoteUserID(session: session) == account else { throw Failure.response }
        guard stillValid() else { throw CancellationError() }
        try await upload(data, key: ownerFolder + "/" + file, fileName: suffix == "jpg" ? "portrait.jpg" : "media." + suffix,
                         contentType: contentType, permit: permit)
        try Task.checkCancellation()
        guard try await KakaAccountStore.shared.remoteUserID(session: session) == account else { throw Failure.response }
        guard stillValid() else { throw CancellationError() }
        return fileURL
    }

    private func select(from presenter: UIViewController) async -> NSItemProvider? {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        return await withCheckedContinuation { continuation in
            selection = continuation
            presenter.present(picker, animated: true)
            picker.presentationController?.delegate = self
        }
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        let reply = selection
        selection = nil
        let provider = results.first?.itemProvider
        picker.dismiss(animated: true) { reply?.resume(returning: provider) }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        let reply = selection
        selection = nil
        reply?.resume(returning: nil)
    }

    private func image(from provider: NSItemProvider, square: Bool) async throws -> Data {
        guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else {
            throw Failure.image
        }
        return try await withCheckedThrowingContinuation { reply in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                guard error == nil, let url else {
                    reply.resume(throwing: Failure.image)
                    return
                }
                do { reply.resume(returning: try Self.photoJPEG(at: url, square: square)) }
                catch { reply.resume(throwing: error) }
            }
        }
    }

    private nonisolated static func photoJPEG(at url: URL, square: Bool) throws -> Data {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1100,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw Failure.image }
        let outputImage: CGImage
        if square {
            let side = min(image.width, image.height, 800)
            guard side > 0 else { throw Failure.image }
            let crop = CGRect(x: CGFloat((image.width - side) / 2), y: CGFloat((image.height - side) / 2),
                              width: CGFloat(side), height: CGFloat(side))
            guard let cropped = image.cropping(to: crop) else { throw Failure.image }
            outputImage = cropped
        } else {
            outputImage = image
        }
        let bytes = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(bytes as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Failure.image
        }
        // A fresh raster encode excludes source filenames, EXIF and location metadata.
        let quality = [kCGImageDestinationLossyCompressionQuality: 0.83] as CFDictionary
        CGImageDestinationAddImage(output, outputImage, quality)
        guard CGImageDestinationFinalize(output), bytes.length > 0, bytes.length <= 4 * 1024 * 1024 else { throw Failure.image }
        return bytes as Data
    }

    private func upload(_ payload: Data, key: String, fileName: String, contentType: String, permit: Permit) async throws {
        let delimiter = "Kaka-" + UUID().uuidString
        var data = Data()
        for (name, value) in [("key", key)] + permit.fields {
            let field = "--\(delimiter)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
            data.append(contentsOf: field.utf8)
        }
        let attachment = "--\(delimiter)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\nContent-Type: \(contentType)\r\n\r\n"
        data.append(contentsOf: attachment.utf8)
        data.append(payload)
        data.append(contentsOf: "\r\n--\(delimiter)--\r\n".utf8)

        var request = URLRequest(url: permit.destination, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(delimiter)", forHTTPHeaderField: "Content-Type")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 100
        let network = URLSession(configuration: configuration, delegate: RedirectGuard(), delegateQueue: nil)
        defer { network.finishTasksAndInvalidate() }

        do {
            let (_, reply) = try await network.upload(for: request, from: data)
            guard let http = reply as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw Failure.upload }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.upload
        }
    }

    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
