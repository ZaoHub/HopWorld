import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isConnectionPanelPresented = false
    @State private var selectedConnectionLogIDs: Set<UUID> = []
    @State private var showsHistoricalConnectionLogs = false
    @State private var presentedPersistenceError: String?
    @State private var lastPresentedPersistenceError: String?
    @State private var showPersistenceAlert = false
    @State private var showTestResults = false
    @State private var presentedTestSummary: NodeTestRunSummary?
    @State private var showsMessageTray = false
    @State private var selectedMessageID: UUID?

    var body: some View {
        VStack(spacing: 0) {
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
                        .padding(.top, 8)
                        .frame(height: navigationHeight)

                        // Keep sizing one-way during live resize and progress updates.
                        // Short content sits at the bottom; taller content can scroll.
                        ScrollView(.vertical) {
                            VStack(spacing: 0) {
                                TestProgressFloatingBar()
                                CodexUsageCard(statisticsHeight: max(360, geometry.size.height - 24),
                                               monitor: appState.codexUsageMonitor)
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
                VStack(spacing: 0) {
                    detailView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    ephemeralStatusBanner
                }
                .overlay(alignment: .bottom) {
                    GeometryReader { geometry in
                        ZStack(alignment: .bottom) {
                            if isConnectionPanelPresented {
                                ConnectionLogPanel(
                                    isConnectionPanelPresented: $isConnectionPanelPresented,
                                    selectedConnectionLogIDs: $selectedConnectionLogIDs,
                                    showsHistoricalLogs: $showsHistoricalConnectionLogs
                                )
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
            connectionStatusBar
                .background(.bar)
        }
        .overlay(alignment: .bottomTrailing) {
            if let message = appState.toastMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text(message.title).font(.headline)
                    Text(message.body)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Color(red: 0.32, green: 0.16, blue: 0.02))
                .padding(14)
                .frame(width: 320, alignment: .leading)
                .background(Color(red: 1, green: 0.86, blue: 0.52), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(red: 0.78, green: 0.42, blue: 0.05), lineWidth: 1.5)
                }
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .padding(.trailing, 16)
                .padding(.bottom, 36)
                .onTapGesture {
                    appState.dismissToast()
                    selectedMessageID = nil
                    showsMessageTray = true
                    appState.markMessagesRead()
                }
                .accessibilityAddTraits(.updatesFrequently)
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
        .toolbar {
            ToolbarItem(placement: .automatic) {
                ConnectedNodeScoreButton(connection: appState.connection)
            }
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
                .accessibilityElement(children: .combine)
                .accessibilityLabel(appState.connection.state.status.displayName)
            }
        }
        .onAppear {
            presentPersistenceErrorIfNeeded()
        }
        .onChange(of: appState.persistenceError) { _ in
            presentPersistenceErrorIfNeeded()
        }
        .alert(appState.offlineNoticeTitle, isPresented: $appState.showsNoNetworkAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(appState.offlineNoticeMessage)
        }
        .alert("暂时没有可连接的节点", isPresented: $appState.showsNoConnectionCandidates) {
            Button("前往测试") { appState.selectedSidebar = .testing }
            Button("管理临时屏蔽") {
                UserDefaults.standard.set(false, forKey: "quickSwitchMergeCountries")
                appState.selectedSidebar = .dashboard
            }
            Button("添加订阅") { appState.showAddSubscription = true }
            Button("稍后", role: .cancel) {}
        } message: {
            Text(appState.noConnectionCandidatesMessage)
        }
        .alert(appState.isLibraryReady ? "节点与订阅保存失败" : "节点与订阅读取失败",
               isPresented: $showPersistenceAlert) {
            if appState.isLibraryReady {
                if showPersistenceAlert && hasQuickSwitchNodes {
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
        .alert("订阅更新成功", isPresented: Binding(
            get: { !appState.subscriptionTestPromptIDs.isEmpty },
            set: { if !$0 { appState.subscriptionTestPromptIDs.removeAll() } }
        ), presenting: appState.subscriptionTestPromptIDs) { ids in
            let selectAllSubscriptions = appState.subscriptionTestPromptSelectsAll
            Button("手动测试") {
                Task { await appState.testSubscriptionNodes(ids, selectAllSubscriptions: selectAllSubscriptions) }
            }
            Button("稍后", role: .cancel) {}
        } message: { ids in
            let updated = appState.subscriptions.filter { ids.contains($0.id) }
            let names = updated.prefix(5).map(\.name).joined(separator: "、")
            let summary = updated.count > 5 ? "「\(names)」等 \(updated.count) 个订阅" : "「\(names)」"
            Text("\(summary)的节点有变化。可手动测试节点；若已开启「自动测试可用节点的应用连通」，测速后会继续测试应用连通。")
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
        .onReceive(appState.testManager.$showFinishedAlert.receive(on: RunLoop.main)) { shouldPresent in
            guard shouldPresent, let summary = appState.testManager.takeFinishedSummary() else { return }
            presentedTestSummary = summary
            showTestResults = true
        }
        .sheet(isPresented: $showTestResults) {
            VStack(alignment: .leading, spacing: 20) {
                Text(presentedTestSummary?.installGuidance == nil ? "测速结果" : "需要安装 Xray")
                    .font(.title2.bold())
                ScrollView {
                    Text(presentedTestSummary?.message ?? "测试已结束")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Divider()
                HStack {
                    Spacer()
                    Button("好的", role: .cancel) { showTestResults = false }
                        .keyboardShortcut(.cancelAction)
                    if presentedTestSummary?.installGuidance != nil {
                        Button("安装 Xray") {
                            showTestResults = false
                            appState.selectedSidebar = .about
                            appState.showComponentUpdates = true
                        }
                        .keyboardShortcut(.defaultAction)
                    } else {
                        Button("查看可用节点") {
                            showTestResults = false
                            appState.selectedSidebar = .nodes
                            appState.preferredNodeCategory = "available"
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(24)
            .frame(width: 600, height: 420)
        }
        .sheet(isPresented: $appState.showComponentUpdates) {
            ComponentUpdatesDialog()
                .environmentObject(appState)
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
        guard showPersistenceAlert else { return "" }
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
        let name = node.map { "「\(appState.settings.nodeDisplayTitle($0))」" } ?? "该节点"
        if node?.lastTestStatus == .failed {
            return "\(name)最近测速为配置失败（客户端无法按当前配置探测），连接多半无法成功。确定继续吗？"
        }
        return "\(name)最近测速为不可用，连接可能失败或很慢。确定继续吗？"
    }

    private func presentPersistenceErrorIfNeeded() {
        guard let error = appState.persistenceError else {
            lastPresentedPersistenceError = nil
            presentedPersistenceError = nil
            showPersistenceAlert = false
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
            .accessibilityLabel(isConnectionPanelPresented ? "收起日志面板" : "展开日志面板")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.bottom, 3)
        .overlay(alignment: .trailing) {
            if !appState.messages.isEmpty {
                Button {
                    if showsMessageTray {
                        showsMessageTray = false
                        selectedMessageID = nil
                    } else {
                        selectedMessageID = nil
                        showsMessageTray = true
                        appState.markMessagesRead()
                    }
                } label: {
                    Label(appState.unreadMessageCount > 0 ? "\(appState.unreadMessageCount)" : "消息", systemImage: "bell")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.borderless)
                .help("网络消息")
                .accessibilityLabel("消息")
                .padding(.trailing, 8)
                .popover(isPresented: $showsMessageTray, arrowEdge: .bottom) {
                    messageTray
                }
            }
        }
    }

    private var messageTray: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if selectedMessageID != nil {
                    Button("返回") { selectedMessageID = nil }
                        .buttonStyle(.borderless)
                }
                Text(selectedMessage == nil ? "消息" : "详情").font(.headline)
                Spacer()
                Button("清空") {
                    appState.clearMessages()
                    selectedMessageID = nil
                    showsMessageTray = false
                }
                .buttonStyle(.borderless)
            }
            if let message = selectedMessage {
                Text(message.date.formatted(date: .abbreviated, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(message.title).font(.callout.weight(.semibold))
                Text(message.body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(appState.messages) { message in
                            Button {
                                selectedMessageID = message.id
                            } label: {
                                HStack(spacing: 8) {
                                    Text(message.date.formatted(.dateTime.month(.defaultDigits).day().hour().minute()))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    Text(message.title)
                                        .font(.callout)
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 320, height: 280)
    }

    private var selectedMessage: AppMessage? {
        appState.messages.first { $0.id == selectedMessageID }
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

private struct ConnectedNodeScoreButton: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var connection: ConnectionManager

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let node = connection.state.status == .connected ? appState.currentNode : nil
            let score = node.flatMap {
                connection.nodeQuality[$0.id]?.score(for: .codex, settings: appState.settings, now: max(context.date, Date()))
            }
            let title = score.map { String($0.points) } ?? (node == nil ? "打盹中" : "热身中")
            let symbol = score != nil ? "chart.bar.xaxis" : (node == nil ? "moon.zzz.fill" : "sparkles")
            Button {
                if connection.state.status == .connected, let current = appState.currentNode {
                    appState.openNetworkHealthCenter(for: current.id)
                }
            } label: {
                Label(title, systemImage: symbol)
                    .labelStyle(.titleAndIcon)
                    .monospacedDigit()
                    .fixedSize()
            }
            .disabled(node == nil)
            .help(node == nil ? "节点打盹中，连接后就能查看评分。" : score.map {
                "当前节点评分：\($0.points) / 100，已测维度覆盖 \($0.coverage)%。点击打开完整网络健康中心。"
            } ?? "评分热身中，等待有效采样；点击打开网络健康中心查看观测与采样。")
            .accessibilityLabel("当前已连接节点评分")
            .accessibilityValue(score.map { "\($0.points) 分，覆盖 \($0.coverage)%" }
                ?? (node == nil ? "未连接，打盹中" : "采样不足，热身中"))
            .accessibilityHint("打开完整网络健康中心")
        }
    }
}

// Only the open log panel observes log traffic, not the navigation/detail tree.
private struct ConnectionLogPanel: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var logger = AppLogger.shared
    @Binding var isConnectionPanelPresented: Bool
    @Binding var selectedConnectionLogIDs: Set<UUID>
    @Binding var showsHistoricalLogs: Bool
    @State private var showsOnlyProblems = true

    var body: some View {
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
                    Text(LatencyFormat.display(latency))
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

            if showsHistoricalLogs || logger.hasCurrentSessionProblems {
                logContents
            } else {
                historyButton
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .overlay {
            Rectangle()
                .stroke(Color.primary.opacity(0.1))
        }
        .shadow(color: .black.opacity(0.14), radius: 10, y: -2)
        .onAppear {
            selectedConnectionLogIDs.formIntersection(visibleConnectionLogs.map(\.id))
        }
        .onChange(of: visibleConnectionLogs.map(\.id)) { ids in
            selectedConnectionLogIDs.formIntersection(ids)
        }
    }

    private var historyButton: some View {
        Button("历史记录") {
            showsHistoricalLogs = true
        }
        .buttonStyle(.borderless)
        .help("展开历史日志")
        .accessibilityHint("显示本次启动前保存的日志")
    }

    private var logContents: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("运行日志", systemImage: "text.alignleft")
                    .font(.caption.weight(.semibold))
                Spacer()
                Picker("日志范围", selection: $showsOnlyProblems) {
                    Text("问题日志").tag(true)
                    Text("全部日志").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 180)
                Text("最近 \(visibleConnectionLogs.count) 条")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Group {
                if visibleConnectionLogs.isEmpty {
                    VStack(spacing: 6) {
                        Label(showsOnlyProblems ? "暂无警告或错误" : "暂无日志", systemImage: "text.magnifyingglass")
                            .font(.callout)
                        if showsOnlyProblems {
                            Text("普通连接与断开记录可在“全部日志”中查看")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    List(visibleConnectionLogs, selection: $selectedConnectionLogIDs) { entry in
                        connectionLogRow(entry)
                            .tag(entry.id)
                            .contextMenu {
                                Button(selectedConnectionLogIDs.contains(entry.id) && selectedConnectionLogIDs.count > 1 ? "复制选中的 \(selectedConnectionLogIDs.count) 条日志" : "复制此条日志") {
                                    copySelectedLogs(fallback: entry)
                                }
                                Button("复制当前显示日志") {
                                    copyToPasteboard(logger.exportText(Array(visibleConnectionLogs.reversed())))
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
                        Button("复制当前显示日志") {
                            copyToPasteboard(logger.exportText(Array(visibleConnectionLogs.reversed())))
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            HStack {
                if logger.hasHistoricalEntries && !showsHistoricalLogs {
                    historyButton
                } else {
                    Text(showsOnlyProblems ? "仅显示警告和错误" : "显示所有已记录级别")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("复制当前显示日志") {
                    copyToPasteboard(logger.exportText(Array(visibleConnectionLogs.reversed())))
                }
                .disabled(visibleConnectionLogs.isEmpty)
                Button("打开日志页") {
                    appState.selectedSidebar = .logs
                    isConnectionPanelPresented = false
                }
            }
            .controlSize(.small)
        }
        .padding(10)
    }

    private var statusColor: Color {
        switch appState.connection.state.status {
        case .connected: return .green
        case .connecting, .disconnecting: return .orange
        case .error: return .red
        case .disconnected: return .secondary
        }
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
        logger.recentEntries(problemsOnly: showsOnlyProblems, includeHistory: showsHistoricalLogs)
    }

    private func connectionLogRow(_ entry: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text(entry.date, format: .dateTime.hour().minute().second())
                .foregroundStyle(.secondary)
                .fixedSize()
            Text("[\(entry.level.displayName)]")
                .foregroundStyle(logColor(entry.level))
                .fixedSize()
            Text("[\(entry.category.displayName)] \(entry.displayMessage)")
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(.caption, design: .monospaced))
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
        let selected = visibleConnectionLogs.reversed().filter { selectedConnectionLogIDs.contains($0.id) }
        if let fallback, !selectedConnectionLogIDs.contains(fallback.id) {
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
                return "正在连接 \(appState.settings.nodeDisplayTitle(node))"
            case .connected:
                return "\(appState.settings.nodeDisplayTitle(node)) · \(node.protocolType.displayName)"
            case .disconnecting:
                return "正在断开 \(appState.settings.nodeDisplayTitle(node))"
            case .disconnected, .error:
                break
            }
        }
        return "未连接节点"
    }

}
