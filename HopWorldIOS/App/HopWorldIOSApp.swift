import SwiftUI
import UIKit

@main
final class HopWorldIOSApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var promptWindow: UIWindow?
    private var library: IOSLibrary?
    private let keyboardDismiss = BlankAreaKeyboardDismiss()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let theme = IOSTheme(rawValue: UserDefaults.standard.string(forKey: IOSSettings.themeKey) ?? "") ?? .blackGold
        Self.configureNavigationBar(UINavigationBar.appearance(), theme: theme)
        UITableView.appearance().backgroundColor = .clear
        library = IOSLibrary()
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = HopWorldIOSSceneDelegate.self
        return configuration
    }

    fileprivate func attachInterface(to windowScene: UIWindowScene) -> UIWindow {
        let library = self.library ?? IOSLibrary()
        self.library = library
        let content = HomeView()
            .accentColor(Color(red: 1, green: 0.87, blue: 0.62))
            .environmentObject(library)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: content)
        window.makeKeyAndVisible()
        keyboardDismiss.install(on: window)
        let prompt = UIWindow(windowScene: windowScene)
        prompt.frame = windowScene.coordinateSpace.bounds
        prompt.windowLevel = .alert
        prompt.backgroundColor = .clear
        prompt.rootViewController = makeGlobalPromptController(library: library)
        prompt.isHidden = true
        self.promptWindow = prompt
        self.window = window
        return window
    }


    static func configureNavigationBar(_ navigationBar: UINavigationBar, theme: IOSTheme) {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundColor = .clear
        appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        appearance.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        appearance.shadowColor = .clear
        navigationBar.standardAppearance = appearance
        navigationBar.scrollEdgeAppearance = appearance
        navigationBar.compactAppearance = appearance
        navigationBar.tintColor = UIColor(red: 1, green: 0.87, blue: 0.62, alpha: 1)
    }
}

final class HopWorldIOSSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene,
              let app = UIApplication.shared.delegate as? HopWorldIOSApp else { return }
        window = app.attachInterface(to: windowScene)
    }
}

/// 点空白收起键盘。点在输入框上不处理，避免这次点击把焦点一起清掉。
private final class BlankAreaKeyboardDismiss: NSObject, UIGestureRecognizerDelegate {
    func install(on window: UIWindow) {
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismiss))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        window.addGestureRecognizer(tap)
    }

    @objc private func dismiss(_ gesture: UITapGestureRecognizer) {
        gesture.view?.endEditing(true)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view {
            if current is UITextField || current is UITextView { return false }
            view = current.superview
        }
        return true
    }
}
