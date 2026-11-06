import AppKit
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var appState: AppState
    private var connection: ConnectionManager { appState.connection }
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("quickSwitchMergeCountries") private var quickSwitchMergeCountries = true
    @State private var showsClearAutoSelectConfirmation = false
    @State private var showsQuickSwitchExplanation = false

    var body: some View {
        let quickSwitchNodes = quickSwitchNodes
        let quickSwitchNodeIDs = quickSwitchNodes.map(\.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                heroCard
                pendingConfigBanner
                DashboardTrafficStats(chrome: cardChrome)
                quickSwitchCard(nodes: quickSwitchNodes)
                recentCard
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(pageBackground)
        .background {
            Button("打开设置") { appState.selectedSidebar = .settings }
                .keyboardShortcut("o", modifiers: .control)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .frame(width: 0, height: 0)
        }
        .task { appState.refreshNetworkName() }
        .task(id: quickSwitchNodeIDs) {
            await appState.refreshMissingExitTypes(nodeIDs: quickSwitchNodeIDs)
        }
        .alert("清除自动优选列表？", isPresented: $showsClearAutoSelectConfirmation) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) {
                Task {
                    await appState.clearAutoSelectResults()
                }
            }
            .disabled(appState.isClearingAutoSelectResults || appState.testManager.isTesting || appState.testManager.isProbingApps)
        } message: {
            Text("将先断开当前连接，再清除所有节点的测速和应用连通结果。节点和订阅会保留。重新测试后，可用节点将按当前规则重新加入自动优选列表。")
        }
    }

    // MARK: - 连接卡

    private let heroInset: CGFloat = 22
    private let connectionButtonSize: CGFloat = 120

    private var heroCard: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    Image("AppLogo")
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 44, height: 44)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("跃界")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(heroPrimary)
                        Text("HopWorld")
                            .font(.subheadline)
                            .foregroundStyle(heroSecondary)
                    }
                }

                if let node = appState.activeOrLastNode {
                    HStack(alignment: .center, spacing: 8) {
                        Text(FlagResolver.flag(for: CountryResolver.effectiveCode(for: node)))
                            .font(.system(size: 26))
                        Text(CountryResolver.displayName(for: CountryResolver.effectiveCode(for: node)))
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(heroPrimary)
                            .lineLimit(1)
                    }
                    .padding(.top, 6)

                    HStack(spacing: 6) {
                        if let failover = connection.failoverStatus, !failover.isEmpty {
                            Text(failover)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(failover)
                        } else if connection.state.status == .connected,
                                  connection.state.exitIP == nil || connection.state.lastError != nil {
                            let warning = connection.state.lastError ?? "已连接，暂未获取到出口 IP"
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                                .help(warning)
                        } else {
                            ExitMetadataLabels(city: connection.state.exitCity,
                                               networkOperator: connection.state.exitOperator,
                                               asn: connection.state.exitASN,
                                               countryCode: appState.currentNode?.exitMetadata?.countryCode ?? connection.state.currentCountryCode,
                                               localizedCity: appState.currentNode?.exitMetadata?.localizedCity)
                            if showsLastSelectedNode {
                                Text("上次选中")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(heroPrimary.opacity(0.08), in: Capsule())
                            }
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(heroSecondary)

                    HStack(spacing: 14) {
                        Label(node.protocolType.displayName, systemImage: "globe")
                        Label(nodeLatencyText, systemImage: "clock")
                    }
                    .font(.caption)
                    .foregroundStyle(heroSecondary)
                    .labelStyle(HeroMetaLabelStyle())
                } else {
                    Text(connection.state.status.displayName)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(heroPrimary)
                        .padding(.top, 6)
                    Text(heroEmptyDetail)
                        .font(.subheadline)
                        .foregroundStyle(heroSecondary)
                        .lineLimit(2)
                }

            }
            .frame(maxWidth: .infinity, alignment: .leading)

            connectionButton
        }
        // 按钮到上、下、右的边距同为 heroInset，不再额外拉高卡片。
        .padding(heroInset)
        .frame(maxWidth: .infinity, minHeight: connectionButtonSize + heroInset * 2, alignment: .leading)
        .background { heroBackground }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.25 : 0.06), radius: 14, y: 6)
    }

    private var connectionButton: some View {
        Button {
            Task { await appState.toggleConnection() }
        } label: {
            VStack(spacing: 4) {
                if connection.state.status == .connecting || connection.state.status == .disconnecting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .frame(height: 32)
                } else {
                    Image(systemName: "power")
                        .font(.system(size: 30, weight: .medium))
                        .frame(height: 32)
                }
                Text(connection.state.status.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(.white)
            .frame(width: connectionButtonSize, height: connectionButtonSize)
            .background { connectionButtonFill }
            .clipShape(Circle())
            .overlay {
                Circle()
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom),
                        lineWidth: 1.5
                    )
                    .padding(1)
            }
            .shadow(color: connectionButtonShadow.opacity(0.28), radius: 8, y: 0)
        }
        .buttonStyle(.plain)
        .disabled(connection.state.status == .disconnecting)
        .opacity(connection.state.status == .disconnecting ? 0.72 : 1)
        .help(isConnectionActive ? "断开当前连接" : "按当前优选规则连接")
        .accessibilityLabel(connection.state.status.displayName)
        .accessibilityHint(isConnectionActive ? "断开当前连接" : "按当前优选规则连接")
    }

    private var connectionButtonFill: some View {
        LinearGradient(colors: connectionButtonColors, startPoint: .top, endPoint: .bottom)
    }

    private var connectionButtonColors: [Color] {
        switch connection.state.status {
        case .connected, .connecting, .disconnecting:
            return [Color(red: 1, green: 0.42, blue: 0.38), Color(red: 0.90, green: 0.16, blue: 0.18)]
        case .error:
            return [Color(red: 1, green: 0.62, blue: 0.28), Color(red: 0.90, green: 0.38, blue: 0.12)]
        case .disconnected:
            return [Color(red: 0.38, green: 0.66, blue: 0.98), Color(red: 0.18, green: 0.45, blue: 0.90)]
        }
    }

    private var connectionButtonShadow: Color {
        switch connection.state.status {
        case .connected, .connecting, .disconnecting: return Color(red: 0.90, green: 0.16, blue: 0.18)
        case .error: return .orange
        case .disconnected: return Color(red: 0.18, green: 0.45, blue: 0.90)
        }
    }

    private var heroBackground: some View {
        ZStack(alignment: .trailing) {
            LinearGradient(
                colors: [
                    colorScheme == .dark
                        ? Color(red: 0.075, green: 0.11, blue: 0.17)
                        : Color(red: 0.91, green: 0.96, blue: 1),
                    colorScheme == .dark
                        ? Color(red: 0.11, green: 0.19, blue: 0.28)
                        : Color(red: 0.78, green: 0.89, blue: 0.98)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            GeometryReader { geo in
                Image("HeroWorldMap")
                    .resizable()
                    .scaledToFit()
                    .opacity(colorScheme == .dark ? 0.24 : 0.58)
                    .accessibilityHidden(true)
                    .frame(height: geo.size.height * 0.94)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black.opacity(0.45), location: 0.14),
                                .init(color: .black, location: 0.32)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.trailing, 4)
            }
        }
    }

    private var heroPrimary: Color {
        colorScheme == .dark
            ? Color(red: 0.92, green: 0.95, blue: 0.99)
            : Color(red: 0.08, green: 0.12, blue: 0.18)
    }
    private var heroSecondary: Color {
        colorScheme == .dark
            ? Color(red: 0.68, green: 0.76, blue: 0.86)
            : Color(red: 0.25, green: 0.32, blue: 0.42)
    }

    private var isConnectionActive: Bool {
        switch connection.state.status {
        case .connected, .connecting, .disconnecting: return true
        case .disconnected, .error: return false
        }
    }

    private var heroEmptyDetail: String {
        if connection.state.status == .error,
           let error = connection.state.lastError, !error.isEmpty {
            return error
        }
        return "选择节点后开始"
    }

    private var nodeLatencyText: String {
        connection.state.dashboardLatencyText(lastTestLatency: appState.activeOrLastNode?.lastLatency)
    }

    @ViewBuilder
    private var pendingConfigBanner: some View {
        if let node = appState.currentNode, node.pendingConfigUpdate,
           connection.state.status == .connected {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 29, height: 29)
                    .background(Color.orange.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("当前节点「\(appState.settings.nodeDisplayTitle(node))」参数已更新")
                        .font(.subheadline.weight(.semibold))
                    Text("仍使用连接中的旧配置；可立即应用或断开后再连以使用新参数。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("下次连接") {
                    appState.dismissPendingConfigUpdate()
                    appState.statusBanner = "已保留新参数，下次连接时生效"
                }
                Button("立即应用") {
                    Task { await appState.applyPendingConfigForCurrentNode() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(14)
            .background(cardChrome)
        }
    }

    // MARK: - 出口与流量

    // MARK: - 快速切换

    private let quickSwitchRowHeight: CGFloat = 46

    private func quickSwitchCard(nodes: [ProxyNode]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("快速切换")
                        .font(.system(size: 16, weight: .semibold))
                    Button { showsQuickSwitchExplanation = true } label: {
                        Image(systemName: "info.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("查看快速切换排序说明")
                    .accessibilityLabel("快速切换排序说明")
                    .popover(isPresented: $showsQuickSwitchExplanation) {
                        Text(quickSwitchSortDescription)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(16)
                            .frame(width: 320, alignment: .leading)
                    }
                    Text(quickSwitchCountsText(rankedNodes: nodes))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("可连：符合当前自动优选条件的节点；过滤：测速可用或应用曾连通，但被国家、速度、收藏、启用状态或最新连通结果排除的节点；屏蔽单独统计。")
                    Text(quickSwitchLastUpdatedText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help("最近一次节点测速或应用连通测试的更新时间")
                    Spacer(minLength: 8)
                    labeledSwitch("国家", isOn: $quickSwitchMergeCountries)
                        .help("开启后按国家合并，关闭后逐个显示节点")
                    labeledSwitch("自动优选", isOn: Binding(
                        get: { connection.state.autoSelectEnabled },
                        set: {
                            connection.state.autoSelectEnabled = $0
                            appState.persist()
                        }
                    ))
                    refreshButton
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .contextMenu {
                Button("重新测速") { refreshQuickSwitch() }
                    .disabled(!canRefreshQuickSwitch)
                Button("清除自动优选列表", role: .destructive) {
                    showsClearAutoSelectConfirmation = true
                }
                .disabled(appState.isClearingAutoSelectResults || appState.testManager.isTesting || appState.testManager.isProbingApps)
            }

            quickSwitchEntries(nodes: nodes)
        }
        .background(cardChrome)
    }

    private func labeledSwitch(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private var refreshButton: some View {
        Button(action: refreshQuickSwitch) {
            Group {
                if appState.testManager.isTesting || appState.isClearingAutoSelectResults {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canRefreshQuickSwitch)
        .help("重新测速全部节点。右键可清除自动优选列表")
        .accessibilityLabel("重新测速")
    }

    private var canRefreshQuickSwitch: Bool {
        appState.testManager.canRetest
            && !appState.testManager.isProbingApps
            && !appState.isClearingAutoSelectResults
            && !retestTargets.isEmpty
    }

    private var retestTargets: [ProxyNode] {
        appState.nodes.filter { $0.enabled && !$0.pendingRemoval }
    }

    private func refreshQuickSwitch() {
        let targets = retestTargets
        guard canRefreshQuickSwitch else { return }
        Task { await appState.testNodes(targets) }
    }

    @ViewBuilder
    private func quickSwitchEntries(nodes: [ProxyNode]) -> some View {
        if appState.countryGroups.isEmpty {
            quickSwitchEmptyGuidance
        } else {
            let groups = quickSwitchMergeCountries ? quickSwitchGroups(from: nodes) : []
            let entryCount = quickSwitchMergeCountries ? groups.count : nodes.count
            if entryCount == 0 {
                quickSwitchEmptyGuidance
            } else {
                QuickSwitchRows(mergeCountries: quickSwitchMergeCountries,
                                groups: groups,
                                nodes: nodes,
                                liveNodeID: liveNodeID,
                                rowHeight: quickSwitchRowHeight)
                Color.clear.frame(height: 6)
            }
        }
    }

    private var quickSwitchEmptyGuidance: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("暂无可切换节点")
                .font(.callout.weight(.semibold))
            Text(appState.noConnectionCandidatesMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("前往测试") { appState.selectedSidebar = .testing }
                Button("添加订阅") { appState.showAddSubscription = true }
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var quickSwitchSortDescription: String {
        var priorities: [String] = []
        switch appState.settings.favoritePreference {
        case .preferFavorites: priorities.append("收藏优先")
        case .favoritesOnly: priorities.append("仅收藏")
        case .all: break
        }
        if appState.settings.autoAppProbeUsableNodes {
            priorities.insert("按应用优先顺序逐项比较连通结果", at: 0)
        }
        priorities.append("测速延迟从低到高")
        let description = "排序：" + priorities.joined(separator: " → ")
        return quickSwitchMergeCountries ? description + "；标识和延迟对应各国首选节点" : description
    }

    private func quickSwitchCountsText(rankedNodes: [ProxyNode]) -> String {
        let counts = appState.settings.quickSwitchCounts(for: appState.nodes)
        let countries: String
        if quickSwitchMergeCountries {
            let countryCount = Set(rankedNodes.lazy
                .filter { !appState.settings.isTemporarilyBlocked($0.id) }
                .map { CountryResolver.effectiveCode(for: $0) }).count
            countries = "\(countryCount) 国 · "
        } else {
            countries = ""
        }
        return "\(countries)可连 \(counts.available) · 过滤 \(counts.filtered) · 屏蔽 \(counts.blocked)"
    }

    private var quickSwitchLastUpdatedText: String {
        let updatedAt = appState.nodes
            .filter { !$0.pendingRemoval }
            .flatMap { [$0.lastTestDate, $0.lastAppProbeDate].compactMap { $0 } }
            .max()
        guard let updatedAt else { return "尚未更新" }
        return "上次更新：\(Self.updateStamp.string(from: updatedAt))"
    }

    private var quickSwitchNodes: [ProxyNode] {
        let ranked = appState.automaticallyRankedNodes(appState.nodes, includingTemporarilyBlocked: true)
        let visibleIDs = Set(ranked.map(\.id))
        // Keep blocked nodes reachable for unblocking even when later tests fail.
        return ranked + appState.nodes.filter {
            !$0.pendingRemoval && appState.settings.isTemporarilyBlocked($0.id) && !visibleIDs.contains($0.id)
        }
    }

    private func quickSwitchGroups(from nodes: [ProxyNode]) -> [CountryGroup] {
        let settings = appState.settings
        let rankedNodes = nodes.filter { !settings.isTemporarilyBlocked($0.id) }
            + nodes.filter { settings.isTemporarilyBlocked($0.id) }
        let knownGroups = Dictionary(appState.countryGroups.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })
        var order: [String] = []
        var buckets: [String: [ProxyNode]] = [:]
        for node in rankedNodes {
            let code = CountryResolver.effectiveCode(for: node)
            guard knownGroups[code] != nil else { continue }
            if buckets[code] == nil { order.append(code) }
            buckets[code, default: []].append(node)
        }
        return order.compactMap { code in
            guard let group = knownGroups[code] else { return nil }
            return CountryGroup(code: group.code, name: group.name, flag: group.flag, nodes: buckets[code] ?? [])
        }
    }

    // MARK: - 最近使用

    private var recentCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("最近使用")
                .font(.system(size: 16, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 4)

            if appState.recentNodes.isEmpty {
                emptyRow("暂无")
            } else {
                ForEach(Array(appState.recentNodes.enumerated()), id: \.element.id) { index, node in
                    if index > 0 { Divider().padding(.leading, 16) }
                    Button {
                        appState.requestConnect(to: node)
                    } label: {
                        HStack(spacing: 12) {
                            Text(appState.settings.nodeDisplayTitle(node))
                                .lineLimit(1)
                            NodeGroupLabel(name: node.groupName(subscriptions: appState.subscriptions))
                            Spacer()
                            Text(node.latencyText)
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("查看") { appState.viewingNodeID = node.id }
                    }
                }
                Color.clear.frame(height: 4)
            }
        }
        .background(cardChrome)
    }

    // MARK: - 状态与样式

    private var showsLiveSelection: Bool {
        switch connection.state.status {
        case .connected, .connecting, .disconnecting:
            return appState.currentNode != nil
        case .disconnected, .error:
            return false
        }
    }

    private var showsLastSelectedNode: Bool {
        !showsLiveSelection && appState.recentNodes.first != nil
    }

    /// 当前已连接的节点。
    private var liveNodeID: UUID? {
        showsLiveSelection ? appState.currentNode?.id : nil
    }

    private var cardChrome: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(cardFill)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.22 : 0.05), radius: 10, y: 3)
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.05), lineWidth: 0.5)
            }
    }

    private var cardFill: Color {
        colorScheme == .dark ? Color(nsColor: .controlBackgroundColor) : .white
    }

    private var pageBackground: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color(red: 0.07, green: 0.09, blue: 0.12), Color(red: 0.05, green: 0.07, blue: 0.10)]
                : [Color(red: 0.94, green: 0.97, blue: 1), Color(red: 0.86, green: 0.93, blue: 0.98)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 14)
            .padding(.vertical, 16)
    }

    private static let updateStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()
}

