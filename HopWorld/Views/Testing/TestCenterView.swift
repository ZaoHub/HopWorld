import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct UsageHelpButton: View {
    var title: String
    var text: String
    @State private var showingHelp = false

    var body: some View {
        Button { showingHelp = true } label: {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .popover(isPresented: $showingHelp) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(width: 360, alignment: .leading)
        }
    }
}

/// 测试页「实验室」主题调色板，深浅色自适应。
private struct LabPalette {
    var scheme: ColorScheme
    var bgTop: Color
    var bgBottom: Color
    var gridline: Color
    var card: Color
    var cardBorder: Color
    var text: Color
    var subtext: Color
    var accent: Color
    var onAccent: Color
    var line: Color

    init(scheme: ColorScheme) {
        self.scheme = scheme
        if scheme == .dark {
            bgTop = Color(red: 0.030, green: 0.052, blue: 0.100)
            bgBottom = Color(red: 0.052, green: 0.082, blue: 0.145)
            gridline = Color.white.opacity(0.035)
            card = Color.white.opacity(0.055)
            cardBorder = Color.white.opacity(0.10)
            text = Color(red: 0.92, green: 0.94, blue: 0.97)
            subtext = Color(red: 0.60, green: 0.66, blue: 0.72)
            accent = Color(red: 0.35, green: 0.75, blue: 1.0)
            onAccent = Color(red: 0.02, green: 0.10, blue: 0.18)
            line = Color.white.opacity(0.10)
        } else {
            bgTop = Color(red: 0.940, green: 0.952, blue: 0.968)
            bgBottom = Color(red: 0.888, green: 0.912, blue: 0.938)
            gridline = Color.black.opacity(0.035)
            card = .white
            cardBorder = Color.black.opacity(0.08)
            text = Color(red: 0.10, green: 0.14, blue: 0.20)
            subtext = Color(red: 0.42, green: 0.47, blue: 0.54)
            accent = Color(red: 0.0, green: 0.45, blue: 0.85)
            onAccent = .white
            line = Color.black.opacity(0.09)
        }
    }
}

/// 实验室背景：渐变 + 坐标网格。
private struct LabBackdrop: View {
    var palette: LabPalette

    var body: some View {
        ZStack {
            LinearGradient(colors: [palette.bgTop, palette.bgBottom], startPoint: .top, endPoint: .bottom)
            Canvas { context, size in
                var path = Path()
                var x: CGFloat = 0
                while x <= size.width {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    x += 28
                }
                var y: CGFloat = 0
                while y <= size.height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    y += 28
                }
                context.stroke(path, with: .color(palette.gridline), lineWidth: 0.5)
            }
        }
        .ignoresSafeArea()
    }
}

/// 通用卡片容器。
private struct LabCard<Content: View>: View {
    var title: String
    var icon: String
    var tint: Color
    var palette: LabPalette
    var subtitle: String? = nil
    var footnote: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.text)
                    .fixedSize(horizontal: true, vertical: false)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.subtext)
                        .lineLimit(1)
                        .help(subtitle)
                }
                if let footnote {
                    Spacer(minLength: 8)
                    Text(footnote)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.subtext)
                        .multilineTextAlignment(.trailing)
                }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(palette.cardBorder, lineWidth: 1)
        }
    }
}

/// 仪表读数格：大数字 + 小标签。
private struct LabStatTile: View {
    var label: String
    var value: String
    var tint: Color
    var palette: LabPalette
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(value)
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                    Text(label)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.subtext)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.subtext)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.text.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(palette.line, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("查看\(label)的分类与数量")
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .accessibilityHint("查看分类与数量")
    }
}

private struct TestStatisticsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var statistic: NodeTestStatistic
    var scopeTitle: String
    var nodes: [ProxyNode]
    var remainingNodeIDs: Set<UUID>

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(statistic.title)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(scopeTitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(statistic.sections(for: nodes, remainingNodeIDs: remainingNodeIDs)) { section in
                        Section {
                            if section.counts.isEmpty {
                                Text("当前范围没有相关节点")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(section.sortedCounts, id: \.key) { row in
                                    HStack(alignment: .top, spacing: 16) {
                                        Text(row.key)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .lineLimit(nil)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Text("\(row.value) 个")
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                            .fixedSize()
                                    }
                                    .accessibilityElement(children: .combine)
                                }
                            }
                        } header: {
                            Text(section.title)
                                .font(.headline)
                                .padding(.top, 4)
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            Divider()
            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 600, height: 480)
    }
}

