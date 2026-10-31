import AppKit
import SwiftUI

/// 按应用代理卡片内容：容器无关（由路由页的卡片包裹），逻辑与原来一致。
struct ApplicationProxySection: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var connection: ConnectionManager
    @Environment(\.colorScheme) private var colorScheme
    @Binding var applications: [ProxyApplication]
    @State private var isEditing = false
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
            HStack {
                Text("\(applications.count) 个应用")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(subtext)
                Text(CaptureStatusPresentation.text(
                    status: connection.state.status,
                    activeMode: connection.effectiveCaptureMode,
                    cleanupPending: connection.captureCleanupFailed
                ))
                .font(.caption)
                .foregroundStyle(subtext)
                Spacer(minLength: 8)
                if isEditing {
                    applyButton
                    Button("取消") {
                        applications = appState.settings.proxyApplications
                        error = nil
                        isEditing = false
                    }
                    .buttonStyle(.bordered)
                } else if appState.settings.connectionCaptureMode == .applications {
                    Button("恢复系统代理模式") {
                        Task {
                            saving = true
                            await appState.setConnectionCaptureMode(.systemProxy)
                            saving = false
                        }
                    }
                    .buttonStyle(.bordered)
                } else if !isEditing {
                    applyButton
                }
                if !isEditing {
                    Button("编辑") {
                        applications = appState.settings.proxyApplications
                        error = nil
                        isEditing = true
                    }
                    .buttonStyle(.bordered)
                }
            }
            if hasUnsavedChanges {
                Label("有未保存的修改", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            } else if appState.settings.connectionCaptureMode != .applications {
                Label(
                    applications.isEmpty
                        ? "当前仍是系统代理：所有遵循系统代理的应用都会走节点。添加应用并切换后，才仅名单生效。"
                        : "名单尚未生效：当前仍是系统代理，所有遵循系统代理的应用都会走节点。请点击「切换为应用代理」。",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            } else if isEditing {
                Text("保存后按新名单重新连接。")
                    .font(.caption).foregroundStyle(subtext)
            }
            if !applications.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 8)], spacing: 8) {
                    ForEach(applications) { application in
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: application.path))
                                .resizable().frame(width: 24, height: 24)
                            Text(application.name)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if isEditing {
                                Button { applications.removeAll { $0.id == application.id } } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("移除\(application.name)")
                                .accessibilityLabel("移除\(application.name)")
                            }
                        }
                        .help("\(application.path)（\(matchKind(application))）")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(rowFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
            if isEditing {
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
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            if connection.state.status == .error, let message = connection.state.lastError, message != error {
                Text(message).font(.caption).foregroundStyle(.red)
            }

        }
        .onChange(of: appState.settings.proxyApplications) { saved in
            if !isEditing { applications = saved }
        }
        .disabled(saving || appState.connection.isBusy)

    }

    private var applyButton: some View {
        Button(saving ? "正在应用…" : saveButtonTitle) {
            Task {
                saving = true
                defer { saving = false }
                do {
                    try await appState.applyApplicationProxy(applications)
                    error = nil
                    isEditing = false
                } catch { self.error = error.localizedDescription }
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(applications.isEmpty)
        .help("保存应用列表并切换为应用代理；已连接时会重新连接。")
    }

    private func matchKind(_ application: ProxyApplication) -> String {
        application.path.hasSuffix(".app") || application.path.contains(".app/") ? "应用包" : "可执行文件"
    }

    private var hasUnsavedChanges: Bool {
        Set(applications) != Set(appState.settings.proxyApplications)
    }

    private var saveButtonTitle: String {
        if !isEditing { return "切换为应用代理" }
        return "保存并应用"
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
