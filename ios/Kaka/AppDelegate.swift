import Combine
import UIKit
import UserNotifications

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    private var restoredWindows: [ObjectIdentifier: UIWindow] = [:]

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        let notifications = NotificationCenter.default
        notifications.addObserver(self, selector: #selector(restoreWindowIfNeeded(_:)),
                                  name: UIScene.willEnterForegroundNotification, object: nil)
        notifications.addObserver(self, selector: #selector(releaseRestoredWindow(_:)),
                                  name: UIScene.didDisconnectNotification, object: nil)
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        KakaPushNotifications.shared.registered(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        KakaPushNotifications.shared.registrationFailed()
    }

    @objc private func restoreWindowIfNeeded(_ notification: Notification) {
        // UIKit can restore a session saved with the former SwiftUI scene delegate.
        guard let scene = notification.object as? UIWindowScene,
              scene.session.role == .windowApplication,
              !(scene.delegate is SceneDelegate) else { return }

        let identifier = ObjectIdentifier(scene)
        guard restoredWindows[identifier] == nil else { return }

        let window = SceneDelegate.makeWindow(for: scene)
        restoredWindows[identifier] = window
        window.makeKeyAndVisible()
    }

    @objc private func releaseRestoredWindow(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene else { return }
        restoredWindows[ObjectIdentifier(scene)] = nil
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard let route = KakaPushNotifications.Tap(response) else {
            completionHandler()
            return
        }
        Task { @MainActor in
            KakaPushNotifications.shared.open(route)
            completionHandler()
        }
    }
}

@MainActor
final class KakaPushNotifications: ObservableObject {
    static let shared = KakaPushNotifications()

    struct Tap: Sendable {
        enum Destination: Sendable {
            case calls
            case room(id: Int64, voice: Bool)
            case host(Int64)
        }

        let id: String
        let appID: String?
        let recipient: Int64?
        let destination: Destination
        let receivedAt = Date()

        init?(_ response: UNNotificationResponse) {
            let request = response.notification.request
            guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
                  request.trigger is UNPushNotificationTrigger, (1...256).contains(request.identifier.utf8.count) else { return nil }
            id = request.identifier
            let payload = request.content.userInfo
            if let app = payload["appId"] {
                guard let app = app as? String, (1...128).contains(app.utf8.count) else { return nil }
                appID = app
            } else {
                appID = nil
            }
            if let user = payload["recipientUserId"] {
                guard let user = KakaRemoteClient.userID(user), user > 0 else { return nil }
                recipient = user
            } else {
                recipient = nil
            }
            switch payload["route"] as? String {
            case "calls": destination = .calls
            case "live", "party":
                guard let room = KakaRemoteClient.userID(payload["roomId"]), room > 0 else { return nil }
                destination = .room(id: room, voice: payload["route"] as? String == "party")
            case "profile":
                guard let user = KakaRemoteClient.userID(payload["userId"]), user > 0 else { return nil }
                destination = .host(user)
            default: return nil
            }
        }
    }

    @Published private(set) var pendingTap: Tap?
    @Published private(set) var permission: UNAuthorizationStatus = .notDetermined
    @Published private(set) var registrationIssue = false

    private var session: UUID?
    private var token: Data?
    private var requestedRegistration = false
    private var binding: Task<Void, Never>?
    private var handledTapIDs: [String] = []

    static var messagingCertificate: String? {
        let value = (Bundle.main.object(forInfoDictionaryKey: "NIMPushCertificate") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (1...128).contains(value.utf8.count) && !value.hasPrefix("$(") ? value : nil
    }

    var settingsTitle: String {
        permission == .notDetermined ? "Enable push notifications" : "Notification settings"
    }

    func activate(_ session: UUID) async {
        guard (try? await KakaAccountStore.shared.remoteUserID(session: session)) != nil,
              !Task.isCancelled else { return }
        if self.session != session {
            binding?.cancel()
            self.session = session
            requestedRegistration = false
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard !Task.isCancelled, self.session == session else { return }
        permission = settings.authorizationStatus
        if permitsRegistration {
            registerIfNeeded()
            if let token { bind(token, session: session) }
        } else {
            requestedRegistration = false
            binding?.cancel()
            try? await KakaAccountStore.shared.setPushToken(nil, session: session)
        }
    }

    func openSettings(session: UUID) async {
        guard self.session == session else { return }
        if permission == .notDetermined {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            if self.session == session { await activate(session) }
        } else if let url = URL(string: UIApplication.openSettingsURLString) {
            await UIApplication.shared.open(url)
        }
    }

    func end(_ session: UUID) {
        guard self.session == session else { return }
        self.session = nil
        pendingTap = nil
        binding?.cancel()
        binding = nil
    }

    func open(_ tap: Tap) {
        guard !handledTapIDs.contains(tap.id) else { return }
        handledTapIDs.append(tap.id)
        if handledTapIDs.count > 32 { handledTapIDs.removeFirst() }
        pendingTap = tap
    }

    func consume(_ tap: Tap) {
        if pendingTap?.id == tap.id { pendingTap = nil }
    }

    func registered(_ data: Data) {
        guard !data.isEmpty, data.count <= 256 else { return }
        token = data
        registrationIssue = false
        if let session, permitsRegistration { bind(data, session: session) }
    }

    func registrationFailed() {
        requestedRegistration = false
        registrationIssue = true
    }

    private var permitsRegistration: Bool {
        [.authorized, .provisional, .ephemeral].contains(permission)
    }

    private func registerIfNeeded() {
        guard !requestedRegistration else { return }
        requestedRegistration = true
        UIApplication.shared.registerForRemoteNotifications()
    }

    private func bind(_ data: Data, session: UUID) {
        binding?.cancel()
        binding = Task {
            do {
                try Task.checkCancellation()
                try await KakaAccountStore.shared.setPushToken(data, session: session)
                guard !Task.isCancelled, self.session == session, permitsRegistration else { return }
                if Self.messagingCertificate != nil { try await KakaRoomChat.updatePushToken(data, session: session) }
            } catch { }
        }
    }
}
