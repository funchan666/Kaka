import UIKit
import WebKit

@objc(KakaOfflineView)
public final class KakaOfflineView: UIView, WKNavigationDelegate {
    private static let archiveQueue = DispatchQueue(label: "com.kakastudio.kaka.content")
    private static let bridgeName = "kakaStudio"
    private let overlay = UIView()
    private let message = UILabel()
    private let retry = UIButton(type: .custom)
    private var webView: WKWebView?
    private var entryURL: URL?
    private var loadID = UUID()
    private var ready = false
    private var accountRoutes = false
    private var launched = false
    private var watchdog: DispatchWorkItem?
    private var regions: [[String: Double]] = []
    private var lastGeometry: [String: Any] = [:]

    public override init(frame: CGRect) {
        super.init(frame: frame)
        configureOverlay()
        NotificationCenter.default.addObserver(self, selector: #selector(sceneWillDeactivate(_:)),
                                               name: UIScene.willDeactivateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(transparencyChanged),
                                               name: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
                                               object: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("KakaOfflineView is created by Fabric.")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        watchdog?.cancel()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !launched else { return }
        launched = true
        load()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        webView?.frame = bounds
        publishGeometry()
    }

    public override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        publishGeometry()
    }

    public override func updateConstraints() {
        if #available(iOS 27.1, *) {
            regions = activeRegions()
        }
        super.updateConstraints()
        publishGeometry()
    }

    @available(iOS 27.1, *)
    private func activeRegions() -> [[String: Double]] {
        [UIView.ReservedRegion.Kind.occlusion, .division].flatMap { kind in
            reservedRegions(kind: kind).filter(\.isActive).map { region in
                let frame = region.frame
                return [
                    "x": Double(frame.minX - bounds.minX), "y": Double(frame.minY - bounds.minY),
                    "width": Double(frame.width), "height": Double(frame.height),
                    "division": kind == .division ? 1 : 0,
                ]
            }
        }
    }

    private func geometry() -> [String: Any] {
        let insets = safeAreaInsets
        return [
            "width": Double(bounds.width), "height": Double(bounds.height),
            "top": Double(insets.top), "right": Double(insets.right),
            "bottom": Double(insets.bottom), "left": Double(insets.left),
            "reduceTransparency": UIAccessibility.isReduceTransparencyEnabled,
            "regions": regions,
        ]
    }

    private func publishGeometry() {
        guard ready, let webView, bounds.width > 0, bounds.height > 0 else { return }
        let snapshot = geometry()
        guard !NSDictionary(dictionary: snapshot).isEqual(to: lastGeometry) else { return }
        lastGeometry = snapshot
        webView.callAsyncJavaScript(
            "window.dispatchEvent(new CustomEvent('kaka:geometry', { detail: geometry }));",
            arguments: ["geometry": snapshot], in: nil, in: .page, completionHandler: nil
        )
    }

    @objc private func transparencyChanged() {
        publishGeometry()
    }

    private func configureOverlay() {
        let ink = UIColor(red: 0.035, green: 0.039, blue: 0.09, alpha: 1)
        backgroundColor = ink
        overlay.backgroundColor = ink

        let mark = UIImageView(image: UIImage(named: "LaunchMark"))
        mark.contentMode = .scaleAspectFit
        mark.layer.cornerRadius = 19
        mark.clipsToBounds = true
        mark.isAccessibilityElement = false

        message.numberOfLines = 0
        message.textAlignment = .center
        message.font = .preferredFont(forTextStyle: .body)
        message.adjustsFontForContentSizeCategory = true
        message.textColor = UIColor(red: 0.96, green: 0.95, blue: 1, alpha: 1)

        retry.setTitle("Try again", for: .normal)
        retry.setTitleColor(ink, for: .normal)
        retry.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        retry.titleLabel?.adjustsFontForContentSizeCategory = true
        retry.backgroundColor = UIColor(red: 0.82, green: 0.78, blue: 1, alpha: 1)
        retry.layer.cornerRadius = 14
        retry.addTarget(self, action: #selector(load), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [mark, message, retry])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlay)
        overlay.addSubview(stack)
        let safe = overlay.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: safe.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: safe.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -24),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            mark.widthAnchor.constraint(equalToConstant: 88),
            mark.heightAnchor.constraint(equalToConstant: 88),
            retry.widthAnchor.constraint(greaterThanOrEqualToConstant: 132),
            retry.heightAnchor.constraint(greaterThanOrEqualToConstant: 46),
        ])
        showOverlay("Opening Kaka…", retrying: false)
    }

    private func showOverlay(_ text: String, retrying: Bool) {
        message.text = text
        retry.isHidden = !retrying
        overlay.isHidden = false
        overlay.accessibilityViewIsModal = true
    }

    @objc private func load() {
        discardWebView()
        let currentLoad = UUID()
        loadID = currentLoad
        showOverlay("Opening Kaka…", retrying: false)
        let timeout = DispatchWorkItem { [weak self] in
            self?.showFailure("Kaka took too long to open. Please try again.")
        }
        watchdog = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)

        Self.archiveQueue.async { [weak self] in
            let result = Result { try KakaArchive.prepare() }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadID == currentLoad else { return }
                switch result {
                case .success(let url): self.open(url)
                case .failure: self.showFailure("Kaka’s content couldn’t load. Please try again.")
                }
            }
        }
    }

    private func open(_ url: URL) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.userContentController.addScriptMessageHandler(
            KakaMessageRelay(owner: self), contentWorld: .page, name: Self.bridgeName
        )
        let browser = WKWebView(frame: bounds, configuration: configuration)
        browser.navigationDelegate = self
        browser.allowsBackForwardNavigationGestures = true
        browser.isOpaque = false
        browser.backgroundColor = backgroundColor
        browser.scrollView.contentInsetAdjustmentBehavior = .never
        browser.scrollView.keyboardDismissMode = .interactive
        browser.scrollView.bounces = false
        browser.accessibilityElementsHidden = true
        entryURL = url
        webView = browser
        insertSubview(browser, belowSubview: overlay)
        if browser.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) == nil {
            showFailure("Kaka’s content couldn’t load. Please try again.")
        }
    }

    private func discardWebView() {
        watchdog?.cancel()
        watchdog = nil
        ready = false
        accountRoutes = false
        entryURL = nil
        lastGeometry = [:]
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.bridgeName, contentWorld: .page)
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
    }

    private func showFailure(_ text: String) {
        loadID = UUID()
        discardWebView()
        showOverlay(text, retrying: true)
    }

    private func isEntry(_ url: URL?) -> Bool {
        guard let url, url.isFileURL, url.query == nil,
              let entryURL, url.host == nil || url.host == "" || url.host == "localhost" else { return false }
        return url.standardizedFileURL.path == entryURL.standardizedFileURL.path
    }

    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let allowed = webView === self.webView && action.targetFrame?.isMainFrame == true
            && isEntry(action.request.url) && action.navigationType != .reload
        decisionHandler(allowed ? .allow : .cancel)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        let failure = error as NSError
        guard failure.domain != NSURLErrorDomain || failure.code != NSURLErrorCancelled else { return }
        showFailure("This page couldn’t open. Please try again.")
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        showFailure("This page stopped responding. Reopen Kaka to continue.")
    }

    @objc private func sceneWillDeactivate(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === window?.windowScene,
              ready, let webView else { return }
        webView.evaluateJavaScript("window.dispatchEvent(new Event('kaka:pause'));", completionHandler: nil)
    }

    fileprivate func receive(_ incoming: WKScriptMessage,
                             reply: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard incoming.name == Self.bridgeName, incoming.webView === webView,
              incoming.frameInfo.isMainFrame, isEntry(incoming.frameInfo.request.url),
              let body = incoming.body as? [String: Any],
              body["version"] as? Int == 1,
              let id = body["id"] as? String, UUID(uuidString: id) != nil,
              let command = body["command"] as? String else {
            reply(nil, "bridge-denied")
            return
        }
        if command == "ready", Set(body.keys) == ["version", "id", "command"] {
            let snapshot = geometry()
            if !ready {
                ready = true
                watchdog?.cancel()
                watchdog = nil
                lastGeometry = snapshot
                webView?.accessibilityElementsHidden = false
                overlay.isHidden = true
            }
            reply(["id": id, "value": snapshot], nil)
            return
        }
        guard let request = workspaceRequest(command, body: body) else {
            reply(nil, "bridge-denied")
            return
        }
        let currentLoad = loadID
        Task { [weak self] in
            do {
                let response = try await KakaAccountStore.shared.perform(request)
                guard self?.loadID == currentLoad else {
                    reply(nil, "bridge-denied")
                    return
                }
                reply(["id": id, "value": Self.envelope(response)], nil)
            } catch KakaRecordStore.Failure.writeConflict {
                reply(nil, "write-conflict")
            } catch let error as KakaAccountStore.Failure {
                reply(nil, error.rawValue)
            } catch {
                reply(nil, "storage-error")
            }
        }
    }

    private func workspaceRequest(_ command: String, body: [String: Any]) -> KakaAccountStore.Request? {
        let fields = Set(body.keys).subtracting(["version", "id", "command"])
        let token = (body["session"] as? String).flatMap { UUID(uuidString: $0) }
        switch command {
        case "auth.session" where fields.isEmpty:
            accountRoutes = true
            return .session
        case "auth.register" where ready && fields == ["name", "email", "password"]:
            guard let name = body["name"] as? String, name.utf8.count <= 96,
                  let email = body["email"] as? String, email.utf8.count <= 254,
                  let password = body["password"] as? String, password.utf8.count <= 512 else { return nil }
            return .register(name: name, email: email, password: password)
        case "auth.login" where ready && fields == ["email", "password"]:
            guard let email = body["email"] as? String, email.utf8.count <= 254,
                  let password = body["password"] as? String, password.utf8.count <= 512 else { return nil }
            return .login(email: email, password: password)
        case "auth.guest" where ready && fields.isEmpty:
            return .guest
        case "auth.signOut" where ready && fields == ["session"]:
            return token.map { .signOut($0) }
        case "auth.delete" where ready && fields == ["session"]:
            return token.map { .delete($0) }
        case "records.read" where (fields == ["session"] && token != nil) || (!accountRoutes && fields.isEmpty):
            return .read(token)
        case "records.write" where ready:
            let expected = Set(["revision", "recordJSON"])
            // A verified fallback edition can still access the guest workspace.
            guard (fields == expected.union(["session"]) && token != nil) || (!accountRoutes && fields == expected),
                  let revision = body["revision"] as? Int, revision >= 0,
                  let record = body["recordJSON"] as? String,
                  record.utf8.count <= 512 * 1024 else { return nil }
            return .write(token, revision: revision, record: record)
        default:
            return nil
        }
    }

    private static func envelope(_ response: KakaAccountStore.Response) -> Any {
        switch response {
        case .session(let session):
            guard let session else { return NSNull() }
            return ["token": session.token.uuidString,
                    "name": (session.name as Any?) ?? NSNull(),
                    "email": (session.email as Any?) ?? NSNull()]
        case .record(let snapshot):
            return ["revision": snapshot.revision, "recordJSON": (snapshot.recordJSON as Any?) ?? NSNull()]
        }
    }
}

@MainActor
private final class KakaMessageRelay: NSObject, WKScriptMessageHandlerWithReply {
    weak var owner: KakaOfflineView?

    init(owner: KakaOfflineView) {
        self.owner = owner
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let owner else {
            replyHandler(nil, "bridge-denied")
            return
        }
        owner.receive(message, reply: replyHandler)
    }
}