/// Fixed-height rows rendered only around the visible window; the hosting view cannot be lazy on its own.
private struct QuickSwitchList<Content: View>: NSViewRepresentable {
    let rowCount: Int
    let rowHeight: CGFloat
    let verticalPadding: CGFloat
    let focusIndex: Int?
    let content: (Range<Int>) -> Content

    init(rowCount: Int, rowHeight: CGFloat, verticalPadding: CGFloat, focusIndex: Int? = nil,
         @ViewBuilder content: @escaping (Range<Int>) -> Content) {
        self.rowCount = rowCount
        self.rowHeight = rowHeight
        self.verticalPadding = verticalPadding
        self.focusIndex = focusIndex
        self.content = content
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ScrollContainer {
        let scrollView = ScrollContainer()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        let rootView = root(context: context)
        context.coordinator.updateWindow()
        let hosting = NSHostingView(rootView: rootView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = hosting
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            hosting.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            hosting.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observe(scrollView.contentView)
        return scrollView
    }

    func updateNSView(_ nsView: ScrollContainer, context: Context) {
        (nsView.documentView as? NSHostingView<Root>)?.rootView = root(context: context)
        let coordinator = context.coordinator
        coordinator.focusIndex = focusIndex
        DispatchQueue.main.async { coordinator.updateWindow() }
    }

    static func dismantleNSView(_ nsView: ScrollContainer, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    private func root(context: Context) -> Root {
        let coordinator = context.coordinator
        coordinator.rowCount = rowCount
        coordinator.rowHeight = rowHeight
        coordinator.verticalPadding = verticalPadding
        return Root(window: coordinator.window, rowCount: rowCount, rowHeight: rowHeight,
                    verticalPadding: verticalPadding, content: content, environment: context.environment)
    }

    final class VisibleWindow: ObservableObject {
        @Published var range: Range<Int> = 0..<0
    }

    final class Coordinator {
        let window = VisibleWindow()
        var rowCount = 0
        var rowHeight: CGFloat = 1
        var verticalPadding: CGFloat = 0
        var focusIndex: Int?
        private var didApplyFocus = false
        private weak var clipView: NSClipView?
        private var observer: NSObjectProtocol?
        private let overscan = 6

        func observe(_ clipView: NSClipView) {
            self.clipView = clipView
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main
            ) { [weak self] _ in self?.updateWindow() }
            updateWindow()
        }

        func stopObserving() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }

        func updateWindow() {
            let bounds = clipView?.bounds ?? .zero
            let height = bounds.height > 0 ? bounds.height : rowHeight * 8
            let first = Int(((bounds.minY - verticalPadding) / rowHeight).rounded(.down)) - overscan
            let last = Int(((bounds.minY + height - verticalPadding) / rowHeight).rounded(.up)) + overscan
            let lower = min(max(0, first), rowCount)
            let range = lower..<min(max(lower, last), rowCount)
            if window.range != range { window.range = range }
            applyFocusIfNeeded()
        }

        /// Bring the recalled row on screen once. Later scrolling stays with the user.
        private func applyFocusIfNeeded() {
            guard !didApplyFocus, let index = focusIndex, let clipView, rowHeight > 0 else { return }
            let visibleHeight = clipView.bounds.height
            guard visibleHeight > 0 else { return }
            let documentHeight = clipView.documentView?.frame.height ?? 0
            let visibleRows = max(1, Int((visibleHeight / rowHeight).rounded(.down)))
            if index >= visibleRows, documentHeight <= visibleHeight + 1 { return }
            didApplyFocus = true
            guard index >= visibleRows else { return }
            let maxY = max(0, documentHeight - visibleHeight)
            let y = min(maxY, max(0, verticalPadding + CGFloat(index - 1) * rowHeight))
            clipView.scroll(to: NSPoint(x: 0, y: y))
            clipView.enclosingScrollView?.reflectScrolledClipView(clipView)
        }
    }

    struct Root: View {
        @ObservedObject var window: VisibleWindow
        let rowCount: Int
        let rowHeight: CGFloat
        let verticalPadding: CGFloat
        let content: (Range<Int>) -> Content
        let environment: EnvironmentValues

        var body: some View {
            let range = window.range.clamped(to: 0..<rowCount)
            VStack(spacing: 0) {
                Color.clear.frame(height: verticalPadding + CGFloat(range.lowerBound) * rowHeight)
                content(range)
                Color.clear.frame(height: verticalPadding + CGFloat(rowCount - range.upperBound) * rowHeight)
            }
            .environment(\.self, environment)
        }
    }

    final class ScrollContainer: NSScrollView {
        override func scrollWheel(with event: NSEvent) {
            guard let documentView else { return }
            let visible = contentView.bounds
            let document = documentView.bounds
            // AppKit forwards wheel events to the page at either edge unless consumed here.
            guard (event.scrollingDeltaY > 0 && visible.minY > document.minY)
                || (event.scrollingDeltaY < 0 && visible.maxY < document.maxY) else { return }
            super.scrollWheel(with: event)
        }
    }
}

/// 单击选中只刷新这里，不让整页重新排序节点。
private struct QuickSwitchRows: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    let mergeCountries: Bool
    let groups: [CountryGroup]
    let nodes: [ProxyNode]
    let liveNodeID: UUID?
    let rowHeight: CGFloat
    /// 单击选中、尚未连接的节点。未连接时为空则用上次连接。
    @State private var pickedID: UUID?

