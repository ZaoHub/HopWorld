import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var appState: AppState
    /// Observe connection directly so live traffic updates without rebuilding MenuBarExtra via AppState.
    @EnvironmentObject private var connection: ConnectionManager
    @State private var isConnectionButtonHovered = false
    @State private var connectionButtonPulse = false
    @AppStorage("quickSwitchMergeCountries") private var quickSwitchMergeCountries = true
    @State private var showsAllQuickSwitchCountries = false
    @State private var showsClearAutoSelectConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                pendingConfigBanner
                metrics
                quickSwitch
                recent
            }
            .padding(24)
        }
        .safeAreaPadding(.top, 8)
        .background(pageBackground)
        .alert("清除自动优选列表？", isPresented: $showsClearAutoSelectConfirmation) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) {
                Task {
                    await appState.clearAutoSelectResults()
                    showsAllQuickSwitchCountries = false
                }
            }
            .disabled(appState.isClearingAutoSelectResults || appState.testManager.isTesting || appState.testManager.isProbingApps)
        } message: {
            Text("将先断开当前连接，再清除所有节点的测速和应用连通结果。节点和订阅会保留。重新测试后，可用节点将按当前规则重新加入自动优选列表。")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("跃界")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("HopWorld")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(countryTitle)
                        .font(.system(size: 42, weight: .semibold, design: .rounded))
                    Text(appState.currentNode?.displayTitle ?? "尚未选择节点")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Label(appState.currentNode?.protocolType.displayName ?? "—", systemImage: "network")
                        Label(LatencyFormat.seconds(connection.state.latency), systemImage: "timer")
                    }
                    .foregroundStyle(.secondary)
                }

                Spacer()

                ZStack {
                    Button {
                        Task { await appState.toggleConnection() }
                    } label: {
                        VStack(spacing: 9) {
                            if connection.state.status == .connecting ||
                                connection.state.status == .disconnecting {
                                ProgressView()
                                    .controlSize(.regular)
                                    .tint(.white)
                                    .scaleEffect(1.3)
                                    .frame(width: 34, height: 34)
                            } else {
                                Image(systemName: connectionButtonSymbol)
                                    .font(.system(size: 32, weight: .semibold))
                                    .frame(width: 34, height: 34)
                            }

                            Text(connection.state.status.displayName)
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.white)
                        .frame(width: 136, height: 136)
                        .background(connectionButtonGradient)
                        .clipShape(Circle())
                        .overlay {
                            Circle()
                                .strokeBorder(.white.opacity(isConnectionButtonHovered ? 0.34 : 0.2), lineWidth: 1)
                        }
                        .overlay {
                            if connection.state.status == .connecting {
                                Circle()
                                    .stroke(Color.white.opacity(connectionButtonPulse ? 0.08 : 0.42), lineWidth: 3)
                                    .scaleEffect(connectionButtonPulse ? 1.14 : 0.92)
                            }
                        }
                        .shadow(
                            color: connectionButtonShadowColor.opacity(connectionButtonPulse ? 0.42 : (isConnectionButtonHovered ? 0.34 : 0.22)),
                            radius: connectionButtonPulse ? 15 : (isConnectionButtonHovered ? 10 : 7),
                            y: isConnectionButtonHovered ? 5 : 3
                        )
                        .scaleEffect(connectionButtonPulse ? 1.035 : (isConnectionButtonHovered ? 1.025 : 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(connection.state.status == .disconnecting)
                    .opacity(connection.state.status == .disconnecting ? 0.72 : 1)
                    .offset(y: -32)
                    .onHover { hovering in
                        withAnimation(.easeOut(duration: 0.16)) {
                            isConnectionButtonHovered = hovering
                        }
                    }
                    .task(id: connection.state.status) {
                        connectionButtonPulse = false
                        guard connection.state.status == .connecting else { return }
                        while !Task.isCancelled {
                            withAnimation(.easeInOut(duration: 0.75)) {
                                connectionButtonPulse = true
                            }
                            try? await Task.sleep(nanoseconds: 750_000_000)
                            guard !Task.isCancelled else { break }
                            withAnimation(.easeInOut(duration: 0.75)) {
                                connectionButtonPulse = false
                            }
                            try? await Task.sleep(nanoseconds: 750_000_000)
                        }
                    }

                    if let failover = connection.failoverStatus {
                        Text(failover)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    }
                }
                .frame(width: 360, height: 135)
            }

            if connection.state.status == .connected,
               connection.state.exitIP == nil || connection.state.lastError != nil {
                Text(connection.state.lastError ?? "出口 IP 未获取到，当前节点可能无法正常打开 Google / ChatGPT，请切换节点")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.background.opacity(0.01))
                .background(
                    LinearGradient(
                        colors: [
                            Color(red: 0.12, green: 0.28, blue: 0.34).opacity(0.18),
                            Color(red: 0.08, green: 0.16, blue: 0.22).opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        )
    }

    @ViewBuilder
    private var pendingConfigBanner: some View {
        if let node = appState.currentNode, node.pendingConfigUpdate,
           connection.state.status == .connected {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("当前节点「\(node.displayTitle)」参数已更新")
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
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.12)))
        }
    }

    private var metrics: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
            metricCard("出口 IP", connection.state.exitIP ?? "—")
            metricCard("出口国家", connection.state.exitCountry ?? "—")
            metricCard("下载", speedText(connection.state.downloadMbps))
            metricCard("上传", speedText(connection.state.uploadMbps))
            metricCard("本次下载", byteText(connection.state.sessionDownloadBytes))
            metricCard("本次上传", byteText(connection.state.sessionUploadBytes))
        }
    }

    private var quickSwitch: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("快速切换")
                    .font(.headline)
                Text(quickSwitchLastUpdatedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("最近一次节点测速或应用连通测试的更新时间")
                Spacer()
                Toggle("国家", isOn: $quickSwitchMergeCountries)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .onChange(of: quickSwitchMergeCountries) { _, _ in
                        showsAllQuickSwitchCountries = false
                    }
                    .help("开启时按国家合并，关闭后逐个显示节点；按当前自动优选规则排序")
                Text("国家")
                    .foregroundStyle(.secondary)
                Toggle("自动优选", isOn: Binding(
                    get: { connection.state.autoSelectEnabled },
                    set: {
                        connection.state.autoSelectEnabled = $0
                        appState.persist()
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                Text("自动优选")
                    .foregroundStyle(.secondary)
                Button {
                    showsClearAutoSelectConfirmation = true
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .accessibilityLabel("清除自动优选列表")
                .buttonStyle(.bordered)
                .disabled(appState.isClearingAutoSelectResults || appState.testManager.isTesting || appState.testManager.isProbingApps)
                .help("先断开连接，再清除测速和应用连通结果；重新测试后按当前规则加入自动优选")
            }

            Text(quickSwitchSortDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            if appState.countryGroups.isEmpty {
                Text("添加订阅后将按国家显示可切换入口")
                    .foregroundStyle(.secondary)
            } else {
                let groups = quickSwitchGroups
                let nodes = quickSwitchNodes
                let entryCount = quickSwitchMergeCountries ? groups.count : nodes.count
                if entryCount == 0 {
                    Text("暂无符合自动优选条件的节点，请重新测试后刷新列表")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    if quickSwitchMergeCountries {
                    ForEach(Array(groups.prefix(showsAllQuickSwitchCountries ? groups.count : 5))) { group in
                        let isConnected = connection.state.status == .connected &&
                            connection.state.currentCountryCode == group.code
                        HStack {
                            Text("\(group.flag)  \(group.name)")
                            Spacer()
                            if let preferredNode = group.nodes.first {
                                quickSwitchPriorityBadges(for: preferredNode)
                            }
                            Text(LatencyFormat.seconds(group.nodes.first?.lastLatency))
                                .foregroundStyle(.secondary)
                            Text("\(group.availableCount)/\(enabledNodeCount(in: group))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isConnected ? Color.accentColor.opacity(0.14) : Color.clear)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(isConnected ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
                        }
                        .accessibilityValue(isConnected ? "当前已连接" : "未连接")
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            Task { await appState.connectCountry(group.code) }
                        }
                        .help("双击切换到\(group.name)节点")
                    }

                    } else {
                        ForEach(Array(nodes.prefix(showsAllQuickSwitchCountries ? nodes.count : 5))) { node in
                            let isConnected = connection.state.status == .connected &&
                                connection.state.currentNodeID == node.id
                            HStack {
                                Text("\(FlagResolver.flag(for: CountryResolver.effectiveCode(for: node)))  \(CountryResolver.displayName(for: CountryResolver.effectiveCode(for: node)))  \(node.displayTitle)")
                                    .lineLimit(1)
                                Spacer()
                                quickSwitchPriorityBadges(for: node)
                                Text(LatencyFormat.seconds(node.lastLatency))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(isConnected ? Color.accentColor.opacity(0.14) : Color.clear)
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(isConnected ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
                            }
                            .accessibilityValue(isConnected ? "当前已连接" : "未连接")
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                appState.requestConnect(to: node)
                            }
                            .help("双击切换到\(node.displayTitle)")
                        }
                    }

                    if entryCount > 5 {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                showsAllQuickSwitchCountries.toggle()
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Text(showsAllQuickSwitchCountries ? "收起" : "显示更多（\(entryCount - 5)）")
                                Image(systemName: showsAllQuickSwitchCountries ? "chevron.up" : "chevron.down")
                                    .font(.caption2.weight(.semibold))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var quickSwitchSortDescription: String {
        var priorities: [String] = []
        switch appState.settings.favoritePreference {
        case .preferFavorites: priorities.append("收藏优先")
        case .favoritesOnly: priorities.append("仅收藏")
        case .all: break
        }
        if appState.settings.autoAppProbeUsableNodes {
            priorities.append("应用连通通过数从多到少")
        }
        priorities.append("测速延迟从低到高")
        let description = "排序：" + priorities.joined(separator: " → ")
        return quickSwitchMergeCountries ? description + "；标识和延迟对应各国首选节点" : description
    }

    @ViewBuilder
    private func quickSwitchPriorityBadges(for node: ProxyNode) -> some View {
        if node.isFavorite {
            Image(systemName: "star.fill")
                .foregroundStyle(.yellow)
                .accessibilityLabel("已收藏")
                .help(appState.settings.favoritePreference == .all ? "已收藏；当前不优先收藏" : "已收藏；当前优先使用收藏节点")
        }
        if appState.settings.autoAppProbeUsableNodes || node.lastAppProbeDate != nil {
            let probeText = node.lastAppProbeDate == nil
                ? "应用未测"
                : "应用通过 \(node.appProbePassTier)"
            Label(probeText, systemImage: node.appProbePassTier > 0 ? "checkmark.circle.fill" : "circle.dashed")
                .font(.caption)
                .foregroundStyle(node.appProbePassTier > 0 ? Color.green : Color.secondary)
                .fixedSize()
                .help(appState.settings.autoAppProbeUsableNodes
                    ? "应用连通有效通过目标数：\(node.appProbePassTier)；通过数越多越优先，同档再按测速延迟排序"
                    : "应用连通有效通过目标数：\(node.appProbePassTier)；当前未启用应用连通优先")
        }
    }

    private var quickSwitchLastUpdatedText: String {
        let updatedAt = appState.nodes
            .filter { !$0.pendingRemoval }
            .flatMap { [$0.lastTestDate, $0.lastAppProbeDate].compactMap { $0 } }
            .max()
        guard let updatedAt else { return "尚未更新" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return "上次更新：\(formatter.string(from: updatedAt))"
    }

    private var quickSwitchNodes: [ProxyNode] {
        appState.automaticallyRankedNodes(appState.nodes)
    }

    private var quickSwitchGroups: [CountryGroup] {
        let rankedNodes = quickSwitchNodes
        var seen = Set<String>()
        return rankedNodes.compactMap { node in
            let code = CountryResolver.effectiveCode(for: node)
            guard seen.insert(code).inserted,
                  let group = appState.countryGroups.first(where: { $0.code == code }) else { return nil }
            return CountryGroup(
                code: group.code,
                name: group.name,
                flag: group.flag,
                nodes: rankedNodes.filter { CountryResolver.effectiveCode(for: $0) == code }
            )
        }
    }

    private func enabledNodeCount(in group: CountryGroup) -> Int {
        group.nodes.filter { $0.enabled && !$0.pendingRemoval }.count
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("最近使用")
                .font(.headline)
            if appState.recentNodes.isEmpty {
                Text("暂无")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appState.recentNodes) { node in
                    Button {
                        appState.requestConnect(to: node)
                    } label: {
                        HStack {
                            Text(node.displayTitle)
                            Spacer()
                            Text(node.latencyText)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var connectionButtonIsDestructive: Bool {
        switch connection.state.status {
        case .connected, .connecting, .disconnecting:
            return true
        case .disconnected, .error:
            return connection.isBusy
        }
    }

    private var connectionButtonSymbol: String {
        switch connection.state.status {
        case .connected: return "power"
        case .error: return "arrow.clockwise"
        case .disconnected: return "bolt.fill"
        case .connecting, .disconnecting: return "power"
        }
    }

    private var connectionButtonGradient: LinearGradient {
        let colors: [Color]
        switch connection.state.status {
        case .connected:
            colors = [Color(red: 0.96, green: 0.25, blue: 0.29), Color(red: 0.78, green: 0.10, blue: 0.18)]
        case .connecting:
            colors = [Color.orange, Color(red: 0.88, green: 0.38, blue: 0.08)]
        case .disconnecting:
            colors = [Color(red: 0.58, green: 0.60, blue: 0.64), Color(red: 0.40, green: 0.42, blue: 0.47)]
        case .disconnected:
            colors = [Color(red: 0.10, green: 0.66, blue: 0.70), Color(red: 0.04, green: 0.40, blue: 0.62)]
        case .error:
            colors = [Color(red: 0.95, green: 0.36, blue: 0.22), Color(red: 0.75, green: 0.15, blue: 0.16)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var connectionButtonShadowColor: Color {
        connectionButtonIsDestructive ? .red : .cyan
    }

    private var countryTitle: String {
        if connection.state.status == .connected || connection.state.status == .connecting {
            if let code = connection.state.currentCountryCode {
                return "\(FlagResolver.flag(for: code)) \(connection.state.currentCountryName ?? code)"
            }
            if let node = appState.currentNode {
                return "\(FlagResolver.flag(for: node.countryCode)) \(node.displayCountry)"
            }
        }
        return "未连接"
    }

    private var pageBackground: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                Color(red: 0.93, green: 0.96, blue: 0.97)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private func metricCard(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }

    private func speedText(_ mbps: Double) -> String {
        String(format: "%.1f Mbps", mbps)
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }
}
