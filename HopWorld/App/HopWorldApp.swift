import SwiftUI

@main
struct HopWorldApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("跃界", id: MainWindowActivation.sceneID) {
            ContentView()
                .environmentObject(appState)
                .environmentObject(appState.connection)
                .frame(minWidth: 980, minHeight: 640)
                .background(MainWindowRevealAnchor())
        }
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
                .environmentObject(appState.connection)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: menuBarImage)
                if appState.connection.state.status == .connected {
                    Text(appState.connection.state.latency.map { "\($0) ms" } ?? "超时")
                        .monospacedDigit()
                }
            }
            .accessibilityLabel("跃界，\(appState.connection.state.status.displayName)")
            .background(MainWindowRevealAnchor())
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(appState.connection)
                .frame(width: 520, height: 480)
        }
    }

    private var menuBarImage: String {
        switch appState.connection.state.status {
        case .connected: return "shield.lefthalf.filled"
        case .connecting, .disconnecting: return "shield.lefthalf.filled.slash"
        case .error: return "exclamationmark.shield"
        case .disconnected: return "shield"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        // Best-effort restore is handled by ConnectionManager disconnect on quit via notification.
        NotificationCenter.default.post(name: .hopWorldWillTerminate, object: nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DockReopen.start()
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DockReopen.handleDockClick()
        return false
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
                DockReopen.start()
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
