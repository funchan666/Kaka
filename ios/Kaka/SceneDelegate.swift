import Combine
import SwiftUI
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = Self.makeWindow(for: windowScene)
        self.window = window
        window.makeKeyAndVisible()
        if let response = connectionOptions.notificationResponse, let tap = KakaPushNotifications.Tap(response) {
            KakaPushNotifications.shared.open(tap)
        }
    }

    static func makeWindow(for scene: UIWindowScene) -> UIWindow {
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: KakaHostedScene(scene: scene))
        window.backgroundColor = UIColor(KakaTheme.base)
        window.overrideUserInterfaceStyle = .dark
        return window
    }
}

@MainActor
private struct KakaHostedScene: View {
    private weak var scene: UIWindowScene?
    @StateObject private var store = KakaNativeStore()
    @State private var phase: ScenePhase = .inactive

    init(scene: UIWindowScene) {
        self.scene = scene
    }

    var body: some View {
        KakaNativeApp(store: store)
            .environment(\.scenePhase, phase)
            .onAppear {
                switch scene?.activationState {
                case .foregroundActive: phase = .active
                case .background: phase = .background
                default: phase = .inactive
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIScene.willEnterForegroundNotification)) {
                updatePhase(.inactive, from: $0)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) {
                updatePhase(.active, from: $0)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIScene.willDeactivateNotification)) {
                updatePhase(.inactive, from: $0)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIScene.didEnterBackgroundNotification)) {
                updatePhase(.background, from: $0)
            }
    }

    private func updatePhase(_ phase: ScenePhase, from notification: Notification) {
        guard let scene, (notification.object as? UIWindowScene) === scene else { return }
        self.phase = phase
    }
}
