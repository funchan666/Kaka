import CommonCrypto
import CoreFoundation
import CryptoKit
import Foundation

/// Implements the two service wire formats. Session and token ownership stay in the account actor.
struct KakaRemoteClient: Sendable {
    enum Fault: Error {
        case configuration
        case invalidBody
        case response
        case network
        case rejected(Int)

        var isExpired: Bool {
            if case .rejected(let code) = self { return (40101...40105).contains(code) }
            return false
        }
    }

    struct Configuration: Decodable, Sendable {
        let appId: String
        let origin: URL
        let aesKey: String
        let aesIv: String
        let socketAesKey: String?

        var scope: String {
            Self.digest("\(origin.absoluteString)\u{0}\(appId)").map { String(format: "%02x", $0) }.joined()
        }

        func workspaceID(for userID: Int64) -> UUID {
            var bytes = Array(Self.digest("\(scope)\u{0}\(userID)").prefix(16))
            bytes[6] = (bytes[6] & 0x0f) | 0x80
            bytes[8] = (bytes[8] & 0x3f) | 0x80
            return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        }

        private static func digest(_ value: String) -> SHA256.Digest {
            SHA256.hash(data: Data(value.utf8))
        }

        static func load() throws -> Self {
            guard let file = Bundle.main.url(forResource: "KakaService.private", withExtension: "json"),
                  let data = try? Data(contentsOf: file),
                  let value = try? JSONDecoder().decode(Self.self, from: data),
                  value.appId.range(of: #"^[-_A-Za-z0-9]+$"#, options: .regularExpression) != nil,
                  KakaRemoteClient.isHTTPS(value.origin), value.origin.query == nil else {
                throw Fault.configuration
            }
            return value
        }
    }

    struct Runtime: Sendable {
        let partyOrigin: URL
        let rtcAppID: String
        let messagingAppKey: String?
        fileprivate let socket: URL?
        fileprivate let socketKey: String?
        fileprivate let partyCipher: AES
        fileprivate let media: MediaDirectory?

        init(startup: [String: Any], fallbackSocketKey: String?) throws {
            guard let plan = startup["liveConsolePlan"] as? [String: Any],
                  let address = plan["relayEndpoint"] as? String, let origin = URL(string: address),
                  KakaRemoteClient.isHTTPS(origin), origin.query == nil,
                  let rtcAppID = plan["relayAppTag"] as? String, !rtcAppID.isEmpty,
                  let key = plan["cipherSecret"] as? String, let iv = plan["cipherVector"] as? String else {
                throw Fault.response
            }
            self.partyOrigin = origin
            self.rtcAppID = rtcAppID
            messagingAppKey = plan["consoleCipher"] as? String
            socket = (plan["relayAddress"] as? String).flatMap(URL.init(string:))
            socketKey = plan["socketAesKey"] as? String ?? fallbackSocketKey
            partyCipher = try AES(key: key, iv: iv)
            media = MediaDirectory(startup["studioDomain"])
        }
    }

    fileprivate struct MediaDirectory: Sendable {
        private let destination: URL
        private let sourceHosts: Set<String>
        private static let fields: Set<String> = [
            "cometGlyph", "spotlightFace", "relayLink", "cometImage", "orbitalStream", "mediaUrl", "fileUrl",
            "photoUrl", "imageUrl", "imgUrl", "coverUrl", "roomCover", "roomAvatar", "stageBackdrop", "bigImgUrl",
            "bgImgUrl", "nebulaCanvas", "nebulaTile", "orbitGlyph", "signalMotion", "giftEffect", "animUrl",
            "voyagerRoute", "minImage", "gifImage", "cipherPortal", "thumbUrl", "thumbnail", "itemSmallImg",
            "consoleBorder", "marqueePanel", "fanWhisper", "tierPortrait", "musicUrl", "nebulaLinks", "photos",
            "nebulaGallery", "mediaList", "photoList", "icon", "avatar", "url", "picUrl", "backgroundImgUrl",
            "giftImg", "giftSmallImg", "giftIcon", "giftSvga", "playUrl", "privateUrl", "headFrame", "cardFrame",
            "chatBubble", "medalImageUrl", "imgUrls", "picList"
        ]

        init?(_ raw: Any?) {
            let directory: [String: Any]?
            if let escaped = raw as? String {
                directory = try? KakaRemoteClient.object(Data(escaped.utf8))
            } else {
                directory = raw as? [String: Any]
            }
            guard let address = directory?["defaultCdnUrl"] as? String,
                  let destination = URL(string: address), KakaRemoteClient.isHTTPS(destination),
                  destination.query == nil,
                  let hosts = directory?["needReplaceCdnDomains"] as? [String] else { return nil }
            self.destination = destination
            sourceHosts = Set(hosts.compactMap { value in
                URL(string: value.contains("://") ? value : "https://" + value)?.host?.lowercased()
            })
        }

        func rewrite(_ value: Any, field: String? = nil) -> Any {
            if let object = value as? [String: Any] {
                return Dictionary(uniqueKeysWithValues: object.map { ($0.key, rewrite($0.value, field: $0.key)) })
            }
            if let collection = value as? [Any] { return collection.map { rewrite($0, field: field) } }
            guard let field, Self.fields.contains(field), let string = value as? String,
                  var uri = URLComponents(string: string), let host = uri.host,
                  let scheme = uri.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  sourceHosts.contains(host.lowercased()), uri.user == nil, uri.password == nil,
                  let cdn = URLComponents(url: destination, resolvingAgainstBaseURL: false) else { return value }
            uri.host = cdn.host
            uri.scheme = cdn.scheme
            uri.port = cdn.port
            let prefix = cdn.percentEncodedPath.hasSuffix("/") ? String(cdn.percentEncodedPath.dropLast()) : cdn.percentEncodedPath
            uri.percentEncodedPath = prefix + uri.percentEncodedPath
            return uri.url?.absoluteString ?? string
        }
    }