struct TestCenterView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var testManager: NodeTestManager
    @Environment(\.colorScheme) private var colorScheme
    /// Node picked in the results list for connect / app probe.
    @State private var selectedNodeID: UUID?
    @State private var appProbeTestNodeID: UUID?
    @State private var appProbeScope: NodeListFilter.Source = .all
    @State private var showingLatencyTierHelp = false
    @State private var selectedStatistic: NodeTestStatistic?
    @State private var editingAppProbes = false
    @State private var draftAppProbeSettings: AppSettings?
    @State private var appProbeBaseline: AppSettings?
    @State private var resultPage = 1

    /// Shared with 节点 page subscription chips.
    private var testScope: NodeListFilter.Source {
        NodeListFilter.decode(appState.settings.nodeListCategoryRaw).source
    }

    private func setTestScope(_ value: NodeListFilter.Source) {
        let current = NodeListFilter.decode(appState.settings.nodeListCategoryRaw)
        let raw = NodeListFilter.encode(scope: current.scope, source: value)
        guard appState.settings.nodeListCategoryRaw != raw else { return }
        appState.updateSettingsFromView { $0.nodeListCategoryRaw = raw }
    }

    private var testScopeBinding: Binding<NodeListFilter.Source> {
        Binding(
            get: { testScope },
            set: { setTestScope($0) }
        )
    }

    private var palette: LabPalette { LabPalette(scheme: colorScheme) }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 700
            ScrollView {
                LazyVStack(spacing: 14) {
                    header
                    statusCard
                    controlsCard(wide: wide)
                    coverageStrip
                    appProbeCard
                    resultsCard
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .frame(maxWidth: 920)
                .frame(maxWidth: .infinity)
            }
            .background { LabBackdrop(palette: palette) }
        }
        .onAppear {
            let resultNodeLabel = testManager.appProbeNodeLabel
            let targetNodeLabel = probeTargetNode.map { appState.appProbeNodeDescription(for: $0, useOriginalName: true) }
            if !testManager.isProbingApps,
               testManager.appProbeResults.map(\.target) != appState.settings.automaticAppProbeTargets
                || (resultNodeLabel != nil && resultNodeLabel != targetNodeLabel) {
                testManager.resetAppProbes(targets: appState.settings.automaticAppProbeTargets)
            }
        }
        .onChange(of: appState.nodes.map(\.id)) { ids in
            if let id = appProbeTestNodeID ?? testManager.appProbeNodeID, !ids.contains(id) {
                restoreCurrentProxyProbeTarget()
            }
        }
        .onChange(of: appState.connection.state.status) { status in
            guard appProbeTestNodeID == nil, testManager.appProbeNodeID == nil,
                  !testManager.isProbingApps else { return }
            if status == .connected {
                selectedNodeID = appState.connection.state.currentNodeID
                testManager.appProbeStatusText = "已连接，可独立探测当前节点"
            }
        }
        .onChange(of: appState.subscriptions.map(\.id)) { ids in
            if case .subscription(let id) = testScope, !ids.contains(id) {
                setTestScope(.all)
            }
        }
        .onChange(of: subscriptionScopeOptions.map(\.scope)) { scopes in
            if appProbeScope != .all, !scopes.contains(appProbeScope) { appProbeScope = .all }
        }
        .onChange(of: testScope) { _ in
            resultPage = 1
        }
        .sheet(item: $selectedStatistic) { statistic in
            TestStatisticsSheet(
                statistic: statistic,
                scopeTitle: scopeLine,
                nodes: scopedTargets,
                remainingNodeIDs: Set(testManager.remainingNodeIDs)
            )
        }
    }

    // MARK: - 页眉

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("LAB · 测速实验室")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(palette.accent)
                HStack(spacing: 8) {
                    Image(systemName: "flask.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(palette.text)
                    Text("测试中心")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(palette.text)
                        .fixedSize()
                    Text(scopeLine)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(palette.subtext)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(scopeLine)
                }
            }
            Spacer(minLength: 8)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(context.date, format: .dateTime.hour().minute().second())
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(palette.text)
            }
        }
    }

    private var scopeLine: String {
        let count = scopedTargets.count
        switch testScope {
        case .all:
            return "全部 · \(count) 节点"
        case .subscription:
            return "\(selectedSubscriptionTitle) · \(count) 节点"
        case .manual:
            return "手动导入 · \(count) 节点"
        case .namedSource(let name):
            return "\(name) · \(count) 节点"
        }
    }

    // MARK: - 测试仪表：阶段 + 进度 + 读数

    /// 测速中用本轮实时计数（开测即清零）；空闲时用节点落盘结果。
    /// 关自动应用连通只显示可用；开启时测速/探测中显示可用，探测结束后显示应用连通。
    private var statusCard: some View {
        let targets = scopedTargets
        let summary = scopedSummary(for: targets)
        let running = testManager.phase == .running || testManager.phase == .paused
        let probingApps = appState.appProbeBatch.isRunning || testManager.isProbingApps
        let available = running ? testManager.availableCount : summary.available
        let unavailable = running ? testManager.unavailableCount : summary.unavailable
        let failed = running ? testManager.failedCount : summary.failed
        let tested = running ? testManager.testedCount : summary.tested
        let appConnected = summary.appConnected
        let availableTile = availableStatTile(
            available: available,
            appConnected: appConnected,
            targets: targets,
            running: running,
            probingApps: probingApps
        )
        return LabCard(
            title: "测试仪表", icon: "gauge.with.dots.needle.67percent",
            tint: palette.accent, palette: palette,
            footnote: running ? testManager.statusText
                : (probingApps ? "正在测试应用连通性" : statusIdleLine(summary: summary, total: targets.count))
        ) {
            HStack(spacing: 8) {
                SignalDot(color: !running && probingApps ? palette.accent : phaseColor)
                Text(running ? "节点延迟\(testManager.phase.displayName)"
                     : (probingApps ? "应用连通测试中" : testManager.phase.displayName))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.text)
                Spacer(minLength: 8)
                Button {
                    showingLatencyTierHelp = true
                } label: {
                    Label("延迟档次", systemImage: "questionmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.subtext)
                }
                .buttonStyle(.plain)
                .help("查看延迟档次阈值")
                .alert("延迟档次说明", isPresented: $showingLatencyTierHelp) {
                    Button("好", role: .cancel) {}
                } message: {
                    Text(NodeTestStatus.latencyTierHelpMessage)
                }
            }
            if running {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("节点延迟")
                        Spacer(minLength: 8)
                        Text("\(testManager.testedCount)/\(testManager.totalCount)")
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(palette.subtext)
                    ProgressView(value: testManager.progress)
                        .tint(palette.accent)
                        .accessibilityLabel("节点延迟测试进度")
                }
            }
            if appState.appProbeBatch.isRunning {
                AppProbeProgressView(
                    title: "应用连通 · 可用节点",
                    completed: appState.appProbeBatch.completed,
                    total: appState.appProbeBatch.total,
                    statusText: appState.appProbeBatch.statusText
                )
                .tint(palette.accent)
            }
            if testManager.isProbingApps {
                AppProbeProgressView(
                    title: "应用连通 · 单节点",
                    completed: testManager.appProbeCompletedCount,
                    total: testManager.appProbeResults.count,
                    statusText: testManager.appProbeNodeLabel.map { appState.settings.nodeDisplayName($0) }
                        ?? testManager.appProbeStatusText
                )
                .tint(palette.accent)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                LabStatTile(
                    label: availableTile.label,
                    value: availableTile.value,
                    tint: .green, palette: palette
                ) { selectedStatistic = .available }
                LabStatTile(label: "不可用", value: "\(unavailable)", tint: .orange, palette: palette) {
                    selectedStatistic = .unavailable
                }
                LabStatTile(label: "失败", value: "\(failed)", tint: .red, palette: palette) {
                    selectedStatistic = .failed
                }
                LabStatTile(
                    label: testManager.canResume ? "延迟剩余" : "延迟已测 / 范围",
                    value: testManager.canResume
                        ? "\(testManager.remainingNodeIDs.count)"
                        : "\(tested)/\(targets.count)",
                    tint: palette.text, palette: palette
                ) { selectedStatistic = .progress }
            }
        }
    }

    /// 关自动应用连通：只显示可用。开：测速/探测中显示可用，探测结束后显示应用连通。
    private func availableStatTile(
        available: Int,
        appConnected: Int,
        targets: [ProxyNode],
        running: Bool,
        probingApps: Bool
    ) -> (label: String, value: String) {
        let autoProbe = appState.settings.autoAppProbeUsableNodes
        if !autoProbe {
            return ("可用", "\(available)")
        }
        if running || probingApps {
            return ("可用", "\(available)")
        }
        let probed = targets.contains { $0.lastAppProbeDate != nil }
        if probed {
            return ("应用连通", "\(appConnected)")
        }
        return ("可用", "\(available)")
    }

    private func statusIdleLine(summary: (available: Int, unavailable: Int, failed: Int, tested: Int, appConnected: Int), total: Int) -> String {
        summary.tested > 0 ? "当前范围已测 \(summary.tested) / \(total)" : "尚未测试，点击「测试全部」开始"
    }

    private struct SignalDot: View {
        var color: Color
        var body: some View {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
                .shadow(color: color.opacity(0.6), radius: 3)
        }
    }

    // MARK: - 测试控制：范围 + 动作

    private func controlsCard(wide: Bool) -> some View {
        LabCard(
            title: "测试控制", icon: "slider.horizontal.3",
            tint: palette.accent, palette: palette
        ) {
            Group {
                if wide {
                    HStack(spacing: 10) {
                        scopePicker
                        Spacer(minLength: 8)
                        controlButtons
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        scopePicker
                        controlButtons
                    }
                }
            }
        }
    }

    private var scopePicker: some View {
        HStack(spacing: 8) {
            Text("订阅范围")
                .font(.system(size: 12))
                .foregroundStyle(palette.subtext)
            Picker("订阅", selection: testScopeBinding) {
                Text("全部").tag(NodeListFilter.Source.all)
                ForEach(subscriptionScopeOptions) { option in
                    Text(option.title).tag(option.scope)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 220)
            .disabled(testManager.isTesting)
        }
    }

    private var controlButtons: some View {
        HStack(spacing: 8) {
            Button("测试当前连接") {
                Task { await appState.testCurrentConnection() }
            }
            .buttonStyle(.bordered)
            .disabled(
                testManager.isTesting ||
                appState.connection.state.status != .connected
            )

            testControls
        }
    }

    // MARK: - 覆盖链路

    private var coverageStrip: some View {
        LabCard(
            title: "覆盖链路", icon: "point.topleft.down.curvedto.point.bottomright.up",
            tint: palette.accent, palette: palette, footnote: "每次测速依次经过"
        ) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    coverageChip("配置检查")
                    coverageArrow
                    coverageChip("DNS")
                    coverageArrow
                    coverageChip("TCP")
                    coverageArrow
                    coverageChip("代理 HTTP RTT")
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func coverageChip(_ label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(palette.accent).frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.text)
                .fixedSize()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(palette.text.opacity(0.06), in: Capsule())
        .overlay { Capsule().strokeBorder(palette.line, lineWidth: 1) }
    }

    private var coverageArrow: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(palette.subtext.opacity(0.7))
    }

    // MARK: - 节点结果：检测试管架

    private var resultsCard: some View {
        // This property used to reevaluate and sort liveResultRows for the empty
        // check, ForEach, and header count in the same render pass.
        let rows = liveResultRows
        let pageSize = 18
        let pageCount = max(1, (rows.count + pageSize - 1) / pageSize)
        let page = min(max(resultPage, 1), pageCount)
        let startIndex = (page - 1) * pageSize
        let pageRows = Array(rows.dropFirst(startIndex).prefix(pageSize))
        return LabCard(
            title: "节点结果", icon: "testtube.2",
            tint: palette.accent, palette: palette,
            subtitle: selectionHint,
            footnote: "可用 \(rows.count) 条"
        ) {
            if rows.isEmpty {
                UnavailablePlaceholder(
                    "暂无可用节点",
                    systemImage: "list.bullet.rectangle",
                    description: {
                        Text("测试后仅显示可用节点；单击节点可选中，再连接并探测应用")
                    }
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                if pageCount > 1 {
                    resultPagination(page: page, pageCount: pageCount)
                }
                LazyVStack(spacing: 2) {
                    ForEach(Array(pageRows.enumerated()), id: \.element.id) { index, row in
                        resultRow(row, striped: index % 2 == 1)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard !testManager.isProbingApps else { return }
                                selectAppProbeTestNode(row.id)
                            }
                            .contextMenu {
                                nodeResultContextMenu(for: row)
                            }
                    }
                }
            }
        }
        .onChange(of: pageCount) { _ in
            resultPage = min(max(resultPage, 1), pageCount)
        }
        .animation(.default, value: selectedNodeID)
        .animation(.default, value: appState.connection.state.currentNodeID)
    }

    private func resultPagination(page: Int, pageCount: Int) -> some View {
        HStack(spacing: 8) {
            Text("第 \(page) / \(pageCount) 页 · 每页 18 个")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(palette.subtext)
            Spacer(minLength: 8)
            Button("首页") { resultPage = 1 }
                .disabled(page == 1)
            Button("上一页") { resultPage = page - 1 }
                .disabled(page == 1)
            Button("下一页") { resultPage = page + 1 }
                .disabled(page == pageCount)
            Button("尾页") { resultPage = pageCount }
                .disabled(page == pageCount)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var selectionHint: String {
        if let selected = appProbeTestNode {
            return "当前测试：\(appState.settings.nodeDisplayTitle(selected))；点击上方「当前测试」可返回当前代理"
        } else if appState.connection.state.status == .connected {
            return "已连接：应用探测使用当前代理"
        } else if let node = appState.recentNodes.first {
            return "上次选中：\(appState.settings.nodeDisplayTitle(node))。单击可改选；不改选时探测使用该节点"
        } else {
            return "未连接：单击选中后点「探测应用」，选中只用于探测、不会建立代理"
        }
    }

    private func resultRow(_ row: TestResultRow, striped: Bool) -> some View {
        let allowSelect = appState.connection.state.status != .connected
        let highlighted = row.isCurrent || row.isConnecting || (row.isSelected && allowSelect)
        return HStack(spacing: 8) {
            Circle()
                .fill(row.statusColor)
                .frame(width: 8, height: 8)
                .shadow(color: row.statusColor.opacity(0.5), radius: 2)
            if let countryName = row.countryName {
                Text(countryName)
                    .font(.caption)
                    .foregroundStyle(palette.subtext)
                    .fixedSize(horizontal: true, vertical: false)
                    .help("国家/地区：\(countryName)")
                    .accessibilityLabel("国家/地区：\(countryName)")
            }
            Text(row.name)
                .font(.system(size: 13, weight: highlighted ? .semibold : .medium))
                .foregroundStyle(palette.text)
                .lineLimit(1)
                .help(row.name)
            Text(row.exitIPType?.displayName ?? "未知")
                .font(.caption)
                .foregroundStyle(palette.subtext)
                .fixedSize(horizontal: true, vertical: false)
                .help("出口 IP 属性：\(row.exitIPType?.displayName ?? "未知")")
                .accessibilityLabel("出口 IP 属性：\(row.exitIPType?.displayName ?? "未知")")
            NodeGroupLabel(name: row.groupName)

            if row.isSelected && allowSelect {
                Text("探测选中")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(palette.accent.opacity(0.18)))
                    .foregroundStyle(palette.accent)
            }
            if row.isConnecting {
                Text("连接中")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.15)))
                    .foregroundStyle(.orange)
            } else if row.isCurrent {
                Text("代理已连")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.green.opacity(0.15)))
                    .foregroundStyle(.green)
            }

            Spacer(minLength: 8)
            if !row.passedAppTargets.isEmpty {
                HStack(spacing: 4) {
                    ForEach(row.passedAppTargets) { target in
                        AppProbeIcon(target: target, passed: true, size: 18)
                    }
                }
            } else if row.appProbeCompleted {
                Text("应用均未通过")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("应用连通已测完，没有应用通过；节点延迟结果单独显示")
            }
            Text(row.status)
                .font(.system(size: 12))
                .foregroundStyle(row.statusColor)
                .lineLimit(1)
            Text(row.latency)
                .font(.system(size: 12, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(palette.subtext)
                .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(
                    row.isSelected && allowSelect ? palette.accent.opacity(0.6) : Color.clear,
                    lineWidth: 1
                )
        }
        .modifier(WarmCardHover(
            cornerRadius: 7,
            fill: highlighted ? palette.accent.opacity(palette.scheme == .dark ? 0.14 : 0.10)
                : (striped ? palette.text.opacity(0.035) : .clear)
        ))
    }

    @ViewBuilder
    private func nodeResultContextMenu(for row: TestResultRow) -> some View {
        let node = appState.nodes.first { $0.id == row.id }

        Button("查看") {
            appState.viewingNodeID = row.id
        }

        Button("连接此节点（系统代理）") {
            guard let node else { return }
            selectedNodeID = row.id
            appState.requestConnect(to: node)
        }

        if appState.connection.state.status == .connected,
           appState.connection.state.currentNodeID == row.id {
            Button("断开连接", role: .destructive) {
                Task { await appState.disconnect() }
            }
        }

        Divider()

        Button("选中并探测应用") {
            guard let node else { return }
            selectAppProbeTestNode(row.id)
            Task { await appState.probeApps(forSelectedNode: node) }
        }
        .disabled(node == nil || testManager.isProbingApps)
        Divider()

        Button("单独测速此节点") {
            guard let node else { return }
            selectedNodeID = node.id
            Task { await appState.testNodes([node]) }
        }
        .disabled(testManager.isTesting)

        if let node {
            Button(node.isFavorite ? "取消收藏" : "收藏") {
                appState.toggleFavorite(node.id)
            }
        }
    }

    // MARK: - 应用连通：试剂反应板

    private var appProbeCard: some View {
        let connected = appState.connection.state.status == .connected
        let showsCurrentProxy = appProbeTestNode == nil && appState.currentNode != nil && (
            connected
            || appState.connection.state.status == .connecting
            || appState.connection.state.status == .disconnecting
        )
        let connectionNote = appState.connection.state.status == .connecting ? "连接中" : "断开中"

        return LabCard(
            title: "应用连通", icon: "aqi.medium",
            tint: palette.accent, palette: palette,
            subtitle: appProbePreviewSettings.effectiveAppProbeSource.displayName,
            footnote: appProbeHasDraftChanges ? "预览中 · 尚未应用设置"
                : (appState.appProbeBatch.isRunning ? "可用节点应用连通测试中" : testManager.appProbeStatusText)
        ) {
            appProbeBatchControls
            Divider().overlay(palette.line)

            HStack(spacing: 8) {
                if appProbeTestNode != nil {
                    Button("当前测试") { restoreCurrentProxyProbeTarget() }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .help("切换回当前代理")
                        .disabled(testManager.isProbingApps)
                } else {
                    Text(showsCurrentProxy ? "当前代理" : "探测目标")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.subtext)
                        .fixedSize()
                }
                if let node = appProbeTestNode {
                    probeNodeLabel(node, note: "仅测试此节点 · 不切换代理", noteColor: palette.subtext)
                } else if showsCurrentProxy, let node = appState.currentNode {
                    probeNodeLabel(
                        node,
                        note: connected ? "已连接 · 独立探测节点" : connectionNote,
                        noteColor: connected ? .green : palette.subtext
                    )
                } else if let node = selectedNode {
                    probeNodeLabel(node, note: "未连接 · 仅测试选中节点", noteColor: palette.subtext)
                } else if let node = appState.recentNodes.first {
                    probeNodeLabel(node, note: "未连接 · 上次选中", noteColor: palette.subtext)
                } else {
                    Text("请先在下方节点列表点选一个节点")
                        .font(.system(size: 13))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                appProbeActions
            }

            if editingAppProbes {
                Picker("应用来源", selection: Binding(
                    get: { appProbePreviewSettings.effectiveAppProbeSource },
                    set: { source in
                        guard source != appProbePreviewSettings.effectiveAppProbeSource else { return }
                        let baseline = appProbeBaseline ?? appState.settings
                        updateAppProbeDraft {
                            $0.appProbeSource = source == baseline.effectiveAppProbeSource ? baseline.appProbeSource : source
                        }
                    }
                )) {
                    ForEach(AppProbeSource.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                if appProbePreviewSettings.effectiveAppProbeSource != .defaults {
                    InstalledAppProbeSettings(settings: Binding(get: { appProbePreviewSettings }, set: { updated in updateAppProbeDraft { $0 = updated } }))
                }
                Stepper(
                    "探测超时：\(appProbePreviewSettings.appProbeTimeoutSeconds) 秒",
                    value: Binding(
                        get: { appProbePreviewSettings.appProbeTimeoutSeconds },
                        set: { value in
                            updateAppProbeDraft { $0.appProbeTimeoutSeconds = value }
                        }
                    ),
                    in: 1...30
                )
                .help("每个应用探测目标的超时时间")
            }

            if !appProbePreviewSettings.automaticAppProbeTargets.isEmpty {
                if editingAppProbes {
                    Text("左右箭头调整应用优先级。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 168), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(appProbePreviewSettings.automaticAppProbeTargets) { target in
                        let sameTargets = Set(appProbePreviewSettings.automaticAppProbeTargets) == Set(appState.settings.automaticAppProbeTargets)
                        let result = sameTargets
                            ? testManager.appProbeResults.first { $0.target == target } ?? .placeholder(target)
                            : AppProbeResult.placeholder(target)
                        appProbeChip(result)
                    }
                }
            }
        }
    }

    private var appProbeActions: some View {
        HStack(spacing: 8) {
            Button(testManager.isProbingApps ? "探测中…" : "探测应用") {
                Task { await runAppProbe() }
            }
            .buttonStyle(.borderedProminent)
            .tint(palette.accent)
            .disabled(appProbeButtonDisabled)
            .help(
                appProbeTestNode != nil
                    ? "通过当前测试节点临时探测，不切换当前代理"
                    : "通过当前连接节点或所选节点独立探测，不影响连接"
            )
            if editingAppProbes {
                Button("应用设置") {
                    if let baseline = appProbeBaseline {
                        let draft = appProbePreviewSettings
                        appState.updateSettings { $0 = $0.applyingSettingsEdits(from: draft, comparedTo: baseline) }
                    }
                    draftAppProbeSettings = nil
                    appProbeBaseline = nil
                    editingAppProbes = false
                }
                .buttonStyle(.borderedProminent)
                Button("取消") {
                    draftAppProbeSettings = nil
                    appProbeBaseline = nil
                    editingAppProbes = false
                }
                .buttonStyle(.bordered)
            } else {
                Button("编辑") { editingAppProbes = true }
                    .buttonStyle(.bordered)
            }
        }
        .fixedSize()
        .disabled(testManager.isProbingApps)
    }

    private var appProbeBatchControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    appProbeBatchSelection
                    appProbeAutoTestToggle
                    Spacer(minLength: 8)
                    appProbeBatchButtons
                        .fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) {
                    appProbeBatchSelection
                    HStack(spacing: 16) {
                        appProbeAutoTestToggle
                        Spacer(minLength: 8)
                        appProbeBatchButtons
                            .fixedSize()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if appState.appProbeBatch.isRunning {
                ProgressView(value: Double(appState.appProbeBatch.completed), total: Double(max(1, appState.appProbeBatch.total)))
                    .accessibilityLabel("可用节点应用连通测试进度")
            }
            if !appState.appProbeBatch.statusText.isEmpty {
                Text(appState.appProbeBatch.statusText)
                    .font(.caption)
                    .foregroundStyle(palette.subtext)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("批量结果见下方「节点结果」，测试不会切换当前代理。")
                .font(.caption)
                .foregroundStyle(palette.subtext)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var appProbeBatchSelection: some View {
        HStack(spacing: 8) {
            Text("可用节点")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.subtext)
                .fixedSize()
            appProbeAvailablePicker
        }
    }

    private var appProbeAutoTestToggle: some View {
        Toggle("测速后自动测试应用连通", isOn: Binding(
            get: { appState.settings.autoAppProbeUsableNodes },
            set: { value in appState.updateSettingsFromView { $0.autoAppProbeUsableNodes = value } }
        ))
        .font(.caption)
        .toggleStyle(.checkbox)
        .fixedSize()
        .help("开启后，手动与后台测速完成都会继续测试可用节点的应用连通；关闭后都不自动继续，仍可在「应用连通 → 可用」手动测试")
    }

    private var appProbeAvailablePicker: some View {
        Picker("可用", selection: $appProbeScope) {
            Text("全部（\(appState.usableNodesForAppProbe(in: .all).count)）")
                .tag(NodeListFilter.Source.all)
            ForEach(subscriptionScopeOptions) { option in
                Text("\(option.title)（\(appState.usableNodesForAppProbe(in: option.scope).count)）")
                    .tag(option.scope)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: 180, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(appState.appProbeBatch.isRunning)
        .help("选择全部或指定节点组，仅测试其中已通过延迟测试的可用节点")
    }

    private var appProbeBatchButtons: some View {
        HStack(spacing: 8) {
            Button("测试可用节点") {
                setTestScope(appProbeScope)
                appState.testUsableNodeApps(in: appProbeScope)
            }
            .buttonStyle(.bordered)
            .disabled(appProbeHasDraftChanges || appState.appProbeBatch.isRunning ||
                      appState.settings.automaticAppProbeTargets.isEmpty ||
                      appState.usableNodesForAppProbe(in: appProbeScope).isEmpty)
            if appState.appProbeBatch.isRunning {
                Button("停止") { appState.stopAppProbeBatch() }
                    .buttonStyle(.bordered)
                    .help("停止可用节点的批量应用连通测试")
            }
        }
    }

    private var appProbePreviewSettings: AppSettings {
        draftAppProbeSettings ?? appState.settings
    }

    private func updateAppProbeDraft(_ mutate: (inout AppSettings) -> Void) {
        if appProbeBaseline == nil { appProbeBaseline = appState.settings }
        var draft = appProbePreviewSettings
        mutate(&draft)
        if let baseline = appProbeBaseline,
           baseline.applyingSettingsEdits(from: draft, comparedTo: baseline) == baseline {
            draftAppProbeSettings = nil
            appProbeBaseline = nil
        } else {
            draftAppProbeSettings = draft
        }
    }

    private var appProbeHasDraftChanges: Bool {
        guard let baseline = appProbeBaseline else { return false }
        let draft = appProbePreviewSettings
        return draft.appProbeSource != baseline.appProbeSource ||
            draft.appProbeOrder != baseline.appProbeOrder ||
            draft.installedAppProbes != baseline.installedAppProbes ||
            draft.appProbeTimeoutSeconds != baseline.appProbeTimeoutSeconds
    }

    private var appProbeButtonDisabled: Bool {
        if appProbeHasDraftChanges { return true }
        if appState.settings.automaticAppProbeTargets.isEmpty { return true }
        if testManager.isProbingApps {
            return true
        }
        return probeTargetNode == nil
    }

    /// 单独测试的节点独立于当前代理，直到用户主动切回。
    private var appProbeTestNode: ProxyNode? {
        let snapshotID = testManager.appProbeNodeID
        let snapshotIsSeparate = testManager.isProbingApps || snapshotID != appState.currentNode?.id
        guard let id = appProbeTestNodeID ?? (snapshotIsSeparate ? snapshotID : nil) else { return nil }
        return appState.nodes.first { $0.id == id }
    }

    private func selectAppProbeTestNode(_ id: UUID) {
        selectedNodeID = id
        if appProbeTestNodeID != id {
            testManager.resetAppProbes(targets: appState.settings.automaticAppProbeTargets)
        }
        appProbeTestNodeID = id
        testManager.appProbeStatusText = "当前测试节点已选中，可探测应用"
    }

    private func restoreCurrentProxyProbeTarget() {
        appProbeTestNodeID = nil
        selectedNodeID = appState.currentNode?.id
        testManager.resetAppProbes(targets: appState.settings.automaticAppProbeTargets)
        testManager.appProbeStatusText = appState.connection.state.status == .connected
            ? "已切回当前代理，可探测应用" : "当前未连接代理，请先连接或选择测试节点"
    }

    private var probeTargetNode: ProxyNode? {
        if let node = appProbeTestNode { return node }
        if appState.connection.state.status == .connected {
            return appState.currentNode
        }
        return selectedNode ?? appState.recentNodes.first
    }

    private func probeNodeLabel(_ node: ProxyNode, note: String, noteColor: Color) -> some View {
        HStack(spacing: 8) {
            Text(appState.appProbeNodeDescription(for: node))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.text)
                .lineLimit(1)
            Text(note)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(noteColor)
                .lineLimit(1)
        }
    }

    private var selectedNode: ProxyNode? {
        guard let id = selectedNodeID else { return nil }
        return appState.nodes.first { $0.id == id }
    }

    private func scopedSummary(
        for targets: [ProxyNode]
    ) -> (available: Int, unavailable: Int, failed: Int, tested: Int, appConnected: Int) {
        var available = 0
        var unavailable = 0
        var failed = 0
        var tested = 0
        var appConnected = 0
        for node in targets {
            if node.hasAppProbeSuccess { appConnected += 1 }
            switch node.lastTestStatus {
            case .ultraFast, .fast, .fairlyFast, .fairlySlow, .slow, .ultraSlow:
                available += 1
                tested += 1
            case .unavailable:
                unavailable += 1
                tested += 1
            case .failed:
                failed += 1
                tested += 1
            case .testing, .untested:
                break
            }
        }
        return (available, unavailable, failed, tested, appConnected)
    }

    private func runAppProbe() async {
        if appProbeTestNode == nil, appState.connection.state.status == .connected {
            await appState.probeCurrentConnectionNodeApps()
            return
        }
        guard let node = probeTargetNode else {
            appState.statusBanner = "未连接时代理：请先在节点结果中单击选中一个节点"
            return
        }
        await appState.probeApps(forSelectedNode: node)
    }

    private func appProbeChip(_ result: AppProbeResult) -> some View {
        let targets = appProbePreviewSettings.automaticAppProbeTargets
        let index = targets.firstIndex { $0.id == result.target.id } ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Text(appProbeLatencyText(result))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Circle().fill(appProbeDotColor(result.status)).frame(width: 8, height: 8)
                }
            }
            HStack(spacing: 6) {
                AppProbeIcon(target: result.target, passed: true)
                Text(result.target.displayName).font(.system(size: 13)).lineLimit(1)
                    .help(result.target.displayName)
            }
            if editingAppProbes {
                HStack {
                    Button { moveAppProbe(result.target.id, by: -1) } label: { Image(systemName: "arrow.left") }
                        .disabled(index == 0 || testManager.isProbingApps)
                        .help("提高\(result.target.displayName)的优先级")
                        .accessibilityLabel("提高\(result.target.displayName)的优先级")
                    Spacer(minLength: 4)
                    Button { moveAppProbe(result.target.id, by: 1) } label: { Image(systemName: "arrow.right") }
                        .disabled(index == targets.count - 1 || testManager.isProbingApps)
                        .help("降低\(result.target.displayName)的优先级")
                        .accessibilityLabel("降低\(result.target.displayName)的优先级")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.text.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(palette.line, lineWidth: 1) }
    }

    private func moveAppProbe(_ id: String, by offset: Int) {
        updateAppProbeDraft { settings in
            var ids = settings.automaticAppProbeTargets.map(\.id)
            guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return }
            ids.swapAt(index, index + offset)
            settings.appProbeOrder[settings.effectiveAppProbeSource.rawValue] = ids
        }
    }

    private func appProbeDotColor(_ status: AppProbeResult.Status) -> Color {
        switch status {
        case .ok: return .green
        case .failed: return .red
        case .testing: return .blue
        case .untested: return .secondary.opacity(0.45)
        }
    }

    private func appProbeLatencyText(_ result: AppProbeResult) -> String {
        switch result.status {
        case .untested: return "未探测"
        case .testing: return "探测中"
        case .ok: return result.latencyMs.map { LatencyFormat.display($0) } ?? "通"
        case .failed: return "不通"
        }
    }

    @ViewBuilder
    private var testControls: some View {
        if testManager.canPause {
            Button("暂停") {
                appState.pauseTesting()
            }
        }

        if testManager.canResume {
            Button("继续测试") {
                Task { await appState.resumeTesting() }
            }
            .buttonStyle(.borderedProminent)
        }

        if testManager.canResume {
            Button("重新测试") {
                Task { await startScopedTest() }
            }
            .disabled(!testManager.canRetest || scopedTargets.isEmpty)
        } else {
            Button(primaryTestButtonTitle) {
                Task { await startScopedTest() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!testManager.canRetest || scopedTargets.isEmpty)
        }
    }

    private var primaryTestButtonTitle: String {
        let rerun = testManager.phase != .idle
        switch testScope {
        case .all:
            return rerun ? "重新测试全部" : "测试全部"
        case .subscription:
            let name = selectedSubscriptionTitle
            return rerun ? "重新测试 \(name)" : "测试 \(name)"
        case .manual:
            return rerun ? "重新测试手动" : "测试手动"
        case .namedSource(let name):
            return rerun ? "重新测试 \(name)" : "测试 \(name)"
        }
    }

    private var selectedSubscriptionTitle: String {
        if case .subscription(let id) = testScope {
            return appState.subscriptions.first(where: { $0.id == id })?.name ?? "订阅"
        }
        if case .namedSource(let name) = testScope {
            return name
        }
        return "订阅"
    }

    private var subscriptionScopeOptions: [SubscriptionScopeOption] {
        var options: [SubscriptionScopeOption] = appState.subscriptions.map {
            SubscriptionScopeOption(
                id: $0.id.uuidString,
                title: $0.name,
                scope: .subscription($0.id)
            )
        }
        let knownIDs = Set(appState.subscriptions.map(\.id))
        let orphaned = appState.nodes.filter {
            $0.enabled && !$0.pendingRemoval &&
            ($0.subscriptionID.map { !knownIDs.contains($0) } ?? false)
        }
        let orphanNames = Set(orphaned.map { $0.sourceName ?? "未知订阅" }).sorted()
        for name in orphanNames {
            options.append(
                SubscriptionScopeOption(id: "named:\(name)", title: name, scope: .namedSource(name))
            )
        }
        let manualCount = appState.nodes.filter {
            $0.enabled && !$0.pendingRemoval && $0.subscriptionID == nil
        }.count
        if manualCount > 0 {
            options.append(
                SubscriptionScopeOption(id: "manual", title: "手动导入", scope: .manual)
            )
        }
        return options
    }

    private var scopedTargets: [ProxyNode] {
        NodeListFilter.nodes(in: appState.nodes, source: testScope, subscriptions: appState.subscriptions)
    }

    private var usableResults: [ProxyNode] {
        scopedTargets.filter {
            $0.resolvedTestStatus.isUsable
        }
    }

    /// 仅显示可用各档；当前连接 / 已选中节点排在最前。
    private var liveResultRows: [TestResultRow] {
        let connStatus = appState.connection.state.status
        let currentID = (connStatus == .connected || connStatus == .connecting)
            ? appState.connection.state.currentNodeID
            : nil
        let selectedID = selectedNodeID
        let appTargets = appState.settings.automaticAppProbeTargets
        let ranked = usableResults.sorted { lhs, rhs in
            let leftPin = (lhs.id == currentID ? 0 : 1) + (lhs.id == selectedID ? 0 : 1)
            let rightPin = (rhs.id == currentID ? 0 : 1) + (rhs.id == selectedID ? 0 : 1)
            if leftPin != rightPin { return leftPin < rightPin }
            return resultSort(lhs, rhs)
        }
        return ranked.map { node in
            let isConnecting = connStatus == .connecting && node.id == currentID
            let isConnected = connStatus == .connected && node.id == currentID
            return TestResultRow(
                id: node.id,
                name: appState.settings.nodeDisplayTitle(node),
                countryName: appState.settings.nodeCountryLabel(node),
                exitIPType: isConnected
                    ? appState.connection.state.exitIPType ?? node.exitMetadata?.networkType
                    : node.exitMetadata?.networkType,
                groupName: node.groupName(subscriptions: appState.subscriptions),
                status: isConnecting ? "连接中" : statusLabel(for: node),
                latency: isConnecting ? "—" : node.latencyText,
                statusColor: isConnecting ? .orange : statusColor(node.resolvedTestStatus),
                isCurrent: isConnected,
                isConnecting: isConnecting,
                isSelected: node.id == selectedID,
                passedAppTargets: appTargets.filter { node.lastAppProbePassedIDs?.contains($0.id) == true },
                appProbeCompleted: node.lastAppProbeDate != nil && node.lastAppProbePassedIDs != nil
            )
        }
    }

    private func resultSort(_ lhs: ProxyNode, _ rhs: ProxyNode) -> Bool {
        let leftBucket = resultBucket(lhs)
        let rightBucket = resultBucket(rhs)
        if leftBucket != rightBucket { return leftBucket < rightBucket }

        if leftBucket == 0 {
            let leftRank = lhs.resolvedTestStatus.sortRank
            let rightRank = rhs.resolvedTestStatus.sortRank
            if leftRank != rightRank { return leftRank < rightRank }
        }

        // Within usable / TCP-reachable: lower latency first.
        if leftBucket == 0 || leftBucket == 3 {
            let leftLatency = lhs.lastLatency ?? Int.max
            let rightLatency = rhs.lastLatency ?? Int.max
            if leftLatency != rightLatency { return leftLatency < rightLatency }
        }

        return appState.settings.nodeDisplayTitle(lhs).localizedStandardCompare(appState.settings.nodeDisplayTitle(rhs)) == .orderedAscending
    }

    /// 0 = 可用各档, 1 = 测试中, 2 = 未测试, 3 = 失败(配置), 4 = 不可用但有 TCP, 5 = 完全不可用.
    private func resultBucket(_ node: ProxyNode) -> Int {
        switch node.lastTestStatus {
        case .ultraFast, .fast, .fairlyFast, .fairlySlow, .slow, .ultraSlow:
            return 0
        case .testing:
            return 1
        case .untested:
            return 2
        case .failed:
            return 3
        case .unavailable:
            return node.lastLatency != nil ? 4 : 5
        }
    }

    private func statusLabel(for node: ProxyNode) -> String {
        switch node.resolvedTestStatus {
        case .untested: return "未测试"
        case .testing: return "测试中"
        case .ultraFast, .fast, .fairlyFast, .fairlySlow, .slow, .ultraSlow:
            return node.resolvedTestStatus.displayName
        case .failed:
            return "失败"
        case .unavailable:
            return "不可用"
        }
    }

    private func statusColor(_ status: NodeTestStatus) -> Color {
        switch status {
        case .ultraFast: return Color(red: 0.05, green: 0.65, blue: 0.35)
        case .fast: return .green
        case .fairlyFast: return Color(red: 0.45, green: 0.75, blue: 0.2)
        case .fairlySlow: return .orange
        case .slow: return Color(red: 0.95, green: 0.45, blue: 0.1)
        case .ultraSlow: return Color(red: 0.85, green: 0.25, blue: 0.15)
        case .failed: return Color(red: 0.75, green: 0.2, blue: 0.15)
        case .unavailable: return .red
        case .testing: return .blue
        case .untested: return .secondary
        }
    }

    private struct TestResultRow: Identifiable {
        var id: UUID
        var name: String
        var countryName: String?
        var exitIPType: ExitIPType?
        var groupName: String
        var status: String
        var latency: String
        var statusColor: Color
        var isCurrent: Bool
        var isConnecting: Bool = false
        var isSelected: Bool
        var passedAppTargets: [AppProbeTarget]
        var appProbeCompleted: Bool
    }

    private func startScopedTest() async {
        await appState.testNodes(scopedTargets)
    }

    private var phaseColor: Color {
        switch testManager.phase {
        case .running: return .blue
        case .paused: return .orange
        case .finished: return .green
        case .idle: return .secondary
        }
    }
}

private struct SubscriptionScopeOption: Identifiable {
    var id: String
    var title: String
    var scope: NodeListFilter.Source
}

/// 路由页「信号塔」主题调色板，深浅色自适应。
private struct RoutePalette {
    var scheme: ColorScheme
    var bgTop: Color
    var bgBottom: Color
    var gridline: Color
    var card: Color
    var cardBorder: Color
    var editor: Color
    var text: Color
    var subtext: Color
    var accent: Color
    var onAccent: Color
    var line: Color

    init(scheme: ColorScheme) {
        self.scheme = scheme
        if scheme == .dark {
            bgTop = Color(red: 0.035, green: 0.075, blue: 0.095)
            bgBottom = Color(red: 0.060, green: 0.110, blue: 0.130)
            gridline = Color.white.opacity(0.035)
            card = Color.white.opacity(0.055)
            cardBorder = Color.white.opacity(0.10)
            editor = Color.black.opacity(0.30)
            text = Color(red: 0.92, green: 0.95, blue: 0.95)
            subtext = Color(red: 0.60, green: 0.68, blue: 0.70)
            accent = Color(red: 0.30, green: 0.85, blue: 0.58)
            onAccent = Color(red: 0.02, green: 0.12, blue: 0.08)
            line = Color.white.opacity(0.10)
        } else {
            bgTop = Color(red: 0.940, green: 0.958, blue: 0.965)
            bgBottom = Color(red: 0.890, green: 0.918, blue: 0.930)
            gridline = Color.black.opacity(0.035)
            card = .white
            cardBorder = Color.black.opacity(0.08)
            editor = Color(red: 0.952, green: 0.966, blue: 0.970)
            text = Color(red: 0.10, green: 0.16, blue: 0.18)
            subtext = Color(red: 0.42, green: 0.49, blue: 0.51)
            accent = Color(red: 0.02, green: 0.52, blue: 0.38)
            onAccent = .white
            line = Color.black.opacity(0.09)
        }
    }

    func modeTint(_ mode: RoutingMode) -> Color {
        let dark = scheme == .dark
        switch mode {
        case .global:
            return dark ? Color(red: 0.40, green: 0.65, blue: 1.0) : Color(red: 0.12, green: 0.38, blue: 0.85)
        case .direct:
            return dark ? Color(red: 0.62, green: 0.66, blue: 0.70) : Color(red: 0.45, green: 0.50, blue: 0.54)
        case .rules:
            return accent
        }
    }

    func statusColor(_ status: ConnectionStatus) -> Color {
        let dark = scheme == .dark
        switch status {
        case .connected:
            return dark ? Color(red: 0.30, green: 0.85, blue: 0.55) : Color(red: 0.05, green: 0.55, blue: 0.32)
        case .connecting, .disconnecting:
            return dark ? Color(red: 1.0, green: 0.70, blue: 0.25) : Color(red: 0.75, green: 0.48, blue: 0.05)
        case .error:
            return dark ? Color(red: 1.0, green: 0.45, blue: 0.40) : Color(red: 0.72, green: 0.22, blue: 0.16)
        case .disconnected:
            return dark ? Color(red: 0.55, green: 0.60, blue: 0.64) : Color(red: 0.55, green: 0.59, blue: 0.62)
        }
    }
}

/// 信号塔背景：渐变 + 网格线，像调度室的坐标图。
private struct RouteBackdrop: View {
    var palette: RoutePalette

    var body: some View {
        ZStack {
            LinearGradient(colors: [palette.bgTop, palette.bgBottom], startPoint: .top, endPoint: .bottom)
            Canvas { context, size in
                var path = Path()
                var x: CGFloat = 0
                while x <= size.width {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    x += 28
                }
                var y: CGFloat = 0
                while y <= size.height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    y += 28
                }
                context.stroke(path, with: .color(palette.gridline), lineWidth: 0.5)
            }
        }
        .ignoresSafeArea()
    }
}

/// 通用卡片容器。
private struct RouteCard<Content: View>: View {
    var title: String
    var icon: String
    var tint: Color
    var palette: RoutePalette
    var footnote: String? = nil
    var helpText: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.text)
                if let helpText {
                    UsageHelpButton(title: "\(title)使用说明", text: helpText)
                        .font(.system(size: 13))
                }
                if let footnote {
                    Spacer(minLength: 8)
                    Text(footnote)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.subtext)
                        .multilineTextAlignment(.trailing)
                }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(palette.cardBorder, lineWidth: 1)
        }
    }
}