    var body: some View {
        let marker = makeMarker()
        let entryCount = mergeCountries ? groups.count : nodes.count
        QuickSwitchList(rowCount: entryCount, rowHeight: rowHeight, verticalPadding: 8,
                        focusIndex: liveNodeID == nil ? focusRow(for: marker.recalledNodeID) : nil) { range in
            if mergeCountries {
                ForEach(range, id: \.self) { index in
                    let group = groups[index]
                    VStack(spacing: 0) {
                        if index > 0,
                           marker.country(group.code) == .none,
                           marker.country(groups[index - 1].code) == .none {
                            Divider().padding(.leading, 90)
                        }
                        countryRow(group: group, position: index + 1, mark: marker.country(group.code))
                    }
                    .frame(height: rowHeight)
                    .id(group.id)
                }
            } else {
                ForEach(range, id: \.self) { index in
                    let node = nodes[index]
                    VStack(spacing: 0) {
                        if index > 0,
                           marker.node(node.id) == .none,
                           marker.node(nodes[index - 1].id) == .none {
                            Divider().padding(.leading, 90)
                        }
                        nodeRow(node: node, position: index + 1, mark: marker.node(node.id))
                    }
                    .frame(height: rowHeight)
                    .id(node.id)
                }
            }
        }
        .id(mergeCountries)
        .frame(height: CGFloat(min(entryCount, 8)) * rowHeight + 16)
    }

