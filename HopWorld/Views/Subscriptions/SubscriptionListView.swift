import SwiftUI
import AppKit

/// 订阅页「补给码头」主题调色板，深浅色自适应。
/// 内部可见，供同样内部可见的 `SubscriptionCard` 使用。
struct SubPalette {
    var scheme: ColorScheme
    var bgTop: Color
    var bgBottom: Color
    var ribLine: Color
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
            bgTop = Color(red: 0.075, green: 0.055, blue: 0.045)
            bgBottom = Color(red: 0.105, green: 0.075, blue: 0.055)
            ribLine = Color.white.opacity(0.035)
            card = Color.white.opacity(0.055)
            cardBorder = Color.white.opacity(0.10)
            text = Color(red: 0.96, green: 0.94, blue: 0.92)
            subtext = Color(red: 0.70, green: 0.64, blue: 0.59)
            accent = Color(red: 1.0, green: 0.62, blue: 0.25)
            onAccent = Color(red: 0.20, green: 0.10, blue: 0.02)
            line = Color.white.opacity(0.10)
        } else {
            bgTop = Color(red: 0.965, green: 0.953, blue: 0.942)
            bgBottom = Color(red: 0.928, green: 0.908, blue: 0.888)
            ribLine = Color.black.opacity(0.035)
            card = .white
            cardBorder = Color.black.opacity(0.08)
            text = Color(red: 0.18, green: 0.13, blue: 0.09)
            subtext = Color(red: 0.50, green: 0.44, blue: 0.39)
            accent = Color(red: 0.80, green: 0.42, blue: 0.08)
            onAccent = .white
            line = Color.black.opacity(0.09)
        }
    }
}

/// 补给码头背景：渐变 + 集装箱肋纹（竖线）。
private struct SubBackdrop: View {
    var palette: SubPalette

    var body: some View {
        ZStack {
            LinearGradient(colors: [palette.bgTop, palette.bgBottom], startPoint: .top, endPoint: .bottom)
            Canvas { context, size in
                var path = Path()
                var x: CGFloat = 0
                while x <= size.width {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    x += 34
                }
                context.stroke(path, with: .color(palette.ribLine), lineWidth: 0.5)
            }
        }
        .ignoresSafeArea()
    }
}

/// 码头读数格：大数字 + 小标签。
private struct SubStatTile: View {
    var label: String
    var value: String
    var tint: Color
    var palette: SubPalette

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(palette.text)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(palette.subtext)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(palette.card, in: Capsule())
        .overlay { Capsule().strokeBorder(palette.cardBorder, lineWidth: 1) }
    }
}