/// 信号灯：选中轨道亮起并带光晕。
private struct SignalLamp: View {
    var tint: Color
    var active: Bool

    var body: some View {
        Circle()
            .fill(active ? tint : Color.gray.opacity(0.35))
            .frame(width: 10, height: 10)
            .shadow(color: active ? tint.opacity(0.7) : .clear, radius: 4)
    }
}

/// 路由模式轨道卡：点整张卡切换模式。
private struct RouteModeCard: View {
    var mode: RoutingMode
    var palette: RoutePalette
    var isActive: Bool
    var disabled: Bool
    var action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    SignalLamp(tint: palette.modeTint(mode), active: isActive)
                    Spacer(minLength: 4)
                    if isActive {
                        Text("当前")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(palette.onAccent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(palette.modeTint(mode), in: Capsule())
                    }
                }
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: icon)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(palette.modeTint(mode))
                        .frame(width: 32, alignment: .center)
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(mode.displayName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(palette.text)
                        Text(shortDesc)
                            .font(.system(size: 11))
                            .foregroundStyle(palette.subtext)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isActive ? palette.modeTint(mode).opacity(palette.scheme == .dark ? 0.14 : 0.10)
                    : (hovered ? palette.text.opacity(0.05) : Color.clear),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isActive ? palette.modeTint(mode).opacity(0.7) : palette.line,
                        lineWidth: isActive ? 1.4 : 1
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled && !isActive ? 0.55 : 1)
        .onHover { hovered = $0 }
        .help(mode.helpText)
    }

    private var icon: String {
        switch mode {
        case .global: return "globe"
        case .direct: return "arrow.right"
        case .rules: return "arrow.triangle.branch"
        }
    }

    private var shortDesc: String {
        switch mode {
        case .global: return "全部流量进隧道"
        case .direct: return "全部直连，不走节点"
        case .rules: return "按规则分流"
        }
    }
}

