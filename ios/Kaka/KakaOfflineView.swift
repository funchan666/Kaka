import QuartzCore
import UIKit
import WebKit

@objc(KakaOfflineView)
public final class KakaOfflineView: UIView, WKNavigationDelegate {
    static let startupBackground = UIColor(red: 23.0 / 255, green: 21.0 / 255, blue: 51.0 / 255, alpha: 1)
    private static let archiveQueue = DispatchQueue(label: "com.kakastudio.kaka.content")
    private static let bridgeName = "kakaStudio"
    private static let startupAnimationKey = "startupSweep"
    private let overlay = UIView()
    private let startupIcon = UIImageView(image: UIImage(named: "KakaBrand"))
    private let startupTrack = UIView()
    private let startupHighlight = UIView()
    private let recoveryStack = UIStackView()
    private let message = UILabel()
    private let retry = UIButton(type: .custom)
    private let liveMedia = KakaRealtimeMedia()
    private lazy var roomChat = KakaRoomChat(voiceRoom: { [weak self] session, roomID in
        self?.liveMedia.chatroomID(session: session, serverID: roomID)
    })
    private var webView: WKWebView?
    private var welcomeGlass: UIVisualEffectView?
    private var tabDock: KakaTabDock?
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
        NotificationCenter.default.addObserver(self, selector: #selector(sceneDidEnterBackground(_:)),
                                               name: UIScene.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sceneDidActivate(_:)),
                                               name: UIScene.didActivateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateStartupSweep),
                                               name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
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
        updateStartupSweep()
        guard window != nil else {
            stopMedia()
            return
        }
        if launched {
            publishGeometry(force: true)
            return
        }
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
            "welcomeGlass": supportsGlass, "dockGlass": supportsGlass,
            "regions": regions,
        ]
    }

    private func publishGeometry(force: Bool = false) {
        guard ready, let webView, bounds.width > 0, bounds.height > 0 else { return }
        let snapshot = geometry()
        guard force || !NSDictionary(dictionary: snapshot).isEqual(to: lastGeometry) else { return }
        lastGeometry = snapshot
        welcomeGlass?.isHidden = true
        tabDock?.isHidden = true
        liveMedia.setVideoFrame(nil)
        webView.callAsyncJavaScript(
            "window.dispatchEvent(new CustomEvent('kaka:geometry', { detail: geometry }));",
            arguments: ["geometry": snapshot], in: nil, in: .page, completionHandler: nil
        )
    }

    @objc private func transparencyChanged() {
        publishGeometry()
    }

    private var supportsGlass: Bool {
        if #available(iOS 26.0, *) { return !UIAccessibility.isReduceTransparencyEnabled }
        return false
    }

    private func surfaceFrame(_ payload: Any?, minimum: CGSize) -> CGRect? {
        guard let layout = payload as? [String: Double], layout.count == 6,
              layout.values.allSatisfy(\.isFinite),
              let x = layout["x"], let y = layout["y"],
              let width = layout["width"], width >= Double(minimum.width),
              let height = layout["height"], height >= Double(minimum.height),
              let viewportWidth = layout["viewportWidth"], abs(viewportWidth - Double(bounds.width)) <= 1,
              let viewportHeight = layout["viewportHeight"], abs(viewportHeight - Double(bounds.height)) <= 1 else {
            return nil
        }
        let frame = CGRect(x: x, y: y, width: width, height: height)
        let positioned = frame.offsetBy(dx: bounds.minX, dy: bounds.minY)
        guard bounds.inset(by: safeAreaInsets).insetBy(dx: -1, dy: -1).contains(positioned),
              !regions.contains(where: { region in
                  guard let x = region["x"], let y = region["y"],
                        let width = region["width"], let height = region["height"] else { return false }
                  return frame.intersects(CGRect(x: x, y: y, width: width, height: height))
              }) else { return nil }
        return positioned
    }

    private func positionWelcomeGlass(_ payload: Any?) -> Bool {
        welcomeGlass?.isHidden = true
        guard #available(iOS 26.0, *), supportsGlass,
              let frame = surfaceFrame(payload, minimum: CGSize(width: 44, height: 44)) else {
            return false
        }
        let glass = welcomeGlass ?? makeWelcomeGlass()
        glass.frame = frame
        glass.isHidden = false
        return true
    }

    private func positionTabDock(_ payload: Any?, selection: Any?) -> Bool {
        guard #available(iOS 26.0, *), supportsGlass, window?.windowScene?.activationState == .foregroundActive,
              let key = selection as? String, let tab = KakaTabDock.Tab(rawValue: key),
              let frame = surfaceFrame(payload, minimum: KakaTabDock.minimumSize),
              frame.width <= 280, frame.height <= 56 else {
            tabDock?.isHidden = true
            return false
        }

        let dock: KakaTabDock
        if let tabDock {
            dock = tabDock
        } else {
            dock = KakaTabDock { [weak self] tab in self?.openDockTab(tab) }
            dock.isHidden = true
            insertSubview(dock, belowSubview: overlay)
            tabDock = dock
        }
        dock.show(at: frame, selecting: tab)
        return true
    }

    private func openDockTab(_ tab: KakaTabDock.Tab) {
        guard tabDock?.isHidden == false, ready, let webView else { return }
        webView.callAsyncJavaScript(
            "window.dispatchEvent(new CustomEvent('kaka:dock-select', { detail: tab }));",
            arguments: ["tab": tab.rawValue], in: nil, in: .page, completionHandler: nil
        )
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
        let ink = Self.startupBackground
        backgroundColor = ink
        overlay.backgroundColor = ink

        startupIcon.contentMode = .scaleAspectFit
        startupIcon.isAccessibilityElement = false
        startupIcon.translatesAutoresizingMaskIntoConstraints = false
        startupTrack.backgroundColor = UIColor(red: 62.0 / 255, green: 56.0 / 255, blue: 95.0 / 255, alpha: 1)
        startupTrack.clipsToBounds = true
        startupTrack.isAccessibilityElement = true
        startupTrack.accessibilityLabel = "Loading"
        startupTrack.accessibilityTraits = .staticText
        startupTrack.translatesAutoresizingMaskIntoConstraints = false
        startupHighlight.backgroundColor = UIColor(red: 218.0 / 255, green: 201.0 / 255, blue: 1, alpha: 1)
        startupHighlight.translatesAutoresizingMaskIntoConstraints = false
        startupTrack.addSubview(startupHighlight)

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

        recoveryStack.addArrangedSubview(message)
        recoveryStack.addArrangedSubview(retry)
        recoveryStack.axis = .vertical
        recoveryStack.alignment = .center
        recoveryStack.spacing = 18
        recoveryStack.translatesAutoresizingMaskIntoConstraints = false
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlay)
        overlay.addSubview(startupIcon)
        overlay.addSubview(startupTrack)
        overlay.addSubview(recoveryStack)
        let safe = overlay.safeAreaLayoutGuide
        let iconWidth = startupIcon.widthAnchor.constraint(equalToConstant: 156)
        iconWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            startupIcon.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            startupIcon.centerYAnchor.constraint(equalTo: safe.centerYAnchor),
            iconWidth,
            startupIcon.heightAnchor.constraint(equalTo: startupIcon.widthAnchor),
            startupIcon.widthAnchor.constraint(lessThanOrEqualTo: safe.widthAnchor, multiplier: 0.62),
            startupIcon.heightAnchor.constraint(lessThanOrEqualTo: safe.heightAnchor, multiplier: 0.5),
            startupTrack.topAnchor.constraint(equalTo: startupIcon.bottomAnchor, constant: 20),
            startupTrack.centerXAnchor.constraint(equalTo: startupIcon.centerXAnchor),
            startupTrack.widthAnchor.constraint(equalToConstant: 92),
            startupTrack.heightAnchor.constraint(equalToConstant: 3),
            startupHighlight.centerXAnchor.constraint(equalTo: startupTrack.centerXAnchor),
            startupHighlight.centerYAnchor.constraint(equalTo: startupTrack.centerYAnchor),
            startupHighlight.widthAnchor.constraint(equalToConstant: 32),
            startupHighlight.heightAnchor.constraint(equalToConstant: 3),
            recoveryStack.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            recoveryStack.centerYAnchor.constraint(equalTo: safe.centerYAnchor),
            recoveryStack.leadingAnchor.constraint(greaterThanOrEqualTo: safe.leadingAnchor, constant: 24),
            recoveryStack.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -24),
            recoveryStack.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            retry.widthAnchor.constraint(greaterThanOrEqualToConstant: 132),
            retry.heightAnchor.constraint(greaterThanOrEqualToConstant: 46),
        ])
        showOverlay("Loading…", retrying: false)
    }

    private func showOverlay(_ text: String, retrying: Bool) {
        message.text = text
        recoveryStack.isHidden = !retrying
        startupIcon.isHidden = retrying
        startupTrack.isHidden = retrying
        overlay.isHidden = false
        overlay.accessibilityViewIsModal = true
        updateStartupSweep()
    }

    @objc private func updateStartupSweep() {
        let layer = startupHighlight.layer
        let key = Self.startupAnimationKey
        guard !overlay.isHidden, !startupTrack.isHidden, !UIAccessibility.isReduceMotionEnabled,
              window?.windowScene?.activationState == .foregroundActive else {
            layer.removeAnimation(forKey: key)
            return
        }
        guard layer.animation(forKey: key) == nil else { return }
        let sweep = CABasicAnimation(keyPath: "transform.translation.x")
        sweep.fromValue = -30
        sweep.toValue = 30
        sweep.duration = 0.78
        sweep.timeOffset = 0.39
        sweep.autoreverses = true
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(sweep, forKey: key)
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
        liveMedia.videoView.isUserInteractionEnabled = false
        liveMedia.videoView.accessibilityElementsHidden = true
        insertSubview(liveMedia.videoView, aboveSubview: browser)
        if browser.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) == nil {
            showFailure("Couldn’t load the app content.")
        }
    }

    private func discardWebView() {
        stopMedia()
        liveMedia.videoView.removeFromSuperview()
        watchdog?.cancel()
        watchdog = nil
        ready = false
        entryURL = nil
        lastGeometry = [:]
        welcomeGlass?.removeFromSuperview()
        welcomeGlass = nil
        tabDock?.removeFromSuperview()
        tabDock = nil
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
        guard let scene = notification.object as? UIScene, scene === window?.windowScene else { return }
        startupHighlight.layer.removeAnimation(forKey: Self.startupAnimationKey)
        tabDock?.isHidden = true
    }

    @objc private func sceneDidEnterBackground(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === window?.windowScene else { return }
        stopMedia()
        guard ready, let webView else { return }
        webView.evaluateJavaScript("window.dispatchEvent(new Event('kaka:pause'));", completionHandler: nil)
    }

    @objc private func sceneDidActivate(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === window?.windowScene else { return }
        updateStartupSweep()
        publishGeometry(force: true)
    }

    private func stopMedia() {
        liveMedia.setVideoFrame(nil)
        roomChat.close()
        Task { [liveMedia] in await liveMedia.leave() }
    }

    private func mediaCommand(_ operation: String, input: [String: Any], session: UUID) async throws {
        if operation == "leaveRoomMedia", input.isEmpty {
            _ = try await KakaAccountStore.shared.remoteUserID(session: session)
            await liveMedia.leave()
            return
        }
        guard operation == "joinRoomMedia", let kind = input["kind"] as? String,
              ["live", "voice"].contains(kind), let roomID = input["roomID"] as? Int64, roomID > 0,
              Set(input.keys).isSubset(of: ["kind", "roomID", "password"]),
              input["password"] == nil || ((input["password"] as? String)?.utf8.count ?? Int.max) <= 96,
              window?.windowScene?.activationState == .foregroundActive,
              webView?.url?.fragment == (kind == "live" ? "room/\(roomID)" : "voice/party-\(roomID)") else {
            throw KakaAccountStore.Failure.invalidInput
        }
        try await liveMedia.join(kind: kind, roomID: roomID, password: input["password"] as? String, session: session)
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
                updateStartupSweep()
            }
            reply(["id": id, "value": snapshot], nil)
            return
        }
        if ready, command == "welcome.glass", Set(body.keys) == ["version", "id", "command", "frame"] {
            reply(["id": id, "value": positionWelcomeGlass(body["frame"])], nil)
            return
        }
        if ready, command == "dock.glass", Set(body.keys) == ["version", "id", "command", "frame", "tab"] {
            reply(["id": id, "value": positionTabDock(body["frame"], selection: body["tab"])], nil)
            return
        }
        if ready, command == "media.frame", Set(body.keys) == ["version", "id", "command", "frame"] {
            let frame = webView?.url?.fragment?.hasPrefix("room/") == true &&
                window?.windowScene?.activationState == .foregroundActive
                ? surfaceFrame(body["frame"], minimum: CGSize(width: 60, height: 44)) : nil
            liveMedia.setVideoFrame(frame)
            reply(["id": id, "value": frame != nil], nil)
            return
        }
        if ready, command == "service.request", Set(body.keys) == ["version", "id", "command", "session", "operation", "input"],
           let session = (body["session"] as? String).flatMap({ UUID(uuidString: $0) }),
           let operation = body["operation"] as? String, operation.utf8.count <= 64,
           let input = body["input"] as? [String: Any] {
            let currentLoad = loadID
            Task { [weak self] in
                do {
                    guard let self, self.loadID == currentLoad else {
                        reply(nil, "bridge-denied")
                        return
                    }
                    let data: Data
                    if operation == "joinRoomMedia" || operation == "leaveRoomMedia" {
                        try await self.mediaCommand(operation, input: input, session: session)
                        data = Data("true".utf8)
                    } else if ["voiceSeat.status", "voiceSeat.take", "voiceSeat.leave", "voiceSeat.microphone"].contains(operation) {
                        let expected: Set<String> = operation == "voiceSeat.microphone" ? ["roomID", "enabled"] : ["roomID"]
                        guard Set(input.keys) == expected, let roomID = input["roomID"] as? Int64, roomID > 0,
                              operation != "voiceSeat.microphone" || input["enabled"] is Bool,
                              self.webView?.url?.fragment == "voice/party-\(roomID)" else {
                            throw KakaAccountStore.Failure.invalidInput
                        }
                        let result = try await self.liveMedia.voiceSeat(operation: operation, roomID: roomID,
                                                                        enabled: input["enabled"] as? Bool, session: session)
                        data = try JSONSerialization.data(withJSONObject: result)
                    } else if operation.hasPrefix("roomChat.") {
                        if operation != "roomChat.close" {
                            guard let kind = input["kind"] as? String, let identifier = input["serverID"] as? String,
                                  ["live", "voice"].contains(kind), Int64(identifier).map({ $0 > 0 }) == true,
                                  self.webView?.url?.fragment == (kind == "live" ? "room/\(identifier)" : "voice/party-\(identifier)") else {
                                throw KakaAccountStore.Failure.invalidInput
                            }
                        }
                        data = try await self.roomChat.perform(operation: operation, input: input, session: session)
                    } else if operation.hasPrefix("directChat.") {
                        guard let userID = input["userID"] as? Int64, userID > 0,
                              operation == "directChat.close" ||
                                self.webView?.url?.fragment?.hasPrefix("creator/\(userID)/") == true else {
                            throw KakaAccountStore.Failure.invalidInput
                        }
                        data = try await self.roomChat.performDirect(operation: operation, input: input, session: session)
                    } else if operation == "profile.avatar", input.isEmpty,
                              self.webView?.url?.fragment == "crate", let presenter = self.window?.rootViewController,
                              presenter.presentedViewController == nil {
                        data = try await KakaAvatarUpload.shared.pick(from: presenter, session: session)
                    } else if ["creator.blocked", "creator.block"].contains(operation) {
                        let expected: Set<String> = operation == "creator.block" ? ["userID", "blocked"] : ["userID"]
                        guard Set(input.keys) == expected, let userID = input["userID"] as? Int64, userID > 0,
                              self.webView?.url?.fragment?.hasPrefix("creator/\(userID)/") == true else {
                            throw KakaAccountStore.Failure.invalidInput
                        }
                        let blocked: Bool
                        if operation == "creator.block" {
                            guard let value = input["blocked"] as? Bool else { throw KakaAccountStore.Failure.invalidInput }
                            try await KakaRoomChat.setBlocked(userID: userID, blocked: value, session: session)
                            blocked = value
                        } else {
                            blocked = try await KakaRoomChat.isBlocked(userID: userID, session: session)
                        }
                        data = Data(String(blocked).utf8)
                    } else {
                        data = try await KakaServiceBridge.perform(operation: operation, input: input, session: session)
                    }
                    guard self.loadID == currentLoad else {
                        reply(nil, "bridge-denied")
                        return
                    }
                    let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
                    reply(["id": id, "value": value], nil)
                } catch let error as KakaAccountStore.Failure {
                    if error == .expired {
                        self?.stopMedia()
                        await KakaRoomChat.signOut(session: session)
                    }
                    reply(nil, error.rawValue)
                } catch let error as KakaRealtimeMedia.Failure {
                    reply(nil, error.rawValue)
                } catch let error as KakaAvatarUpload.Failure {
                    reply(nil, error.rawValue)
                } catch {
                    reply(nil, "service-rejected")
                }
            }
            return
        }
        guard let request = workspaceRequest(command, body: body) else {
            reply(nil, "bridge-denied")
            return
        }
        let currentLoad = loadID
        Task { [weak self] in
            do {
                if case .signOut = request {
                    self?.roomChat.close()
                    await self?.liveMedia.leave()
                }
                let response = try await KakaAccountStore.shared.perform(request)
                guard self?.loadID == currentLoad else {
                    reply(nil, "bridge-denied")
                    return
                }
                reply(["id": id, "value": Self.envelope(response)], nil)
                if case .session(let session?) = response {
                    Task { await KakaCommerce.shared.resume(session: session.token) }
                }
                if case .signOut(let session) = request {
                    Task { await KakaRoomChat.signOut(session: session) }
                }
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

private final class KakaTabDock: UIVisualEffectView {
    enum Tab: String, CaseIterable {
        case stage, voice, notebook, crate

        var title: String {
            switch self {
            case .stage: return "Live Rooms"
            case .voice: return "Voice Rooms"
            case .notebook: return "Verse Lab"
            case .crate: return "Profile"
            }
        }
    }

    private static let padding: CGFloat = 4
    static let minimumSize = CGSize(width: CGFloat(Tab.allCases.count) * 44 + padding * 2,
                                    height: 44 + padding * 2)

    private let highlight = UIView()
    private let buttons: [UIButton]
    private var selectedIndex = 0

    @available(iOS 26.0, *)
    init(onSelect: @escaping (Tab) -> Void) {
        buttons = Tab.allCases.map { tab in
            let button = UIButton(type: .custom)
            let image = UIImage(named: "Dock-\(tab.rawValue)")?.withRenderingMode(.alwaysOriginal)
            button.setImage(image, for: .normal)
            if let layer = button.imageView?.layer {
                layer.shadowColor = UIColor.black.cgColor
                layer.shadowOpacity = 0.55
                layer.shadowOffset = CGSize(width: 0, height: 1)
                layer.shadowRadius = 1.5
            }
            button.accessibilityLabel = tab.title
            button.addAction(UIAction { _ in onSelect(tab) }, for: .touchUpInside)
            return button
        }
        let glass = UIGlassEffect(style: .clear)
        glass.isInteractive = true
        glass.tintColor = UIColor(red: 0.08, green: 0.07, blue: 0.14, alpha: 0.18)
        super.init(effect: glass)
        cornerConfiguration = .capsule()
        overrideUserInterfaceStyle = .dark

        highlight.backgroundColor = UIColor(red: 0.94, green: 0.92, blue: 1, alpha: 0.23)
        highlight.isUserInteractionEnabled = false
        contentView.addSubview(highlight)
        buttons.forEach { contentView.addSubview($0) }
        accessibilityContainerType = .semanticGroup
        accessibilityLabel = "Main navigation"
        accessibilityElements = buttons
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("KakaTabDock requires navigation actions.")
    }

    func show(at frame: CGRect, selecting tab: Tab) {
        guard let index = Tab.allCases.firstIndex(of: tab) else { return }
        let animates = !isHidden && self.frame == frame && selectedIndex != index && !UIAccessibility.isReduceMotionEnabled
        self.frame = frame
        selectedIndex = index
        for (slot, button) in buttons.enumerated() {
            let selected = slot == index
            button.isSelected = selected
            button.accessibilityTraits = selected ? [.button, .selected] : .button
            button.imageView?.alpha = selected ? 1 : 0.84
        }
        if animates {
            UIView.animate(withDuration: 0.24, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]) {
                self.positionHighlight()
            }
        } else {
            highlight.layer.removeAllAnimations()
            positionHighlight()
        }
        isHidden = false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width >= Self.minimumSize.width, bounds.height >= Self.minimumSize.height else { return }
        for (index, button) in buttons.enumerated() {
            button.frame = slotFrame(index)
        }
        positionHighlight()
    }

    private func slotFrame(_ index: Int) -> CGRect {
        let inner = bounds.insetBy(dx: Self.padding, dy: Self.padding)
        let width = inner.width / CGFloat(buttons.count)
        return CGRect(x: inner.minX + CGFloat(index) * width, y: inner.minY, width: width, height: inner.height)
    }

    private func positionHighlight() {
        let frame = slotFrame(selectedIndex).insetBy(dx: 1, dy: 1)
        highlight.frame = frame
        highlight.layer.cornerRadius = frame.height / 2
    }
}

private enum KakaPolicyDocument: String, CaseIterable {
    case terms, privacy

    func placeholder(in entry: URL) -> URL {
        entry.deletingLastPathComponent().appendingPathComponent("policies", isDirectory: true)
            .appendingPathComponent(rawValue + ".html")
    }

    @MainActor var liveURL: URL? {
        let key = self == .terms ? "KakaTermsURL" : "KakaPrivacyURL"
        let candidates = [Bundle.main.object(forInfoDictionaryKey: key) as? String, KakaServiceBridge.configuration[rawValue + "URL"]]
        for case let value? in candidates {
            if let components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
               components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
               components.user == nil, components.password == nil, let url = components.url {
                return url
            }
        }
        return nil
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
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = !source.isFileURL
        configuration.defaultWebpagePreferences = preferences
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
