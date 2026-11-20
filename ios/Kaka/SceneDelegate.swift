import React
import React_RCTAppDelegate
import ReactAppDependencyProvider
import UIKit

final class SceneDelegate: RCTDefaultReactNativeFactoryDelegate, UIWindowSceneDelegate {
    var window: UIWindow?
    private var reactNativeFactory: RCTReactNativeFactory?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        window.backgroundColor = KakaOfflineView.startupBackground
        self.window = window
        dependencyProvider = RCTAppDependencyProvider()
        let factory = RCTReactNativeFactory(delegate: self)
        #if DEBUG
        factory.devMenuConfiguration = RCTDevMenuConfiguration(
            devMenuEnabled: false,
            shakeGestureEnabled: false,
            keyboardShortcutsEnabled: false
        )
        #endif
        reactNativeFactory = factory
        factory.startReactNative(withModuleName: "Kaka", in: window, connectionOptions: connectionOptions)
    }

    override func bundleURL() -> URL? {
        Bundle.main.url(forResource: "main", withExtension: "jsbundle")
    }
}
