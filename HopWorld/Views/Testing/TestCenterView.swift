import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(palette.subtext)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.text.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(palette.line, lineWidth: 1)
        }
    }
}

/// 应用探测目标芯片：状态灯 + 名称 + 延迟。
private struct LabTargetChip: View {
    var dot: Color
    var name: String
    var latency: String
    var palette: LabPalette
    var dimmed: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dot)
                .frame(width: 8, height: 8)
            Text(name)
                .font(.system(size: 13))
                .foregroundStyle(palette.text)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(latency)
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(palette.subtext)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(palette.text.opacity(dimmed ? 0.03 : 0.055))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(palette.line, lineWidth: 1)
        }
        .opacity(dimmed ? 0.55 : 1)
    }
}

struct TestCenterView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    /// Node picked in the results list for connect / app probe.
    @State private var selectedNodeID: UUID?
    @State private var showingLatencyTierHelp = false

    /// Shared with 节点 page subscription chips.
    private var testScope: NodeListFilter.Source {
        NodeListFilter.decode(appState.settings.nodeListCategoryRaw).source
    }

    private func setTestScope(_ value: NodeListFilter.Source) {
        let current = NodeListFilter.decode(appState.settings.nodeListCategoryRaw)
        let raw = NodeListFilter.encode(scope: current.scope, source: value)
        guard appState.settings.nodeListCategoryRaw != raw else { return }
        appState.updateSettings { $0.nodeListCategoryRaw = raw }
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
                VStack(spacing: 14) {
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
            if !appState.testManager.isProbingApps,
               appState.testManager.appProbeResults.map(\.target) != appState.settings.automaticAppProbeTargets {
                appState.testManager.resetAppProbes(targets: appState.settings.automaticAppProbeTargets)
            }
        }
        .onChange(of: appState.connection.state.status) { _, status in
            if status == .connected {
                // Live proxy takes over app probe target; clear list-only selection highlight.
                selectedNodeID = appState.connection.state.currentNodeID
                appState.testManager.resetAppProbes(targets: appState.settings.automaticAppProbeTargets)
                appState.testManager.appProbeStatusText = "已连接：可直接探测当前代理"
            } else if status == .disconnected || status == .error {
                appState.testManager.resetAppProbes(targets: appState.settings.automaticAppProbeTargets)
            }
        }
        .onChange(of: appState.subscriptions.map(\.id)) { _, ids in
            if case .subscription(let id) = testScope, !ids.contains(id) {
                setTestScope(.all)
            }
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
                }
                Text(scopeLine)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.subtext)
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

    /// Always show counts from persisted node results (not only during an active session).
    private var statusCard: some View {
        let targets = scopedTargets
        let summary = scopedSummary(for: targets)
        let running = appState.testManager.phase == .running || appState.testManager.phase == .paused
        return LabCard(
            title: "测试仪表", icon: "gauge.with.dots.needle.67percent",
            tint: palette.accent, palette: palette,
            footnote: running ? appState.testManager.statusText : statusIdleLine(summary: summary, total: targets.count)
        ) {
            HStack(spacing: 8) {
                SignalDot(color: phaseColor)
                Text(appState.testManager.phase.displayName)
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
                ProgressView(value: appState.testManager.progress)
                    .tint(palette.accent)
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 130), spacing: 10)],
                spacing: 10
            ) {
                LabStatTile(label: "可用", value: "\(summary.available)", tint: .green, palette: palette)
                LabStatTile(label: "不可用", value: "\(summary.unavailable)", tint: .orange, palette: palette)
                LabStatTile(label: "失败", value: "\(summary.failed)", tint: .red, palette: palette)
                LabStatTile(
                    label: appState.testManager.canResume ? "剩余" : "已测 / 范围",
                    value: appState.testManager.canResume
                        ? "\(appState.testManager.remainingNodeIDs.count)"
                        : "\(summary.tested)/\(targets.count)",
                    tint: palette.text, palette: palette
                )
            }
        }
    }

    private func statusIdleLine(summary: (available: Int, unavailable: Int, failed: Int, tested: Int), total: Int) -> String {
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
            .disabled(appState.testManager.isTesting)
        }
    }

    private var controlButtons: some View {
        HStack(spacing: 8) {
            Button("测试当前连接") {
                Task { await appState.testCurrentConnection() }
            }
            .buttonStyle(.bordered)
            .disabled(
                appState.testManager.isTesting ||
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
        return LabCard(
            title: "节点结果", icon: "testtube.2",
            tint: palette.accent, palette: palette,
            footnote: "共 \(rows.count) 条"
        ) {
            selectionHint
            if rows.isEmpty {
                ContentUnavailableView(
                    "暂无测试结果",
                    systemImage: "list.bullet.rectangle",
                    description: Text("点击「测试全部」开始测速；测完后单击节点可选中，再连接并探测应用")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        resultRow(row, striped: index % 2 == 1)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard appState.connection.state.status != .connected else {
                                    appState.statusBanner = "已连接代理：请直接点「探测应用」测试当前连接"
                                    return
                                }
                                selectedNodeID = selectedNodeID == row.id ? nil : row.id
                            }
                            .contextMenu {
                                nodeResultContextMenu(for: row)
                            }
                    }
                }
            }
        }
        .animation(.default, value: selectedNodeID)
        .animation(.default, value: appState.connection.state.currentNodeID)
    }

    @ViewBuilder
    private var selectionHint: some View {
        if let selected = selectedNode, appState.connection.state.status != .connected {
            Text("已选探测：\(selected.displayTitle)")
                .font(.system(size: 11))
                .foregroundStyle(palette.subtext)
                .lineLimit(1)
        } else if appState.connection.state.status == .connected {
            Text("已连接：应用探测使用当前代理")
                .font(.system(size: 11))
                .foregroundStyle(palette.subtext)
        } else {
            Text("未连接：单击选中后点「探测应用」，选中只用于探测、不会建立代理")
                .font(.system(size: 11))
                .foregroundStyle(palette.subtext)
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
            Text(row.name)
                .font(.system(size: 13, weight: highlighted ? .semibold : .medium))
                .foregroundStyle(palette.text)
                .lineLimit(1)

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
        .background(
            highlighted ? palette.accent.opacity(palette.scheme == .dark ? 0.14 : 0.10)
                : (striped ? palette.text.opacity(0.035) : Color.clear),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(
                    row.isSelected && allowSelect ? palette.accent.opacity(0.6) : Color.clear,
                    lineWidth: 1
                )
        }
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

        if appState.connection.state.status != .connected {
            Button("选中用于应用探测") {
                selectedNodeID = row.id
            }
            Button("选中并探测应用") {
                selectedNodeID = row.id
                Task {
                    guard let node else { return }
                    await appState.probeApps(forSelectedNode: node)
                }
            }
            .disabled(appState.testManager.isProbingApps || appState.testManager.isTesting)
        } else {
            Button("探测当前代理应用连通") {
                Task { await appState.probeLiveConnectionApps() }
            }
            .disabled(appState.testManager.isProbingApps || appState.testManager.isTesting)
        }

        Divider()

        Button("单独测速此节点") {
            guard let node else { return }
            Task { await appState.testNodes([node]) }
        }
        .disabled(appState.testManager.isTesting)

        if let node {
            Button(node.isFavorite ? "取消收藏" : "收藏") {
                appState.toggleFavorite(node.id)
            }
        }
    }

    // MARK: - 应用连通：试剂反应板

    private var appProbeCard: some View {
        let connected = appState.connection.state.status == .connected

        return LabCard(
            title: "应用连通", icon: "aqi.medium",
            tint: palette.accent, palette: palette,
            footnote: appState.testManager.appProbeStatusText
        ) {
            Picker("测试应用", selection: Binding(
                get: { appState.settings.effectiveAppProbeSource },
                set: { source in appState.updateAppProbeSettings { $0.appProbeSource = source } }
            )) {
                ForEach(AppProbeSource.allCases) { source in
                    Text(source.displayName).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .disabled(appState.testManager.isProbingApps)
            if appState.settings.effectiveAppProbeSource != .defaults {
                InstalledAppProbeSettings()
            }
            HStack(spacing: 10) {
                Stepper(
                    "\(appState.settings.appProbeTimeoutSeconds) 秒",
                    value: Binding(
                        get: { appState.settings.appProbeTimeoutSeconds },
                        set: { value in appState.updateSettings { $0.appProbeTimeoutSeconds = value } }
                    ),
                    in: 1...30
                )
                .help("每个应用探测目标的超时时间")
                Spacer(minLength: 8)
                Button(appState.testManager.isProbingApps ? "探测中…" : "探测应用") {
                    Task { await runAppProbe() }
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
                .disabled(appProbeButtonDisabled)
                .help(
                    connected
                        ? "通过当前代理探测所选应用"
                        : "未连接时：对列表选中的节点临时探测（不切换系统代理）"
                )
            }

            HStack(spacing: 8) {
                Text(connected ? "当前代理" : "探测目标")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.subtext)
                if connected, let node = appState.currentNode {
                    Text(appState.appProbeNodeDescription(for: node))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                    Text("已连接 · 测当前代理")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.green)
                } else if let node = selectedNode {
                    Text(appState.appProbeNodeDescription(for: node))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                    Text("未连接 · 仅测试选中节点")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.subtext)
                } else {
                    Text("未连接：请先在下方列表单击选中一个节点再探测")
                        .font(.system(size: 13))
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 4)
            }

            if !appState.testManager.appProbeResults.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(appState.testManager.appProbeResults) { result in
                        appProbeChip(result)
                    }
                }
            }
        }
    }

    private var appProbeButtonDisabled: Bool {
        if appState.settings.automaticAppProbeTargets.isEmpty { return true }
        if appState.testManager.isProbingApps || appState.testManager.isTesting {
            return true
        }
        if appState.connection.state.status == .connected {
            return appState.currentNode == nil
        }
        return selectedNodeID == nil
    }

    private var selectedNode: ProxyNode? {
        guard let id = selectedNodeID else { return nil }
        return appState.nodes.first { $0.id == id }
    }

    private func scopedSummary(
        for targets: [ProxyNode]
    ) -> (available: Int, unavailable: Int, failed: Int, tested: Int) {
        var available = 0
        var unavailable = 0
        var failed = 0
        var tested = 0
        for node in targets {
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
            case .testing:
                tested += 1
            case .untested:
                break
            }
        }
        return (available, unavailable, failed, tested)
    }

    private func runAppProbe() async {
        if appState.connection.state.status == .connected {
            await appState.probeLiveConnectionApps()
            return
        }
        guard let node = selectedNode else {
            appState.statusBanner = "未连接时代理：请先在节点结果中单击选中一个节点"
            return
        }
        await appState.probeApps(forSelectedNode: node)
    }

    private func appProbeChip(_ result: AppProbeResult) -> some View {
        LabTargetChip(
            dot: appProbeDotColor(result.status),
            name: result.target.displayName,
            latency: appProbeLatencyText(result),
            palette: palette,
            dimmed: appProbeButtonDisabled
        )
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
        case .untested: return "—"
        case .testing: return "…"
        case .ok: return result.latencyMs.map { LatencyFormat.seconds($0) } ?? "通"
        case .failed: return "不通"
        }
    }

    @ViewBuilder
    private var testControls: some View {
        if appState.testManager.canPause {
            Button("暂停") {
                appState.pauseTesting()
            }
        }

        if appState.testManager.canResume {
            Button("继续测试") {
                Task { await appState.resumeTesting() }
            }
            .buttonStyle(.borderedProminent)
        }

        if appState.testManager.canResume {
            Button("重新测试") {
                Task { await startScopedTest() }
            }
            .disabled(!appState.testManager.canRetest || scopedTargets.isEmpty)
        } else {
            Button(primaryTestButtonTitle) {
                Task { await startScopedTest() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!appState.testManager.canRetest || scopedTargets.isEmpty)
        }
    }

    private var primaryTestButtonTitle: String {
        let rerun = appState.testManager.phase != .idle
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
        let active = appState.nodes.filter { $0.enabled && !$0.pendingRemoval }
        switch testScope {
        case .all:
            return active
        case .subscription(let id):
            return active.filter { $0.subscriptionID == id }
        case .manual:
            return active.filter { $0.subscriptionID == nil }
        case .namedSource(let name):
            let knownIDs = Set(appState.subscriptions.map(\.id))
            return active.filter { node in
                guard let sid = node.subscriptionID, !knownIDs.contains(sid) else { return false }
                return (node.sourceName ?? "未知订阅") == name
            }
        }
    }

    private var recentResults: [ProxyNode] {
        scopedTargets.filter {
            $0.lastTestStatus != .untested && $0.lastTestStatus != .failed
        }
    }

    /// 可用各档 → 测试中 → 未测试 → 有 TCP 数字的不可用 → 完全不可用。
    /// 当前连接 / 已选中节点排在最前。
    private var liveResultRows: [TestResultRow] {
        let connStatus = appState.connection.state.status
        let currentID = (connStatus == .connected || connStatus == .connecting)
            ? appState.connection.state.currentNodeID
            : nil
        let selectedID = selectedNodeID
        let ranked = recentResults.sorted { lhs, rhs in
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
                name: node.displayTitle,
                status: isConnecting ? "连接中" : statusLabel(for: node),
                latency: isConnecting ? "—" : node.latencyText,
                statusColor: isConnecting ? .orange : statusColor(node.resolvedTestStatus),
                isCurrent: isConnected,
                isConnecting: isConnecting,
                isSelected: node.id == selectedID
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

        return lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedAscending
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
        var status: String
        var latency: String
        var statusColor: Color
        var isCurrent: Bool
        var isConnecting: Bool = false
        var isSelected: Bool
    }

    private func startScopedTest() async {
        await appState.testNodes(scopedTargets)
    }

    private var phaseColor: Color {
        switch appState.testManager.phase {
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
            VStack(alignment: .leading, spacing: 8) {
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
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(palette.modeTint(mode))
                Text(mode.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.text)
                Text(shortDesc)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.subtext)
                    .fixedSize(horizontal: false, vertical: true)
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
        }
    }
}

struct RoutingView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingRoutingModeHelp = false
    @State private var draft = RoutingRules()
    @State private var saving = false
    @State private var ruleError: String?

    private var palette: RoutePalette { RoutePalette(scheme: colorScheme) }

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
                VStack(spacing: 14) {
                    header
                    modeCard(wide: wide)
                    if appState.settings.routingMode == .global {
                        globalCard
                    }
                    if appState.settings.supportsApplicationProxy {
                        RouteCard(title: "按应用代理", icon: "app.badge", tint: .orange, palette: palette, footnote: "实验性") {
                            ApplicationProxySection()
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
        .onAppear { draft = appState.settings.routingRules }
        .alert("路由模式说明", isPresented: $showingRoutingModeHelp) {
            Button("好", role: .cancel) {}
        } message: {
            Text(
                RoutingMode.allCases
                    .map { "· \($0.displayName)\n\($0.helpText)" }
                    .joined(separator: "\n\n")
                + "\n\n另：已连接时切换会立即按新模式重载代理。"
            )
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
                }
                HStack(spacing: 7) {
                    Circle()
                        .fill(palette.statusColor(connectionStatus))
                        .frame(width: 8, height: 8)
                    Text(connectionStatus.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.text)
                    Text(captureText)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.subtext)
                        .lineLimit(1)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(palette.card, in: Capsule())
                .overlay { Capsule().strokeBorder(palette.cardBorder, lineWidth: 1) }
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
            palette: palette, footnote: "已连接时切换会立即重载"
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
            Button {
                showingRoutingModeHelp = true
            } label: {
                Label("查看各模式说明", systemImage: "questionmark.circle")
                    .font(.system(size: 12))
            }
            .buttonStyle(.link)
        }
    }

    private func modeCard(for mode: RoutingMode) -> some View {
        RouteModeCard(
            mode: mode,
            palette: palette,
            isActive: appState.settings.routingMode == mode,
            disabled: modeBusy
        ) {
            Task { await appState.setRoutingMode(mode) }
        }
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
            footnote: draftDirty ? "有未保存修改" : nil
        ) {
            Toggle("国内域名和 IP 直连", isOn: $draft.bypassChina)
                .tint(palette.accent)
            Text("仅在规则代理模式生效。")
                .font(.system(size: 11))
                .foregroundStyle(palette.subtext)
            Text("每行一条：example.com（含子域名）、full:example.com（精确匹配）、1.2.3.4 或 10.0.0.0/8。支持 IPv6；# 开头为注释。")
                .font(.system(size: 11))
                .foregroundStyle(palette.subtext)
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
            HStack(spacing: 10) {
                Button(saving ? "正在应用…" : "保存并应用") {
                    saving = true
                    ruleError = nil
                    Task {
                        do { try await appState.saveRoutingRules(draft) }
                        catch { ruleError = error.localizedDescription }
                        saving = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
                .disabled(saving)
                Button("撤销未保存修改") { draft = appState.settings.routingRules; ruleError = nil }
                    .buttonStyle(.bordered)
                    .disabled(saving || !draftDirty)
                if draftDirty && !saving {
                    HStack(spacing: 4) {
                        Circle().fill(.orange).frame(width: 7, height: 7)
                        Text("未保存")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                }
            }
            Text("已连接时会重连当前节点。全局/直连模式下保存，下次启用规则代理时生效。")
                .font(.system(size: 11))
                .foregroundStyle(palette.subtext)
        }
        .disabled(rulesBusy)
    }

    @ViewBuilder
    private var ruleEditors: some View {
        RouteRuleEditor(
            title: "强制代理", icon: "paperplane.fill",
            tint: .blue, palette: palette,
            count: entryCount(draft.proxy), text: $draft.proxy
        )
        RouteRuleEditor(
            title: "强制直连", icon: "arrow.right.circle.fill",
            tint: .gray, palette: palette,
            count: entryCount(draft.direct), text: $draft.direct
        )
        RouteRuleEditor(
            title: "拦截", icon: "octagon.fill",
            tint: .red, palette: palette,
            count: entryCount(draft.blocked), text: $draft.blocked
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
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 240), spacing: 12)],
                alignment: .leading, spacing: 12
            ) {
                portField(
                    title: "SOCKS 主机",
                    text: Binding(
                        get: { appState.settings.socksHost },
                        set: { value in appState.updateSettings { $0.socksHost = value } }
                    )
                )
                portField(
                    title: "SOCKS 端口",
                    value: Binding(
                        get: { appState.settings.socksPort },
                        set: { value in appState.updateSettings { $0.socksPort = value } }
                    )
                )
                portField(
                    title: "HTTP 主机",
                    text: Binding(
                        get: { appState.settings.httpHost },
                        set: { value in appState.updateSettings { $0.httpHost = value } }
                    )
                )
                portField(
                    title: "HTTP 端口",
                    value: Binding(
                        get: { appState.settings.httpPort },
                        set: { value in appState.updateSettings { $0.httpPort = value } }
                    )
                )
            }
        }
    }

    private func portField(title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(palette.subtext)
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
        }
    }

    private func portField(title: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(palette.subtext)
            TextField(title, value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
        }
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

struct SettingsView: View {
    private struct CountryListConflict {
        let code: String
        let name: String
        let addingToAllowed: Bool
        var destination: String { addingToAllowed ? "指定国家" : "排除国家" }
        var source: String { addingToAllowed ? "排除国家" : "指定国家" }
    }
    @State private var countryListConflict: CountryListConflict?
    @State private var countryListFeedback: String?
    @EnvironmentObject private var appState: AppState
    @State private var showingScheduledScopeHelp = false
    @State private var showingFavoritePreferenceHelp = false
    @State private var showingUpdateModeHelp = false
    @State private var backupPassphrase = ""
    @State private var includeCredentialsInBackup = false
    @State private var backupFeedback: String?
    @State private var pendingImportData: Data?
    @State private var pendingImportPassphrase = ""
    @State private var showReplaceImportConfirm = false
    @Environment(\.colorScheme) private var colorScheme

    private var palette: SetPalette { SetPalette(scheme: colorScheme) }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                settingsHeader
                SetCard(title: "常规", icon: "gearshape", palette: palette) {
                Toggle("登录时启动", isOn: Binding(
                    get: { appState.settings.launchAtLogin },
                    set: { value in appState.updateSettings { $0.launchAtLogin = value } }
                ))
                Toggle("显示菜单栏", isOn: Binding(
                    get: { appState.settings.showMenuBar },
                    set: { value in appState.updateSettings { $0.showMenuBar = value } }
                ))
                Picker("启动后", selection: Binding(
                    get: { appState.settings.connectOnLaunch },
                    set: { value in appState.updateSettings { $0.connectOnLaunch = value } }
                )) {
                    ForEach(ConnectOnLaunch.allCases, id: \.self) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                Toggle("电脑锁屏时自动断开连接", isOn: Binding(
                    get: { appState.settings.disconnectOnScreenLock },
                    set: { value in appState.updateSettings { $0.disconnectOnScreenLock = value } }
                ))
                if appState.settings.disconnectOnScreenLock {
                    Stepper(
                        "锁屏后断开：\(appState.settings.screenLockDisconnectDelayMinutes) 分钟",
                        value: Binding(
                            get: { appState.settings.screenLockDisconnectDelayMinutes },
                            set: { value in appState.updateSettings { $0.screenLockDisconnectDelayMinutes = value } }
                        ),
                        in: 0...1440
                    )
                }
                Text("默认锁屏 15 分钟后断开并恢复系统网络设置；提前解锁会取消断开。设为 0 分钟则立即断开。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SetCard(title: "连接", icon: "cable.connector", palette: palette) {
                Toggle("自动故障切换", isOn: Binding(
                    get: { appState.settings.autoFailover },
                    set: { value in appState.updateSettings { $0.autoFailover = value } }
                ))

                Picker("候选范围", selection: Binding(
                    get: { appState.settings.failoverPoolMode },
                    set: { value in appState.updateSettings { $0.failoverPoolMode = value } }
                )) {
                    ForEach(FailoverPoolMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .disabled(!appState.settings.autoFailover)

                if appState.settings.failoverPoolMode == .limited {
                    Stepper(
                        "最大尝试节点：\(appState.settings.maxFailoverAttempts)",
                        value: Binding(
                            get: { appState.settings.maxFailoverAttempts },
                            set: { value in appState.updateSettings { $0.maxFailoverAttempts = value } }
                        ),
                        in: 1...50
                    )
                    .disabled(!appState.settings.autoFailover)
                }

                Stepper(
                    "连接超时：\(appState.settings.connectTimeoutSeconds) 秒",
                    value: Binding(
                        get: { appState.settings.connectTimeoutSeconds },
                        set: { value in appState.updateSettings { $0.connectTimeoutSeconds = value } }
                    ),
                    in: 1...30
                )
                Text(
                    appState.settings.failoverPoolMode == .allAvailable
                        ? (appState.settings.autoAppProbeUsableNodes
                            ? "超时后按应用连通通过数与延迟依次尝试全部可用节点"
                            : "超时后按测速延迟依次尝试全部可用节点")
                        : (appState.settings.autoAppProbeUsableNodes
                            ? "超时后按应用连通通过数与延迟依次尝试前 \(appState.settings.maxFailoverAttempts) 个可用节点"
                            : "超时后按测速延迟依次尝试前 \(appState.settings.maxFailoverAttempts) 个可用节点")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            SetCard(title: "自动优选国家", icon: "globe", palette: palette) {
                Picker("连接范围", selection: Binding(
                    get: { appState.settings.autoSelectCountryScope },
                    set: { value in appState.updateSettings { $0.autoSelectCountryScope = value } }
                )) {
                    ForEach(AutoSelectCountryScope.allCases, id: \.self) { scope in
                        Text(scope.displayName).tag(scope)
                    }
                }
                .pickerStyle(.segmented)

                Picker("最低速度", selection: Binding(
                    get: { appState.settings.autoSelectMinimumSpeed },
                    set: { value in appState.updateSettings { $0.autoSelectMinimumSpeed = value } }
                )) {
                    ForEach(AutoSelectMinimumSpeed.allCases, id: \.self) { speed in
                        Text(speed.displayName).tag(speed)
                    }
                }
                Text("选择“较快及以上”时，会包含较快、快和特快节点。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper("自动切换延时：\(appState.settings.autoSelectUnhealthySeconds) 秒", value: Binding(
                    get: { appState.settings.autoSelectUnhealthySeconds },
                    set: { value in appState.updateSettings { $0.autoSelectUnhealthySeconds = value } }
                ), in: 5...300, step: 5)
                Text("持续超时或低于最低速度要求后自动优选其它节点；恢复正常则重新计时。按实时探测结果检查，无合格节点时保留连接。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if appState.settings.autoSelectCountryScope == .specified {
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
                                        appState.updateSettings { settings in
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
                        CountryTagFlow(spacing: 8) {
                            ForEach(excludedAutoSelectCountries, id: \.code) { country in
                                HStack(spacing: 6) {
                                    Text(country.flag)
                                    Text(country.name).font(.callout).lineLimit(1)
                                    Spacer(minLength: 2)
                                    Button {
                                        appState.updateSettings { $0.autoSelectExcludedCountryCodes.remove(country.code) }
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
                    get: { appState.settings.scheduledTestEnabled },
                    set: { value in appState.updateSettings { $0.scheduledTestEnabled = value } }
                ))
                Stepper(
                    "间隔：\(appState.settings.scheduledTestIntervalMinutes) 分钟",
                    value: Binding(
                        get: { appState.settings.scheduledTestIntervalMinutes },
                        set: { value in
                            appState.updateSettings {
                                $0.scheduledTestIntervalMinutes = max(5, value)
                            }
                        }
                    ),
                    in: 5...1440,
                    step: 5
                )
                .disabled(!appState.settings.scheduledTestEnabled)

                Picker("订阅范围", selection: Binding(
                    get: { appState.settings.scheduledTestSubscriptionRaw },
                    set: { value in appState.updateSettings { $0.scheduledTestSubscriptionRaw = value } }
                )) {
                    Text("全部订阅").tag("all")
                    ForEach(appState.subscriptions) { sub in
                        Text(sub.name).tag("subscription:\(sub.id.uuidString)")
                    }
                }
                .disabled(!appState.settings.scheduledTestEnabled)

                Picker(selection: Binding(
                    get: { appState.settings.scheduledTestScope },
                    set: { value in appState.updateSettings { $0.scheduledTestScope = value } }
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
                .disabled(!appState.settings.scheduledTestEnabled)
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
                TextField("连通性测试 URL", text: Binding(
                    get: { appState.settings.testURL },
                    set: { value in appState.updateSettings { $0.testURL = value } }
                ))
                Stepper(
                    "批量并发：\(min(16, appState.settings.testConcurrency))", 
                    value: Binding(
                        get: { appState.settings.testConcurrency },
                        set: { value in appState.updateSettings { $0.testConcurrency = value } }
                    ),
                    in: 1...16
                )
                Stepper(
                    "单测超时：\(appState.settings.testTimeoutSeconds) 秒",
                    value: Binding(
                        get: { appState.settings.testTimeoutSeconds },
                        set: { value in appState.updateSettings { $0.testTimeoutSeconds = value } }
                    ),
                    in: 1...30
                )
                Text("右键/详情只测 1 个节点，以及「单测」路径使用此时限；慢握手节点可调高。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper(
                    "批量测速超时：\(appState.settings.batchTestTimeoutSeconds) 秒",
                    value: Binding(
                        get: { appState.settings.batchTestTimeoutSeconds },
                        set: { value in appState.updateSettings { $0.batchTestTimeoutSeconds = value } }
                    ),
                    in: 1...30
                )
                Text("每个节点的 HTTPS 预算，默认 2 秒；批量不自动延长或重复测试，进程清理最多另需约 1 秒。TCP 预检最多 3 秒，慢握手节点可调高预算或单独复测。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("自动测试可用节点的应用连通", isOn: Binding(
                    get: { appState.settings.autoAppProbeUsableNodes },
                    set: { value in appState.updateSettings { $0.autoAppProbeUsableNodes = value } }
                ))
                Text("关闭（默认）：测速后不自动做应用连通，自动优选也不按应用连通分档，只按测速延迟排序。开启后会对可用且未探测的节点补测，并按通过目标数优选。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                InstalledAppProbeSettings()
                Stepper(
                    "应用连通超时：\(appState.settings.appProbeTimeoutSeconds) 秒",
                    value: Binding(
                        get: { appState.settings.appProbeTimeoutSeconds },
                        set: { value in appState.updateSettings { $0.appProbeTimeoutSeconds = value } }
                    ),
                    in: 1...30
                )
                Text("每个应用目标的最长等待；手动点「探测应用」不受上方自动开关限制。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper(
                    "结果有效期：\(appState.settings.testResultTTLMinutes) 分钟",
                    value: Binding(
                        get: { appState.settings.testResultTTLMinutes },
                        set: { value in appState.updateSettings { $0.testResultTTLMinutes = value } }
                    ),
                    in: 5...180
                )
            }

            SetCard(title: "订阅默认值", icon: "link.badge.plus", palette: palette) {
                Stepper(
                    "默认更新时间 \(String(format: "%02d:%02d", appState.settings.defaultUpdateHour, appState.settings.defaultUpdateMinute))",
                    value: Binding(
                        get: { appState.settings.defaultUpdateHour },
                        set: { value in appState.updateSettings { $0.defaultUpdateHour = value } }
                    ),
                    in: 0...23
                )
                TextField("默认时区", text: Binding(
                    get: { appState.settings.defaultTimeZoneID },
                    set: { value in appState.updateSettings { $0.defaultTimeZoneID = value } }
                ))
                Picker(selection: Binding(
                    get: { appState.settings.defaultUpdateMode },
                    set: { value in appState.updateSettings { $0.defaultUpdateMode = value } }
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
                    "默认回退天数：\(appState.settings.defaultFallbackDays)",
                    value: Binding(
                        get: { appState.settings.defaultFallbackDays },
                        set: { value in appState.updateSettings { $0.defaultFallbackDays = value } }
                    ),
                    in: 0...14
                )
            }

            SetCard(title: "节点", icon: "paperplane", palette: palette) {
                Picker(selection: Binding(
                    get: { appState.settings.favoritePreference },
                    set: { value in appState.updateSettings { $0.favoritePreference = value } }
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
                SecureField("备份密码", text: $backupPassphrase)
                Toggle("包含节点凭证（文件含敏感信息）", isOn: $includeCredentialsInBackup)
                HStack {
                    Button("导出备份…") { exportLibraryBackup() }
                    Button("从备份恢复…") { pickLibraryBackup() }
                }
                Text("备份使用您设置的密码加密，可迁移到其他 Mac；与本机钥匙串无关。默认不含密码/UUID。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let backupFeedback {
                    Text(backupFeedback)
                        .font(.caption)
                        .foregroundStyle(backupFeedback.contains("失败") ? .red : .secondary)
                }
            }

            SetCard(title: "高级", icon: "wrench", palette: palette) {
                Picker("日志等级", selection: Binding(
                    get: { appState.settings.logLevel },
                    set: { value in appState.updateSettings { $0.logLevel = value } }
                )) {
                    ForEach(AppLogLevel.allCases, id: \.self) { level in
                        Text(level.displayName).tag(level)
                    }
                }

                if XrayProcessManager.resolveBinaryURL() == nil {
                    Text("未检测到本地 xray。首次连接时会自动下载安装；也可手动运行 Scripts/fetch_xray.sh。")
                        .foregroundStyle(.orange)
                        .font(.caption)
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
            Text("\(conflict.name)已在“\(conflict.source)”中。是否从该名单移除，并加入“\(conflict.destination)”？\(conflict.addingToAllowed ? "指定国家模式下，将允许自动优选该国家。" : "自动优选将不再连接该国家。")")
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
                pendingImportData = nil
            }
        }         message: {
            Text("将用备份替换本机全部节点与订阅（连接状态不受影响，建议先断开）。")
        }
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

    private func exportLibraryBackup() {
        let phrase = backupPassphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phrase.count >= 6 else {
            backupFeedback = "请设置至少 6 位的备份密码"
            return
        }
        do {
            let data = try appState.exportLibraryBackup(
                passphrase: phrase,
                includeCredentials: includeCredentialsInBackup
            )
            let panel = NSSavePanel()
            panel.title = "导出跃界备份"
            panel.nameFieldStringValue = "HopWorld-backup.hopbackup"
            panel.allowedContentTypes = [.data]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            backupFeedback = "已导出至 \(url.lastPathComponent)"
        } catch {
            backupFeedback = "导出失败：\(error.localizedDescription)"
        }
    }

    private func pickLibraryBackup() {
        let panel = NSOpenPanel()
        panel.title = "选择跃界备份"
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let phrase = backupPassphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phrase.count >= 6 else {
            backupFeedback = "请先填写与导出时相同的备份密码"
            return
        }
        do {
            let data = try Data(contentsOf: url)
            pendingImportData = data
            pendingImportPassphrase = phrase
            try appState.importLibraryBackup(from: data, passphrase: phrase, replaceExisting: false)
        } catch LibraryBackupError.requiresReplaceConfirmation {
            showReplaceImportConfirm = true
        } catch {
            backupFeedback = "导入失败：\(error.localizedDescription)"
            pendingImportData = nil
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
            backupFeedback = "备份已恢复"
        } catch {
            backupFeedback = "导入失败：\(error.localizedDescription)"
        }
        pendingImportData = nil
    }

    private func requestAddCountry(_ country: CountryGroup, toAllowed: Bool) {
        let code = country.code.uppercased()
        let opposite = toAllowed ? appState.settings.autoSelectExcludedCountryCodes
            : appState.settings.autoSelectIncludedCountryCodes
        if opposite.contains(code) {
            countryListConflict = CountryListConflict(code: code, name: country.name, addingToAllowed: toAllowed)
        } else {
            addCountry(code, toAllowed: toAllowed)
        }
    }

    private func addCountry(_ code: String, toAllowed: Bool) {
        appState.updateSettings { settings in
            if toAllowed {
                settings.autoSelectExcludedCountryCodes.remove(code)
                settings.autoSelectIncludedCountryCodes.insert(code)
            } else {
                settings.autoSelectIncludedCountryCodes.remove(code)
                settings.autoSelectExcludedCountryCodes.insert(code)
            }
        }
        let name = CountryResolver.displayName(for: code)
        countryListFeedback = toAllowed ? "已加入指定国家：\(name)" : "已排除：\(name)"
    }

    private var availableAutoSelectCountries: [CountryGroup] {
        appState.countryGroups.filter {
            !appState.settings.autoSelectIncludedCountryCodes.contains($0.code.uppercased())
        }
    }

    private var availableAutoSelectExcludedCountries: [CountryGroup] {
        appState.countryGroups.filter {
            !appState.settings.autoSelectExcludedCountryCodes.contains($0.code.uppercased())
        }
    }

    private var excludedAutoSelectCountries: [(code: String, name: String, flag: String, nodeCount: Int)] {
        appState.settings.autoSelectExcludedCountryCodes.map { code in
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
        appState.settings.autoSelectIncludedCountryCodes
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

private struct CountryTagFlow: Layout {
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
            HStack(spacing: 10) {
                Picker("分类", selection: $filter) {
                    Text("全部").tag(LogCategory?.none)
                    ForEach(LogCategory.allCases, id: \.self) { category in
                        Text(category.displayName).tag(Optional(category))
                    }
                }
                .frame(width: 180)

                Picker("级别", selection: $levelFilter) {
                    Text("全部级别").tag(AppLogLevel?.none)
                    ForEach(AppLogLevel.allCases, id: \.self) { level in
                        Text(level.displayName).tag(Optional(level))
                    }
                }
                .frame(width: 140)

                TextField("搜索日志", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 160, maxWidth: 280)

                Text("\(filtered.count) / \(appState.logger.entries.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer()
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
            .padding()

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
                    Text(entry.message)
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

    private var filtered: [LogEntry] {
        appState.logger.entries.reversed().filter { entry in
            if let filter, entry.category != filter { return false }
            if let levelFilter, entry.level != levelFilter { return false }
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return true }
            return entry.message.localizedCaseInsensitiveContains(query) ||
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

        Menu(appState.settings.connectionCaptureMode == .applications ? "路由模式：规则代理 · 应用白名单" : "路由模式：\(appState.settings.routingMode.displayName)") {
            ForEach(RoutingMode.allCases, id: \.self) { mode in
                Button {
                    Task { await appState.setRoutingMode(mode) }
                } label: {
                    if appState.settings.routingMode == mode {
                        Text("✓ \(mode.displayName)")
                    } else {
                        Text(mode.displayName)
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
            Task {
                await appState.disconnect()
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - Node menus

    private var menuStatusLine: String {
        appState.connection.state.status.displayName
    }

    private func menuNodeLine(for node: ProxyNode) -> String {
        let flag = FlagResolver.flag(for: CountryResolver.effectiveCode(for: node))
        let country = CountryResolver.effectiveCountry(for: node).name
        let title = node.displayTitle
        let base: String
        if title == country || title.hasPrefix(country) {
            base = "\(flag) \(title)"
        } else {
            base = "\(flag) \(country) · \(title)"
        }
        if appState.connection.state.status == .connected {
            if let ms = appState.connection.state.latency {
                return "\(base) \(LatencyFormat.seconds(ms))"
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
        let latency = group.bestLatency.map { " · \(LatencyFormat.seconds($0))" } ?? ""
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
        parts.append(node.displayTitle)
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
    @EnvironmentObject private var appState: AppState
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(appState.settings.effectiveAppProbeSource == .custom
                ? "添加已安装应用并设置测试服务地址。"
                : "使用已保存的规则代理应用列表；请在规则代理设置中调整应用。")
                .font(.caption).foregroundStyle(.secondary)
            Text("测试服务地址的可达性，不会启动应用；HTTP 错误响应也表示网络可达。浏览器默认测试 Google，未知应用请配置服务地址。")
                .font(.caption).foregroundStyle(.secondary)
            if appState.settings.effectiveAppProbeSource == .custom {
                ForEach(appState.settings.installedAppProbes) { probe in
                    HStack {
                        Text(probe.application.name).frame(width: 100, alignment: .leading)
                        TextField("https://应用服务地址", text: Binding(
                            get: { appState.settings.installedAppProbes.first { $0.id == probe.id }?.endpoint ?? "" },
                            set: { value in
                                appState.updateAppProbeSettings { settings in
                                    if let index = settings.installedAppProbes.firstIndex(where: { $0.id == probe.id }) {
                                        settings.installedAppProbes[index].endpoint = value
                                    }
                                }
                            }
                        ))
                        if probe.target == nil { Text("请输入有效地址").font(.caption).foregroundStyle(.orange) }
                        Button("移除") {
                            appState.updateAppProbeSettings { $0.installedAppProbes.removeAll { $0.id == probe.id } }
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
                ForEach(appState.settings.proxyApplications.filter { application in
                    !appState.settings.ruleAppProbeTargets.contains { $0.id == application.id && !$0.probeURLs.isEmpty }
                }) { application in
                    HStack {
                        Text("\(application.name)：尚未配置测试地址").font(.caption).foregroundStyle(.orange)
                        Text("请在自定义应用中配置该应用的服务地址").font(.caption).foregroundStyle(.secondary)
                    }
            }
            }
            Text("本次自动测试目标：\(appState.settings.automaticAppProbeTargets.map(\.displayName).joined(separator: "、"))")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }

    private func add(_ application: ProxyApplication) {
        guard !appState.settings.installedAppProbes.contains(where: { $0.id == application.id }) else { return }
        appState.updateAppProbeSettings { $0.installedAppProbes.append(InstalledAppProbe(application: application, endpoint: "")) }
    }
}