    fileprivate struct AES: Sendable {
        let key: Data
        let iv: Data?

        init(key: String, iv: String?) throws {
            self.key = Data(key.utf8)
            self.iv = iv.map { Data($0.utf8) }
            guard self.key.count == kCCKeySizeAES128,
                  self.iv.map({ $0.count == kCCBlockSizeAES128 }) != false else {
                throw Fault.configuration
            }
        }

        func encrypt(_ input: Data) throws -> Data {
            try transform(input, operation: CCOperation(kCCEncrypt))
        }

        func decryptHex(_ string: String) throws -> Data {
            let hex = Array(string.utf8)
            guard !hex.isEmpty, hex.count % (2 * kCCBlockSizeAES128) == 0 else { throw Fault.response }
            let bytes = try stride(from: 0, to: hex.count, by: 2).map { index -> UInt8 in
                guard let high = Self.hexDigit(hex[index]), let low = Self.hexDigit(hex[index + 1]) else {
                    throw Fault.response
                }
                return high << 4 | low
            }
            return try transform(Data(bytes), operation: CCOperation(kCCDecrypt))
        }

        private static func hexDigit(_ value: UInt8) -> UInt8? {
            switch value {
            case 48...57: return value - 48
            case 65...70: return value - 55
            case 97...102: return value - 87
            default: return nil
            }
        }

        private func transform(_ input: Data, operation: CCOperation) throws -> Data {
            var written = 0
            let size = input.count + kCCBlockSizeAES128
            let vector = iv ?? Data()
            let options = CCOptions(kCCOptionPKCS7Padding | (iv == nil ? kCCOptionECBMode : 0))
            var output = Data(count: size)
            let status = output.withUnsafeMutableBytes { outputBytes in
                input.withUnsafeBytes { inputBytes in
                    key.withUnsafeBytes { keyBytes in
                        vector.withUnsafeBytes { ivBytes in
                            CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), options,
                                    keyBytes.baseAddress, key.count, iv == nil ? nil : ivBytes.baseAddress,
                                    inputBytes.baseAddress, input.count, outputBytes.baseAddress, size, &written)
                        }
                    }
                }
            }
            guard status == kCCSuccess else { throw Fault.response }
            output.count = written
            return output
        }
    }

    let configuration: Configuration
    private let device: String
    private let cipher: AES
    private let network: URLSession

    init(device: UUID) throws {
        let settings = try Configuration.load()
        configuration = settings
        self.device = device.uuidString.lowercased()
        cipher = try AES(key: settings.aesKey, iv: settings.aesIv)
        let ephemeral = URLSessionConfiguration.ephemeral
        ephemeral.httpShouldSetCookies = false
        ephemeral.httpCookieStorage = nil
        ephemeral.urlCredentialStorage = nil
        network = URLSession(configuration: ephemeral, delegate: DirectConnection(), delegateQueue: nil)
    }

    func gateway(_ path: String, body: Data, bearer: String? = nil, renewalHint: String? = nil) async throws -> Data {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        var headers = [
            "Content-Type": "application/json;charset=UTF-8",
            "appId": configuration.appId,
            "X-Voyager-Tag": configuration.appId,
            "X-Console-Mark": device,
            "X-Nebula-Release": version,
            "X-Cosmic-Tongue": "en"
        ]
        if let bearer { headers["Authorization"] = "Bearer " + bearer }
        if let renewalHint { headers["X-Orbit-Renewal"] = renewalHint }
        let url = try Self.endpoint(base: configuration.origin, path: path)
        let encrypted = try cipher.encrypt(body).map { String(format: "%02x", $0) }.joined()
        return try await send(url, body: Data(encrypted.utf8), headers: headers, cipher: cipher, success: [0])
    }

    func party(_ path: String, body: Data, runtime: Runtime, token: String? = nil) async throws -> Data {
        guard path.hasPrefix("/sapi/") else { throw Fault.invalidBody }
        var headers = [
            "Content-Type": "text/plain;charset=UTF-8",
            "appid": configuration.appId,
            "deviceNo": device,
            "appVersion": "1.0"
        ]
        if let token { headers["auth_token"] = token }
        let url = try Self.endpoint(base: runtime.partyOrigin, path: path, replacePath: true)
        let encrypted = try runtime.partyCipher.encrypt(body).base64EncodedData()
        return try await send(url, body: encrypted, headers: headers, cipher: runtime.partyCipher, success: [0, 200])
    }

    func normalizedMedia(_ data: Data, runtime: Runtime?) throws -> Data {
        guard let directory = runtime?.media else { return data }
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try Self.json(directory.rewrite(object))
    }

    func heartbeatURL(token: String, runtime: Runtime) throws -> URL {
        guard let socket = runtime.socket, let key = runtime.socketKey,
              var parts = URLComponents(url: socket, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "wss", !(parts.host?.isEmpty ?? true),
              parts.user == nil, parts.password == nil, parts.fragment == nil else { throw Fault.configuration }
        let body = try Self.json(["appToken": token])
        let encrypted = try AES(key: key, iv: nil).encrypt(body)
        let query = (parts.queryItems ?? []).filter { $0.name != "ciphertext" }
        parts.queryItems = query + [URLQueryItem(name: "ciphertext",
                                               value: encrypted.map { String(format: "%02x", $0) }.joined())]
        guard let result = parts.url else { throw Fault.configuration }
        return result
    }

    static func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any] else { throw Fault.response }
        return object
    }

    static func userID(_ value: Any?) -> Int64? {
        if let string = value as? String { return Int64(string) }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return Int64(number.stringValue)
        }
        return nil
    }

    private static func isHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && !(url.host?.isEmpty ?? true) &&
            url.user == nil && url.password == nil && url.fragment == nil
    }

    private static func endpoint(base: URL, path: String, replacePath: Bool = false) throws -> URL {
        guard path.range(of: #"^/[-_A-Za-z0-9]+(?:/[-_A-Za-z0-9]+)*$"#, options: .regularExpression) != nil,
              var uri = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw Fault.invalidBody }
        let basePath = uri.percentEncodedPath
        let prefix = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
        uri.percentEncodedPath = (replacePath ? "" : prefix) + path
        guard let url = uri.url else { throw Fault.configuration }
        return url
    }

    private func send(_ url: URL, body: Data, headers: [String: String], cipher: AES, success: Set<Int>) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.setValue("application/json, text/plain", forHTTPHeaderField: "Accept")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let response: (Data, URLResponse)
        do {
            response = try await network.data(for: request)
        } catch {
            throw Fault.network
        }
        guard let http = response.1 as? HTTPURLResponse else { throw Fault.response }
        guard (200...299).contains(http.statusCode) else { throw Fault.rejected(http.statusCode) }
        let envelope = try Self.object(response.0)
        guard let status = Self.userID(envelope["code"]), let code = Int(exactly: status) else { throw Fault.response }
        guard success.contains(code) else { throw Fault.rejected(code) }
        let result = envelope["result"] ?? NSNull()
        if let encrypted = result as? String, !encrypted.isEmpty {
            let plaintext = try cipher.decryptHex(encrypted)
            guard (try? JSONSerialization.jsonObject(with: plaintext, options: [.fragmentsAllowed])) != nil else {
                throw Fault.response
            }
            return plaintext
        }
        return try Self.json(result)
    }
}

/// Never follow server redirects with encrypted bodies or private identity headers.
private final class DirectConnection: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