struct SubscriptionListView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var confirmDelete: Subscription?
    /// 节点数 / 分享链接条数只在订阅或节点变化时重算，不跟监测状态一起刷新。
    @State private var nodeCounts: [UUID: Int] = [:]
    @State private var activeNodeTotal = 0
    @State private var shareLinkCounts: [UUID: Int] = [:]
    @State private var testingSubscriptionIDs: Set<UUID> = []

    private var palette: SubPalette { SubPalette(scheme: colorScheme) }

    private func activity(for id: UUID) -> SubscriptionActivity? {
        if appState.refreshingSubscriptionID == id { return .updating }
        if testingSubscriptionIDs.contains(id) { return .testingLatency }
        if appState.appProbeBatch.isRunning, appState.appProbeBatch.currentSubscriptionID == id { return .probingApps }
        return nil
    }

    private var abnormalCount: Int {
        appState.subscriptions.lazy.filter { $0.lastError != nil }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if !appState.isLibraryReady {
                libraryLockedEmptyState
            } else if appState.subscriptions.isEmpty {
                subscriptionsEmptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(appState.subscriptions) { sub in
                            let current = activity(for: sub.id)
                            SubscriptionCard(
                                subscription: sub,
                                nodeCount: nodeCounts[sub.id, default: 0],
                                shareLinkCount: shareLinkCounts[sub.id, default: 0],
                                activity: current,
                                probeTargets: current == .probingApps
                                    ? appState.settings.automaticAppProbeTargets : [],
                                palette: palette,
                                onView: { appState.viewingSubscriptionID = sub.id },
                                onEdit: { appState.editingSubscriptionID = sub.id },
                                onRefresh: {
                                    Task { await appState.refreshSubscription(sub.id) }
                                },
                                onTest: {
                                    Task { await appState.testSubscriptionNodes([sub.id]) }
                                },
                                onDelete: { confirmDelete = sub },
                                onToggleEnabled: { toggleSubscriptionEnabled(sub) }
                            )
                            .equatable()
                            .contextMenu {
                                Button("查看") { appState.viewingSubscriptionID = sub.id }
                                Button("编辑") { appState.editingSubscriptionID = sub.id }
                                if !sub.isShareLinksBundle {
                                    Button("立即更新") {
                                        Task { await appState.refreshSubscription(sub.id) }
                                    }
                                }
                                Button("测试本组全部节点") {
                                    Task { await appState.testSubscriptionNodes([sub.id]) }
                                }
                                Divider()
                                Button("删除", role: .destructive) { confirmDelete = sub }
                                Button(sub.isEnabled ? "禁用" : "启用") { toggleSubscriptionEnabled(sub) }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                }
                .background { SubBackdrop(palette: palette) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if case let state = appState.subscriptionManager.updateState, state != .idle {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(palette.accent)
                    Text(state.displayName)
                        .font(.caption.weight(.medium))
                    Spacer()
                }
                .foregroundStyle(palette.subtext)
                .padding(.horizontal, 16)
                .frame(height: 34)
                .background(palette.card)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(palette.cardBorder)
                        .frame(height: 1)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(item: viewingBinding) { sub in
            SubscriptionDetailView(subscriptionID: sub.id)
                .environmentObject(appState)
        }
        .sheet(item: editingBinding) { sub in
            SubscriptionEditorView(mode: .edit(sub))
                .environmentObject(appState)
        }
        .confirmationDialog(
            "删除订阅「\(confirmDelete?.name ?? "")」？",
            isPresented: Binding(
                get: { confirmDelete != nil },
                set: { if !$0 { confirmDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除订阅及节点", role: .destructive) {
                if let id = confirmDelete?.id {
                    appState.removeSubscription(id)
                }
                confirmDelete = nil
            }
            Button("取消", role: .cancel) {
                confirmDelete = nil
            }
        } message: {
            Text("将同时删除该订阅导入的全部节点，此操作不可撤销。")
        }
        .onAppear(perform: refreshListCounts)
        .onReceive(appState.$subscriptions) { _ in refreshShareLinkCounts() }
        .onReceive(appState.$nodes) { nodes in refreshNodeCounts(nodes) }
    }

    private func toggleSubscriptionEnabled(_ subscription: Subscription) {
        var updated = subscription
        updated.isEnabled.toggle()
        appState.updateSubscription(updated)
    }

    private func refreshListCounts() {
        refreshNodeCounts(appState.nodes)
        refreshShareLinkCounts()
    }

    private func refreshShareLinkCounts() {
        var next: [UUID: Int] = [:]
        for sub in appState.subscriptions where sub.isShareLinksBundle {
            next[sub.id] = NodeLinkParser.extractShareLinks(from: sub.shareLinksText ?? "").count
        }
        if next != shareLinkCounts { shareLinkCounts = next }
    }

    private func refreshNodeCounts(_ nodes: [ProxyNode]) {
        var counts: [UUID: Int] = [:]
        var testing: Set<UUID> = []
        var total = 0
        counts.reserveCapacity(appState.subscriptions.count)
        for node in nodes where !node.pendingRemoval {
            total += 1
            guard let id = node.subscriptionID else { continue }
            counts[id, default: 0] += 1
            if node.lastTestStatus == .testing { testing.insert(id) }
        }
        if total != activeNodeTotal { activeNodeTotal = total }
        if counts != nodeCounts { nodeCounts = counts }
        if testing != testingSubscriptionIDs { testingSubscriptionIDs = testing }
    }

    private var activeNodeCount: Int { activeNodeTotal }

    // MARK: - 码头页眉 + 读数条

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                headerIdentity
                Spacer(minLength: 8)
                headerActions
            }
            VStack(alignment: .leading, spacing: 10) {
                headerIdentity
                HStack {
                    Spacer(minLength: 0)
                    headerActions
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var headerIdentity: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SUPPLY · 补给码头")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(palette.accent)
            HStack(spacing: 8) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(palette.text)
                Text("订阅")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(palette.text)
                    .fixedSize()
                if appState.isLibraryReady && !appState.subscriptions.isEmpty {
                    statsStrip
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var headerActions: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(context.date, format: .dateTime.hour().minute().second())
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(palette.text)
            }
            HStack(spacing: 12) {
                Button {
                    Task { await appState.refreshAllSubscriptions() }
                } label: {
                    Label("全部更新", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(appState.isRefreshingAllSubscriptions || appState.subscriptionManager.updateState != .idle)

                Button {
                    appState.showAddSubscription = true
                } label: {
                    Label("添加订阅", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
                .controlSize(.small)
            }
        }
        .fixedSize()
    }

    private var statsStrip: some View {
        HStack(spacing: 10) {
            SubStatTile(
                label: "订阅",
                value: "\(appState.subscriptions.count)",
                tint: palette.accent, palette: palette
            )
            SubStatTile(
                label: "节点",
                value: "\(activeNodeCount)",
                tint: .green, palette: palette
            )
            SubStatTile(
                label: "异常",
                value: "\(abnormalCount)",
                tint: abnormalCount > 0 ? .red : palette.subtext,
                palette: palette
            )
        }
    }

    private var libraryLockedEmptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(.orange)
            Text("本地节点与订阅尚未读取")
                .font(.title3.weight(.semibold))
                .foregroundStyle(palette.text)
            Text("列表为空不代表数据已删除。常见原因是钥匙串暂时无法解密；在恢复前，此处新建内容也不会保存。")
                .font(.callout)
                .foregroundStyle(palette.subtext)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let error = appState.persistenceError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            Button {
                appState.retryLoadLibrary()
            } label: {
                Label("重新读取数据", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Text("也可在 设置 → 数据备份 从 .hopbackup 恢复（可含指定订阅组与应用配置）")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var subscriptionsEmptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "shippingbox")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(palette.accent.opacity(0.7))
            Text("码头还没有货")
                .font(.title3.weight(.semibold))
                .foregroundStyle(palette.text)
            Text("支持固定地址、日期型订阅 URL，或直接粘贴节点分享链接")
                .font(.callout)
                .foregroundStyle(palette.subtext)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button {
                appState.showAddSubscription = true
            } label: {
                Label("添加订阅", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(palette.accent)
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding(.horizontal, 24)
        .padding(.top, 36)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var viewingBinding: Binding<Subscription?> {
        Binding(
            get: {
                guard let id = appState.viewingSubscriptionID else { return nil }
                return appState.subscription(for: id)
            },
            set: { appState.viewingSubscriptionID = $0?.id }
        )
    }

    private var editingBinding: Binding<Subscription?> {
        Binding(
            get: {
                guard let id = appState.editingSubscriptionID else { return nil }
                return appState.subscription(for: id)
            },
            set: { appState.editingSubscriptionID = $0?.id }
        )
    }
}

enum SubscriptionActivity: Equatable {
    case updating, testingLatency, probingApps

    var title: String {
        switch self {
        case .updating: return "更新中"
        case .testingLatency: return "测试延迟中"
        case .probingApps: return "应用连通测试中"
        }
    }
}

struct SubscriptionCard: View, Equatable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    let subscription: Subscription
    let nodeCount: Int
    let shareLinkCount: Int
    var activity: SubscriptionActivity? = nil
    var probeTargets: [AppProbeTarget] = []
    var palette: SubPalette
    var onView: () -> Void
    var onEdit: () -> Void
    var onRefresh: () -> Void
    var onTest: () -> Void
    var onDelete: () -> Void
    var onToggleEnabled: () -> Void

    static func == (lhs: SubscriptionCard, rhs: SubscriptionCard) -> Bool {
        lhs.subscription == rhs.subscription
            && lhs.nodeCount == rhs.nodeCount
            && lhs.shareLinkCount == rhs.shareLinkCount
            && lhs.activity == rhs.activity
            && lhs.probeTargets.map(\.id) == rhs.probeTargets.map(\.id)
            && lhs.palette.scheme == rhs.palette.scheme
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 0) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusColor.opacity(0.6), radius: 3)
                Rectangle()
                    .fill(palette.line)
                    .frame(width: 1.5, height: 12)
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(statusColor.opacity(0.12))
                    Image(systemName: subscription.isShareLinksBundle ? "doc.on.clipboard.fill" : "antenna.radiowaves.left.and.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(statusColor)
                }
                .frame(width: 22, height: 22)
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(subscription.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                        .layoutPriority(1)

                    Text(activity?.title ?? statusText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(activity == nil ? statusColor : palette.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background((activity == nil ? statusColor : palette.accent).opacity(0.11), in: Capsule())

                    Text(detailLine)
                        .font(.caption)
                        .foregroundStyle(subscription.lastError == nil ? palette.subtext : Color.red)
                        .lineLimit(1)
                        .help(detailLine)
                }

                HStack(spacing: 6) {
                    metadataBadge(subscription.sourceKind.displayName, icon: "link")
                    metadataBadge(subscription.updateMode.displayName, icon: "arrow.triangle.merge")
                    if !subscription.isShareLinksBundle {
                        metadataBadge(updateScheduleText, icon: "clock")
                    }
                }
            }

            Spacer(minLength: 12)

            if activity == .probingApps, !probeTargets.isEmpty {
                probeTargetIcons
                    .help(probeTargets.map(\.displayName).joined(separator: "、"))
                    .accessibilityLabel("正在测试：" + probeTargets.map(\.displayName).joined(separator: "、"))
            }

            VStack(alignment: .trailing, spacing: 3) {
                Text("\(nodeCount)")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(palette.text)
                Text("节点")
                    .font(.caption2)
                    .foregroundStyle(palette.subtext)
            }
            .frame(minWidth: 44)

            if !subscription.isShareLinksBundle {
                Button(action: onRefresh) { refreshBadge }
                    .buttonStyle(.plain)
                    .help(activity?.title ?? "立即更新")
                    .disabled(!subscription.isEnabled)
                    // 保持转动图标的强调色；更新中再点会重复排队。
                    .allowsHitTesting(activity != .updating)
            } else if activity != nil {
                refreshBadge.help(activity?.title ?? "")
            }

            Menu {
                Button("查看", action: onView)
                Button("编辑", action: onEdit)
                Button("测试本组全部节点", action: onTest)
                Divider()
                Button("删除", role: .destructive, action: onDelete)
                Button(subscription.isEnabled ? "禁用" : "启用", action: onToggleEnabled)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 28)
                    .background(palette.text.opacity(0.07), in: Circle())
            }
            .menuStyle(.borderlessButton)
            .help("更多操作")
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.card)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(
                            colors: [palette.accent.opacity(palette.scheme == .dark ? 0.16 : 0.09), .clear],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .opacity(isHovered ? 1 : 0)
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.cardBorder, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .scaleEffect(isHovered && !reduceMotion ? 1.015 : 1)
        .shadow(color: palette.accent.opacity(isHovered ? 0.10 : 0), radius: 10)
        .shadow(color: .black.opacity(isHovered ? (palette.scheme == .dark ? 0.24 : 0.14) : 0), radius: 8, y: 3)
        .zIndex(isHovered ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isHovered)
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onView)
        .help(detailLine == "尚未更新" ? oneLineMeta : detailLine)
    }

    private var refreshBadge: some View {
        refreshIcon
            .frame(width: 28, height: 28)
            .background(palette.accent.opacity(activity == nil ? 0.12 : 0.22), in: Circle())
            .foregroundStyle(palette.accent)
            .accessibilityLabel(activity?.title ?? "立即更新")
    }

    private var probeTargetIcons: some View {
        let icons = Array(probeTargets.prefix(8))
        return Group {
            if icons.count <= 4 {
                probeIconRow(icons)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    probeIconRow(Array(icons.prefix(4)))
                    probeIconRow(Array(icons.dropFirst(4)))
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private func probeIconRow(_ targets: [AppProbeTarget]) -> some View {
        HStack(spacing: 4) {
            ForEach(targets) { target in
                AppProbeIcon(target: target, passed: true, size: 18)
            }
        }
    }

    @ViewBuilder
    private var refreshIcon: some View {
        if activity != nil, !reduceMotion {
            TimelineView(.animation) { context in
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 1) * 360))
            }
        } else {
            Image(systemName: "arrow.clockwise")
        }
    }

    private func metadataBadge(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2)
            .foregroundStyle(palette.subtext)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(palette.text.opacity(0.06), in: Capsule())
    }

    private var updateScheduleText: String {
        guard subscription.autoUpdate else { return "自动更新关" }
        guard subscription.updateInterval.usesTimeOfDay else { return subscription.updateInterval.displayName }
        return "\(subscription.updateInterval.displayName) \(String(format: "%02d:%02d", subscription.updateHour, subscription.updateMinute))"
    }

    private var detailLine: String {
        if let retry = subscription.updateRetryStatusLine { return retry }
        if let error = subscription.lastError, !error.isEmpty { return error }
        // 分享链接列表行只显示实时节点数；「已导入/已追加 N」是操作结果，不能当当前库存。
        if subscription.isShareLinksBundle {
            if nodeCount == 0 {
                if let message = subscription.statusMessage, message.contains("当前无节点") {
                    return message
                }
                if shareLinkCount > 0 {
                    return "\(shareLinkCount) 条分享链接 · 编辑可重新导入"
                }
                return "暂无节点"
            }
            if shareLinkCount > 0 {
                return "当前 \(nodeCount) 个节点 · \(shareLinkCount) 条分享链接"
            }
            return "当前 \(nodeCount) 个节点"
        }
        if let message = subscription.statusMessage, !message.isEmpty { return message }
        if let last = subscription.lastSuccessAt {
            return "最近更新：\(last.formatted(date: .abbreviated, time: .shortened))"
        }
        return "尚未更新"
    }

    private var oneLineMeta: String {
        var parts: [String] = [statusText]
        if !subscription.isEnabled {
            parts = ["禁用"]
        }
        parts.append(subscription.sourceKind.displayName)
        parts.append(subscription.updateMode.displayName)
        if subscription.autoUpdate {
            parts.append(updateScheduleText)
        } else {
            parts.append("自动更新关")
        }
        if let last = subscription.lastSuccessAt {
            parts.append(last.formatted(date: .abbreviated, time: .shortened))
        }
        if subscription.isShareLinksBundle {
            parts.append("\(nodeCount) 个节点")
        } else if let message = subscription.statusMessage, !message.isEmpty {
            parts.append(message)
        }
        return parts.joined(separator: " · ")
    }

    private var statusText: String {
        if !subscription.isEnabled { return "禁用" }
        if subscription.isShareLinksBundle {
            if nodeCount > 0 { return "已导入" }
            return "暂无节点"
        }
        if subscription.isHealthy { return "正常" }
        if subscription.lastError != nil { return "异常" }
        return "待更新"
    }

    private var statusColor: Color {
        if !subscription.isEnabled { return .secondary }
        if subscription.isShareLinksBundle, nodeCount == 0 { return .orange }
        if subscription.isHealthy { return .green }
        if subscription.lastError != nil { return .red }
        return .orange
    }
}

// MARK: - Detail

struct SubscriptionDetailView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let subscriptionID: UUID
    @State private var confirmCleanup = false
    @State private var presentedHistory: SubscriptionHistoryKind?

    private var subscription: Subscription? {
        appState.subscription(for: subscriptionID)
    }

    private var subscriptionPendingNodeCount: Int {
        appState.nodes.filter { node in
            node.subscriptionID == subscriptionID &&
            (node.pendingRemoval || node.pendingConfigUpdate)
        }.count
    }

    var body: some View {
        NavigationStack {
            Group {
                if let sub = subscription {
                    Form {
                        Section("基本信息") {
                            LabeledContent("名称", value: sub.name)
                            LabeledContent("类型", value: sub.sourceKind.displayName)
                            LabeledContent("状态", value: sub.isEnabled ? "启用" : "禁用")
                            if !sub.isShareLinksBundle {
                                LabeledContent("地址模式", value: sub.urlMode.displayName)
                            }
                            LabeledContent(sub.isShareLinksBundle ? "链接处理方式" : "更新模式", value: sub.updateMode.displayName)
                            LabeledContent("节点数量", value: "\(appState.nodes.filter { $0.subscriptionID == sub.id && !$0.pendingRemoval }.count)")
                            if subscriptionPendingNodeCount > 0 {
                                LabeledContent("待处理节点", value: "\(subscriptionPendingNodeCount)（待应用/待移除）")
                            }
                        }

                        Section("长期不可用 / 失败节点清理") {
                            Toggle("自动清理", isOn: Binding(
                                get: { subscription?.autoCleanupUnavailableNodes ?? false },
                                set: { value in
                                    guard var latest = subscription else { return }
                                    latest.autoCleanupUnavailableNodes = value
                                    appState.updateSubscription(latest)
                                }
                            ))
                            Stepper("持续不可用或失败：\(min(30, max(1, sub.unavailableCleanupDays ?? 3))) 天", value: Binding(
                                get: { min(30, max(1, subscription?.unavailableCleanupDays ?? 3)) },
                                set: { value in
                                    guard var latest = subscription else { return }
                                    latest.unavailableCleanupDays = min(30, max(1, value))
                                    appState.updateSubscription(latest)
                                    if latest.autoCleanupUnavailableNodes == true {
                                        appState.cleanupUnavailableNodes(subscriptionID: subscriptionID, automatic: true)
                                    }
                                }
                            ), in: 1...30)
                            Button("清理当前组长期不可用或失败节点", role: .destructive) {
                                confirmCleanup = true
                            }
                            .disabled(appState.unavailableCleanupCandidates(subscriptionID: subscriptionID).isEmpty)
                            let protectedCount = appState.protectedCleanupFavoriteCount(subscriptionID: subscriptionID)
                            if protectedCount > 0 {
                                Label("本组有 \(protectedCount) 个收藏节点已达到不可用或失败期限，仍会一直保留。如需移除，请在节点列表中手动删除。", systemImage: "star.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            let suppressedCount = sub.suppressedUnavailableFingerprints?.count ?? 0
                            if suppressedCount > 0 {
                                Text("有 \(suppressedCount) 个已清理节点不会在订阅更新时重新导入。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("允许这些节点在下次更新时重新导入") {
                                    appState.allowCleanedUnavailableNodesToReturn(subscriptionID: subscriptionID)
                                }
                            }
                            HStack {
                                Text("清理规则").font(.caption).foregroundStyle(.secondary)
                                UsageHelpButton(title: "清理规则", text: "不可用或失败达到设定天数后删除。计时从第一次标成不可用或失败开始，两种结果来回切换不会重计；只有测成可用才重新计时。定时测速选「仅当前可用」时，这两类节点不测；设定天数内如果没有新的相同状态结果，计时顺延，如果有且已超过天数，则立即删除。收藏和当前连接节点保留。已清理的节点不会在下次订阅更新时自动加回。")
                            }
                        }

                        Section("清理历史") {
                            TimelineView(.periodic(from: .now, by: 60)) { context in
                                LabeledContent("今日自动清理", value: "\(sub.automaticCleanupCountToday(now: context.date)) 个节点")
                            }
                            let records = sub.cleanupHistory ?? []
                            if let latest = records.first {
                                SubscriptionCleanupHistoryRow(record: latest)
                                Button("查看全部清理记录（\(records.count) 条）") {
                                    presentedHistory = .cleanup
                                }
                            } else {
                                Text("暂无清理记录").foregroundStyle(.secondary)
                            }
                        }

                        if sub.isShareLinksBundle {
                            shareLinksDetailSection(sub)
                        } else {
                            remoteURLDetailSections(sub)
                        }

                    }
                    .formStyle(.grouped)
                } else {
                    UnavailablePlaceholder("订阅不存在", systemImage: "link")
                }
            }
            .confirmationDialog("清理当前组长期不可用或失败节点？", isPresented: $confirmCleanup, titleVisibility: .visible) {
                Button("清理 \(appState.unavailableCleanupCandidates(subscriptionID: subscriptionID).count) 个节点", role: .destructive) {
                    appState.cleanupUnavailableNodes(subscriptionID: subscriptionID)
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("仅删除符合期限的节点，保留订阅。此操作不可撤销。")
            }
            .navigationTitle("订阅详情")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("编辑") {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            appState.editingSubscriptionID = subscriptionID
                        }
                    }
                    if subscription?.isShareLinksBundle != true {
                        Button("更新") {
                            Task { await appState.refreshSubscription(subscriptionID) }
                        }
                    }
                }
            }
            .frame(minWidth: 560, minHeight: 520)
            .sheet(item: $presentedHistory) { kind in
                SubscriptionHistoryView(subscriptionID: subscriptionID, kind: kind)
                    .environmentObject(appState)
            }
        }
    }

    @ViewBuilder
    private func shareLinksDetailSection(_ sub: Subscription) -> some View {
        let links = appState.currentSubscriptionShareLinks(sub)
        Section("分享链接（\(links.count)）") {
            if links.isEmpty {
                Text("暂无链接").foregroundStyle(.secondary)
            } else {
                HStack {
                    Spacer()
                    Button {
                        copyShareLinks(links)
                    } label: {
                        Label("一键复制", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                ForEach(Array(links.enumerated()), id: \.offset) { index, link in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("链接 \(index + 1)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(link)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        Section("最近状态") {
            if let last = sub.lastSuccessAt {
                LabeledContent("最近导入", value: last.formatted(date: .abbreviated, time: .shortened))
            }
            if sub.updateFailureCount > 0 {
                LabeledContent("连续失败", value: "\(sub.updateFailureCount) 次")
            }
            if let retry = sub.nextRetryAt {
                LabeledContent("失败退避重试", value: retry.formatted(date: .abbreviated, time: .shortened))
            }
            if let error = sub.lastError {
                Text(error).foregroundStyle(.red)
            }
            if let message = sub.statusMessage {
                Text(message).foregroundStyle(.orange)
            }
        }
    }

    private func copyShareLinks(_ links: [String]) {
        let text = links.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        appState.statusBanner = "已复制 \(links.count) 条分享链接"
    }

    @ViewBuilder
    private func remoteURLDetailSections(_ sub: Subscription) -> some View {
        Section("地址") {
            LabeledContent("订阅 URL") {
                Text(sub.originalURL)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            if sub.urlMode == .dateTemplate {
                if let template = sub.urlTemplate {
                    LabeledContent("模板") {
                        Text(template)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                LabeledContent("上次拉取") {
                    Text(sub.lastResolvedURL ?? sub.resolvedURL ?? sub.originalURL)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent("下次请求") {
                    Text(appState.subscriptionManager.nextPreviewURL(for: sub))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            } else if let last = sub.lastResolvedURL, last != sub.originalURL {
                LabeledContent("上次拉取") {
                    Text(last)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }

        Section("更新设置") {
            LabeledContent("自动更新", value: sub.autoUpdate ? "开启" : "关闭")
            LabeledContent("周期", value: sub.updateInterval.displayName)
            if sub.updateInterval.usesTimeOfDay {
                LabeledContent("时间", value: String(format: "%02d:%02d", sub.updateHour, sub.updateMinute))
            }
            LabeledContent("执行时区", value: sub.timeZoneID)
            LabeledContent("URL 日期时区", value: sub.urlDateTimeZoneID)
            LabeledContent("日期偏移", value: dateOffsetLabel(sub.dateOffset))
            LabeledContent("回退天数", value: "\(sub.fallbackDays)")
            LabeledContent("更新后测试", value: sub.testAfterUpdate ? "开启" : "关闭")
        }

        Section("最近状态") {
            if let last = sub.lastSuccessAt {
                LabeledContent("最近成功", value: last.formatted(date: .abbreviated, time: .shortened))
            }
            if let next = sub.nextUpdateAt {
                LabeledContent("下次计划更新", value: next.formatted(date: .abbreviated, time: .shortened))
            }
            if sub.updateFailureCount > 0 {
                LabeledContent("连续失败", value: "\(sub.updateFailureCount) 次")
            }
            if let retry = sub.nextRetryAt {
                LabeledContent("失败退避重试", value: retry.formatted(date: .abbreviated, time: .shortened))
            } else if sub.updateFailureCount > 0 {
                Text("等待调度下一次失败重试")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let code = sub.lastHTTPStatus {
                LabeledContent("HTTP", value: "\(code)")
            }
            if let error = sub.lastError {
                Text(error).foregroundStyle(.red)
            }
            if let message = sub.statusMessage {
                Text(message).foregroundStyle(.orange)
            }
        }

        Section("更新历史") {
            let logs = appState.logs(for: sub.id, limit: .max)
            if let latest = logs.first {
                SubscriptionUpdateHistoryRow(log: latest, compact: true)
                Button("查看全部更新记录（\(logs.count) 条）") {
                    presentedHistory = .updates
                }
            } else {
                Text("暂无记录").foregroundStyle(.secondary)
            }
        }
    }

    private func dateOffsetLabel(_ offset: Int) -> String {
        switch offset {
        case 0: return "当天"
        case -1: return "昨天"
        case -2: return "前天"
        default: return "\(offset) 天"
        }
    }
}

private enum SubscriptionHistoryKind: String, Identifiable {
    case cleanup, updates

    var id: String { rawValue }
    var title: String { self == .cleanup ? "清理历史" : "更新历史" }
}

private struct SubscriptionCleanupHistoryRow: View {
    let record: SubscriptionCleanupRecord

    var body: some View {
        HStack {
            Text(record.cleanedAt.formatted(date: .abbreviated, time: .standard))
            Spacer(minLength: 8)
            Text(record.automatic ? "自动" : "手动")
                .foregroundStyle(.secondary)
            Text("删除 \(record.removedCount) 个节点")
        }
    }
}

private struct SubscriptionUpdateHistoryRow: View {
    let log: SubscriptionUpdateLog
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(log.startedAt.formatted(date: .abbreviated, time: .shortened))
                Spacer(minLength: 8)
                Text(log.success ? "成功" : "失败")
                    .foregroundStyle(log.success ? .green : .red)
            }
            Text(log.requestedURL)
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(compact ? 2 : nil)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if log.success {
                Text("获取 \(log.fetchedCount) · 新增 \(log.addedCount) · 更新 \(log.updatedCount) · 移除 \(log.removedCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let error = log.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(compact ? 2 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct SubscriptionHistoryView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let subscriptionID: UUID
    let kind: SubscriptionHistoryKind
    @State private var cleanupFilter = SubscriptionCleanupHistoryFilter()
    @State private var updateFilter = SubscriptionUpdateHistoryFilter()
    @State private var pendingClear: HistoryClearRequest?
    @State private var clearFeedback: String?

    private struct HistoryClearRequest {
        let recordIDs: Set<UUID>
        let scope: String
    }

    private var periodSelection: Binding<SubscriptionHistoryPeriod> {
        Binding(
            get: { kind == .cleanup ? cleanupFilter.period : updateFilter.period },
            set: { period in
                if kind == .cleanup { cleanupFilter.period = period }
                else { updateFilter.period = period }
            }
        )
    }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let sub = appState.subscription(for: subscriptionID)
                let records = sub?.cleanupHistory ?? []
                let filtered = cleanupFilter.apply(to: records, now: context.date)
                let logs = kind == .updates ? appState.logs(for: subscriptionID, limit: .max) : []
                let filteredLogs = updateFilter.apply(to: logs, now: context.date)
                let allIDs = kind == .cleanup ? Set(records.map(\.id)) : Set(logs.map(\.id))
                let filteredIDs = kind == .cleanup ? Set(filtered.map(\.id)) : Set(filteredLogs.map(\.id))
                let isFiltering = kind == .cleanup ? cleanupFilter.isActive : updateFilter.isActive
                Group {
                    if let sub {
                        VStack(spacing: 0) {
                            HStack(spacing: 16) {
                                Picker("时间", selection: periodSelection) {
                                    ForEach(SubscriptionHistoryPeriod.allCases, id: \.self) { period in
                                        Text(period.rawValue).tag(period)
                                    }
                                }
                                if kind == .cleanup {
                                    Picker("方式", selection: $cleanupFilter.source) {
                                        ForEach(SubscriptionCleanupHistoryFilter.Source.allCases, id: \.self) { source in
                                            Text(source.rawValue).tag(source)
                                        }
                                    }
                                } else {
                                    Picker("结果", selection: $updateFilter.result) {
                                        ForEach(SubscriptionUpdateHistoryFilter.Result.allCases, id: \.self) { result in
                                            Text(result.rawValue).tag(result)
                                        }
                                    }
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(.bar)
                            Divider()
                            List {
                                HStack {
                                    Text(sub.name).font(.headline).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text("显示 \(filteredIDs.count) / \(allIDs.count) 条")
                                        .foregroundStyle(.secondary)
                                }
                                if kind == .cleanup {
                                    LabeledContent("今日自动清理", value: "\(sub.automaticCleanupCountToday(now: context.date)) 个节点")
                                    if filtered.isEmpty {
                                        Text(records.isEmpty ? "暂无清理记录" : "没有符合筛选条件的记录")
                                            .foregroundStyle(.secondary)
                                    }
                                    ForEach(filtered) { record in
                                        SubscriptionCleanupHistoryRow(record: record)
                                    }
                                } else {
                                    if filteredLogs.isEmpty {
                                        Text(logs.isEmpty ? "暂无更新记录" : "没有符合筛选条件的记录")
                                            .foregroundStyle(.secondary)
                                    }
                                    ForEach(filteredLogs) { log in
                                        SubscriptionUpdateHistoryRow(log: log)
                                    }
                                }
                            }
                            .listStyle(.inset)
                        }
                    } else {
                        UnavailablePlaceholder("订阅不存在", systemImage: "link")
                    }
                }
                .navigationTitle(kind.title)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let clearFeedback {
                            Text(clearFeedback).font(.caption).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 12) {
                            Button("清除筛选结果", role: .destructive) {
                                pendingClear = HistoryClearRequest(recordIDs: filteredIDs, scope: "当前筛选结果")
                            }
                            .disabled(!isFiltering || filteredIDs.isEmpty)
                            Button("清除全部", role: .destructive) {
                                pendingClear = HistoryClearRequest(recordIDs: allIDs, scope: "当前订阅的全部\(kind.title)")
                            }
                            .disabled(allIDs.isEmpty)
                            Spacer()
                            Button("关闭") { dismiss() }
                                .keyboardShortcut(.cancelAction)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(12)
                    .background(.bar)
                }
                .alert("清除\(kind.title)？", isPresented: Binding(
                    get: { pendingClear != nil },
                    set: { if !$0 { pendingClear = nil } }
                ), presenting: pendingClear) { request in
                    Button("清除 \(request.recordIDs.count) 条记录", role: .destructive) {
                        if kind == .cleanup {
                            appState.clearSubscriptionCleanupHistory(subscriptionID, recordIDs: request.recordIDs)
                        } else {
                            appState.clearSubscriptionUpdateHistory(subscriptionID, recordIDs: request.recordIDs)
                        }
                        clearFeedback = appState.statusBanner
                    }
                    Button("取消", role: .cancel) {}
                } message: { request in
                    Text(kind == .cleanup
                         ? "\(request.scope)，共 \(request.recordIDs.count) 条。仅清除历史记录，不删除节点或更改自动清理设置。今日统计将按剩余记录重新计算，此操作不可撤销。"
                         : "\(request.scope)，共 \(request.recordIDs.count) 条。仅清除历史记录，不删除节点、订阅或更改更新计划，此操作不可撤销。")
                }
                .frame(width: 600, height: 460)
                .background(.background)
            }
        }
    }
}

// MARK: - Editor

private struct SubscriptionTimeWheel: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let label: String
    @FocusState private var isFocused: Bool
    @State private var scrollValue: Int?

    var body: some View {
        Group {
            if #available(macOS 14.0, *) {
                modernWheel
            } else {
                legacyWheel
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(String(format: "%02d", value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(range.upperBound, value + 1)
            case .decrement: value = max(range.lowerBound, value - 1)
            @unknown default: break
            }
        }
        .help("滚动或使用上下方向键选择\(label)")
    }

    @available(macOS 14.0, *)
    private var modernWheel: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(range, id: \.self) { number in
                    Button {
                        value = number
                    } label: {
                        Text(String(format: "%02d", number))
                            .font(.body.monospacedDigit().weight(number == value ? .semibold : .regular))
                            .foregroundStyle(number == value ? .primary : .secondary)
                            .frame(width: 56, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .id(number)
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.never)
        .safeAreaPadding(.vertical, 28)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $scrollValue, anchor: .center)
        .onAppear { scrollValue = value }
        .onChange(of: value) { _, number in scrollValue = number }
        .onChange(of: scrollValue) { _, number in
            if let number { value = number }
        }
        .frame(width: 56, height: 84)
        .background { wheelChrome }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.upArrow) {
            value = max(range.lowerBound, value - 1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            value = min(range.upperBound, value + 1)
            return .handled
        }
    }

    /// macOS 13：无焦点环的点击/步进选择，避免系统蓝框和滚动错位。
    private var legacyWheel: some View {
        HStack(spacing: 4) {
            Button {
                value = max(range.lowerBound, value - 1)
            } label: {
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.semibold))
                    .frame(width: 22, height: 28)
            }
            .buttonStyle(.borderless)
            .disabled(value <= range.lowerBound)

            Text(String(format: "%02d", value))
                .font(.body.monospacedDigit().weight(.semibold))
                .frame(width: 36, height: 28)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

            Button {
                value = min(range.upperBound, value + 1)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .frame(width: 22, height: 28)
            }
            .buttonStyle(.borderless)
            .disabled(value >= range.upperBound)
        }
        .frame(height: 84)
    }

    private var wheelChrome: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(.quaternary)
            .frame(height: 28)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isFocused ? Color.accentColor : .clear, lineWidth: 1.5)
                    .frame(height: 28)
            }
    }
}

enum SubscriptionEditorMode {
    case create
    case edit(Subscription)
}

struct SubscriptionEditorView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let mode: SubscriptionEditorMode

    @State private var name = ""
    @State private var url = ""
    @State private var shareLinksText = ""
    @State private var sourceKind: SubscriptionSourceKind = .remoteURL
    @State private var urlMode: SubscriptionURLMode = .fixed
    @State private var template = ""
    @State private var detection: DateTemplateDetection?
    @State private var previewToday = ""
    @State private var previewYesterday = ""
    @State private var fetchYesterdayFirst = false

    @State private var isEnabled = true
    @State private var autoUpdate = true
    @State private var updateIntervalCountText = "1"
    @State private var updateIntervalUnit: SubscriptionInterval.Unit = .days
    @FocusState private var intervalCountFocused: Bool
    @State private var intervalClickMonitor: Any?
    @State private var updateHour = 8
    @State private var updateMinute = 30
    @State private var showingUpdateTime = false
    @State private var timeZoneID = "Asia/Shanghai"
    @State private var urlDateTimeZoneID = "Asia/Shanghai"
    @State private var dateOffset = 0
    @State private var fallbackDays = 3
    @State private var updateMode: SubscriptionUpdateMode = .smartMerge
    @State private var showingUpdateModeHelp = false
    @State private var testAfterUpdate = true
    @State private var smartMergeMissingLimit = 3
    @State private var autoCleanupUnavailableNodes = false
    @State private var unavailableCleanupDays = 3
    @State private var refreshAfterSave = false

    init(mode: SubscriptionEditorMode = .create) {
        self.mode = mode
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var isEditingShareLinks: Bool {
        isEditing && sourceKind == .shareLinks
    }

    private var canSave: Bool {
        switch sourceKind {
        case .remoteURL:
            return !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && SubscriptionInterval.validCounts.contains(updateIntervalCount)
        case .shareLinks:
            if isEditingShareLinks {
                return true
            }
            return !NodeLinkParser.extractShareLinks(from: shareLinksText).isEmpty
        }
    }

    private var updateInterval: SubscriptionInterval {
        SubscriptionInterval(count: updateIntervalCount, unit: updateIntervalUnit)
    }

    private var updateIntervalCount: Int { Int(updateIntervalCountText) ?? 0 }

    private var sharePreviewCount: Int {
        NodeLinkParser.parseLines(shareLinksText).validNodes.count
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("导入类型") {
                    Picker("类型", selection: $sourceKind) {
                        ForEach(SubscriptionSourceKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isEditing) // don't flip type on existing entries

                    Text(importTypeFootnote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(isEditingShareLinks ? "追加分享链接" : "基本") {
                    TextField("名称", text: $name)

                    if sourceKind == .remoteURL {
                        HStack(spacing: 8) {
                            TextField("订阅 URL", text: $url)
                                .onChange(of: url) { newValue in
                                    detect(newValue)
                                }
                            Button("粘贴") {
                                guard let text = NSPasteboard.general.string(forType: .string) else { return }
                                url = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                            .help("从剪贴板粘贴并替换订阅 URL")
                            Button("清除") { url = "" }
                                .disabled(url.isEmpty)
                                .help("清空订阅 URL")
                        }
                        .buttonStyle(.bordered)
                    } else {
                        if isEditingShareLinks {
                            Text("输入框留空表示仅修改名称/策略；粘贴新链接后按下方「链接处理方式」覆盖或合并到现有节点。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        TextEditor(text: $shareLinksText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: isEditingShareLinks ? 140 : 180)
                        if !shareLinksText.isEmpty {
                            Text("已识别 \(sharePreviewCount) 个有效节点")
                                .font(.caption)
                                .foregroundStyle(sharePreviewCount > 0 ? Color.secondary : Color.orange)
                        } else if isEditingShareLinks {
                            Text("可粘贴要追加或替换的分享链接")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("已识别 \(sharePreviewCount) 个有效节点")
                                .font(.caption)
                                .foregroundStyle(sharePreviewCount > 0 ? Color.secondary : Color.orange)
                        }
                    }

                    Toggle("启用", isOn: $isEnabled)
                }

                if sourceKind == .remoteURL, detection != nil || urlMode == .dateTemplate {
                    Section("日期型订阅") {
                        if let detection, detection.detected, urlMode != .dateTemplate {
                            Text("检测到日期模板（当前仍使用上方原始地址，不会自动改成今天）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("同步昨天") {
                                    syncYesterdayURL()
                                }
                                .disabled(previewYesterday.isEmpty)

                                Button("同步今天") {
                                    syncTodayURL()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(previewToday.isEmpty)
                            }
                            Text("只有点击同步后，才会把订阅 URL 改成对应日期并启用自动日期地址")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if fetchYesterdayFirst {
                            Text("添加后先拉取昨天的节点，再拉取今天的节点；后续自动更新从今天开始。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Picker("地址模式", selection: $urlMode) {
                            ForEach(SubscriptionURLMode.allCases, id: \.self) { item in
                                Text(item.displayName).tag(item)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .onChange(of: urlMode) { mode in
                            if mode == .dateTemplate {
                                if template.isEmpty, let detected = detection?.template {
                                    template = detected
                                }
                                refreshPreviews()
                            }
                        }

                        if urlMode == .dateTemplate {
                            TextField("URL 模板", text: $template)
                                .font(.system(.body, design: .monospaced))
                                .onChange(of: template) { _ in
                                    refreshPreviews()
                                }
                            if !previewToday.isEmpty {
                                Text("今天将请求：\(previewToday)")
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .foregroundStyle(.secondary)
                            }
                            if !previewYesterday.isEmpty {
                                Text("昨天将请求：\(previewYesterday)")
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .foregroundStyle(.secondary)
                            }
                            HStack {
                                Button("同步昨天") {
                                    syncYesterdayURL()
                                }
                                .disabled(previewYesterday.isEmpty)

                                Button("同步今天") {
                                    syncTodayURL()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(previewToday.isEmpty)
                            }
                        }
                    }
                }

                if sourceKind == .remoteURL {
                    Section("自动更新") {
                        Toggle("自动更新", isOn: $autoUpdate)
                        LabeledContent("更新周期") {
                            HStack(spacing: 8) {
                                Text("每")
                                TextField("数量", text: $updateIntervalCountText)
                                    .focused($intervalCountFocused)
                                    .onSubmit { intervalCountFocused = false }
                                    .onExitCommand { intervalCountFocused = false }
                                    .labelsHidden()
                                    .textFieldStyle(.roundedBorder)
                                    .multilineTextAlignment(.center)
                                    .frame(width: 48)
                                    .accessibilityLabel("更新周期数量")
                                    .accessibilityIdentifier("subscription-interval-count")
                                Stepper("更新周期数量", value: Binding(
                                    get: { min(999, max(1, updateIntervalCount)) },
                                    set: {
                                        intervalCountFocused = false
                                        updateIntervalCountText = String($0)
                                    }
                                ), in: SubscriptionInterval.validCounts)
                                    .labelsHidden()
                                    .fixedSize()
                                Picker("周期单位", selection: $updateIntervalUnit) {
                                    ForEach(SubscriptionInterval.Unit.allCases, id: \.self) { unit in
                                        Text(unit.displayName).tag(unit)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 76)
                                .accessibilityIdentifier("subscription-interval-unit")
                                .onChange(of: updateIntervalUnit) { _ in intervalCountFocused = false }
                            }
                        }
                        if !SubscriptionInterval.validCounts.contains(updateIntervalCount) {
                            Text("更新周期请输入 1–999 的整数")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        if updateInterval.usesTimeOfDay {
                            LabeledContent("更新时间") {
                                Button {
                                    intervalCountFocused = false
                                    showingUpdateTime = true
                                } label: {
                                    HStack(spacing: 6) {
                                        Text(String(format: "%02d:%02d", updateHour, updateMinute))
                                            .monospacedDigit()
                                        Image(systemName: "chevron.down")
                                            .font(.caption2)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .accessibilityLabel("更新时间")
                                .accessibilityValue(String(format: "%02d:%02d", updateHour, updateMinute))
                                .accessibilityIdentifier("subscription-update-time")
                                .popover(isPresented: $showingUpdateTime, arrowEdge: .bottom) {
                                    VStack(spacing: 12) {
                                        Text("更新时间")
                                            .font(.headline)
                                        HStack(spacing: 8) {
                                            SubscriptionTimeWheel(value: $updateHour, range: 0...23, label: "更新小时")
                                            Text("时")
                                            SubscriptionTimeWheel(value: $updateMinute, range: 0...59, label: "更新分钟")
                                            Text("分")
                                        }
                                        Button("完成") { showingUpdateTime = false }
                                            .keyboardShortcut(.defaultAction)
                                            .accessibilityIdentifier("subscription-update-time-done")
                                    }
                                    .padding(16)
                                }
                            }
                        } else if updateInterval != .manual {
                            LabeledContent("更新时间") {
                                Text("按间隔更新，无需设置固定时间。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                        TextField("执行时区", text: $timeZoneID)
                        TextField("URL 日期时区", text: $urlDateTimeZoneID)
                        Picker("日期偏移", selection: $dateOffset) {
                            Text("当天").tag(0)
                            Text("昨天").tag(-1)
                            Text("前天").tag(-2)
                            Text("自定义 -3").tag(-3)
                        }
                        Stepper("回退天数：\(fallbackDays)", value: $fallbackDays, in: 0...14)
                    }
                }

                Section(sourceKind == .shareLinks ? "链接处理方式" : "合并策略") {
                    Picker(selection: $updateMode) {
                        ForEach(SubscriptionUpdateMode.allCases, id: \.self) { item in
                            Text(item.displayName).tag(item)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(sourceKind == .shareLinks ? "处理方式" : "更新方式")
                            Button {
                                showingUpdateModeHelp = true
                            } label: {
                                Image(systemName: "questionmark.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("查看说明")
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .alert("更新模式说明", isPresented: $showingUpdateModeHelp) {
                        Button("好", role: .cancel) {}
                    } message: {
                        Text(
                            SubscriptionUpdateMode.allCases
                                .map { "· \($0.displayName)\n\($0.helpText)" }
                                .joined(separator: "\n\n")
                        )
                    }
                    if sourceKind == .remoteURL {
                        Toggle("定时更新后测试新节点", isOn: $testAfterUpdate)
                    }
                    if updateMode == .smartMerge {
                        Stepper("连续缺失 \(smartMergeMissingLimit) 次后删除", value: $smartMergeMissingLimit, in: 1...10)
                    }
                }

                Section("长期不可用 / 失败节点清理") {
                    Toggle("自动清理", isOn: $autoCleanupUnavailableNodes)
                    Stepper("持续不可用或失败：\(unavailableCleanupDays) 天", value: $unavailableCleanupDays, in: 1...30)
                    Text("在订阅详情中可手动清理。不可用或失败达到设定天数后删除。定时测速选「仅当前可用」时这两类节点不测，没有新的相同状态结果就顺延计时。收藏和当前连接节点保留。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if isEditing, sourceKind == .remoteURL {
                    Section {
                        Toggle("保存后立即更新", isOn: $refreshAfterSave)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isEditing ? "编辑订阅" : "添加订阅")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "保存" : "添加") {
                        save()
                    }
                    .disabled(!canSave)
                }
            }
            .frame(width: 580, height: 620)
            .onAppear(perform: load)
            .onAppear {
                guard intervalClickMonitor == nil else { return }
                // Native Form backgrounds don't move the field editor's focus on click.
                intervalClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                    if intervalCountFocused,
                       let editor = event.window?.firstResponder as? NSTextView, editor.isFieldEditor {
                        let field: NSView = (editor.delegate as? NSTextField) ?? editor
                        if !field.bounds.contains(field.convert(event.locationInWindow, from: nil)) {
                            intervalCountFocused = false
                        }
                    }
                    return event
                }
            }
            .onDisappear {
                if let monitor = intervalClickMonitor { NSEvent.removeMonitor(monitor) }
                intervalClickMonitor = nil
            }
        }
    }

    private func load() {
        switch mode {
        case .create:
            updateHour = appState.settings.defaultUpdateHour
            updateMinute = appState.settings.defaultUpdateMinute
            timeZoneID = appState.settings.defaultTimeZoneID
            urlDateTimeZoneID = appState.settings.defaultTimeZoneID
            fallbackDays = appState.settings.defaultFallbackDays
            updateMode = appState.settings.defaultUpdateMode
            sourceKind = .remoteURL
        case .edit(let sub):
            name = sub.name
            sourceKind = sub.sourceKind
            url = sub.originalURL
            shareLinksText = sub.isShareLinksBundle ? "" : (sub.shareLinksText ?? "")
            urlMode = sub.urlMode
            template = sub.urlTemplate ?? ""
            isEnabled = sub.isEnabled
            autoUpdate = sub.autoUpdate && sub.updateInterval != .manual
            updateIntervalCountText = String(sub.updateInterval.count)
            updateIntervalUnit = sub.updateInterval.unit
            updateHour = sub.updateHour
            updateMinute = sub.updateMinute
            timeZoneID = sub.timeZoneID
            urlDateTimeZoneID = sub.urlDateTimeZoneID
            dateOffset = sub.dateOffset
            fallbackDays = sub.fallbackDays
            updateMode = sub.updateMode
            testAfterUpdate = sub.testAfterUpdate
            smartMergeMissingLimit = sub.smartMergeMissingLimit
            autoCleanupUnavailableNodes = sub.autoCleanupUnavailableNodes ?? false
            unavailableCleanupDays = min(30, max(1, sub.unavailableCleanupDays ?? 3))
            if sub.sourceKind == .remoteURL {
                detect(sub.originalURL)
            }
            if let existing = sub.urlTemplate, !existing.isEmpty {
                template = existing
            }
        }
    }

    private func save() {
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        switch mode {
        case .create:
            if sourceKind == .shareLinks {
                appState.addShareLinkSubscription(name: displayName, shareText: shareLinksText)
                dismiss()
                return
            }

            let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedTemplate = urlMode == .dateTemplate
                ? (template.isEmpty ? detection?.template : template)
                : nil
            appState.addSubscription(
                name: displayName,
                url: trimmedURL,
                urlMode: urlMode,
                template: resolvedTemplate,
                autoUpdate: autoUpdate,
                fetchAfterInsert: false
            )
            // Patch newly added with full settings, then fetch once (avoids racing the editor patch).
            if var created = appState.subscriptions.first(where: { $0.originalURL == trimmedURL }) {
                created.isEnabled = isEnabled
                created.updateInterval = updateInterval
                created.updateHour = updateHour
                created.updateMinute = updateMinute
                created.timeZoneID = timeZoneID
                created.urlDateTimeZoneID = urlDateTimeZoneID
                created.dateOffset = dateOffset
                created.fallbackDays = fallbackDays
                created.updateMode = updateMode
                created.testAfterUpdate = testAfterUpdate
                created.smartMergeMissingLimit = smartMergeMissingLimit
                created.autoCleanupUnavailableNodes = autoCleanupUnavailableNodes
                created.unavailableCleanupDays = unavailableCleanupDays
                appState.updateSubscription(created)
                let includeYesterday = fetchYesterdayFirst
                Task { await appState.refreshSubscription(created.id, fetchYesterdayFirst: includeYesterday) }
            }
        case .edit(let original):
            guard var updated = appState.subscription(for: original.id) else {
                appState.statusBanner = "订阅已被删除，请关闭编辑窗口后重试"
                return
            }
            if original.isShareLinksBundle {
                let trimmed = shareLinksText.trimmingCharacters(in: .whitespacesAndNewlines)
                let hasNewLinks = !trimmed.isEmpty
                if hasNewLinks {
                    let preview = NodeLinkParser.parseLines(trimmed)
                    guard !preview.validNodes.isEmpty else {
                        appState.statusBanner = "未解析到有效节点"
                        return
                    }
                }
                updated.name = displayName.isEmpty ? original.name : displayName
                updated.sourceKind = .shareLinks
                updated.originalURL = "share://links"
                updated.resolvedURL = "share://links"
                updated.autoUpdate = false
                updated.isEnabled = isEnabled
                updated.updateMode = updateMode
                updated.smartMergeMissingLimit = smartMergeMissingLimit
                updated.autoCleanupUnavailableNodes = autoCleanupUnavailableNodes
                updated.unavailableCleanupDays = unavailableCleanupDays
                appState.updateSubscription(updated, refreshAfterSave: false)
                if autoCleanupUnavailableNodes {
                    appState.cleanupUnavailableNodes(subscriptionID: original.id, automatic: true)
                }
                if hasNewLinks {
                    let subscriptionID = original.id
                    Task {
                        await appState.applyShareLinkPaste(subscriptionID: subscriptionID, pastedText: trimmed)
                    }
                }
            } else {
                let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolvedTemplate = urlMode == .dateTemplate
                    ? (template.isEmpty ? detection?.template : template)
                    : nil
                let urlChanged = original.originalURL != trimmedURL
                    || original.urlMode != urlMode
                    || original.urlTemplate != resolvedTemplate
                    || original.dateOffset != dateOffset
                updated.name = displayName.isEmpty ? (URL(string: trimmedURL)?.host ?? original.name) : displayName
                updated.originalURL = trimmedURL
                updated.urlMode = urlMode
                updated.urlTemplate = resolvedTemplate
                if urlChanged {
                    updated.resolvedURL = trimmedURL
                    // Force a full fetch+merge after date/URL edits — stale ETag caused
                    // "成功 / 获取 0" with no merge when switching dated subscription files.
                    updated.lastResolvedURL = nil
                    updated.lastResolvedDate = nil
                    updated.etag = nil
                    updated.lastModified = nil
                    updated.contentHash = nil
                    updated.statusMessage = nil
                    updated.lastError = nil
                }
                updated.isEnabled = isEnabled
                updated.autoUpdate = autoUpdate
                updated.updateInterval = updateInterval
                updated.updateHour = updateHour
                updated.updateMinute = updateMinute
                updated.timeZoneID = timeZoneID
                updated.urlDateTimeZoneID = urlDateTimeZoneID
                updated.dateOffset = dateOffset
                updated.fallbackDays = fallbackDays
                updated.updateMode = updateMode
                updated.testAfterUpdate = testAfterUpdate
                updated.smartMergeMissingLimit = smartMergeMissingLimit
                updated.autoCleanupUnavailableNodes = autoCleanupUnavailableNodes
                updated.unavailableCleanupDays = unavailableCleanupDays
                appState.updateSubscription(updated)
                if refreshAfterSave || urlChanged || fetchYesterdayFirst {
                    let includeYesterday = fetchYesterdayFirst
                    Task { await appState.refreshSubscription(updated.id, fetchYesterdayFirst: includeYesterday) }
                }
                if autoCleanupUnavailableNodes {
                    appState.cleanupUnavailableNodes(subscriptionID: original.id, automatic: true)
                }
            }
        }

        dismiss()
    }

    private var importTypeFootnote: String {
        switch sourceKind {
        case .remoteURL:
            return "订阅地址：填写可下载节点列表的 URL（含日期型订阅）"
        case .shareLinks:
            if isEditingShareLinks {
                return "编辑分享链接订阅：查看请在详情页；此处仅粘贴新增链接并由处理方式决定覆盖或合并。"
            }
            return "支持 VLESS、VMess、Trojan、Shadowsocks、Hysteria2、MASQUE、TUIC、AnyTLS、WireGuard、SOCKS5 和 HTTP/HTTPS 节点链接及 Base64 订阅内容；WireGuard 也可粘贴单 Peer 配置。"
        }
    }

    private func detect(_ value: String) {
        let result = appState.subscriptionManager.detectDateTemplate(for: value)
        detection = result
        if result.detected {
            // Keep template for preview / optional switch, but do NOT auto-switch to dateTemplate
            // on create — that would fetch "today" and overwrite the pasted original URL.
            if template.isEmpty {
                template = result.template
            }
            refreshPreviews()
        } else {
            previewToday = ""
            previewYesterday = ""
            if case .create = mode {
                urlMode = .fixed
            }
        }
    }

    private func refreshPreviews() {
        let templateText = template.isEmpty ? (detection?.template ?? "") : template
        guard !templateText.isEmpty else {
            previewToday = ""
            previewYesterday = ""
            return
        }
        let tz = TimeZone(identifier: urlDateTimeZoneID.isEmpty ? appState.settings.defaultTimeZoneID : urlDateTimeZoneID) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        let tmpl = SubscriptionDateTemplate(template: templateText)
        previewToday = tmpl.resolve(date: Date(), timeZone: tz)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        previewYesterday = tmpl.resolve(date: yesterday, timeZone: tz)
    }

    private func syncTodayURL() {
        refreshPreviews()
        guard !previewToday.isEmpty else { return }
        fetchYesterdayFirst = false
        dateOffset = 0
        url = previewToday
        urlMode = .dateTemplate
        if template.isEmpty, let detected = detection?.template {
            template = detected
        }
    }

    private func syncYesterdayURL() {
        refreshPreviews()
        guard !previewYesterday.isEmpty else { return }
        fetchYesterdayFirst = true
        dateOffset = 0
        url = previewYesterday
        urlMode = .dateTemplate
        if template.isEmpty, let detected = detection?.template {
            template = detected
        }
    }
}

struct ImportLinksView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(targetHint)
                    .font(.subheadline.weight(.medium))
                Text("粘贴已支持的节点分享链接，每行一个；也可粘贴单 Peer WireGuard 配置。")
                    .foregroundStyle(.secondary)
                TextEditor(text: $appState.importText)
                    .font(.system(.body, design: .monospaced))
                    .border(Color.secondary.opacity(0.2))
            }
            .padding()
            .navigationTitle("添加节点")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        appState.importLinksFromText()
                    }
                    .disabled(appState.importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .frame(width: 560, height: 420)
        }
    }

    private var targetHint: String {
        switch appState.currentNodeListSource {
        case .all:
            return "当前筛选为全部订阅，将加入「手动导入」。若要加到某个订阅，请先在节点列表选中该订阅。"
        case .manual:
            return "将加入「手动导入」。"
        case .subscription(let id):
            let name = appState.subscription(for: id)?.name ?? "当前订阅"
            return "将加入订阅「\(name)」。"
        case .namedSource(let name):
            return "将加入「\(name)」。"
        }
    }
}

struct DateTemplatePreviewView: View {
    let detection: DateTemplateDetection
    let timeZoneID: String

    var body: some View {
        let tz = TimeZone(identifier: timeZoneID) ?? .current
        VStack(alignment: .leading, spacing: 6) {
            Text(detection.template).font(.caption.monospaced())
            Text(detection.preview(for: Date(), timeZone: tz)).font(.caption.monospaced())
        }
    }
}
