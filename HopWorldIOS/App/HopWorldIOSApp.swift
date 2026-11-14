import SwiftUI
import UIKit

@main
final class HopWorldIOSApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var library: IOSLibrary?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let theme = IOSTheme(rawValue: UserDefaults.standard.string(forKey: IOSSettings.themeKey) ?? "") ?? .blackGold
        Self.configureNavigationBar(UINavigationBar.appearance(), theme: theme)
        UITableView.appearance().backgroundColor = .clear

        let library = IOSLibrary()
        self.library = library
        let content = HomeView()
            .accentColor(Color(red: 1, green: 0.87, blue: 0.62))
            .environmentObject(library)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIHostingController(rootView: content)
        window.makeKeyAndVisible()
        self.window = window
        return true
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
