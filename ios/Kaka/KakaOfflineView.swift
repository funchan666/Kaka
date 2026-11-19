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
    private var welcomeGlass: UIVisualEffectView?
    private var entryURL: URL?
    private var loadID = UUID()
    private var ready = false
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
            "welcomeGlass": supportsWelcomeGlass,
            "regions": regions,
        ]
    }

    private func publishGeometry() {
        guard ready, let webView, bounds.width > 0, bounds.height > 0 else { return }
        let snapshot = geometry()
        guard !NSDictionary(dictionary: snapshot).isEqual(to: lastGeometry) else { return }
        lastGeometry = snapshot
        welcomeGlass?.isHidden = true
        webView.callAsyncJavaScript(
            "window.dispatchEvent(new CustomEvent('kaka:geometry', { detail: geometry }));",
            arguments: ["geometry": snapshot], in: nil, in: .page, completionHandler: nil
        )
    }

    @objc private func transparencyChanged() {
        publishGeometry()
    }

    private var supportsWelcomeGlass: Bool {
        if #available(iOS 26.0, *) { return !UIAccessibility.isReduceTransparencyEnabled }
        return false
    }

    private func positionWelcomeGlass(_ payload: Any?) -> Bool {
        welcomeGlass?.isHidden = true
        guard #available(iOS 26.0, *), supportsWelcomeGlass,
              let layout = payload as? [String: Double], layout.count == 6,
              layout.values.allSatisfy(\.isFinite),
              let x = layout["x"], let y = layout["y"],
              let width = layout["width"], width >= 44,
              let height = layout["height"], height >= 44,
              let viewportWidth = layout["viewportWidth"], abs(viewportWidth - Double(bounds.width)) <= 1,
              let viewportHeight = layout["viewportHeight"], abs(viewportHeight - Double(bounds.height)) <= 1 else {
            return false
        }
        let frame = CGRect(x: x, y: y, width: width, height: height)
        let positioned = frame.offsetBy(dx: bounds.minX, dy: bounds.minY)
        guard bounds.inset(by: safeAreaInsets).insetBy(dx: -1, dy: -1).contains(positioned),
              !regions.contains(where: { region in
                  guard let x = region["x"], let y = region["y"],
                        let width = region["width"], let height = region["height"] else { return false }
                  return frame.intersects(CGRect(x: x, y: y, width: width, height: height))
              }) else { return false }

        let glass = welcomeGlass ?? makeWelcomeGlass()
        glass.frame = positioned
        glass.isHidden = false
        return true
    }

    @available(iOS 26.0, *)
    private func makeWelcomeGlass() -> UIVisualEffectView {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        effect.tintColor = UIColor(red: 0.68, green: 0.63, blue: 0.96, alpha: 0.26)
        let glass = UIVisualEffectView(effect: effect)
        glass.cornerConfiguration = .capsule()
        glass.overrideUserInterfaceStyle = .dark

        let button = UIButton(type: .custom)
        button.setTitle("Create account", for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.setTitleColor(UIColor.white.withAlphaComponent(0.8), for: .highlighted)
        button.titleLabel?.font = UIFontMetrics(forTextStyle: .callout)
            .scaledFont(for: .systemFont(ofSize: 16, weight: .semibold))
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(openWelcomeRegistration), for: .touchUpInside)
        let content = glass.contentView
        content.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            button.topAnchor.constraint(equalTo: content.topAnchor),
            button.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        insertSubview(glass, belowSubview: overlay)
        welcomeGlass = glass
        return glass
    }

    @objc private func openWelcomeRegistration() {
        guard welcomeGlass?.isHidden == false, let webView else { return }
        webView.evaluateJavaScript(
            """
            if (document.querySelector('#auth[data-page="welcome"]:not([hidden])')
                && (location.hash === '' || location.hash === '#welcome')) {
                document.getElementById('welcome-join')?.click();
            }
            """, completionHandler: nil
        )
    }

    private func configureOverlay() {
        let ink = UIColor(red: 0.035, green: 0.039, blue: 0.09, alpha: 1)
        backgroundColor = ink
        overlay.backgroundColor = ink

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

        let stack = UIStackView(arrangedSubviews: [message, retry])
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
            retry.widthAnchor.constraint(greaterThanOrEqualToConstant: 132),
            retry.heightAnchor.constraint(greaterThanOrEqualToConstant: 46),
        ])
        showOverlay("Loading…", retrying: false)
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
        showOverlay("Loading…", retrying: false)
        let timeout = DispatchWorkItem { [weak self] in
            self?.showFailure("Loading took too long.")
        }
        watchdog = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)

        Self.archiveQueue.async { [weak self] in
            let result = Result { try KakaArchive.prepare() }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadID == currentLoad else { return }
                switch result {
                case .success(let url): self.open(url)
                case .failure: self.showFailure("Couldn’t load the app content.")
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
            showFailure("Couldn’t load the app content.")
        }
    }

    private func discardWebView() {
        watchdog?.cancel()
        watchdog = nil
        ready = false
        entryURL = nil
        lastGeometry = [:]
        welcomeGlass?.removeFromSuperview()
        welcomeGlass = nil
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
        guard webView === self.webView, action.targetFrame?.isMainFrame == true else {
            decisionHandler(.cancel)
            return
        }
        if ready, action.navigationType == .linkActivated,
           action.sourceFrame.isMainFrame, isEntry(action.sourceFrame.request.url),
           let entryURL, let url = action.request.url, url.isFileURL, url.query == nil,
           let document = KakaPolicyDocument.allCases.first(where: { $0.placeholder(in: entryURL).path == url.path }) {
            decisionHandler(.cancel)
            openPolicy(document.liveURL ?? document.placeholder(in: entryURL))
            return
        }
        let allowed = isEntry(action.request.url) && action.navigationType != .reload
        decisionHandler(allowed ? .allow : .cancel)
    }

    private func openPolicy(_ source: URL) {
        guard var presenter = window?.rootViewController else { return }
        while let presented = presenter.presentedViewController {
            guard !(presented is KakaPolicyReader), !presented.isBeingDismissed else { return }
            presenter = presented
        }
        endEditing(true)
        let reader = KakaPolicyReader(source: source)
        reader.modalPresentationStyle = .pageSheet
        presenter.present(reader, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        let failure = error as NSError
        guard failure.domain != NSURLErrorDomain || failure.code != NSURLErrorCancelled else { return }
        showFailure("Couldn’t open this page.")
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        showFailure("This page stopped responding.")
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
        if ready, command == "welcome.glass", Set(body.keys) == ["version", "id", "command", "frame"] {
            reply(["id": id, "value": positionWelcomeGlass(body["frame"])], nil)
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
            return .session
        case "auth.register" where ready && fields == ["name", "email", "password", "acceptedPolicies"]:
            guard body["acceptedPolicies"] as? Bool == true,
                  let name = body["name"] as? String, name.utf8.count <= 96,
                  let email = body["email"] as? String, email.utf8.count <= 254,
                  let password = body["password"] as? String, password.utf8.count <= 512 else { return nil }
            return .register(name: name, email: email, password: password)
        case "auth.login" where ready && fields == ["email", "password", "acceptedPolicies"]:
            guard body["acceptedPolicies"] as? Bool == true,
                  let email = body["email"] as? String, email.utf8.count <= 254,
                  let password = body["password"] as? String, password.utf8.count <= 512 else { return nil }
            return .login(email: email, password: password)
        case "auth.signOut" where ready && fields == ["session"]:
            return token.map { .signOut($0) }
        case "auth.delete" where ready && fields == ["session"]:
            return token.map { .delete($0) }
        case "records.read" where fields == ["session"]:
            return token.map { .read($0) }
        case "records.write" where ready && fields == ["session", "revision", "recordJSON"]:
            guard let token,
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
                    "name": session.name,
                    "email": session.email]
        case .record(let snapshot):
            return ["revision": snapshot.revision, "recordJSON": (snapshot.recordJSON as Any?) ?? NSNull()]
        }
    }
}

