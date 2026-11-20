import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    private var restoredWindows: [ObjectIdentifier: UIWindow] = [:]

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let notifications = NotificationCenter.default
        notifications.addObserver(self, selector: #selector(restoreWindowIfNeeded(_:)),
                                  name: UIScene.willEnterForegroundNotification, object: nil)
        notifications.addObserver(self, selector: #selector(releaseRestoredWindow(_:)),
                                  name: UIScene.didDisconnectNotification, object: nil)
        return true
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
