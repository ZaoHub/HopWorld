import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var logger = AppLogger.shared
    @State private var isConnectionPanelPresented = false
    @State private var selectedConnectionLogIDs: Set<UUID> = []
    @State private var presentedPersistenceError: String?
    @State private var lastPresentedPersistenceError: String?
    @State private var showPersistenceAlert = false

    var body: some View {
        NavigationSplitView {
            GeometryReader { geometry in
                let navigationRowHeight: CGFloat = 32
                let cardSafetySpacing: CGFloat = 12
                let navigationHeight = min(
                    CGFloat(SidebarItem.allCases.count) * navigationRowHeight + 24,
                    max(0, geometry.size.height - cardSafetySpacing)
                )
                let cardsViewportHeight = max(0, geometry.size.height - navigationHeight - cardSafetySpacing)
                VStack(spacing: cardSafetySpacing) {
                    List(SidebarItem.allCases, selection: $appState.selectedSidebar) { item in
                        Label(item.title, systemImage: item.systemImage)
                            .frame(height: navigationRowHeight)
                            .tag(item)
                            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                    }
                    .environment(\.defaultMinListRowHeight, navigationRowHeight)
                    .listStyle(.sidebar)
                    .safeAreaPadding(.top, 8)
                    .frame(height: navigationHeight)

                    // Keep sizing one-way during live resize and progress updates.
                    // Short content sits at the bottom; taller content can scroll.
                    ScrollView(.vertical) {
                        VStack(spacing: 0) {
                            TestProgressFloatingBar()
                            CodexUsageCard()
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: cardsViewportHeight, alignment: .bottom)
                    }
                    .frame(height: cardsViewportHeight)
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ephemeralStatusBanner
                }
                .overlay(alignment: .bottom) {
                    GeometryReader { geometry in
                        ZStack(alignment: .bottom) {
                            if isConnectionPanelPresented {
                                connectionLogPanel
                                    .frame(maxWidth: 620)
                                    .frame(height: min(420, max(180, geometry.size.height - 24)))
                                    .transition(.move(edge: .bottom))
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .clipped()
                        .animation(.smooth(duration: 0.3), value: isConnectionPanelPresented)
                    }
                    .allowsHitTesting(isConnectionPanelPresented)
                }
        }
        .overlay(alignment: .center) {
            if let message = appState.flashToastMessage {
                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .frame(maxWidth: 420)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08))
                    }
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                    .padding(24)
                    .onTapGesture { appState.dismissFlashToast() }
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .navigationTitle("跃界")
        .toolbarBackground(.visible, for: .windowToolbar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            connectionStatusBar
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(appState.connection.state.status.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(statusColor == .secondary ? Color.secondary : statusColor)
                        .lineLimit(1)
                }
                .padding(.leading, 10)
                .padding(.trailing, 12)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.05), in: Capsule())
            }
        }
        .onAppear {
            presentPersistenceErrorIfNeeded()
        }
        .onChange(of: appState.persistenceError) { _, _ in
            presentPersistenceErrorIfNeeded()
        }
        .alert(appState.isLibraryReady ? "节点与订阅保存失败" : "节点与订阅读取失败",
               isPresented: $showPersistenceAlert) {
            if appState.isLibraryReady {
                if hasQuickSwitchNodes {
                    Button("重新连接") {
                        Task { await appState.connectWithAutoSelect() }
                    }
                } else {
                    Button("跳转节点") {
                        appState.preferredNodeCategory = "all"
                        appState.selectedSidebar = .nodes
                    }
                }
            } else {
                Button("重新读取") { appState.retryLoadLibrary() }
            }
            Button("好的", role: .cancel) {}
        } message: {
            Text(persistenceAlertMessage)
        }
        .onReceive(NotificationCenter.default.publisher(for: .hopWorldWillTerminate)) { _ in
            Task {
                if appState.connection.state.status == .connected {
                    await appState.disconnectForTermination()
                }
            }
        }
        .sheet(isPresented: $appState.showAddSubscription) {
            SubscriptionEditorView(mode: .create)
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showImportLinks) {
            ImportLinksView()
                .environmentObject(appState)
        }
        .sheet(item: viewingNodeBinding) { node in
            NodeDetailView(nodeID: node.id)
                .environmentObject(appState)
        }
        .alert(
            "测速结果",
            isPresented: Binding(
                get: { appState.testManager.showFinishedAlert },
                set: { appState.testManager.showFinishedAlert = $0 }
            )
        ) {
            Button("查看可用节点") {
                appState.selectedSidebar = .nodes
                appState.preferredNodeCategory = "available"
            }
            Button("好的", role: .cancel) {}
        } message: {
            if let summary = appState.testManager.lastFinishedSummary {
                Text(summary.message)
            } else {
                Text("测试已结束")
            }
        }
        .alert(
            connectConfirmTitle,
            isPresented: Binding(
                get: { appState.pendingUnavailableConnectID != nil },
                set: { if !$0 { appState.cancelUnavailableConnect() } }
            )
        ) {
            Button("仍然连接") {
                appState.confirmUnavailableConnect()
            }
            Button("取消", role: .cancel) {
                appState.cancelUnavailableConnect()
            }
        } message: {
            Text(connectConfirmMessage)
        }
    }

    private var hasQuickSwitchNodes: Bool {
        !appState.automaticallyRankedNodes(appState.nodes).isEmpty
    }

    private var persistenceAlertMessage: String {
        guard appState.isLibraryReady else {
            return "本地数据尚未读取成功，自动更新与保存已暂停。原数据不会被覆盖。\n\n"
                + (presentedPersistenceError ?? "")
        }
        let nextStep = hasQuickSwitchNodes
            ? "「快速切换」列表中有可用节点，点击「重新连接」将按当前自动优选顺序连接。"
            : "「快速切换」列表中暂无可用节点，点击「跳转节点」前往节点页面进行测试，测试后可重新连接。"
        return "最近的修改尚未保存。\n\n" + (presentedPersistenceError ?? "")
            + "\n\n" + nextStep
    }

    private var connectConfirmTitle: String {
        if appState.pendingUnavailableConnectNode?.lastTestStatus == .failed {
            return "连接失败节点？"
        }
        return "连接不可用节点？"
    }

    private var connectConfirmMessage: String {
        let node = appState.pendingUnavailableConnectNode
        let name = node.map { "「\($0.displayTitle)」" } ?? "该节点"
        if node?.lastTestStatus == .failed {
            return "\(name)最近测速为配置失败（客户端无法按当前配置探测），连接多半无法成功。确定继续吗？"
        }
        return "\(name)最近测速为不可用，连接可能失败或很慢。确定继续吗？"
    }

    private func presentPersistenceErrorIfNeeded() {
        guard let error = appState.persistenceError else {
            lastPresentedPersistenceError = nil
            return
        }
        guard error != lastPresentedPersistenceError else { return }
        lastPresentedPersistenceError = error
        presentedPersistenceError = error
        showPersistenceAlert = true
    }

    @ViewBuilder
    private var ephemeralStatusBanner: some View {
        if let banner = appState.statusBanner {
            Text(banner)
                .font(.callout)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .onTapGesture { appState.statusBanner = nil }
                .task(id: banner) {
                    try? await Task.sleep(nanoseconds: 3_500_000_000)
                    if appState.statusBanner == banner {
                        appState.statusBanner = nil
                    }
                }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch appState.selectedSidebar {
        case .dashboard:
            DashboardView()
        case .countries:
            CountryListView()
        case .nodes:
            NodeListView()
        case .subscriptions:
            SubscriptionListView()
        case .testing:
            TestCenterView()
        case .routing:
            RoutingView()
        case .settings:
            SettingsView()
        case .logs:
            LogView()
        case .about:
            AboutView()
        }
    }

    private var statusColor: Color {
        switch appState.connection.state.status {
        case .connected: return .green
        case .connecting, .disconnecting: return .orange
        case .error: return .red
        case .disconnected: return .secondary
        }
    }

    private var connectionLogPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                connectionStatusIndicator

                VStack(alignment: .leading, spacing: 3) {
                    Text(appState.connection.state.status.displayName)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(statusColor == .secondary ? Color.secondary : statusColor)
                    Text(connectionStatusDetail)
                        .font(.caption)
                        .foregroundStyle(
                            appState.connection.state.status == .error ? Color.red : Color.secondary
                        )
                        .lineLimit(2)
                }

                Spacer(minLength: 12)

                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        isConnectionPanelPresented = false
                    }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("收起日志面板")
                .accessibilityLabel("收起日志面板")

                if let latency = appState.connection.state.latency,
                   appState.connection.state.status == .connected {
                    Text(LatencyFormat.seconds(latency))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if appState.connection.state.status == .connected ||
                    appState.connection.state.status == .connecting {
                    Button("断开") {
                        Task { await appState.disconnect() }
                    }
                    .controlSize(.small)
                }
            }
            .padding(12)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("实时日志", systemImage: "text.alignleft")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("最近 \(visibleConnectionLogs.count) 条")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Group {
                    if visibleConnectionLogs.isEmpty {
                        Text("暂无日志")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    } else {
                        List(visibleConnectionLogs, selection: $selectedConnectionLogIDs) { entry in
                            connectionLogRow(entry)
                                .tag(entry.id)
                                .contextMenu {
                                    Button(selectedConnectionLogIDs.count > 1 ? "复制选中的 \(selectedConnectionLogIDs.count) 条日志" : "复制此条日志") {
                                        copySelectedLogs(fallback: entry)
                                    }
                                    Button("复制全部日志") {
                                        copyToPasteboard(logger.exportText())
                                    }
                                }
                        }
                        .listStyle(.inset)
                        .scrollContentBackground(.hidden)
                        .contextMenu {
                            Button("复制选中日志") {
                                copySelectedLogs()
                            }
                            .disabled(selectedConnectionLogIDs.isEmpty)
                            Button("全选") {
                                selectedConnectionLogIDs = Set(visibleConnectionLogs.map(\.id))
                            }
                            Button("复制全部日志") {
                                copyToPasteboard(logger.exportText())
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .overlay {
            Rectangle()
                .stroke(Color.primary.opacity(0.1))
        }
        .shadow(color: .black.opacity(0.14), radius: 10, y: -2)
    }

    private var connectionStatusBar: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.22)) {
                    isConnectionPanelPresented.toggle()
                }
            } label: {
                Capsule()
                    .fill(statusColor.opacity(appState.connection.state.status == .disconnected ? 0.45 : 0.9))
                    .frame(width: 110, height: 5)
                    .frame(width: 180, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isConnectionPanelPresented ? "收起日志面板" : "展开日志面板")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.bottom, 3)
    }

    @ViewBuilder
    private var connectionStatusIndicator: some View {
        if appState.connection.state.status == .connecting ||
            appState.connection.state.status == .disconnecting {
            ProgressView()
                .controlSize(.small)
                .frame(width: 10, height: 10)
        } else {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
        }
    }

    private var visibleConnectionLogs: [LogEntry] {
        Array(logger.entries.suffix(100).reversed())
    }

    private func connectionLogRow(_ entry: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text(entry.date, format: .dateTime.hour().minute().second())
                .foregroundStyle(.tertiary)
                .fixedSize()
            Text("[\(entry.level.displayName)]")
                .foregroundStyle(logColor(entry.level))
                .fixedSize()
            Text("[\(entry.category.displayName)] \(entry.message)")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11, design: .monospaced))
        .contentShape(Rectangle())
    }

    private func logColor(_ level: AppLogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func copySelectedLogs(fallback: LogEntry? = nil) {
        let selected = logger.entries.filter { selectedConnectionLogIDs.contains($0.id) }
        if selected.isEmpty, let fallback {
            copyToPasteboard(logger.exportText([fallback]))
        } else {
            copyToPasteboard(logger.exportText(selected))
        }
    }

    private var connectionStatusDetail: String {
        if let progress = appState.connection.failoverStatus, !progress.isEmpty {
            return progress
        }
        if appState.connection.state.status == .error,
           let error = appState.connection.state.lastError,
           !error.isEmpty {
            return error
        }
        if let node = appState.currentNode {
            switch appState.connection.state.status {
            case .connecting:
                return "正在连接 \(node.displayTitle)"
            case .connected:
                return "\(node.displayTitle) · \(node.protocolType.displayName)"
            case .disconnecting:
                return "正在断开 \(node.displayTitle)"
            case .disconnected, .error:
                break
            }
        }
        return "未连接节点"
    }

    private var viewingNodeBinding: Binding<ProxyNode?> {
        Binding(
            get: {
                guard let id = appState.viewingNodeID else { return nil }
                return appState.nodes.first { $0.id == id }
            },
            set: { appState.viewingNodeID = $0?.id }
        )
    }
}