/// 分流走向里的一个站点。
private struct RouteFlowChip: View {
    var label: String
    var tint: Color
    var palette: RoutePalette

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.text)
                .fixedSize()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(palette.text.opacity(0.06), in: Capsule())
        .overlay { Capsule().strokeBorder(palette.line, lineWidth: 1) }
    }
}

/// 规则编辑器：标题 + 条数徽标 + 等宽文本区。
private struct RouteRuleEditor: View {
    var title: String
    var icon: String
    var tint: Color
    var palette: RoutePalette
    var count: Int
    var isEditing: Bool
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.text)
                Spacer(minLength: 4)
                Text("\(count) 条")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.subtext)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(palette.text.opacity(0.07), in: Capsule())
            }
            if isEditing {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(palette.editor)
                    .frame(minHeight: 120, maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(palette.line, lineWidth: 1)
                    }
                    .accessibilityLabel(title)
            } else {
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "暂无规则" : text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(palette.subtext)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }
}

struct RoutingView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var pendingRoutingMode: RoutingMode?
    @State private var portsDraft: AppSettings?
    @State private var portsBaseline: AppSettings?
    @State private var proxyApplicationsDraft: [ProxyApplication] = []
    @State private var routingDraftsLoaded = false
    @State private var editingRules = false
    @State private var editingPorts = false
    @State private var portsError: String?

    private var previewMode: RoutingMode { pendingRoutingMode ?? appState.settings.routingMode }
    private var previewPorts: AppSettings { portsDraft ?? appState.settings }
    @State private var draft = RoutingRules()
    @State private var saving = false
    @State private var ruleError: String?

    private var palette: RoutePalette { RoutePalette(scheme: colorScheme) }

    private var rulesActiveModeSummary: String {
        let mode = appState.settings.routingMode
        guard mode == .rules else { return "当前生效：\(mode.displayName)" }
        switch appState.settings.connectionCaptureMode {
        case .applications: return "当前生效：规则代理 · 仅指定应用"
        case .systemProxy: return "当前生效：规则代理 · 系统代理（全应用）"
        default: return "当前生效：规则代理 · \(appState.settings.connectionCaptureMode.displayName)"
        }
    }

    private var connectionStatus: ConnectionStatus { appState.connection.state.status }

    private var modeBusy: Bool {
        saving || appState.connection.isBusy ||
        connectionStatus == .connecting || connectionStatus == .disconnecting
    }

    private var rulesBusy: Bool {
        saving || connectionStatus == .connecting || connectionStatus == .disconnecting
    }

    private var draftDirty: Bool { draft != appState.settings.routingRules }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 700
            ScrollView {
                LazyVStack(spacing: 14) {
                    header
                    modeCard(wide: wide)
                    if previewMode == .global {
                        globalCard
                    }
                    if previewMode == .rules, HopWorldAppGroup.isSystemVPNAvailable {
                        captureModeCard
                    }
                    if previewMode == .rules {
                        RouteCard(title: "按应用代理", icon: "app.badge", tint: .orange, palette: palette, footnote: "实验性", helpText: """
                        所选应用走代理，其他应用直连。仅在「仅指定应用（TUN）」生效时，名单中的应用走代理。

                        连接节点并完成管理员授权后生效；首次连接会下载并校验 sing-box 核心。此模式不使用域名分流规则。

                        应用包内的辅助程序自动包含；包外命令行工具需单独添加，会匹配该工具的所有实例。应用后请重建连接，必要时重启目标应用。移除应用后，新连接直连，已有连接可能需要重启该应用。

                        系统 DNS 保持本地解析；局域网及无法识别进程的流量直连，此模式不提供防泄漏隔离。

                        请关闭其他 VPN / TUN 和第三方系统代理，避免冲突。断开后恢复本地网络；异常退出通常约 13 秒内清理，不含休眠时间。
                        """) {
                            ApplicationProxySection(applications: $proxyApplicationsDraft)
                                .disabled(previewMode != appState.settings.routingMode)
                            if previewMode != appState.settings.routingMode {
                                Text("先应用规则代理模式，再保存代理应用。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    flowCard
                    rulesCard(wide: wide)
                    portsCard
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .frame(maxWidth: 880)
                .frame(maxWidth: .infinity)
            }
            .background { RouteBackdrop(palette: palette) }
        }
        .onAppear {
            guard !routingDraftsLoaded else { return }
            draft = appState.settings.routingRules
            proxyApplicationsDraft = appState.settings.proxyApplications
            routingDraftsLoaded = true
        }
        .onChange(of: appState.settings.routingRules) { saved in
            if !editingRules { draft = saved }
        }

    }

    // MARK: - 页眉：标题 + 实时状态

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("ROUTING · 流量调度")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(palette.accent)
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(palette.text)
                    Text("信号塔")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(palette.text)
                        .fixedSize()
                    HStack(spacing: 7) {
                        Circle()
                            .fill(palette.statusColor(connectionStatus))
                            .frame(width: 8, height: 8)
                        Text(connectionStatus.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(palette.text)
                            .fixedSize()
                        Text(captureText)
                            .font(.system(size: 11))
                            .foregroundStyle(palette.subtext)
                            .lineLimit(1)
                            .help(captureText)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(palette.card, in: Capsule())
                    .overlay { Capsule().strokeBorder(palette.cardBorder, lineWidth: 1) }
                }
            }
            Spacer(minLength: 8)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(context.date, format: .dateTime.hour().minute().second())
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(palette.text)
            }
        }
    }

    private var captureText: String {
        CaptureStatusPresentation.text(
            status: connectionStatus,
            activeMode: appState.connection.effectiveCaptureMode,
            cleanupPending: appState.connection.captureCleanupFailed)
    }

    // MARK: - 路由模式：三条轨道

    private func modeCard(wide: Bool) -> some View {
        RouteCard(
            title: "路由模式", icon: "arrow.triangle.branch", tint: palette.accent,
            palette: palette, footnote: "选择仅预览，应用后生效",
            helpText: RoutingMode.allCases.map { "\($0.displayName)\n\($0.helpText)" }.joined(separator: "\n\n")
        ) {
            Group {
                if wide {
                    HStack(spacing: 10) {
                        ForEach(RoutingMode.allCases, id: \.self, content: modeCard(for:))
                    }
                } else {
                    VStack(spacing: 10) {
                        ForEach(RoutingMode.allCases, id: \.self, content: modeCard(for:))
                    }
                }
            }
            HStack {
                Text(rulesActiveModeSummary)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if previewMode != appState.settings.routingMode {
                    Button("取消修改") { pendingRoutingMode = nil }
                    Button("应用模式") {
                        let mode = previewMode
                        Task {
                            saving = true
                            await appState.setRoutingMode(mode)
                            pendingRoutingMode = nil
                            saving = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(modeBusy)
                }
            }

        }
    }

    private func modeCard(for mode: RoutingMode) -> some View {
        RouteModeCard(
            mode: mode,
            palette: palette,
            isActive: previewMode == mode,
            disabled: modeBusy
        ) {
            pendingRoutingMode = mode
        }
    }

    // MARK: - 接管方式（仅带 Network Extension 权限的构建）

    private var captureModeCard: some View {
        RouteCard(
            title: "接管方式", icon: "lock.shield", tint: palette.accent, palette: palette,
            helpText: [ConnectionCaptureMode.systemProxy, .systemVPN]
                .map { "\($0.displayName)\n\($0.helpText)" }
                .joined(separator: "\n\n")
        ) {
            Picker("接管方式", selection: captureModeSelection) {
                Text(ConnectionCaptureMode.systemProxy.displayName).tag(ConnectionCaptureMode.systemProxy)
                Text(ConnectionCaptureMode.systemVPN.displayName).tag(ConnectionCaptureMode.systemVPN)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(modeBusy || previewMode != appState.settings.routingMode)
            if previewMode != appState.settings.routingMode {
                Text("先应用规则代理模式，再选择接管方式。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if appState.settings.connectionCaptureMode == .applications {
                Text("当前为「仅指定应用（TUN）」；选择上方任一方式将改为全应用接管。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            infoRow(title: "实际接管状态", value: captureText)
        }
    }

    private var captureModeSelection: Binding<ConnectionCaptureMode> {
        Binding(
            get: { appState.settings.connectionCaptureMode },
            set: { mode in
                Task {
                    saving = true
                    await appState.setConnectionCaptureMode(mode)
                    saving = false
                }
            }
        )
    }

    // MARK: - 全局 TUN

    private var globalCard: some View {
        RouteCard(
            title: "全局 TUN", icon: "globe", tint: palette.modeTint(.global), palette: palette
        ) {
            Text("所有 App 自动进入隧道，无需单独勾选 Cursor 或其他应用。连接时需要管理员授权。")
                .font(.system(size: 12))
                .foregroundStyle(palette.subtext)
            infoRow(title: "实际接管状态", value: captureText)
        }
    }

    private func infoRow(title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(palette.subtext)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.text)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - 分流走向：优先级示意

    private var flowCard: some View {
        RouteCard(
            title: "分流走向", icon: "point.topleft.down.curvedto.point.bottomright.up",
            tint: palette.accent, palette: palette, footnote: "优先级从左到右"
        ) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    flowChip("拦截", tint: .red)
                    flowArrow
                    flowChip("强制代理", tint: .blue)
                    flowArrow
                    flowChip("强制直连", tint: .gray)
                    flowArrow
                    flowChip("本机 / 局域网", tint: .teal)
                    flowArrow
                    flowChip("国内直连", tint: .green)
                    flowArrow
                    flowChip("当前节点", tint: palette.accent)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func flowChip(_ label: String, tint: Color) -> some View {
        RouteFlowChip(label: label, tint: tint, palette: palette)
    }

    private var flowArrow: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(palette.subtext.opacity(0.7))
    }

    // MARK: - 规则代理分流

    private func rulesCard(wide: Bool) -> some View {
        RouteCard(
            title: "规则代理分流", icon: "list.bullet.rectangle",
            tint: palette.accent, palette: palette,
            footnote: draftDirty ? "有未保存修改" : nil,
            helpText: "仅在规则代理模式生效。每行一条：example.com（含子域名）、full:example.com（精确匹配）、1.2.3.4 或 10.0.0.0/8。支持 IPv6；# 开头为注释。\n\n已连接时会重连当前节点。全局/直连模式下保存，下次启用规则代理时生效。"
        ) {
            HStack {
                if editingRules {
                    Toggle("国内域名和 IP 直连", isOn: $draft.bypassChina)
                        .tint(palette.accent)
                } else {
                    Label(draft.bypassChina ? "国内域名和 IP 直连" : "国内域名和 IP 不直连",
                          systemImage: draft.bypassChina ? "checkmark.circle" : "minus.circle")
                        .font(.callout)
                        .foregroundStyle(palette.subtext)
                }
                Spacer()
                if editingRules {
                    Button(saving ? "正在应用…" : "保存并应用") {
                        saving = true
                        ruleError = nil
                        Task {
                            do { try await appState.saveRoutingRules(draft); editingRules = false }
                            catch { ruleError = error.localizedDescription }
                            saving = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.accent)
                    .disabled(saving)
                    Button("取消") { draft = appState.settings.routingRules; ruleError = nil; editingRules = false }
                        .buttonStyle(.bordered)
                        .disabled(saving)
                } else {
                    Button("编辑") { draft = appState.settings.routingRules; editingRules = true }
                        .buttonStyle(.bordered)
                }
            }
            Group {
                if wide {
                    HStack(alignment: .top, spacing: 12) {
                        ruleEditors
                    }
                } else {
                    VStack(spacing: 12) {
                        ruleEditors
                    }
                }
            }
            if let ruleError {
                Text(ruleError)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

        }
        .disabled(rulesBusy)
    }

    @ViewBuilder
    private var ruleEditors: some View {
        RouteRuleEditor(
            title: "强制代理", icon: "paperplane.fill",
            tint: .blue, palette: palette,
            count: entryCount(draft.proxy), isEditing: editingRules, text: $draft.proxy
        )
        RouteRuleEditor(
            title: "强制直连", icon: "arrow.right.circle.fill",
            tint: .gray, palette: palette,
            count: entryCount(draft.direct), isEditing: editingRules, text: $draft.direct
        )
        RouteRuleEditor(
            title: "拦截", icon: "octagon.fill",
            tint: .red, palette: palette,
            count: entryCount(draft.blocked), isEditing: editingRules, text: $draft.blocked
        )
    }

    private func entryCount(_ text: String) -> Int {
        text.components(separatedBy: .newlines).filter {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty && !value.hasPrefix("#")
        }.count
    }

    // MARK: - 本地端口

    private var portsCard: some View {
        RouteCard(
            title: "本地端口", icon: "cable.connector",
            tint: palette.accent, palette: palette
        ) {
            HStack {
                Text(editingPorts ? "保存后下次连接生效" : "本地监听地址")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if editingPorts {
                    Button("应用端口") { applyPortsDraft(); if portsDraft == nil { editingPorts = false } }
                        .buttonStyle(.borderedProminent)
                        .disabled(portsDraft == nil || modeBusy)
                    Button("取消") { portsDraft = nil; portsBaseline = nil; portsError = nil; editingPorts = false }
                        .buttonStyle(.bordered)
                } else {
                    Button("编辑") { editingPorts = true }
                        .buttonStyle(.bordered)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), alignment: .leading)], alignment: .leading, spacing: 8) {
                if editingPorts {
                    HStack(spacing: 6) {
                        Text("SOCKS").font(.caption)
                        TextField("主机", text: Binding(get: { previewPorts.socksHost }, set: { value in updatePortsDraft { $0.socksHost = value } }))
                            .accessibilityLabel("SOCKS 主机")
                        TextField("端口", value: Binding(get: { previewPorts.socksPort }, set: { value in updatePortsDraft { $0.socksPort = value } }), format: .number.grouping(.never))
                            .frame(width: 70).accessibilityLabel("SOCKS 端口")
                    }
                    HStack(spacing: 6) {
                        Text("HTTP").font(.caption)
                        TextField("主机", text: Binding(get: { previewPorts.httpHost }, set: { value in updatePortsDraft { $0.httpHost = value } }))
                            .accessibilityLabel("HTTP 主机")
                        TextField("端口", value: Binding(get: { previewPorts.httpPort }, set: { value in updatePortsDraft { $0.httpPort = value } }), format: .number.grouping(.never))
                            .frame(width: 70).accessibilityLabel("HTTP 端口")
                    }
                } else {
                    Text("SOCKS  \(previewPorts.socksHost):\(String(previewPorts.socksPort))")
                    Text("HTTP  \(previewPorts.httpHost):\(String(previewPorts.httpPort))")
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.callout.monospacedDigit())
            if let portsError { Text(portsError).font(.caption).foregroundStyle(.orange) }
        }
    }

    private func updatePortsDraft(_ mutate: (inout AppSettings) -> Void) {
        if portsBaseline == nil { portsBaseline = appState.settings }
        var updated = previewPorts
        mutate(&updated)
        if let baseline = portsBaseline,
           baseline.applyingSettingsEdits(from: updated, comparedTo: baseline) == baseline {
            portsDraft = nil
            portsBaseline = nil
        } else {
            portsDraft = updated
        }
        portsError = nil
    }

    private func applyPortsDraft() {
        guard let draft = portsDraft, let baseline = portsBaseline else { return }
        guard (1...65535).contains(draft.socksPort), (1...65535).contains(draft.httpPort),
              draft.socksPort != draft.httpPort,
              !draft.socksHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !draft.httpHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            portsError = "请填写有效主机和不同的端口（1–65535）。"
            return
        }
        appState.updateSettings { $0 = $0.applyingSettingsEdits(from: draft, comparedTo: baseline) }
        portsDraft = nil
        portsBaseline = nil
        portsError = nil
    }


}

/// 设置页「控制室」主题调色板，深浅色自适应。
private struct SetPalette {
    var scheme: ColorScheme
    var bgTop: Color
    var bgBottom: Color
    var gridline: Color
    var card: Color
    var cardBorder: Color
    var text: Color
    var subtext: Color
    var accent: Color
    var onAccent: Color
    var line: Color

    init(scheme: ColorScheme) {
        self.scheme = scheme
        if scheme == .dark {
            bgTop = Color(red: 0.045, green: 0.075, blue: 0.085)
            bgBottom = Color(red: 0.065, green: 0.105, blue: 0.115)
            gridline = Color.white.opacity(0.035)
            card = Color.white.opacity(0.055)
            cardBorder = Color.white.opacity(0.10)
            text = Color(red: 0.92, green: 0.95, blue: 0.95)
            subtext = Color(red: 0.60, green: 0.67, blue: 0.69)
            accent = Color(red: 0.45, green: 0.78, blue: 0.85)
            onAccent = Color(red: 0.03, green: 0.12, blue: 0.14)
            line = Color.white.opacity(0.10)
        } else {
            bgTop = Color(red: 0.942, green: 0.956, blue: 0.960)
            bgBottom = Color(red: 0.895, green: 0.918, blue: 0.926)
            gridline = Color.black.opacity(0.035)
            card = .white
            cardBorder = Color.black.opacity(0.08)
            text = Color(red: 0.11, green: 0.15, blue: 0.17)
            subtext = Color(red: 0.43, green: 0.48, blue: 0.50)
            accent = Color(red: 0.10, green: 0.44, blue: 0.55)
            onAccent = .white
            line = Color.black.opacity(0.09)
        }
    }
}

/// 控制室背景：渐变 + 蓝图网格。
private struct SetBackdrop: View {
    var palette: SetPalette

    var body: some View {
        ZStack {
            LinearGradient(colors: [palette.bgTop, palette.bgBottom], startPoint: .top, endPoint: .bottom)
            Canvas { context, size in
                var path = Path()
                var x: CGFloat = 0
                while x <= size.width {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    x += 28
                }
                var y: CGFloat = 0
                while y <= size.height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    y += 28
                }
                context.stroke(path, with: .color(palette.gridline), lineWidth: 0.5)
            }
        }
        .ignoresSafeArea()
    }
}

/// 设置分组卡片。
private struct SetCard<Content: View>: View {
    var title: String
    var icon: String
    var palette: SetPalette
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.text)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(palette.cardBorder, lineWidth: 1)
        }
    }
}

private struct SubscriptionTimeZonePicker: View {
    @Binding var selection: String
    private static let identifiers = Set(TimeZone.knownTimeZoneIdentifiers + ["UTC"])

    var body: some View {
        let current = TimeZone.current.identifier
        Picker("默认地区（时区）", selection: $selection) {
            Text("当前地区 · \(Self.title(for: current))").tag(current)
            Divider()
            ForEach(Self.identifiers.union([selection]).sorted().filter { $0 != current }, id: \.self) { identifier in
                Text(Self.title(for: identifier)).tag(identifier)
            }
        }
        .pickerStyle(.menu)
        .help("当前地区取自 macOS 系统时区；新建订阅使用所选地区。")
    }

    private static func title(for identifier: String) -> String {
        guard let zone = TimeZone(identifier: identifier) else { return identifier }
        let name = zone.localizedName(for: .shortGeneric, locale: Locale(identifier: "zh_CN")) ?? identifier
        return "\(name) · \(identifier)"
    }
}

private struct NodeNameAdFilterSettings: View {
    @Binding var isEnabled: Bool
    @Binding var filterText: String
    @State private var isAdding = false
    @State private var pendingFilter = ""
    @FocusState private var inputFocused: Bool

    private var filters: [String] {
        filterText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var trimmedFilter: String {
        pendingFilter.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDuplicate: Bool {
        filters.contains { $0.caseInsensitiveCompare(trimmedFilter) == .orderedSame }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle("过滤节点名称广告", isOn: $isEnabled)
                    .fixedSize()
                Button("添加") { isAdding = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!isEnabled || isAdding)
                    .accessibilityLabel("添加额外过滤文字")
                Spacer(minLength: 0)
            }
            Text("自动隐藏常见格式的推广文字，保留国家、线路信息；关闭后显示原始名称。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 22)

            if isEnabled {
                if isAdding {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            TextField("输入要过滤的广告文字", text: $pendingFilter)
                                .textFieldStyle(.roundedBorder)
                                .focused($inputFocused)
                                .onAppear { inputFocused = true }
                                .onSubmit(addFilter)
                                .accessibilityLabel("额外过滤文字")
                            Button("确定", action: addFilter)
                                .buttonStyle(.borderedProminent)
                                .disabled(trimmedFilter.isEmpty || isDuplicate)
                            Button("取消", action: cancelAdding)
                                .buttonStyle(.bordered)
                        }
                        .controlSize(.small)
                        Text(isDuplicate ? "该文字已添加。" : "按原文匹配，不区分英文大小写；添加后点击「应用设置」生效。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 22)
                }

                if !filters.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(filters.enumerated()), id: \.offset) { index, text in
                            HStack(spacing: 8) {
                                Text(text)
                                    .font(.callout)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                Button {
                                    var updated = filters
                                    updated.remove(at: index)
                                    filterText = updated.joined(separator: "\n")
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("移除这条过滤文字")
                                .accessibilityLabel("移除过滤文字：\(text)")
                            }
                        }
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.leading, 22)
                }
            }
        }
        .onChange(of: isEnabled) { enabled in
            if !enabled { cancelAdding() }
        }
    }

    private func addFilter() {
        guard isEnabled, !trimmedFilter.isEmpty, !isDuplicate else { return }
        filterText = (filters + [trimmedFilter]).joined(separator: "\n")
        cancelAdding()
    }

    private func cancelAdding() {
        pendingFilter = ""
        isAdding = false
        inputFocused = false
    }
}