    /// 非连接时是上次连接；已连接后单击了别的节点时是那个节点。
    private func makeMarker() -> QuickSwitchMarker {
        let recalledID = quickSwitchRecalledNodeID(
            liveNodeID: liveNodeID,
            pickedID: pickedID,
            recentNodeID: appState.recentNodes.first?.id,
            lastConnectedNodeID: appState.lastConnectedNodeID
        )
        var liveCountry: String?
        var recalledCountry: String?
        if mergeCountries {
            for node in appState.nodes where node.id == liveNodeID || node.id == recalledID {
                let code = CountryResolver.effectiveCode(for: node)
                if node.id == liveNodeID { liveCountry = code }
                if node.id == recalledID { recalledCountry = code }
            }
        }
        return QuickSwitchMarker(liveNodeID: liveNodeID, recalledNodeID: recalledID,
                                 liveCountry: liveCountry, recalledCountry: recalledCountry)
    }

    private func focusRow(for recalledID: UUID?) -> Int? {
        guard let recalledID else { return nil }
        if mergeCountries {
            return groups.firstIndex { group in group.nodes.contains { $0.id == recalledID } }
        }
        return nodes.firstIndex { $0.id == recalledID }
    }

    /// 单击用同时手势，避免等待双击超时后才显示选中。
    private func pick(_ id: UUID?) -> some Gesture {
        TapGesture().onEnded { pickedID = id }
    }

