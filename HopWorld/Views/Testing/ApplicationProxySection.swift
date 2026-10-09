import AppKit
import SwiftUI

/// 按应用代理卡片内容：容器无关（由路由页的卡片包裹），逻辑与原来一致。
struct ApplicationProxySection: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var connection: ConnectionManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var applications: [ProxyApplication] = []
    @State private var saving = false
    @State private var error: String?
    @State private var showingRunningApplications = false

    private var subtext: Color {
        colorScheme == .dark ? Color(red: 0.60, green: 0.68, blue: 0.70) : Color(red: 0.42, green: 0.49, blue: 0.51)
    }

    private var rowFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.03)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusRow(title: "已保存模式", value: appState.settings.connectionCaptureMode.displayName)
            statusRow(title: "实际接管状态", value: CaptureStatusPresentation.text(
                status: connection.state.status,
                activeMode: connection.effectiveCaptureMode,
                cleanupPending: connection.captureCleanupFailed
            ))
            if hasUnsavedChanges {
                Label("应用列表已修改，尚未保存；不会自动切换当前网络。", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            } else if appState.settings.connectionCaptureMode != .applications {
                Text("添加应用后，请点击下方按钮保存并选择应用代理；仅添加应用不会切换模式。")
                    .font(.caption).foregroundStyle(subtext)
            } else if connection.state.status == .disconnected {
                Text("应用代理设置已保存。连接节点并完成管理员授权后才会生效。")
                    .font(.caption).foregroundStyle(subtext)
            }
            Text("仅选中应用的公网连接走节点，其他应用默认直连。需要管理员授权；首次连接下载并校验 sing-box 核心。此模式不使用下方的域名分流规则。")
                .font(.caption).foregroundStyle(subtext)
            if !applications.isEmpty {
                VStack(spacing: 6) {
                    ForEach(applications) { application in
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: application.path))
                                .resizable().frame(width: 24, height: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(application.name)
                                    .font(.callout.weight(.medium))
                                Text(application.path).font(.caption2).foregroundStyle(subtext).textSelection(.enabled)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Text("\(matchKind(application))")
                                .font(.caption2)
                                .foregroundStyle(subtext)
                            Button("移除") { applications.removeAll { $0.id == application.id } }
                                .buttonStyle(.link)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(rowFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
            HStack(spacing: 10) {
                Button("添加应用 / 可执行文件…") { chooseApplication() }
                    .buttonStyle(.bordered)
                Button { showingRunningApplications = true } label: {
                    Label("添加运行中的应用", systemImage: "magnifyingglass")
                }
                .buttonStyle(.bordered)
                .popover(isPresented: $showingRunningApplications, arrowEdge: .bottom) {
                    RunningApplicationPicker(selectedPaths: Set(applications.map(\.path)), onSelect: add)
                }
                Spacer(minLength: 4)
                Text("\(applications.count) 个应用")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(subtext)
            }
            Text("应用包内的 Helper 等辅助程序自动包含；包外的命令行工具需另行添加，添加后该工具的所有实例都会匹配。系统 DNS、局域网及无法识别进程的流量保持直连；这不是防泄漏隔离模式。开启后请重建应用连接，必要时重启目标应用。")
                .font(.caption).foregroundStyle(subtext)
            Text("请先关闭其他 VPN / TUN 和第三方系统代理，以免路由冲突。断开后恢复本地网络；异常退出通常约 13 秒内自动清理（不含机器休眠时间）。")
                .font(.caption).foregroundStyle(subtext)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            if connection.state.status == .error, let message = connection.state.lastError, message != error {
                Text(message).font(.caption).foregroundStyle(.red)
            }
            HStack(spacing: 10) {
                Button(saving ? "正在应用…" : saveButtonTitle) {
                    Task {
                        saving = true
                        defer { saving = false }
                        do {
                            try await appState.applyApplicationProxy(applications)
                            error = nil
                        } catch { self.error = error.localizedDescription }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(applications.isEmpty)
                if appState.settings.connectionCaptureMode == .applications {
                    Button("恢复系统代理模式") {
                        Task {
                            saving = true
                            await appState.setConnectionCaptureMode(.systemProxy)
                            saving = false
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .disabled(saving || appState.connection.isBusy)
        .onAppear { applications = appState.settings.proxyApplications }
    }

    private func statusRow(title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .font(.callout)
                .foregroundStyle(subtext)
            Spacer(minLength: 8)
            Text(value)
                .font(.callout.weight(.medium))
                .multilineTextAlignment(.trailing)
        }
    }

    private func matchKind(_ application: ProxyApplication) -> String {
        application.path.hasSuffix(".app") || application.path.contains(".app/") ? "应用包" : "可执行文件"
    }

    private var hasUnsavedChanges: Bool {
        Set(applications) != Set(appState.settings.proxyApplications)
    }

    private var saveButtonTitle: String {
        connection.state.status == .connected ? "保存并切换为应用代理" : "保存并选择应用代理模式"
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "选择要走代理的应用或可执行文件"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls { add(url) }
        }
    }

    private func add(_ url: URL) {
        do {
            let application = try ProxyApplication(url: url)
            if !applications.contains(where: { $0.id == application.id }) { applications.append(application) }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