struct SettingsView: View {
    private enum BackupOperation: String, Identifiable {
        case export, restore
        var id: String { rawValue }
        var title: String { self == .export ? "导出备份" : "从备份恢复" }
        var confirmTitle: String { self == .export ? "导出…" : "选择文件…" }
    }

    private struct CountryListConflict {
        let code: String
        let name: String
        let addingToAllowed: Bool
        var destination: String { addingToAllowed ? "指定国家" : "排除国家" }
        var source: String { addingToAllowed ? "排除国家" : "指定国家" }
    }
    @State private var settingsDraft: AppSettings?
    @State private var settingsBaseline: AppSettings?
    @State private var customTestURL = ""
    @State private var customTestURLName = ""
    @State private var customTestURLUsesGenerate204 = false
    @State private var isAddingCustomTestURL = false
    @FocusState private var customTestURLNameFocused: Bool
    @State private var testURLFeedback: String?
    @State private var settingsFeedback: String?
    @State private var countryListConflict: CountryListConflict?
    @State private var countryListFeedback: String?
    @EnvironmentObject private var appState: AppState
    @State private var showingScheduledScopeHelp = false
    @State private var showingFavoritePreferenceHelp = false
    @State private var showingUpdateModeHelp = false
    @State private var backupPassphrase = ""
    @State private var backupOperation: BackupOperation?
    @FocusState private var backupPasswordFocused: Bool
    @State private var includeCredentialsInBackup = false
    @State private var includeSettingsInBackup = true
    @State private var includeManualNodesInBackup = true
    @State private var selectedBackupSubscriptionIDs: Set<UUID> = []
    @State private var backupFeedback: String?
    @State private var backupDialogFeedback: String?
    @State private var pendingImportData: Data?
    @State private var pendingImportPassphrase = ""
    @State private var showReplaceImportConfirm = false
    @Environment(\.colorScheme) private var colorScheme