    private func ordinal(_ position: Int) -> some View {
        Text("\(position)")
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: 28, alignment: .trailing)
            .accessibilityLabel("第\(position)项")
    }

    private func countryRow(group: CountryGroup, position: Int, mark rowMark: QuickSwitchMark) -> some View {
        let allBlocked = group.nodes.allSatisfy { appState.settings.isTemporarilyBlocked($0.id) }
        return HStack(spacing: 10) {
            ordinal(position)
            Text(group.flag)
                .font(.system(size: 20))
                .frame(width: 28)
            Text(group.name)
                .font(.body.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let preferredNode = group.nodes.first {
                priorityBadges(for: preferredNode)
            }
            Text(LatencyFormat.display(group.nodes.first?.lastLatency))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Text("\(group.availableCount)/\(group.nodes.filter { $0.enabled && !$0.pendingRemoval }.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .modifier(QuickSwitchRowStyle(mark: rowMark, scheme: colorScheme))
        .saturation(allBlocked ? 0 : 1)
        .opacity(allBlocked ? 0.5 : 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard !allBlocked else { showBlockedNodeGuidance(); return }
            Task { await appState.connectCountry(group.code) }
        }
        .simultaneousGesture(pick(group.nodes.first?.id))
        .contextMenu {
            ForEach(group.nodes) { node in
                Menu(appState.settings.nodeDisplayTitle(node) + " · " + node.groupName(subscriptions: appState.subscriptions) + (appState.settings.isTemporarilyBlocked(node.id) ? "（临时屏蔽）" : "")) {
                    Button("查看") { appState.viewingNodeID = node.id }
                    Divider()
                    temporaryBlockButton(for: node)
                }
            }
        }
        .help("单击选中，双击切换到\(group.name)节点")
        .accessibilityValue(rowMark.accessibilityValue)
    }

    private func nodeRow(node: ProxyNode, position: Int, mark rowMark: QuickSwitchMark) -> some View {
        let isBlocked = appState.settings.isTemporarilyBlocked(node.id)
        let connection = appState.connection
        let country = CountryResolver.displayName(for: CountryResolver.effectiveCode(for: node))
        let exitType = connection.state.status == .connected && connection.state.currentNodeID == node.id
            ? connection.state.exitIPType ?? node.exitMetadata?.networkType : node.exitMetadata?.networkType
        let groupName = node.groupName(subscriptions: appState.subscriptions)
        return HStack(spacing: 10) {
            ordinal(position)
            Text(FlagResolver.flag(for: CountryResolver.effectiveCode(for: node)))
                .font(.system(size: 20))
                .frame(width: 28)
            Text(country)
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .layoutPriority(1)
            Text(exitType?.displayName ?? "未知")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("出口 IP 属性：\(exitType?.displayName ?? "未知")")
                .accessibilityLabel("出口 IP 属性：\(exitType?.displayName ?? "未知")")
            NodeGroupLabel(name: groupName)
            Spacer(minLength: 8)
            priorityBadges(for: node)
            if isBlocked {
                Image(systemName: "nosign")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("临时屏蔽")
                    .help("临时屏蔽：右键可解除，自动连接将跳过此节点")
            }
            Text(LatencyFormat.display(node.lastLatency))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .modifier(QuickSwitchRowStyle(mark: rowMark, scheme: colorScheme))
        .contentShape(Rectangle())
        .saturation(isBlocked ? 0 : 1)
        .opacity(isBlocked ? 0.5 : 1)
        .contextMenu {
            Button("查看") { appState.viewingNodeID = node.id }
            Divider()
            temporaryBlockButton(for: node)
        }
        .onTapGesture(count: 2) {
            guard !isBlocked else { showBlockedNodeGuidance(); return }
            appState.requestConnect(to: node)
        }
        .simultaneousGesture(pick(node.id))
        .help("单击选中，双击切换到\(appState.settings.nodeDisplayTitle(node))；所属组：\(groupName)")
        .accessibilityValue(isBlocked ? "临时屏蔽，自动连接已排除" : rowMark.accessibilityValue)
    }

    @ViewBuilder
    private func priorityBadges(for node: ProxyNode) -> some View {
        if node.isFavorite {
            Image(systemName: "star.fill")
                .font(.caption)
                .foregroundStyle(.yellow)
                .accessibilityLabel("已收藏")
                .help(appState.settings.favoritePreference == .all ? "已收藏；当前不优先收藏" : "已收藏；当前优先使用收藏节点")
        }
        HStack(spacing: 4) {
            ForEach(Array(appState.settings.automaticAppProbeTargets.prefix(8))) { target in
                AppProbeIcon(target: target, passed: node.lastAppProbePassedIDs?.contains(target.id) == true, size: 18)
            }
        }
    }

    private func showBlockedNodeGuidance() {
        if appState.automaticallyRankedNodes(appState.nodes).isEmpty {
            appState.presentNoConnectionCandidates()
        } else {
            appState.flashToast("节点已临时屏蔽，请右键解除屏蔽或选择其它可用节点")
        }
    }

    private func temporaryBlockButton(for node: ProxyNode) -> some View {
        Button(appState.settings.isTemporarilyBlocked(node.id) ? "关闭临时屏蔽" : "临时屏蔽") {
            appState.toggleTemporaryBlock(for: node.id)
        }
    }
}

private struct QuickSwitchMarker {
    let liveNodeID: UUID?
    let recalledNodeID: UUID?
    let liveCountry: String?
    let recalledCountry: String?

    func node(_ id: UUID) -> QuickSwitchMark {
        if id == liveNodeID { return .current }
        if id == recalledNodeID { return .recalled }
        return .none
    }

    func country(_ code: String) -> QuickSwitchMark {
        if code == liveCountry { return .current }
        if code == recalledCountry { return .recalled }
        return .none
    }
}

private enum QuickSwitchMark {
    case none
    /// 未连接时的上次连接，或已连接后单击的其它节点。
    case recalled
    /// 当前已连接。
    case current

    var accessibilityValue: String {
        switch self {
        case .none: return "未选中"
        case .recalled: return "上次选中"
        case .current: return "当前已连接"
        }
    }
}

/// 选中行是卡片内的圆角框，不贴到左右边缘。
private struct QuickSwitchRowStyle: ViewModifier {
    var mark: QuickSwitchMark
    var scheme: ColorScheme

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                if mark != .none {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(stroke, lineWidth: mark == .current ? 1.5 : 1)
                }
            }
            .modifier(WarmCardHover(cornerRadius: 10, fill: mark == .none ? .clear : fill))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
    }

    private var fill: Color {
        if scheme == .dark {
            return Color.accentColor.opacity(mark == .current ? 0.28 : 0.12)
        }
        return mark == .current
            ? Color(red: 0.86, green: 0.93, blue: 0.99)
            : Color(red: 0.94, green: 0.97, blue: 1)
    }

    private var stroke: Color {
        if scheme == .dark {
            return Color.accentColor.opacity(mark == .current ? 0.9 : 0.55)
        }
        return mark == .current
            ? Color(red: 0.32, green: 0.58, blue: 0.95)
            : Color(red: 0.55, green: 0.72, blue: 0.92)
    }
}

private struct HeroMetaLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

struct ExitMetadataLabels: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var cityLibrary = ChineseCityLibrary.shared
    let city: String?
    let networkOperator: String?
    let asn: String?
    var countryCode: String? = nil
    var localizedCity: String? = nil

    var body: some View {
        let showChinese = appState.settings.showChineseNodeMetadata
        let cityText = ExitMetadataLocalization.city(city, countryCode: countryCode, localizedCity: localizedCity, showChinese: showChinese)
        let operatorText = ExitMetadataLocalization.networkOperator(networkOperator, showChinese: showChinese)
        HStack(spacing: 14) {
            Label(cityText, systemImage: "mappin.and.ellipse")
                .help("出口城市：" + ExitMetadataLocalization.help(raw: city, displayed: cityText, showChinese: showChinese))
                .accessibilityLabel("出口城市：\(cityText)")
            Label(operatorText, systemImage: "building.2")
                .truncationMode(.middle)
                .help("出口运营商：" + ExitMetadataLocalization.help(raw: networkOperator, displayed: operatorText, showChinese: showChinese))
                .accessibilityLabel("出口运营商：\(operatorText)")
            Text(asn ?? "ASN 未知")
                .fixedSize()
                .accessibilityLabel("出口 ASN：\(asn ?? "未知")")
        }
        .lineLimit(1)
        .labelStyle(HeroMetaLabelStyle())
    }
}

