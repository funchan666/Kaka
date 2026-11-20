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
    }

    static func makeWindow(for scene: UIWindowScene) -> UIWindow {
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: KakaNativeApp(store: KakaNativeStore()))
        window.backgroundColor = UIColor(KakaTheme.base)
        window.overrideUserInterfaceStyle = .dark
        return window
    }
}