    private var palette: SetPalette { SetPalette(scheme: colorScheme) }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                settingsHeader
                themeSettings
                SetCard(title: "中文地名离线库", icon: "globe.asia.australia", palette: palette) {
                    ChineseCityLibrarySettings()
                }
                SetCard(title: "常规", icon: "gearshape", palette: palette) {
                Toggle("登录时启动", isOn: Binding(
                    get: { previewSettings.launchAtLogin },
                    set: { value in updateDraftSettings { $0.launchAtLogin = value } }
                ))
                Toggle("节点信息显示中文", isOn: Binding(
                    get: { previewSettings.showChineseNodeMetadata },
                    set: { value in updateDraftSettings { $0.showChineseNodeMetadata = value } }
                ))
                .help("默认开启。仅可用节点会自动在线匹配中文城市；未找到可靠中文名时显示原名，悬停提示中文名待补充。")
                NodeNameAdFilterSettings(isEnabled: Binding(
                    get: { previewSettings.filterNodeNameAds },
                    set: { value in updateDraftSettings { $0.filterNodeNameAds = value } }
                ), filterText: Binding(
                    get: { previewSettings.nodeNameAdFilterText },
                    set: { value in updateDraftSettings { $0.nodeNameAdFilterText = value } }
                ))
                Picker("启动后", selection: Binding(
                    get: { previewSettings.connectOnLaunch },
                    set: { value in updateDraftSettings { $0.connectOnLaunch = value } }
                )) {
                    ForEach(ConnectOnLaunch.allCases, id: \.self) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                Toggle("电脑锁屏时自动断开连接", isOn: Binding(
                    get: { previewSettings.disconnectOnScreenLock },
                    set: { value in updateDraftSettings { $0.disconnectOnScreenLock = value } }
                ))
                if previewSettings.disconnectOnScreenLock {
                    Stepper(
                        "锁屏后断开：\(previewSettings.screenLockDisconnectDelayMinutes) 分钟",
                        value: Binding(
                            get: { previewSettings.screenLockDisconnectDelayMinutes },
                            set: { value in updateDraftSettings { $0.screenLockDisconnectDelayMinutes = value } }
                        ),
                        in: 0...1440
                    )
                }
                HStack {
                    Text("锁屏断开说明").font(.caption).foregroundStyle(.secondary)
                    UsageHelpButton(title: "锁屏断开说明", text: "默认锁屏 15 分钟后断开并恢复系统网络设置；提前解锁会取消断开。设为 0 分钟则立即断开。关闭此选项后，锁屏期间保留连接，并继续执行定时检测、订阅更新和数据保存。电脑需要保持唤醒；系统睡眠或注销会暂停运行。")
                }
            }

            SetCard(title: "连接", icon: "cable.connector", palette: palette) {
                Toggle("自动故障切换", isOn: Binding(
                    get: { previewSettings.autoFailover },
                    set: { value in updateDraftSettings { $0.autoFailover = value } }
                ))

                HStack {
                    Toggle("依据 Codex 应用健康智能切换", isOn: Binding(
                        get: { previewSettings.codexSmartFailover },
                        set: { value in updateDraftSettings { $0.codexSmartFailover = value } }
                    ))
                    .disabled(!previewSettings.autoFailover)
                    UsageHelpButton(
                        title: "Codex 智能切换说明",
                        text: "连接策略对所有节点统一生效，修改后点击“应用设置”。需开启概览中的自动优选和 TUN 接管。开启后，主要依据状态 2（无法加载工作空间设置）、状态 3（正在重新连接）、状态 4（等待网络）判断故障。慢连接和偶发超时会先延长等待并复验，持续不可用才按顺序切换备用节点；故障期间状态 1 检查成功时，会额外观察，同一故障只延长一次。状态 1 异常、对话空闲、认证或服务异常不会单独触发切换。"
                    )
                }
                LabeledContent("当前自动恢复状态", value: appState.applicationHealthSwitchStatus)
                    .font(.caption)

                Picker("候选范围", selection: Binding(
                    get: { previewSettings.failoverPoolMode },
                    set: { value in updateDraftSettings { $0.failoverPoolMode = value } }
                )) {
                    ForEach(FailoverPoolMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .disabled(!previewSettings.autoFailover)

                if previewSettings.failoverPoolMode == .limited {
                    Stepper(
                        "最大尝试节点：\(previewSettings.maxFailoverAttempts)",
                        value: Binding(
                            get: { previewSettings.maxFailoverAttempts },
                            set: { value in updateDraftSettings { $0.maxFailoverAttempts = value } }
                        ),
                        in: 1...50
                    )
                    .disabled(!previewSettings.autoFailover)
                }

                Stepper(
                    "连接超时：\(previewSettings.connectTimeoutSeconds) 秒",
                    value: Binding(
                        get: { previewSettings.connectTimeoutSeconds },
                        set: { value in updateDraftSettings { $0.connectTimeoutSeconds = value } }
                    ),
                    in: 1...99
                )
                Text("默认 15 秒。慢连接和偶发超时先延长等待并复验，仍无法连通时再尝试备用节点。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(
                    previewSettings.failoverPoolMode == .allAvailable
                        ? (previewSettings.autoAppProbeUsableNodes
                            ? "复验仍失败时，按应用优先顺序和延迟依次尝试全部可用节点"
                            : "复验仍失败时，按测速延迟依次尝试全部可用节点")
                        : (previewSettings.autoAppProbeUsableNodes
                            ? "复验仍失败时，按应用优先顺序和延迟依次尝试前 \(previewSettings.maxFailoverAttempts) 个可用节点"
                            : "复验仍失败时，按测速延迟依次尝试前 \(previewSettings.maxFailoverAttempts) 个可用节点")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            SetCard(title: "自动优选国家", icon: "globe", palette: palette) {
                Picker("连接范围", selection: Binding(
                    get: { previewSettings.autoSelectCountryScope },
                    set: { value in updateDraftSettings { $0.autoSelectCountryScope = value } }
                )) {
                    ForEach(AutoSelectCountryScope.allCases, id: \.self) { scope in
                        Text(scope.displayName).tag(scope)
                    }
                }
                .pickerStyle(.segmented)

                Picker("最低速度", selection: Binding(
                    get: { previewSettings.autoSelectMinimumSpeed },
                    set: { value in updateDraftSettings { $0.autoSelectMinimumSpeed = value } }
                )) {
                    ForEach(AutoSelectMinimumSpeed.allCases, id: \.self) { speed in
                        Text(speed.displayName).tag(speed)
                    }
                }
                Text("选择“较快及以上”时，会包含较快、快和特快节点。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper("自动切换延时：\(previewSettings.autoSelectUnhealthySeconds) 秒", value: Binding(
                    get: { previewSettings.autoSelectUnhealthySeconds },
                    set: { value in updateDraftSettings { $0.autoSelectUnhealthySeconds = value } }
                ), in: 5...300, step: 5)
                Text("持续超时或低于最低速度要求后自动优选其它节点；恢复正常则重新计时。按实时探测结果检查，无合格节点时保留连接。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if previewSettings.autoSelectCountryScope == .specified {
                    HStack {
                        Text("允许连接")
                        Spacer()
                        Menu {
                            if availableAutoSelectCountries.isEmpty {
                                Text("没有可添加的国家")
                            } else {
                                ForEach(availableAutoSelectCountries) { country in
                                    Button("\(country.flag) \(country.name)（\(country.nodes.count)）") {
                                        requestAddCountry(country, toAllowed: true)
                                    }
                                }
                            }
                        } label: {
                            Label("添加国家", systemImage: "plus")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }

                    if includedAutoSelectCountries.isEmpty {
                        Text("尚未指定国家，自动优选将不会连接任何节点")
                            .foregroundStyle(.orange)
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 112, maximum: 170), spacing: 8)],
                            alignment: .leading,
                            spacing: 8
                        ) {
                            ForEach(includedAutoSelectCountries, id: \.code) { country in
                                HStack(spacing: 6) {
                                    Text(country.flag)
                                    Text(country.name)
                                        .font(.callout)
                                        .lineLimit(1)
                                    Text("\(country.nodeCount)")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                    Spacer(minLength: 2)
                                    Button {
                                        updateDraftSettings { settings in
                                            settings.autoSelectIncludedCountryCodes.remove(country.code)
                                        }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("移除\(country.name)")
                                }
                                .padding(.leading, 9)
                                .padding(.trailing, 7)
                                .frame(height: 28)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                                .overlay { Capsule().stroke(Color.primary.opacity(0.08)) }
                            }
                        }
                    }
                }
                Group {
                    HStack {
                        Text("排除国家")
                        Spacer()
                        Menu {
                            if availableAutoSelectExcludedCountries.isEmpty {
                                Text("没有可排除的国家")
                            } else {
                                ForEach(availableAutoSelectExcludedCountries) { country in
                                    Button("\(country.flag) \(country.name)（\(country.nodes.count)）") {
                                        requestAddCountry(country, toAllowed: false)
                                    }
                                }
                            }
                        } label: {
                            Label("添加国家", systemImage: "plus")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("已排除 \(excludedAutoSelectCountries.count) 个国家")
                            .font(.subheadline)
                        if excludedAutoSelectCountries.isEmpty {
                            Text("尚未排除任何国家，请点击上方“添加国家”。")
                                .foregroundStyle(.secondary)
                        }
                        WrappingFlow(spacing: 8) {
                            ForEach(excludedAutoSelectCountries, id: \.code) { country in
                                HStack(spacing: 6) {
                                    Text(country.flag)
                                    Text(country.name).font(.callout).lineLimit(1)
                                    Spacer(minLength: 2)
                                    Button {
                                        updateDraftSettings { $0.autoSelectExcludedCountryCodes.remove(country.code) }
                                        countryListFeedback = "已取消排除：\(country.name)"
                                    } label: {
                                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("移除\(country.name)")
                                }
                                .padding(.horizontal, 9)
                                .frame(height: 28)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let countryListFeedback {
                    Label(countryListFeedback, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Text("自动优选只使用连接范围内且未被排除的国家；排除优先于指定。仍可手动连接其它节点。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SetCard(title: "定时测速", icon: "timer", palette: palette) {
                Toggle("启用定时测速", isOn: Binding(
                    get: { previewSettings.scheduledTestEnabled },
                    set: { value in updateDraftSettings { $0.scheduledTestEnabled = value } }
                ))
                Stepper(
                    "间隔：\(previewSettings.scheduledTestIntervalMinutes) 分钟",
                    value: Binding(
                        get: { previewSettings.scheduledTestIntervalMinutes },
                        set: { value in
                            updateDraftSettings {
                                $0.scheduledTestIntervalMinutes = max(5, value)
                            }
                        }
                    ),
                    in: 5...1440,
                    step: 5
                )
                .disabled(!previewSettings.scheduledTestEnabled)

                Picker("订阅范围", selection: Binding(
                    get: { previewSettings.scheduledTestSubscriptionRaw },
                    set: { value in updateDraftSettings { $0.scheduledTestSubscriptionRaw = value } }
                )) {
                    Text("全部订阅").tag("all")
                    ForEach(appState.subscriptions) { sub in
                        Text(sub.name).tag("subscription:\(sub.id.uuidString)")
                    }
                }
                .disabled(!previewSettings.scheduledTestEnabled)

                Picker(selection: Binding(
                    get: { previewSettings.scheduledTestScope },
                    set: { value in updateDraftSettings { $0.scheduledTestScope = value } }
                )) {
                    ForEach(ScheduledTestNodeScope.allCases, id: \.self) { scope in
                        Text(scope.displayName).tag(scope)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("节点范围")
                        Button {
                            showingScheduledScopeHelp = true
                        } label: {
                            Image(systemName: "questionmark.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("查看节点范围说明")
                    }
                }
                .disabled(!previewSettings.scheduledTestEnabled)
                .alert("节点范围说明", isPresented: $showingScheduledScopeHelp) {
                    Button("好", role: .cancel) {}
                } message: {
                    Text(
                        ScheduledTestNodeScope.allCases
                            .map { "· \($0.displayName)\n\($0.helpText)" }
                            .joined(separator: "\n\n")
                        + "\n\n另：已连接或收藏节点测速失败时，不会从「可用」降成「不可用」，也不会取消收藏。"
                    )
                }

                if let last = appState.settings.lastScheduledTestAt {
                    Text("上次定时测速：\(last.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            SetCard(title: "测试", icon: "flask", palette: palette) {
                testURLSettings
                Stepper(
                    "批量并发：\(min(16, previewSettings.testConcurrency))",
                    value: Binding(
                        get: { previewSettings.testConcurrency },
                        set: { value in updateDraftSettings { $0.testConcurrency = value } }
                    ),
                    in: 1...16
                )
                Stepper(
                    "单测超时：\(previewSettings.testTimeoutSeconds) 秒",
                    value: Binding(
                        get: { previewSettings.testTimeoutSeconds },
                        set: { value in updateDraftSettings { $0.testTimeoutSeconds = value } }
                    ),
                    in: 1...30
                )
                HStack {
                    Text("单节点测速说明").font(.caption).foregroundStyle(.secondary)
                    UsageHelpButton(title: "单节点测速说明", text: "右键/详情只测 1 个节点，以及「单测」路径使用此时限；慢握手节点可调高。")
                }
                Stepper(
                    "批量测速超时：\(previewSettings.batchTestTimeoutSeconds) 秒",
                    value: Binding(
                        get: { previewSettings.batchTestTimeoutSeconds },
                        set: { value in updateDraftSettings { $0.batchTestTimeoutSeconds = value } }
                    ),
                    in: 1...30
                )
                HStack {
                    Text("批量测速说明").font(.caption).foregroundStyle(.secondary)
                    UsageHelpButton(title: "批量测速说明", text: "每个节点的 HTTPS 预算，默认 2 秒；批量不自动延长或重复测试，进程清理最多另需约 1 秒。TCP 预检最多 3 秒，慢握手节点可调高预算或单独复测。")
                }
                HStack {
                    Toggle("自动测试可用节点的应用连通", isOn: Binding(
                        get: { previewSettings.autoAppProbeUsableNodes },
                        set: { value in updateDraftSettings { $0.autoAppProbeUsableNodes = value } }
                    ))
                    UsageHelpButton(title: "自动应用连通说明", text: "关闭（默认）时，手动与后台测速完成后都不自动继续应用探测，自动优选只按测速延迟排序。开启后，测速结束会补测可用节点，并按应用优先顺序比较连通结果，再结合收藏偏好和延迟优选。也可在「应用连通 → 可用」中独立手动测试；进度显示在「测试仪表」。\n\n探测名单默认来自「路由 → 按应用代理」，也可改用默认应用或自定义应用；只检查网址能否打开，不会启动应用，也不会改变哪些应用走代理。浏览器默认测 Google，没有对应网址的应用需要填写。")
                }
                InstalledAppProbeSettings(settings: Binding(
                    get: { previewSettings },
                    set: { updated in
                        updateDraftSettings { $0.installedAppProbes = updated.installedAppProbes }
                    }
                ))
                Stepper(
                    "应用连通超时：\(previewSettings.appProbeTimeoutSeconds) 秒",
                    value: Binding(
                        get: { previewSettings.appProbeTimeoutSeconds },
                        set: { value in updateDraftSettings { $0.appProbeTimeoutSeconds = value } }
                    ),
                    in: 1...30
                )
                Text("每个应用目标的最长等待；手动点「探测应用」不受上方自动开关限制。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper(
                    "结果有效期：\(previewSettings.testResultTTLMinutes) 分钟",
                    value: Binding(
                        get: { previewSettings.testResultTTLMinutes },
                        set: { value in updateDraftSettings { $0.testResultTTLMinutes = value } }
                    ),
                    in: 5...180
                )
            }

            SetCard(title: "订阅默认值", icon: "link.badge.plus", palette: palette) {
                Stepper(
                    "默认更新时间 \(String(format: "%02d:%02d", previewSettings.defaultUpdateHour, previewSettings.defaultUpdateMinute))",
                    value: Binding(
                        get: { previewSettings.defaultUpdateHour },
                        set: { value in updateDraftSettings { $0.defaultUpdateHour = value } }
                    ),
                    in: 0...23
                )
                SubscriptionTimeZonePicker(selection: Binding(
                    get: { previewSettings.defaultTimeZoneID },
                    set: { value in updateDraftSettings { $0.defaultTimeZoneID = value } }
                ))
                Picker(selection: Binding(
                    get: { previewSettings.defaultUpdateMode },
                    set: { value in updateDraftSettings { $0.defaultUpdateMode = value } }
                )) {
                    ForEach(SubscriptionUpdateMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("默认更新模式")
                        Button {
                            showingUpdateModeHelp = true
                        } label: {
                            Image(systemName: "questionmark.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("查看更新模式说明")
                    }
                }
                .alert("更新模式说明", isPresented: $showingUpdateModeHelp) {
                    Button("好", role: .cancel) {}
                } message: {
                    Text(
                        SubscriptionUpdateMode.allCases
                            .map { "· \($0.displayName)\n\($0.helpText)" }
                            .joined(separator: "\n\n")
                    )
                }
                Stepper(
                    "默认回退天数：\(previewSettings.defaultFallbackDays)",
                    value: Binding(
                        get: { previewSettings.defaultFallbackDays },
                        set: { value in updateDraftSettings { $0.defaultFallbackDays = value } }
                    ),
                    in: 0...14
                )
            }

            SetCard(title: "节点", icon: "paperplane", palette: palette) {
                Picker(selection: Binding(
                    get: { previewSettings.favoritePreference },
                    set: { value in updateDraftSettings { $0.favoritePreference = value } }
                )) {
                    ForEach(FavoritePreference.allCases, id: \.self) { item in
                        Text(item.displayName).tag(item)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("收藏策略")
                        Button {
                            showingFavoritePreferenceHelp = true
                        } label: {
                            Image(systemName: "questionmark.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("查看收藏策略说明")
                    }
                }
                .alert("收藏策略说明", isPresented: $showingFavoritePreferenceHelp) {
                    Button("好", role: .cancel) {}
                } message: {
                    Text(
                        FavoritePreference.allCases
                            .map { "· \($0.displayName)\n\($0.helpText)" }
                            .joined(separator: "\n\n")
                        + "\n\n另：收藏节点可定时测速；失败不会取消收藏，也不会从「可用」里移除。"
                    )
                }
            }

            SetCard(title: "数据备份", icon: "externaldrive", palette: palette) {
                backupSettings
            }

            SetCard(title: "高级", icon: "wrench", palette: palette) {
                Picker("日志等级", selection: Binding(
                    get: { previewSettings.logLevel },
                    set: { value in updateDraftSettings { $0.logLevel = value } }
                )) {
                    ForEach(AppLogLevel.allCases, id: \.self) { level in
                        Text(level.displayName).tag(level)
                    }
                }

                if XrayProcessManager.resolveBinaryURL() == nil {
                    Text("未检测到本地 xray。请打开「关于 → 管理更新」安装；首次连接也会自动下载。下载失败可切换下载线路。")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Button("打开管理更新") { appState.showComponentUpdates = true }
                        .buttonStyle(.bordered)
                } else {
                    Text("已检测到 xray：\(XrayProcessManager.resolveBinaryURL()!.path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background { SetBackdrop(palette: palette) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Text(settingsDraft == nil ? "主题即时保存，其他设置修改后点击应用。" : "有未保存的设置")
                    .font(.caption).foregroundStyle(.secondary)
                if let settingsFeedback { Text(settingsFeedback).font(.caption).foregroundStyle(.orange) }
                Spacer()
                Button("取消修改") {
                    settingsDraft = nil
                    settingsBaseline = nil
                    settingsFeedback = nil
                    countryListFeedback = nil
                    cancelCustomTestURLAddition()
                    cancelBackupOperation()
                }
                    .disabled(settingsDraft == nil)
                Button("应用设置") { applySettingsDraft() }
                    .buttonStyle(.borderedProminent)
                    .disabled(settingsDraft == nil)
            }
            .padding(12)
            .background(.regularMaterial)
        }
        .onDisappear(perform: cancelBackupOperation)
        .sheet(item: $backupOperation, onDismiss: dismissBackupSheet) { operation in
            backupDialog(for: operation)
        }
        .alert("国家名单冲突", isPresented: Binding(
            get: { countryListConflict != nil },
            set: { if !$0 { countryListConflict = nil } }
        ), presenting: countryListConflict) { conflict in
            Button("移至\(conflict.destination)") {
                addCountry(conflict.code, toAllowed: conflict.addingToAllowed)
                countryListConflict = nil
            }
            Button("取消", role: .cancel) { countryListConflict = nil }
        } message: { conflict in
            Text("\(conflict.name)已在“\(conflict.source)”中。是否从该名单移除，并加入“\(conflict.destination)”？\(conflict.addingToAllowed ? "保存设置后，指定国家模式下将允许自动优选该国家。" : "保存设置后，自动优选将不再连接该国家。")")
        }
        .confirmationDialog(
            "覆盖当前节点与订阅？",
            isPresented: $showReplaceImportConfirm,
            titleVisibility: .visible
        ) {
            Button("覆盖并恢复", role: .destructive) {
                applyPendingImport(replaceExisting: true)
            }
            Button("取消", role: .cancel) {
                cancelBackupOperation()
            }
        } message: {
            Text("将用备份替换本机全部节点与订阅；若备份含应用配置也会一并覆盖（连接状态不受影响，建议先断开）。")
        }
    }

    private var themeSettings: some View {
        SetCard(title: "主题", icon: "paintpalette", palette: palette) {
            Picker("主题模式", selection: Binding(
                get: { appState.settings.theme },
                set: { theme in appState.updateSettingsFromView { $0.theme = theme } }
            )) {
                ForEach(AppTheme.allCases, id: \.self) { theme in
                    Text(theme.displayName).tag(theme)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("更改后立即生效，并自动保存。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var testURLSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("连通性测试地址")
                    .fixedSize()
                Picker("连通性测试地址", selection: Binding(
                    get: { previewSettings.testURL },
                    set: { value in updateDraftSettings { $0.testURL = value } }
                )) {
                    ForEach(previewSettings.availableTestURLs, id: \.self) { url in
                        Text("\(previewSettings.testURLDisplayTitle(url)) · \(url)").tag(url)
                    }
                }
                .labelsHidden()
                .layoutPriority(-1)
                Button("添加") { isAddingCustomTestURL = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(isAddingCustomTestURL)
                    .accessibilityLabel("添加连通性测试地址")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isAddingCustomTestURL {
                HStack(spacing: 8) {
                    TextField("测试名称", text: $customTestURLName)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: customTestURLName) { _ in testURLFeedback = nil }
                        .frame(minWidth: 72, idealWidth: 160, maxWidth: 160)
                        .focused($customTestURLNameFocused)
                        .onAppear { customTestURLNameFocused = true }
                    TextField("HTTP 或 HTTPS 测试地址", text: $customTestURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 100)
                        .onChange(of: customTestURL) { _ in testURLFeedback = nil }
                        .onSubmit(addCustomTestURL)
                    Toggle("/generate_204", isOn: $customTestURLUsesGenerate204)
                        .toggleStyle(.checkbox)
                        .fixedSize()
                        .help("将地址路径设为 /generate_204，并移除查询参数和片段。是否返回 204 取决于目标网站。")
                    Button("确定", action: addCustomTestURL)
                        .buttonStyle(.borderedProminent)
                        .fixedSize()
                        .disabled(customTestURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || customTestURLName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("取消", action: cancelCustomTestURLAddition)
                        .buttonStyle(.bordered)
                        .fixedSize()
                }
                .controlSize(.small)
                if customTestURLUsesGenerate204,
                   let url = AppSettings.testURLForAddition(customTestURL, useGenerate204: true) {
                    Text("将添加：\(url.absoluteString)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let testURLFeedback {
                    Text(testURLFeedback).font(.caption).foregroundStyle(.red)
                }
            }
            Text("选择的地址用于节点连通性测试；添加后点击「应用设置」生效。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func addCustomTestURL() {
        let name = customTestURLName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            testURLFeedback = "请填写测试名称。"
            return
        }
        guard let url = AppSettings.testURLForAddition(customTestURL, useGenerate204: customTestURLUsesGenerate204) else {
            testURLFeedback = "请输入有效的 HTTP 或 HTTPS 地址。"
            return
        }
        let value = url.absoluteString
        updateDraftSettings {
            if !$0.availableTestURLs.contains(value) {
                $0.customTestURLs = ($0.customTestURLs ?? []) + [value]
            }
            var names = $0.customTestURLNames ?? [:]
            names[value] = name
            $0.customTestURLNames = names
            $0.testURL = value
        }
        cancelCustomTestURLAddition()
    }

    private func cancelCustomTestURLAddition() {
        customTestURL = ""
        customTestURLName = ""
        customTestURLUsesGenerate204 = false
        testURLFeedback = nil
        isAddingCustomTestURL = false
        customTestURLNameFocused = false
    }

    private var previewSettings: AppSettings { settingsDraft ?? appState.settings }

    private func updateDraftSettings(_ mutate: (inout AppSettings) -> Void) {
        if settingsBaseline == nil { settingsBaseline = appState.settings }
        var updated = previewSettings
        mutate(&updated)
        if let baseline = settingsBaseline,
           baseline.applyingSettingsEdits(from: updated, comparedTo: baseline) == baseline {
            settingsDraft = nil
            settingsBaseline = nil
        } else {
            settingsDraft = updated
        }
        settingsFeedback = nil
    }

    private func applySettingsDraft() {
        guard let draft = settingsDraft, let baseline = settingsBaseline else { return }
        if draft.testURL != baseline.testURL {
            guard let url = URL(string: draft.testURL),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                settingsFeedback = "请输入有效的 HTTP 或 HTTPS 测试地址。"
                return
            }
        }
        if draft.defaultTimeZoneID != baseline.defaultTimeZoneID,
           TimeZone(identifier: draft.defaultTimeZoneID) == nil {
            settingsFeedback = "请输入有效时区，例如 Asia/Shanghai。"
            return
        }
        appState.updateSettings { $0 = $0.applyingSettingsEdits(from: draft, comparedTo: baseline) }
        settingsDraft = nil
        settingsBaseline = nil
        settingsFeedback = "设置已应用"
        countryListFeedback = nil
    }

    // MARK: - 控制室页眉

    private var settingsHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("CONSOLE · 控制室")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(palette.accent)
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(palette.text)
                    Text("设置")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(palette.text)
                }
            }
            Spacer(minLength: 8)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(context.date, format: .dateTime.hour().minute().second())
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(palette.text)
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private var manualBackupNodeCount: Int {
        appState.nodes.filter { $0.subscriptionID == nil && !$0.pendingRemoval }.count
    }

    private var canConfirmBackupExport: Bool {
        backupPassphrase.trimmingCharacters(in: .whitespacesAndNewlines).count >= 6
            && (includeSettingsInBackup
                || !selectedBackupSubscriptionIDs.isEmpty
                || (includeManualNodesInBackup && manualBackupNodeCount > 0))
    }

    private var backupSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("导出备份") { beginBackupOperation(.export) }
                Button("从备份恢复") { beginBackupOperation(.restore) }
            }
            .buttonStyle(.bordered)
            .disabled(backupOperation != nil)

            Text("以弹窗选择订阅组与配置，导出加密的 .hopbackup 专用文件；恢复时需同一密码。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let backupFeedback {
                Text(backupFeedback)
                    .font(.caption)
                    .foregroundStyle(backupFeedback.contains("失败") ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func backupDialog(for operation: BackupOperation) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(operation.title)
                .font(.title2.bold())
            Text(operation == .export
                 ? "选择要导出的订阅组，并可一并导出应用配置。文件使用下方密码加密。"
                 : "输入导出时设置的密码，再选择 .hopbackup 文件恢复。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField(operation == .export ? "设置备份密码（至少 6 位）" : "输入备份密码", text: $backupPassphrase)
                .textFieldStyle(.roundedBorder)
                .onChange(of: backupPassphrase) { _ in backupDialogFeedback = nil }
                .focused($backupPasswordFocused)
                .onSubmit(confirmBackupOperation)

            if operation == .export {
                backupExportOptions
            }

            if let backupDialogFeedback {
                Text(backupDialogFeedback)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("取消", action: cancelBackupOperation)
                    .keyboardShortcut(.cancelAction)
                Button(operation.confirmTitle, action: confirmBackupOperation)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(operation == .export
                              ? !canConfirmBackupExport
                              : backupPassphrase.trimmingCharacters(in: .whitespacesAndNewlines).count < 6)
            }
        }
        .padding(24)
        .frame(width: 480, height: operation == .export ? 560 : 240)
        .onAppear { backupPasswordFocused = true }
    }

    private var backupExportOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("包含节点凭证（文件含敏感信息）", isOn: $includeCredentialsInBackup)
                .toggleStyle(.checkbox)
            Toggle("一并导出应用配置（设置页参数）", isOn: $includeSettingsInBackup)
                .toggleStyle(.checkbox)

            HStack(spacing: 8) {
                Text("导出订阅组")
                    .font(.headline)
                Spacer(minLength: 0)
                Button("全选") {
                    selectedBackupSubscriptionIDs = Set(appState.subscriptions.map(\.id))
                }
                .buttonStyle(.borderless)
                .disabled(selectedBackupSubscriptionIDs.count == appState.subscriptions.count)
                Button("全不选") { selectedBackupSubscriptionIDs = [] }
                    .buttonStyle(.borderless)
                    .disabled(selectedBackupSubscriptionIDs.isEmpty)
            }

            if appState.subscriptions.isEmpty {
                Text("暂无订阅组")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(appState.subscriptions) { subscription in
                            Toggle(isOn: Binding(
                                get: { selectedBackupSubscriptionIDs.contains(subscription.id) },
                                set: { selected in
                                    if selected {
                                        selectedBackupSubscriptionIDs.insert(subscription.id)
                                    } else {
                                        selectedBackupSubscriptionIDs.remove(subscription.id)
                                    }
                                }
                            )) {
                                HStack(spacing: 6) {
                                    Text(subscription.name)
                                    Text("\(appState.nodes.filter { $0.subscriptionID == subscription.id && !$0.pendingRemoval }.count) 节点")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .padding(8)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }

            if manualBackupNodeCount > 0 {
                Toggle("包含手动导入节点（\(manualBackupNodeCount)）", isOn: $includeManualNodesInBackup)
                    .toggleStyle(.checkbox)
            }
        }
    }

    private func beginBackupOperation(_ operation: BackupOperation) {
        resetBackupForm(clearFeedback: true)
        if operation == .export {
            selectedBackupSubscriptionIDs = Set(appState.subscriptions.map(\.id))
            includeManualNodesInBackup = manualBackupNodeCount > 0
            includeSettingsInBackup = true
        }
        backupOperation = operation
    }

    private func dismissBackupSheet() {
        // Sheet swipe/esc already nil'd the item; only clear form fields.
        if backupOperation == nil {
            resetBackupForm(clearFeedback: false)
        }
    }

    private func cancelBackupOperation() {
        backupOperation = nil
        resetBackupForm(clearFeedback: true)
        pendingImportData = nil
        pendingImportPassphrase = ""
        showReplaceImportConfirm = false
    }

    private func resetBackupForm(clearFeedback: Bool) {
        backupPassphrase = ""
        includeCredentialsInBackup = false
        includeSettingsInBackup = true
        includeManualNodesInBackup = true
        selectedBackupSubscriptionIDs = []
        backupPasswordFocused = false
        backupDialogFeedback = nil
        if clearFeedback { backupFeedback = nil }
    }

    private func confirmBackupOperation() {
        switch backupOperation {
        case .export: exportLibraryBackup()
        case .restore: pickLibraryBackup()
        case nil: break
        }
    }

    private func exportLibraryBackup() {
        let phrase = backupPassphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phrase.count >= 6 else {
            backupDialogFeedback = "请设置至少 6 位的备份密码"
            return
        }
        guard canConfirmBackupExport else {
            backupDialogFeedback = "请至少选择一个订阅组、手动节点或应用配置"
            return
        }
        do {
            let exportingAllSubscriptions = selectedBackupSubscriptionIDs.count == appState.subscriptions.count
            let data = try appState.exportLibraryBackup(
                passphrase: phrase,
                includeCredentials: includeCredentialsInBackup,
                subscriptionIDs: exportingAllSubscriptions ? nil : selectedBackupSubscriptionIDs,
                includeManualNodes: includeManualNodesInBackup,
                includeSettings: includeSettingsInBackup
            )
            let panel = NSSavePanel()
            panel.title = "导出跃界备份"
            let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
                .replacingOccurrences(of: "/", with: "-")
            panel.nameFieldStringValue = exportingAllSubscriptions && includeSettingsInBackup
                ? "HopWorld-backup.hopbackup"
                : "HopWorld-backup-\(stamp).hopbackup"
            panel.allowedContentTypes = [.data]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            let name = url.lastPathComponent
            cancelBackupOperation()
            backupFeedback = "已导出至 \(name)"
        } catch {
            backupDialogFeedback = "导出失败：\(error.localizedDescription)"
        }
    }

    private func pickLibraryBackup() {
        let phrase = backupPassphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phrase.count >= 6 else {
            backupDialogFeedback = "请先填写与导出时相同的备份密码"
            return
        }
        let panel = NSOpenPanel()
        panel.title = "选择跃界备份"
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            pendingImportData = data
            pendingImportPassphrase = phrase
            try appState.importLibraryBackup(from: data, passphrase: phrase, replaceExisting: false)
            cancelBackupOperation()
            backupFeedback = "备份已恢复"
        } catch LibraryBackupError.requiresReplaceConfirmation {
            // Keep the sheet open until the user confirms or cancels replace.
            showReplaceImportConfirm = true
        } catch {
            backupDialogFeedback = "导入失败：\(error.localizedDescription)"
            pendingImportData = nil
            pendingImportPassphrase = ""
        }
    }

    private func applyPendingImport(replaceExisting: Bool) {
        guard let data = pendingImportData else { return }
        do {
            try appState.importLibraryBackup(
                from: data,
                passphrase: pendingImportPassphrase,
                replaceExisting: replaceExisting
            )
            cancelBackupOperation()
            backupFeedback = "备份已恢复"
        } catch {
            backupDialogFeedback = "导入失败：\(error.localizedDescription)"
            backupFeedback = backupDialogFeedback
        }
        pendingImportData = nil
        pendingImportPassphrase = ""
    }

    private func requestAddCountry(_ country: CountryGroup, toAllowed: Bool) {
        let code = country.code.uppercased()
        let opposite = toAllowed ? previewSettings.autoSelectExcludedCountryCodes
            : previewSettings.autoSelectIncludedCountryCodes
        if opposite.contains(code) {
            countryListConflict = CountryListConflict(code: code, name: country.name, addingToAllowed: toAllowed)
        } else {
            addCountry(code, toAllowed: toAllowed)
        }
    }

    private func addCountry(_ code: String, toAllowed: Bool) {
        updateDraftSettings { settings in
            if toAllowed {
                settings.autoSelectExcludedCountryCodes.remove(code)
                settings.autoSelectIncludedCountryCodes.insert(code)
            } else {
                settings.autoSelectIncludedCountryCodes.remove(code)
                settings.autoSelectExcludedCountryCodes.insert(code)
            }
        }
        let name = CountryResolver.displayName(for: code)
        countryListFeedback = toAllowed ? "待保存到指定国家：\(name)" : "待保存到排除国家：\(name)"
    }

    private var availableAutoSelectCountries: [CountryGroup] {
        appState.countryGroups.filter {
            !previewSettings.autoSelectIncludedCountryCodes.contains($0.code.uppercased())
        }
    }

    private var availableAutoSelectExcludedCountries: [CountryGroup] {
        appState.countryGroups.filter {
            !previewSettings.autoSelectExcludedCountryCodes.contains($0.code.uppercased())
        }
    }

    private var excludedAutoSelectCountries: [(code: String, name: String, flag: String, nodeCount: Int)] {
        previewSettings.autoSelectExcludedCountryCodes.map { code in
            let group = appState.countryGroups.first { $0.code.uppercased() == code.uppercased() }
            return (
                code: code.uppercased(),
                name: group?.name ?? CountryResolver.displayName(for: code),
                flag: group?.flag ?? FlagResolver.flag(for: code),
                nodeCount: group?.nodes.count ?? 0
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var includedAutoSelectCountries: [(code: String, name: String, flag: String, nodeCount: Int)] {
        previewSettings.autoSelectIncludedCountryCodes
            .map { code in
                let group = appState.countryGroups.first { $0.code.uppercased() == code.uppercased() }
                return (
                    code: code.uppercased(),
                    name: group?.name ?? CountryResolver.displayName(for: code),
                    flag: group?.flag ?? FlagResolver.flag(for: code),
                    nodeCount: group?.nodes.count ?? 0
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct WrappingFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct LogView: View {
    @EnvironmentObject private var appState: AppState
    @State private var filter: LogCategory?
    @State private var levelFilter: AppLogLevel?
    @State private var searchText = ""
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                filterPickers
                searchField
                entryCount
                Spacer(minLength: 0)
                logActions
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 16)

            List(filtered) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(entry.level.displayName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(color(for: entry.level))
                        Text(entry.category.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(entry.date.formatted(date: .omitted, time: .standard))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(entry.displayMessage)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                .contextMenu {
                    Button("复制此条") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            appState.logger.exportText([entry]),
                            forType: .string
                        )
                    }
                }
            }
        }
        .confirmationDialog("清除全部日志？", isPresented: $confirmClear) {
            Button("清除全部日志", role: .destructive) {
                appState.logger.clear()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("该操作会同时清除已持久化的历史日志。")
        }
    }

    private var filterPickers: some View {
        HStack(spacing: 8) {
            Picker("分类", selection: $filter) {
                Text("全部分类").tag(LogCategory?.none)
                ForEach(LogCategory.allCases, id: \.self) { category in
                    Text(category.displayName).tag(Optional(category))
                }
            }
            .labelsHidden()
            .frame(width: 128)
            Picker("级别", selection: $levelFilter) {
                Text("全部级别").tag(AppLogLevel?.none)
                ForEach(AppLogLevel.allCases, id: \.self) { level in
                    Text(level.displayName).tag(Optional(level))
                }
            }
            .labelsHidden()
            .frame(width: 112)
        }
    }

    private var searchField: some View {
        TextField("搜索日志", text: $searchText)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 80, maxWidth: 280)
    }

    private var entryCount: some View {
        Text("\(filtered.count) / \(appState.logger.entries.count)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    private var logActions: some View {
        HStack(spacing: 8) {
            Button("复制") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    appState.logger.exportText(Array(filtered.reversed())),
                    forType: .string
                )
                appState.statusBanner = "已复制 \(filtered.count) 条脱敏日志"
            }
            .disabled(filtered.isEmpty)
            Button("导出…") { exportLogs() }
                .disabled(filtered.isEmpty)
            Button("清除", role: .destructive) { confirmClear = true }
                .disabled(appState.logger.entries.isEmpty)
        }
        .fixedSize()
    }

    private var filtered: [LogEntry] {
        appState.logger.entries.reversed().filter { entry in
            if let filter, entry.category != filter { return false }
            if let levelFilter, entry.level != levelFilter { return false }
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return true }
            return entry.displayMessage.localizedCaseInsensitiveContains(query) ||
                entry.category.displayName.localizedCaseInsensitiveContains(query) ||
                entry.level.displayName.localizedCaseInsensitiveContains(query)
        }
    }

    private func exportLogs() {
        let panel = NSSavePanel()
        panel.title = "导出脱敏日志"
        panel.nameFieldStringValue = "HopWorld-logs-\(Int(Date().timeIntervalSince1970)).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try appState.logger.exportText(Array(filtered.reversed())).write(
                to: url,
                atomically: true,
                encoding: .utf8
            )
            appState.statusBanner = "已导出 \(filtered.count) 条日志"
        } catch {
            appState.statusBanner = "导出失败：\(error.localizedDescription)"
        }
    }

    private func color(for level: AppLogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .primary
        case .warning: return .orange
        case .error: return .red
        }
    }

}

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if appState.connection.state.status == .connected {
            Button {
                Task { await appState.disconnect() }
            } label: {
                HStack {
                    Text("已连接")
                    Spacer()
                    Text("断开连接")
                }
            }
        } else if appState.connection.state.status == .connecting || appState.connection.isBusy {
            Button {
                Task { await appState.disconnect() }
            } label: {
                HStack {
                    Text(menuStatusLine)
                    Spacer()
                    Text("取消连接")
                }
            }
        } else {
            Text(menuStatusLine)
        }
        if let node = appState.currentNode {
            Text(menuNodeLine(for: node))
        }

        Divider()

        Menu("节点") {
            if !favoriteNodes.isEmpty {
                Menu("★ 收藏 (\(favoriteNodes.count))") {
                    nodeButtons(
                        favoriteNodes,
                        emptyText: appState.connection.state.autoSelectEnabled
                            ? "暂无可用收藏节点"
                            : "暂无收藏节点"
                    )
                }
            }

            if appState.countryGroups.isEmpty {
                Text("暂无节点，请先添加订阅")
            } else {
                let groupsWithConnectable = appState.countryGroups.filter {
                    !connectableNodes(in: $0.nodes).isEmpty
                }
                if groupsWithConnectable.isEmpty {
                    Text(appState.connection.state.autoSelectEnabled
                         ? "暂无可用节点，请先测速"
                         : "暂无节点")
                } else {
                    ForEach(groupsWithConnectable) { group in
                        let connectable = connectableNodes(in: group.nodes)
                        let usableCount = availableNodes(in: group.nodes).count
                        Menu(countryMenuTitle(group, availableCount: usableCount, listedCount: connectable.count)) {
                            if usableCount > 0 {
                                Button("连接最快") {
                                    Task { await appState.connectCountry(group.code) }
                                }
                                Divider()
                            }

                            nodeButtons(
                                connectable,
                                emptyText: appState.connection.state.autoSelectEnabled
                                    ? "该国家暂无可用节点"
                                    : "该国家暂无节点"
                            )
                        }
                    }
                }
            }

            if !manualOrOtherNodes.isEmpty {
                Divider()
                Menu("其它 (\(manualOrOtherNodes.count))") {
                    nodeButtons(manualOrOtherNodes, emptyText: "暂无")
                }
            }
        }

        Divider()

        Toggle("自动优选", isOn: Binding(
            get: { appState.connection.state.autoSelectEnabled },
            set: {
                appState.connection.state.autoSelectEnabled = $0
                appState.persist()
            }
        ))

        Menu(routingModeMenuTitle) {
            ForEach(RoutingMode.allCases, id: \.self) { mode in
                Button {
                    Task { await appState.setRoutingMode(mode) }
                } label: {
                    if appState.settings.routingMode == mode {
                        Text("✓ \(mode.displayName)（当前）")
                    } else {
                        Text("应用\(mode.displayName)")
                    }
                }
            }
        }
        .disabled(appState.connection.isBusy)

        Button("测试当前节点") {
            Task { await appState.testCurrentConnection() }
        }
        Button("更新订阅") {
            Task { await appState.refreshAllSubscriptions() }
        }

        Divider()

        Button("打开跃界") {
            DockReopen.handleDockClick()
        }

        Button("退出") {
            NSApp.terminate(nil)
        }
    }

    // MARK: - Node menus

    private var routingModeMenuTitle: String {
        let mode = appState.settings.routingMode
        guard mode == .rules else { return "路由模式：\(mode.displayName)" }
        switch appState.settings.connectionCaptureMode {
        case .applications: return "路由模式：规则代理 · 应用白名单"
        case .systemProxy: return "路由模式：规则代理 · 系统代理"
        default: return "路由模式：规则代理 · \(appState.settings.connectionCaptureMode.displayName)"
        }
    }

    private var menuStatusLine: String {
        appState.connection.state.status.displayName
    }

    private func menuNodeLine(for node: ProxyNode) -> String {
        let flag = FlagResolver.flag(for: CountryResolver.effectiveCode(for: node))
        let country = CountryResolver.effectiveCountry(for: node).name
        let title = appState.settings.nodeDisplayTitle(node)
        let base: String
        if title == country || title.hasPrefix(country) {
            base = "\(flag) \(title)"
        } else {
            base = "\(flag) \(country) · \(title)"
        }
        if appState.connection.state.status == .connected {
            if let ms = appState.connection.state.latency {
                return "\(base) \(LatencyFormat.display(ms))"
            }
            let text = node.latencyText
            if text != "—" {
                return "\(base) \(text)"
            }
        }
        return base
    }

    @ViewBuilder
    private func nodeButtons(_ nodes: [ProxyNode], emptyText: String) -> some View {
        let sorted = nodes.sorted { lhs, rhs in
            (lhs.lastLatency ?? Int.max) < (rhs.lastLatency ?? Int.max)
        }

        if sorted.isEmpty {
            Text(emptyText)
        } else {
            ForEach(sorted.prefix(40)) { node in
                Button {
                    appState.requestConnect(to: node)
                } label: {
                    Text(nodeMenuLabel(node))
                }
            }
            if sorted.count > 40 {
                Text("…还有 \(sorted.count - 40) 个节点")
            }
        }
    }

    private func countryMenuTitle(_ group: CountryGroup, availableCount: Int, listedCount: Int? = nil) -> String {
        let listed = listedCount ?? availableCount
        let latency = group.bestLatency.map { " · \(LatencyFormat.display($0))" } ?? ""
        let current = appState.connection.state.currentCountryCode == group.code ? " ✓" : ""
        let ratio = appState.connection.state.autoSelectEnabled
            ? "\(availableCount)/\(group.nodes.count)"
            : "\(listed)/\(group.nodes.count)"
        return "\(group.flag) \(group.name) (\(ratio))\(latency)\(current)"
    }

    private func nodeMenuLabel(_ node: ProxyNode) -> String {
        var parts: [String] = []
        if appState.connection.state.status == .connecting,
           appState.connection.state.currentNodeID == node.id {
            parts.append("…")
        } else if appState.connection.state.currentNodeID == node.id,
                  appState.connection.state.status == .connected {
            parts.append("✓")
        }
        if node.isFavorite {
            parts.append("★")
        }
        parts.append(appState.settings.nodeDisplayTitle(node))
        parts.append("·")
        parts.append(node.groupName(subscriptions: appState.subscriptions))
        parts.append("·")
        parts.append(node.protocolType.displayName)
        parts.append("·")
        if appState.connection.state.status == .connecting,
           appState.connection.state.currentNodeID == node.id {
            parts.append("连接中")
        } else {
            parts.append(node.resolvedTestStatus.displayName)
            parts.append(node.latencyText)
        }
        return parts.joined(separator: " ")
    }

    private func availableNodes(in nodes: [ProxyNode]) -> [ProxyNode] {
        nodes.filter {
            $0.enabled &&
            !$0.pendingRemoval &&
            $0.lastTestStatus.isUsable
        }
    }

    /// 菜单可点连接的节点：自动优选开启时仅可用；关闭时可含不可用（连接前会确认）。
    private func connectableNodes(in nodes: [ProxyNode]) -> [ProxyNode] {
        if appState.connection.state.autoSelectEnabled {
            return availableNodes(in: nodes)
        }
        return nodes.filter {
            $0.enabled &&
            !$0.pendingRemoval &&
            ($0.lastTestStatus.isUsable
                || $0.lastTestStatus == .unavailable
                || $0.lastTestStatus == .failed)
        }
    }

    private var favoriteNodes: [ProxyNode] {
        connectableNodes(in: appState.nodes.filter { !$0.pendingRemoval && $0.isFavorite })
    }

    /// 无国家信息的节点（含名称也无法解析的）
    private var manualOrOtherNodes: [ProxyNode] {
        connectableNodes(in: appState.nodes.filter {
            !$0.pendingRemoval &&
            CountryResolver.effectiveCode(for: $0) == "XX"
        })
    }
}


private struct InstalledAppProbeSettings: View {
    @Binding var settings: AppSettings
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(settings.effectiveAppProbeSource == .custom
                ? "添加本机应用，并填写要探测的网址。只检查网址能否打开，不会启动应用，也不会改变哪些应用走代理。"
                : "探测名单来自「路由 → 按应用代理」，增删请到那里。只检查网址能否打开，不会启动应用，也不会改变哪些应用走代理。浏览器默认测 Google，没有对应网址的应用需要填写。")
                .font(.caption).foregroundStyle(.secondary)
            if settings.effectiveAppProbeSource == .custom {
                ForEach(settings.installedAppProbes) { probe in
                    HStack {
                        Text(probe.application.name).frame(width: 100, alignment: .leading)
                        TextField("https://应用服务地址", text: Binding(
                            get: { settings.installedAppProbes.first { $0.id == probe.id }?.endpoint ?? "" },
                            set: { value in
                                updateSettings { settings in
                                    if let index = settings.installedAppProbes.firstIndex(where: { $0.id == probe.id }) {
                                        settings.installedAppProbes[index].endpoint = value
                                    }
                                }
                            }
                        ))
                        if probe.target == nil { Text("请输入有效地址").font(.caption).foregroundStyle(.orange) }
                        Button("移除") {
                            updateSettings { $0.installedAppProbes.removeAll { $0.id == probe.id } }
                        }
                    }
            }
                Button("添加已安装应用…") {
                    let panel = NSOpenPanel()
                    panel.title = "选择要测试连通的已安装应用"
                    panel.directoryURL = URL(fileURLWithPath: "/Applications")
                    panel.allowsMultipleSelection = true
                    panel.canChooseDirectories = false
                    panel.allowedContentTypes = [.applicationBundle]
                    guard panel.runModal() == .OK else { return }
                    do {
                        for url in panel.urls { add(try ProxyApplication(url: url)) }
                        error = nil
                    } catch { self.error = error.localizedDescription }
            }
            } else {
                ForEach(settings.proxyApplications.filter { application in
                    !settings.ruleAppProbeTargets.contains { $0.id == application.id && !$0.probeURLs.isEmpty }
                }) { application in
                    HStack {
                        Text("\(application.name) 还没有探测网址").font(.caption).foregroundStyle(.orange)
                        Text("请在「自定义应用」里填写").font(.caption).foregroundStyle(.secondary)
                    }
            }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }

    private func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        var updated = settings
        mutate(&updated)
        settings = updated
    }

    private func add(_ application: ProxyApplication) {
        guard !settings.installedAppProbes.contains(where: { $0.id == application.id }) else { return }
        updateSettings { $0.installedAppProbes.append(InstalledAppProbe(application: application, endpoint: "")) }
    }
}


/// AppKit 提示。SwiftUI 的 help 在快速切换行里经常被挡住，悬停时看不到应用名。
private final class AppProbeNameTooltipView: NSView {
    var tip = "" {
        didSet { toolTip = tip }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }
}

private struct AppProbeNameTooltip: NSViewRepresentable {
    var text: String

    func makeNSView(context: Context) -> AppProbeNameTooltipView {
        let view = AppProbeNameTooltipView(frame: .zero)
        view.tip = text
        return view
    }

    func updateNSView(_ view: AppProbeNameTooltipView, context: Context) {
        view.tip = text
    }
}

struct AppProbeIcon: View {
    let target: AppProbeTarget
    let passed: Bool
    var size: CGFloat = 20

    var body: some View {
        Group {
            if case .application(let path, _, _) = target {
                Image(nsImage: Self.applicationIcon(path))
                    .resizable().renderingMode(.original).scaledToFit()
            } else if let image = NSImage(named: serviceAssetName) {
                Image(nsImage: image).resizable().renderingMode(.original).scaledToFit()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.2).fill(serviceColor)
                    Text(serviceInitial).font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .saturation(passed ? 1 : 0)
        .opacity(passed ? 1 : 0.4)
        .overlay(AppProbeNameTooltip(text: target.displayName))
        .accessibilityLabel("\(target.displayName)：\(passed ? "通过" : "未通过或未测试")")
        .help(target.displayName)
    }

    private static let applicationIcons = NSCache<NSString, NSImage>()

    private static func applicationIcon(_ path: String) -> NSImage {
        if let cached = applicationIcons.object(forKey: path as NSString) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        applicationIcons.setObject(icon, forKey: path as NSString)
        return icon
    }

    private var serviceAssetName: String {
        switch target {
        case .google: return "AppProbeGoogle"
        case .cloudflare: return "AppProbeCloudflare"
        case .chatgpt: return "AppProbeChatGPT"
        case .github: return "AppProbeGitHub"
        case .youtube: return "AppProbeYouTube"
        case .twitter: return "AppProbeTwitter"
        case .claude: return "AppProbeClaude"
        case .tiktok: return "AppProbeTikTok"
        case .application: return ""
        }
    }

    private var serviceInitial: String {
        switch target {
        case .google: return "G"
        case .cloudflare: return "CF"
        case .chatgpt: return "AI"
        case .github: return "GH"
        case .youtube: return "YT"
        case .twitter: return "X"
        case .claude: return "C"
        case .tiktok: return "TT"
        case .application: return ""
        }
    }
    private var serviceColor: Color {
        switch target {
        case .google: return .blue
        case .cloudflare: return .orange
        case .chatgpt: return .green
        case .github: return .purple
        case .youtube: return .red
        case .twitter: return .black
        case .claude: return .orange
        case .tiktok: return .black
        case .application: return .accentColor
        }
    }
}


private struct ChineseCityLibrarySettings: View {
    @ObservedObject private var library = ChineseCityLibrary.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("GeoNames 中文地名").font(.headline)
                        UsageHelpButton(
                            title: "中文地名离线库说明",
                            text: "从 GeoNames 官方源下载约 220 MB 数据，生成的离线库约 10 MB，保存在本机。开启中文显示后优先使用离线库，仅对可用节点在线补充。"
                        )
                    }
                    if library.isInstalled {
                        Text("GeoNames · \(library.catalog.cityCount) 个地名 · \(library.catalog.version)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if library.stage != nil {
                    ProgressView().controlSize(.small)
                    Button("取消") { library.cancel() }
                } else {
                    Button(library.isInstalled ? "已下载" : "下载离线库") { library.download() }
                        .disabled(library.isInstalled)
                }
            }
            if let stage = library.stage { Text(stage).font(.caption).foregroundStyle(.secondary) }
            if let error = library.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            Link("GeoNames · CC BY 4.0", destination: URL(string: "https://www.geonames.org/")!).font(.caption)
        }
    }
}