// Keep 1-second traffic updates out of the quick-switch sorting and page layout.
private struct DashboardTrafficStats<Chrome: View>: View {
    @EnvironmentObject private var connection: ConnectionManager
    let chrome: Chrome

    var body: some View {
        HStack(spacing: 12) {
            statCard(symbol: "mappin", tint: Color(red: 0.18, green: 0.72, blue: 0.44),
                     title: exitIPTitle, value: connection.state.exitIP ?? "—")
                .frame(minWidth: 190)
                .help("\(exitIPTitle)\n属性由 IPQuery 数据库识别，仅供参考；家庭住宅为排除已知机房、移动网络及代理标记后的推测。")
            statCard(symbol: "globe", tint: Color(red: 0.45, green: 0.38, blue: 0.92),
                     title: "出口国家", value: connection.state.exitCountry ?? "—")
            statCard(symbol: "arrow.down", tint: Color(red: 0.20, green: 0.48, blue: 0.95),
                     title: "下载速度", value: speedText(connection.state.downloadMbps),
                     total: ("下载总量", byteText(connection.state.sessionDownloadBytes)))
            statCard(symbol: "arrow.up", tint: Color(red: 0.96, green: 0.55, blue: 0.18),
                     title: "上传速度", value: speedText(connection.state.uploadMbps),
                     total: ("上传总量", byteText(connection.state.sessionUploadBytes)))
        }
    }

    private var exitIPTitle: String {
        guard connection.state.exitIP != nil else { return "出口 IP" }
        return "出口 IP（\(connection.state.exitIPType?.displayName ?? "未知")）"
    }

    private func statCard(symbol: String, tint: Color, title: String, value: String,
                          total: (title: String, value: String)? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(tint.gradient, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                if let total {
                    ViewThatFits(in: .horizontal) {
                        VStack(alignment: .leading, spacing: 3) {
                            trafficRow(title: title, value: value)
                            trafficRow(title: total.title, value: total.value)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 3) {
                            trafficRow(title: "速度", value: value)
                            trafficRow(title: "总量", value: total.value)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(title) \(value)，\(total.title) \(total.value)")
                } else {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(value)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(chrome)
    }

    private func trafficRow(title: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .accessibilityElement(children: .combine)
    }

    private func speedText(_ mbps: Double) -> String {
        String(format: "%.1f Mbps", mbps)
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }

}