private enum KakaPolicyDocument: String, CaseIterable {
    case terms, privacy

    func placeholder(in entry: URL) -> URL {
        entry.deletingLastPathComponent().appendingPathComponent("policies", isDirectory: true)
            .appendingPathComponent(rawValue + ".html")
    }

    var liveURL: URL? {
        let key = self == .terms ? "KakaTermsURL" : "KakaPrivacyURL"
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              let components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        return components.url
    }
}

private final class KakaPolicyReader: UIViewController, WKNavigationDelegate {
    private let source: URL
    private let browser: WKWebView
    private let failure = UIStackView()

    init(source: URL) {
        self.source = source
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = !source.isFileURL
        browser = WKWebView(frame: .zero, configuration: configuration)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("KakaPolicyReader requires a document URL.")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let ink = UIColor(red: 0.09, green: 0.094, blue: 0.165, alpha: 1)
        view.backgroundColor = ink
        browser.isOpaque = false
        browser.backgroundColor = ink
        browser.navigationDelegate = self
        browser.scrollView.contentInsetAdjustmentBehavior = .never

        let done = UIButton(type: .custom)
        done.setTitle("Done", for: .normal)
        done.addTarget(self, action: #selector(close), for: .touchUpInside)
        let retry = UIButton(type: .custom)
        retry.setTitle("Try again", for: .normal)
        retry.addTarget(self, action: #selector(loadDocument), for: .touchUpInside)
        for button in [done, retry] {
            button.setTitleColor(UIColor(red: 0.91, green: 0.87, blue: 1, alpha: 1), for: .normal)
            button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
            button.titleLabel?.adjustsFontForContentSizeCategory = true
        }
        let message = UILabel()
        message.text = "Couldn’t open this document."
        message.font = .preferredFont(forTextStyle: .body)
        message.adjustsFontForContentSizeCategory = true
        message.textColor = .white
        message.numberOfLines = 0
        message.textAlignment = .center
        failure.axis = .vertical
        failure.addArrangedSubview(message)
        failure.addArrangedSubview(retry)

        for child in [done, browser, failure] as [UIView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            done.topAnchor.constraint(equalTo: safe.topAnchor, constant: 6),
            done.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -15),
            done.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
            done.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            browser.topAnchor.constraint(equalTo: done.bottomAnchor, constant: 4),
            browser.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            browser.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            browser.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            failure.centerXAnchor.constraint(equalTo: browser.centerXAnchor),
            failure.centerYAnchor.constraint(equalTo: browser.centerYAnchor),
            failure.widthAnchor.constraint(lessThanOrEqualTo: safe.widthAnchor, constant: -32),
            retry.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        loadDocument()
    }

    @objc private func loadDocument() {
        browser.isHidden = false
        failure.isHidden = true
        let load = source.isFileURL
            ? browser.loadFileURL(source, allowingReadAccessTo: source.deletingLastPathComponent())
            : browser.load(URLRequest(url: source))
        if load == nil { showFailure() }
    }

    @objc private func close() {
        dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func showFailure() {
        browser.isHidden = true
        failure.isHidden = false
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let target = action.targetFrame, let url = action.request.url else {
            decisionHandler(.cancel)
            return
        }
        let allowed: Bool
        if source.isFileURL {
            allowed = target.isMainFrame && url.isFileURL && url.query == nil
                && url.standardizedFileURL.path == source.standardizedFileURL.path
        } else {
            let sameOrigin = url.host == source.host && (url.port ?? 443) == (source.port ?? 443)
            allowed = url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil
                && (!target.isMainFrame || sameOrigin)
        }
        decisionHandler(allowed ? .allow : .cancel)
        if !allowed && target.isMainFrame && webView.url == nil { showFailure() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let failure = error as NSError
        if failure.domain != NSURLErrorDomain || failure.code != NSURLErrorCancelled { showFailure() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        showFailure()
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
