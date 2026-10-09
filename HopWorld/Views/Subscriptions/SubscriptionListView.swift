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

    private var palette: SubPalette { SubPalette(scheme: colorScheme) }

    private var abnormalCount: Int {
        appState.subscriptions.filter { $0.lastError != nil }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if !appState.isLibraryReady {
                libraryLockedEmptyState
            } else if appState.subscriptions.isEmpty {
                subscriptionsEmptyState
            } else {
                statsStrip

                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(appState.subscriptions) { sub in
                            SubscriptionCard(
                                subscription: sub,
                                palette: palette,
                                onView: { appState.viewingSubscriptionID = sub.id },
                                onEdit: { appState.editingSubscriptionID = sub.id },
                                onDelete: { confirmDelete = sub }
                            )
                            .contextMenu {
                                Button("查看") { appState.viewingSubscriptionID = sub.id }
                                Button("编辑") { appState.editingSubscriptionID = sub.id }
                                if !sub.isShareLinksBundle {
                                    Button("立即更新") {
                                        Task { await appState.refreshSubscription(sub.id) }
                                    }
                                    Button("测试订阅地址") {
                                        Task { await appState.testSubscriptionAddress(sub.id) }
                                    }
                                }
                                Button("测试本组全部节点") {
                                    Task { await appState.testSubscriptionNodes(sub.id) }
                                }
                                Divider()
                                Button("删除", role: .destructive) { confirmDelete = sub }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
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
    }

    private var activeNodeCount: Int {
        appState.nodes.filter { !$0.pendingRemoval }.count
    }

    // MARK: - 码头页眉 + 读数条

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(palette.accent.opacity(0.15))
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(palette.accent)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text("SUPPLY · 补给码头")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(palette.accent)
                Text("订阅")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(palette.text)
            }
            Spacer(minLength: 8)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(context.date, format: .dateTime.hour().minute().second())
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(palette.text)
            }
            Button {
                Task { await appState.refreshAllSubscriptions() }
            } label: {
                Label("全部更新", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(appState.subscriptionManager.updateState != .idle)

            Button {
                appState.showAddSubscription = true
            } label: {
                Label("添加订阅", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(palette.accent)
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var statsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
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
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
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
            Text("也可在 设置 → 数据备份 从 .hopbackup 恢复")
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

struct SubscriptionCard: View {
    @EnvironmentObject private var appState: AppState
    let subscription: Subscription
    var palette: SubPalette
    var onView: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 0) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                    .shadow(color: statusColor.opacity(0.6), radius: 3)
                Rectangle()
                    .fill(palette.line)
                    .frame(width: 1.5)
                    .padding(.vertical, 4)
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(statusColor.opacity(0.12))
                    Image(systemName: subscription.isShareLinksBundle ? "doc.on.clipboard.fill" : "antenna.radiowaves.left.and.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(statusColor)
                }
                .frame(width: 38, height: 38)
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(subscription.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)

                    Text(statusText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(statusColor.opacity(0.11), in: Capsule())
                }

                HStack(spacing: 6) {
                    metadataBadge(subscription.sourceKind.displayName, icon: "link")
                    metadataBadge(subscription.updateMode.displayName, icon: "arrow.triangle.merge")
                    if !subscription.isShareLinksBundle {
                        metadataBadge(updateScheduleText, icon: "clock")
                    }
                    if let retry = subscription.updateRetryStatusLine {
                        metadataBadge(retry, icon: "arrow.clockwise.circle")
                    }
                }

                Text(detailLine)
                    .font(.caption)
                    .foregroundStyle(subscription.lastError == nil ? palette.subtext : Color.red)
                    .lineLimit(1)
                    .help(detailLine)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 3) {
                Text("\(subscription.nodeCount)")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(palette.text)
                Text("节点")
                    .font(.caption2)
                    .foregroundStyle(palette.subtext)
            }
            .frame(minWidth: 44)

            if !subscription.isShareLinksBundle {
                Button {
                    Task { await appState.refreshSubscription(subscription.id) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 28, height: 28)
                        .background(palette.accent.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.accent)
                .help("立即更新")
                .disabled(!subscription.isEnabled)
            }

            Menu {
                Button("查看", action: onView)
                Button("编辑", action: onEdit)
                if !subscription.isShareLinksBundle {
                    Button("测试订阅地址") {
                        Task { await appState.testSubscriptionAddress(subscription.id) }
                    }
                }
                Button("测试本组全部节点") {
                    Task { await appState.testSubscriptionNodes(subscription.id) }
                }
                Divider()
                Button("删除", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 28)
                    .background(palette.text.opacity(0.07), in: Circle())
            }
            .menuStyle(.borderlessButton)
            .help("更多操作")
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.card)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.cardBorder, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture(perform: onView)
        .help(subscription.statusMessage ?? oneLineMeta)
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
        return "\(subscription.updateInterval.displayName) \(String(format: "%02d:%02d", subscription.updateHour, subscription.updateMinute))"
    }

    private var detailLine: String {
        if let retry = subscription.updateRetryStatusLine { return retry }
        if let error = subscription.lastError, !error.isEmpty { return error }
        if let message = subscription.statusMessage, !message.isEmpty { return message }
        if subscription.isShareLinksBundle {
            let linkCount = NodeLinkParser.extractShareLinks(from: subscription.shareLinksText ?? "").count
            if linkCount > 0 {
                return "\(linkCount) 条分享链接 · 编辑可追加或按策略覆盖"
            }
            return "分享链接订阅"
        }
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
            parts.append(
                "\(subscription.updateInterval.displayName) \(String(format: "%02d:%02d", subscription.updateHour, subscription.updateMinute))"
            )
        } else {
            parts.append("自动更新关")
        }
        if let last = subscription.lastSuccessAt {
            parts.append(last.formatted(date: .abbreviated, time: .shortened))
        }
        if let message = subscription.statusMessage, !message.isEmpty {
            parts.append(message)
        }
        return parts.joined(separator: " · ")
    }

    private var statusText: String {
        if !subscription.isEnabled { return "禁用" }
        if subscription.isShareLinksBundle, subscription.nodeCount > 0 { return "已导入" }
        if subscription.isHealthy { return "正常" }
        if subscription.lastError != nil { return "异常" }
        return subscription.isShareLinksBundle ? "待导入" : "待更新"
    }

    private var statusColor: Color {
        if !subscription.isEnabled { return .secondary }
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
                            LabeledContent("节点数量", value: "\(sub.nodeCount)")
                            if subscriptionPendingNodeCount > 0 {
                                LabeledContent("待处理节点", value: "\(subscriptionPendingNodeCount)（待应用/待移除）")
                            }
                        }

                        Section("长期不可用节点清理") {
                            Toggle("自动清理", isOn: Binding(
                                get: { subscription?.autoCleanupUnavailableNodes ?? false },
                                set: { value in
                                    guard var latest = subscription else { return }
                                    latest.autoCleanupUnavailableNodes = value
                                    appState.updateSubscription(latest)
                                }
                            ))
                            Stepper("持续不可用期限：\(min(30, max(1, sub.unavailableCleanupDays ?? 3))) 天", value: Binding(
                                get: { min(30, max(1, subscription?.unavailableCleanupDays ?? 3)) },
                                set: { value in
                                    guard var latest = subscription else { return }
                                    latest.unavailableCleanupDays = min(30, max(1, value))
                                    appState.updateSubscription(latest)
                                }
                            ), in: 1...30)
                            Button("清理当前组长期不可用节点", role: .destructive) {
                                confirmCleanup = true
                            }
                            .disabled(appState.unavailableCleanupCandidates(subscriptionID: subscriptionID).isEmpty)
                            Text("需在期限开始及近期测速中均不可用；恢复可用后重新计时。未测试、配置失败、收藏和当前连接节点均保留。订阅地址保留，更新可能重新导入节点。")
                                .font(.caption).foregroundStyle(.secondary)
                        }

                        if sub.isShareLinksBundle {
                            shareLinksDetailSection(sub)
                        } else {
                            remoteURLDetailSections(sub)
                        }

                        if !sub.isShareLinksBundle {
                            if let report = appState.subscriptionManager.lastTestReport {
                                Section("最近地址测试") {
                                    Text("URL：\(report.resolvedURL)")
                                    Text("HTTP：\(report.httpStatus.map(String.init) ?? "—")")
                                    Text("有效 \(report.validCount) / 重复 \(report.duplicateCount) / 无效 \(report.invalidCount)")
                                    Text("耗时 \(LatencyFormat.seconds(report.durationMS))")
                                }
                                .font(.caption)
                            }
                        }
                    }
                    .formStyle(.grouped)
                } else {
                    ContentUnavailableView("订阅不存在", systemImage: "link")
                }
            }
            .confirmationDialog("清理当前组长期不可用节点？", isPresented: $confirmCleanup, titleVisibility: .visible) {
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
        }
    }

    @ViewBuilder
    private func shareLinksDetailSection(_ sub: Subscription) -> some View {
        let links = NodeLinkParser.extractShareLinks(from: sub.shareLinksText ?? "")
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
            LabeledContent("时间", value: String(format: "%02d:%02d", sub.updateHour, sub.updateMinute))
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
            let logs = appState.logs(for: sub.id)
            if logs.isEmpty {
                Text("暂无记录").foregroundStyle(.secondary)
            } else {
                ForEach(logs) { log in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(log.startedAt.formatted(date: .abbreviated, time: .shortened))
                            Spacer()
                            Text(log.success ? "成功" : "失败")
                                .foregroundStyle(log.success ? .green : .red)
                        }
                        Text(log.requestedURL)
                            .font(.system(.caption2, design: .monospaced))
                            .lineLimit(2)
                        if log.success {
                            Text("获取 \(log.fetchedCount) · 新增 \(log.addedCount) · 更新 \(log.updatedCount) · 移除 \(log.removedCount)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if let err = log.errorMessage {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                    }
                    .padding(.vertical, 2)
                }
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

// MARK: - Editor

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
    @State private var previewTomorrow = ""

    @State private var isEnabled = true
    @State private var autoUpdate = true
    @State private var updateInterval: SubscriptionInterval = .daily
    @State private var updateHour = 8
    @State private var updateMinute = 30
    @State private var timeZoneID = "Asia/Shanghai"
    @State private var urlDateTimeZoneID = "Asia/Shanghai"
    @State private var dateOffset = 0
    @State private var fallbackDays = 3
    @State private var updateMode: SubscriptionUpdateMode = .smartMerge
    @State private var showingUpdateModeHelp = false
    @State private var testAfterUpdate = true
    @State private var smartMergeMissingLimit = 3
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
        case .shareLinks:
            if isEditingShareLinks {
                return true
            }
            return !NodeLinkParser.extractShareLinks(from: shareLinksText).isEmpty
        }
    }

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
                        TextField("订阅 URL", text: $url)
                            .onChange(of: url) { _, newValue in
                                detect(newValue)
                            }
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
                                Button("同步今天") {
                                    syncTodayURL()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(previewToday.isEmpty)

                                Button("同步明天") {
                                    syncTomorrowURL()
                                }
                                .disabled(previewTomorrow.isEmpty)
                            }
                            Text("只有点击同步后，才会把订阅 URL 改成对应日期并启用自动日期地址")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Picker("地址模式", selection: $urlMode) {
                            ForEach(SubscriptionURLMode.allCases, id: \.self) { item in
                                Text(item.displayName).tag(item)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .onChange(of: urlMode) { _, mode in
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
                                .onChange(of: template) { _, _ in
                                    refreshPreviews()
                                }
                            if !previewToday.isEmpty {
                                Text("今天将请求：\(previewToday)")
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .foregroundStyle(.secondary)
                            }
                            if !previewTomorrow.isEmpty {
                                Text("明天将请求：\(previewTomorrow)")
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .foregroundStyle(.secondary)
                            }
                            HStack {
                                Button("同步今天") {
                                    syncTodayURL()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(previewToday.isEmpty)

                                Button("同步明天") {
                                    syncTomorrowURL()
                                }
                                .disabled(previewTomorrow.isEmpty)
                            }
                        }
                    }
                }

                if sourceKind == .remoteURL {
                    Section("自动更新") {
                        Toggle("自动更新", isOn: $autoUpdate)
                        Picker("更新周期", selection: $updateInterval) {
                            ForEach(SubscriptionInterval.allCases, id: \.self) { item in
                                Text(item.displayName).tag(item)
                            }
                        }
                        HStack {
                            Stepper("小时 \(updateHour)", value: $updateHour, in: 0...23)
                            Stepper("分钟 \(updateMinute)", value: $updateMinute, in: 0...59)
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
                        Toggle("更新后测试新节点", isOn: $testAfterUpdate)
                    }
                    if updateMode == .smartMerge {
                        Stepper("连续缺失 \(smartMergeMissingLimit) 次后删除", value: $smartMergeMissingLimit, in: 1...10)
                    }
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
            .frame(width: 580, height: 560)
            .onAppear(perform: load)
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
            autoUpdate = sub.autoUpdate
            updateInterval = sub.updateInterval
            updateHour = sub.updateHour
            updateMinute = sub.updateMinute
            timeZoneID = sub.timeZoneID
            urlDateTimeZoneID = sub.urlDateTimeZoneID
            dateOffset = sub.dateOffset
            fallbackDays = sub.fallbackDays
            updateMode = sub.updateMode
            testAfterUpdate = sub.testAfterUpdate
            smartMergeMissingLimit = sub.smartMergeMissingLimit
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
                appState.updateSubscription(created, refreshAfterSave: true)
            }
        case .edit(let original):
            var updated = original
            if original.isShareLinksBundle {
                let trimmed = shareLinksText.trimmingCharacters(in: .whitespacesAndNewlines)
                let hasNewLinks = !NodeLinkParser.extractShareLinks(from: trimmed).isEmpty
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
                appState.updateSubscription(updated, refreshAfterSave: false)
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
                updated.resolvedURL = trimmedURL
                if urlChanged {
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
                appState.updateSubscription(updated, refreshAfterSave: refreshAfterSave || urlChanged)
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
            return "节点分享链接：粘贴 ss://、vless://、vmess://、trojan://，每行一个"
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
            previewTomorrow = ""
            if case .create = mode {
                urlMode = .fixed
            }
        }
    }

    private func refreshPreviews() {
        let templateText = template.isEmpty ? (detection?.template ?? "") : template
        guard !templateText.isEmpty else {
            previewToday = ""
            previewTomorrow = ""
            return
        }
        let tz = TimeZone(identifier: urlDateTimeZoneID.isEmpty ? appState.settings.defaultTimeZoneID : urlDateTimeZoneID) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        let tmpl = SubscriptionDateTemplate(template: templateText)
        previewToday = tmpl.resolve(date: Date(), timeZone: tz)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        previewTomorrow = tmpl.resolve(date: tomorrow, timeZone: tz)
    }

    private func syncTodayURL() {
        refreshPreviews()
        guard !previewToday.isEmpty else { return }
        url = previewToday
        urlMode = .dateTemplate
        if template.isEmpty, let detected = detection?.template {
            template = detected
        }
    }

    private func syncTomorrowURL() {
        refreshPreviews()
        guard !previewTomorrow.isEmpty else { return }
        url = previewTomorrow
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
                Text("粘贴 VLESS / VMess / Trojan / Shadowsocks 链接，每行一个。可只加一条。")
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
