import AppKit
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
                .environmentObject(appState.testManager)
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
                .environmentObject(appState.testManager)
        } label: {
            HStack(spacing: 4) {
                MenuBarStatusIcon(status: appState.connection.state.status)
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
                .environmentObject(appState.testManager)
                .frame(width: 520, height: 480)
        }
    }

}

/// 未连接黑图标、已连接白图标；连接中偏黑，断开中偏白。
/// MenuBarExtra 会把 SwiftUI Image 强行当成 template，必须用 isTemplate=false 的 NSImage 才能保住黑/白。
/// 菜单栏标签不能用 TimelineView：每帧换图会卡死状态栏布局。
private struct MenuBarStatusIcon: View {
    let status: ConnectionStatus

    var body: some View {
        Image(nsImage: menuBarImage(named: usesWhiteIcon ? "MenuBarIconWhite" : "MenuBarIconBlack"))
            .resizable()
            .interpolation(.high)
            .frame(width: 18, height: 18)
    }

    private var usesWhiteIcon: Bool {
        switch status {
        case .connected, .disconnecting: return true
        case .disconnected, .error, .connecting: return false
        }
    }

    private func menuBarImage(named name: String) -> NSImage {
        let image = (NSImage(named: name)?.copy() as? NSImage) ?? NSImage(size: NSSize(width: 18, height: 18))
        image.isTemplate = false
        image.size = NSSize(width: 18, height: 18)
        return image
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminationPending = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        NotificationCenter.default.post(name: .hopWorldWillTerminate, object: sender)
        return .terminateLater
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
