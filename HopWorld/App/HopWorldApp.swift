import AppKit
import SwiftUI

@main
enum HopWorldMain {
    static func main() {
        LabUtilityProcess.runIfInvoked()
        HopWorldApp.main()
    }
}

enum MenuBarAnchor {
    static var appState: AppState?
}

struct HopWorldApp: App {
    @StateObject private var appState: AppState
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let appState = AppState()
        MenuBarAnchor.appState = appState
        _appState = StateObject(wrappedValue: appState)
    }

    var body: some Scene {
        Window("跃界", id: MainWindowActivation.sceneID) {
            ContentView()
                .environmentObject(appState)
                .environmentObject(appState.connection)
                .environmentObject(appState.testManager)
                .frame(minWidth: 980, minHeight: 640)
                .background(MainWindowRevealAnchor())
                .onAppear { appDelegate.installStatusMenuIfNeeded() }
        }
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(appState.connection)
                .environmentObject(appState.testManager)
                .frame(width: 520, height: 480)
        }
    }

}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminationPending = false
    private var statusMenu: StatusMenuController?

    @MainActor
    func installStatusMenuIfNeeded() {
        guard statusMenu == nil, let appState = MenuBarAnchor.appState else { return }
        statusMenu = StatusMenuController(appState: appState)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        NotificationCenter.default.post(name: .hopWorldWillTerminate, object: sender)
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in self.installStatusMenuIfNeeded() }
        DockReopen.start()
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DockReopen.handleDockClick()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

}

private struct MainWindowRevealAnchor: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task {
                MainWindowActivation.openMainWindow = { openWindow(id: MainWindowActivation.sceneID) }
            }
            .onAppear {
                MainWindowActivation.openMainWindow = { openWindow(id: MainWindowActivation.sceneID) }
            }
            .onReceive(NotificationCenter.default.publisher(for: MainWindowActivation.revealNotification)) { _ in
                openWindow(id: MainWindowActivation.sceneID)
            }
    }
}

extension Notification.Name {
    static let hopWorldWillTerminate = Notification.Name("hopWorldWillTerminate")
}
