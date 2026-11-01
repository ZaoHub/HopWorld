import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct NetworkHealthView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        // Do not wrap the whole window in TimelineView: AppState/connection already
        // republish when observations change; a 5s full-tree rebuild made all four tabs stutter.
        NetworkHealthContent(health: appState.health)
    }
}

enum NetworkHealthTab: String, CaseIterable, Identifiable {
    case node = "节点"
    case application = "应用"
    case records = "记录"
    case scoring = "评分"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .node: return "server.rack"
        case .application: return "app.connected.to.app.below.fill"
        case .records: return "clock.arrow.circlepath"
        case .scoring: return "chart.bar.xaxis"
        }
    }
}

private struct NetworkHealthContent: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var connection: ConnectionManager
    @ObservedObject var health: NetworkHealthStore
    private var selection: NetworkHealthTab {
        get { appState.networkHealthTab }
        nonmutating set { appState.networkHealthTab = newValue }
    }
    @State private var recordsPage = 1
    @State private var historyNodeID: UUID?
    @State private var selectedApplication: HealthApplication?
    @State private var recordQuery = AppHealthRecordQuery()
    @State private var recordsSnapshot: (records: [AppHealthRecord], at: Date)?
    @State private var exportMessage: String?
    @State private var exportFailed = false

    private var node: ProxyNode? {
        let id = selection == .records && historyNodeID != nil
            ? historyNodeID : connection.state.currentNodeID ?? appState.viewingHealthNodeID
        return appState.nodes.first { $0.id == id }
    }

    private var historyNodes: [ProxyNode] {
        let ids = Set(health.records.compactMap(\.nodeID))
        if !ids.isEmpty {
            return appState.nodes.filter { ids.contains($0.id) }
        }
        // Legacy records without nodeID: hash only when the picker has nothing else to show.
        let keys = Set(health.records.map(\.nodeKey))
        return appState.nodes.filter { keys.contains(appState.healthNodeKey($0)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 6) {
                ForEach(Array(NetworkHealthTab.allCases.enumerated()), id: \.element.id) { index, tab in
                    Button {
                        selection = tab
                    } label: {
                        Label(tab.rawValue, systemImage: tab.symbol)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .foregroundStyle(selection == tab ? Color.accentColor : Color.primary)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(selection == tab ? Color.accentColor : Color.clear, lineWidth: 1.5)
                            .allowsHitTesting(false)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .accessibilityAddTraits(selection == tab ? .isSelected : [])
                    .help("\(tab.rawValue)（⌘\(index + 1)）")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    tabContent
                }
                .frame(maxWidth: 1040, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .id(selection == .records ? "\(recordsScope)-\(recordsPage)" : "\(selection.rawValue)-\(node?.id.uuidString ?? "none")")
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: appState.viewingHealthNodeID) { _ in
            selection = .application
            historyNodeID = nil
            recordsPage = 1
            recordsSnapshot = nil
        }
        .onChange(of: connection.state.currentNodeID) { _ in resetConnectionDisplay() }
        .onChange(of: connection.state.connectedAt) { _ in resetConnectionDisplay() }
        .onChange(of: recordsScope) { _ in recordsPage = 1; recordsSnapshot = nil; exportMessage = nil }
        .onChange(of: recordQuery) { _ in recordsPage = 1; recordsSnapshot = nil; exportMessage = nil }
        .onChange(of: health.records.count) { _ in
            guard selection == .records else { return }
            recordsPage = currentRecordPage.number
        }
        .onChange(of: recordsPage) { page in
            if page == 1 {
                recordsSnapshot = nil
            } else if recordsSnapshot == nil {
                recordsSnapshot = (health.records, observationDate)
            }
        }
        .onChange(of: selection) { tab in
            if tab != .records { recordsPage = 1; recordsSnapshot = nil }
        }
    }

    private func resetConnectionDisplay() {
        recordsPage = 1
        recordsSnapshot = nil
        exportMessage = nil
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("网络健康中心").font(.title2.weight(.semibold))
                Text(node.map { appState.settings.nodeDisplayTitle($0) } ?? "尚未选择节点")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(node.map { appState.settings.nodeDisplayTitle($0) } ?? "尚未选择节点")
                    .textSelection(.enabled)
                if let summary = node.flatMap(headerExitSummary(for:)) {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(summary)
                        .textSelection(.enabled)
                }
                if selection == .records, historyNodeID != nil {
                    Text("历史节点记录").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 16)
            Label("当前代理 · " + connection.state.status.displayName,
                  systemImage: connection.state.status == .connected ? "checkmark.circle" : "circle.dashed")
                .foregroundStyle(connection.state.status == .connected ? Color.green : Color.secondary)
                .font(.callout)
                .fixedSize()
        }
        .padding(20)
    }

    private func headerExitSummary(for node: ProxyNode) -> String? {
        let exit = NetworkHealthExitInfo.resolve(node: node, connection: connection.state,
                                                 showChinese: appState.settings.showChineseNodeMetadata,
                                                 catalog: ChineseCityCatalog.shared)
        guard exit.isCurrentConnection || exit.ip != nil || exit.country != nil || exit.city != "未知" else { return nil }
        if exit.awaitingLive {
            return connection.state.lastError?.contains("出口") == true
                ? connection.state.lastError : "已连接，正在获取出口信息"
        }
        var parts: [String] = []
        if let ip = exit.ip { parts.append(ip) }
        if let country = exit.country, country != "未知" { parts.append(country) }
        if exit.city != "未知" { parts.append(exit.city) }
        if let type = exit.networkType { parts.append(type.displayName) }
        guard !parts.isEmpty else { return nil }
        return (exit.isCurrentConnection ? "当前出口 · " : "最近出口 · ") + parts.joined(separator: " · ")
    }

    private var observationDate: Date { Date() }

    private func currentConnectionEvent(_ date: Date?) -> Date? {
        guard node?.id == connection.state.currentNodeID, connection.state.status == .connected,
              let start = connection.state.connectedAt, let date, date >= start else { return nil }
        return date
    }

    private var snapshot: AppHealthSnapshot? {
        guard let node else { return nil }
        let sessionStart = node.id == connection.state.currentNodeID && connection.state.status == .connected
            ? connection.state.connectedAt : nil
        return health.snapshot(nodeKey: appState.healthNodeKey(node), context: appState.healthContext(for: node),
                               now: observationDate, diagnosticSince: sessionStart)
    }

    private var nodeRecords: [AppHealthRecord] {
        guard let node else { return [] }
        let key = appState.healthNodeKey(node)
        let context = appState.healthContext(for: node)
        return Array(recordQuery.apply(to: recordsSnapshot?.records ?? health.records, nodeKey: key,
                                       context: context, now: recordsSnapshot?.at ?? observationDate, nodeID: node.id)
            .prefix(NetworkHealthStore.applicationCheckLimit))
    }

    private func checkRecords(_ application: HealthApplication, node: ProxyNode) -> [ApplicationCheckRecord] {
        let key = appState.healthNodeKey(node)
        return Array(health.checks.filter { $0.application == application && $0.belongsToNode(nodeKey: key, nodeID: node.id) }
            .reversed().prefix(NetworkHealthStore.applicationCheckLimit))
    }

    private var recordsScope: String {
        guard let node else { return "" }
        return node.id.uuidString + (recordQuery.currentEnvironmentOnly ? appState.healthNodeKey(node) + appState.healthContext(for: node) : "")
    }

    private var currentRecordPage: AppHealthEventPage {
        AppHealthEventPage(records: nodeRecords, number: recordsPage)
    }

    @ViewBuilder private var tabContent: some View {
        if let error = health.persistenceError {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
        switch selection {
        case .node: nodeContent
        case .application: applicationContent
        case .records: recordsContent
        case .scoring: scoringContent
        }
    }

    private var healthApplications: [HealthApplication] { appState.settings.healthApplications }

    private var currentApplication: HealthApplication? {
        selectedApplication.flatMap { healthApplications.contains($0) ? $0 : nil } ?? healthApplications.first
    }

    @ViewBuilder private func applicationPicker(_ application: HealthApplication) -> some View {
        if healthApplications.count > 1 {
            Picker("应用", selection: Binding(get: { application }, set: { selectedApplication = $0 })) {
                ForEach(healthApplications) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var noHealthApplication: some View {
        unavailable("应用连通未包含可诊断的应用", symbol: "app.dashed",
                    detail: "在测试中心「应用连通」中启用 ChatGPT（Codex）、Claude 或 Cursor 目标后，这里会显示对应应用的状态与记录。")
    }

    @ViewBuilder private var applicationContent: some View {
        if let snapshot, let node {
            if let application = currentApplication {
                applicationPicker(application)
                if application == .codex {
                    codexApplicationContent(snapshot)
                } else {
                    claudeModelApplicationContent(application, node: node)
                }
            } else {
                noHealthApplication
            }
        } else {
            unavailable("尚未选择节点", symbol: "server.rack", detail: "连接节点后，点击主窗口顶部的节点评分数值查看应用状态和历史证据。")
        }
    }

    @ViewBuilder private func claudeModelApplicationContent(_ application: HealthApplication, node: ProxyNode) -> some View {
        let name = application.displayName
        let isCurrent = node.id == connection.state.currentNodeID
        let isConnected = isCurrent && connection.state.status == .connected
        let observation = isConnected ? appState.claudeModelObservations[application] : nil
        let detail = isConnected ? appState.claudeModelDetails[application] : nil
        let running = appState.isApplicationRunning(application)
        let latest = health.checks.last { $0.application == application && $0.belongsToNode(nodeKey: appState.healthNodeKey(node), nodeID: node.id) }
        healthCard("\(name) 应用状态", symbol: "app.connected.to.app.below.fill") {
            if isCurrent && !isConnected {
                Label("代理" + connection.state.status.displayName, systemImage: "network")
                    .font(.title3.weight(.semibold))
            } else if let available = observation?.reachable {
                Label(available ? "Claude 模型可正常加载" : "Claude 模型无法加载",
                      systemImage: available ? "checkmark.circle.fill" : "exclamationmark.triangle")
                    .font(.title3.weight(.semibold)).foregroundStyle(available ? Color.green : Color.orange)
            } else if isConnected {
                Label("正在检查 Claude 模型加载", systemImage: "waveform.path")
                    .font(.title3.weight(.semibold)).foregroundStyle(.secondary)
            } else if let latest {
                Label(latest.available ? "上次可加载 Claude 模型" : "上次无法加载 Claude 模型", systemImage: "clock")
                    .font(.title3.weight(.semibold)).foregroundStyle(latest.available ? Color.green : Color.orange)
            } else {
                Label("尚无该节点的检查记录", systemImage: "clock")
                    .font(.title3.weight(.semibold)).foregroundStyle(.secondary)
            }
            if let detail {
                Text(detail).font(.callout).foregroundStyle(observation?.reachable == false ? Color.orange : Color.secondary)
            }
            if let observation, observation.reachable == false, let since = observation.failureSince {
                Text("已持续 \(max(0, Int(observation.lastCheckedAt.map { $0.timeIntervalSince(since) } ?? 0))) 秒；会先延长等待并复验，持续无法恢复时再按设置切换备用节点。")
                    .font(.callout).foregroundStyle(.orange)
            }
            LabeledContent("应用进程", value: running ? "运行中" : "未运行")
            if isCurrent {
                LabeledContent("最近检查", value: observation?.lastCheckedAt.map {
                    $0.formatted(date: .abbreviated, time: .standard)
                } ?? (isConnected ? "等待检查" : "连接后检查"))
                LabeledContent("自动恢复", value: appState.applicationSwitchStatus(for: application))
                    .font(.callout)
            } else {
                Label("此节点当前未连接，以上为该节点最近一次检查记录。", systemImage: "clock")
                    .font(.callout).foregroundStyle(.secondary)
            }
            DisclosureGroup("判定依据与流量接管") {
                VStack(alignment: .leading, spacing: 10) {
                    let capture = appState.applicationHealthCaptureSummary(for: node, application: application)
                    Label(capture.ready ? "TUN 接管已就绪" : "节点归属尚未就绪",
                          systemImage: capture.ready ? "checkmark.shield" : "exclamationmark.shield")
                    Text(capture.detail)
                    Text(application == .cursor
                         ? "只有正常加载出 Claude 模型才算可用：本次连接后 Cursor 刷新过模型列表时以列表中是否含 Claude 模型为准；否则经当前代理每 10 秒检查 Anthropic 是否允许当前出口地区。"
                         : "只有正常加载出 Claude 模型才算可用：连接期间经当前代理每 10 秒检查 Anthropic 是否允许当前出口地区，被拒绝（HTTP 403）或无法连接都算失败。")
                    Text("\(name) 正在运行、流量经 TUN 接管且开启智能应用优选与自动故障切换时，会先延长等待并复验，持续无法恢复时才切换备用节点。")
                }
                .font(.callout).foregroundStyle(.secondary).padding(.top, 8)
            }
        }
    }

    @ViewBuilder private func codexApplicationContent(_ snapshot: AppHealthSnapshot) -> some View {
        let diagnostic = snapshot.diagnostic
        let isCurrent = node?.id == connection.state.currentNodeID
        let isConnected = isCurrent && connection.state.status == .connected
        let runtime = appState.codexApplicationObservation
        let invite = appState.codexInviteObservation
        let inviteCheckedAt = connection.applicationHealthSettings?.routingMode == .direct ? nil : currentConnectionEvent(invite.lastCheckedAt)
        let now = observationDate
        let inviteResult = inviteCheckedAt.map { (0...20).contains(now.timeIntervalSince($0)) } == true ? invite.result : nil
        // Codex logs only failures and keeps the menu grey until it reloads, so its own failure
        // stays valid across reconnects (cleared on Codex relaunch); probe failures are per connection.
        let inviteMenuLoadFailure = isConnected ? runtime.inviteEligibilityFailure.flatMap { failure in
            failure.observationID != CodexInviteCheckResult.probeObservationID
                || currentConnectionEvent(failure.date) != nil ? failure : nil
        } : nil
        let statusOneVerdict = CodexStatusOne.verdict(
            probe: inviteResult, probeCheckedAt: inviteCheckedAt, menuLoadFailure: inviteMenuLoadFailure,
            isChecking: isCurrent && appState.codexInviteCheckInProgress)
        let interface = appState.codexInterfaceObservation
        let interfaceFailure = isCurrent ? interface.pendingFailure(now: now) : nil
        let pending = isCurrent ? [runtime.pendingRecoveryFailure, interfaceFailure].compactMap { $0 }.max { $0.date < $1.date } : nil
        let pendingSettings = isCurrent ? (interfaceFailure?.workspaceFeature == .settings ? interfaceFailure : runtime.pendingSettingsFailure) : nil
        let runtimeResponse = currentConnectionEvent(runtime.lastResponseAt)
        let responseAt = [diagnostic.lastResponseAt, runtimeResponse].compactMap { $0 }.max()
        let transportConfirmedAt = [runtime.lastTransportReadyAt, runtime.lastResponseAt]
            .compactMap { currentConnectionEvent($0) }.max()
        let statusVerdicts = codexVisibleStatusVerdicts(
            isConnected: isConnected, isCurrent: isCurrent, diagnostic: diagnostic,
            statusOne: statusOneVerdict,
            interfaceKinds: interfaceFailure != nil ? interface.activeKinds : [],
            pendingSettings: pendingSettings,
            pendingRecovery: isCurrent ? runtime.pendingRecoveryFailure : nil,
            interfaceSnapshot: appState.codexInterfaceSnapshot,
            transportConfirmed: transportConfirmedAt != nil && runtime.pendingNetworkFailure == nil)
        let abnormalStatuses = CodexVisibleStatus.allCases.filter { statusVerdicts[$0] == .abnormal }
        healthCard("Codex 应用状态", symbol: "app.connected.to.app.below.fill") {
            if isCurrent && !isConnected {
                Label("代理" + connection.state.status.displayName, systemImage: "network")
                    .font(.title3.weight(.semibold))
            } else if isConnected, connection.applicationHealthSettings?.routingMode == .direct {
                Label("直连模式 · 未使用当前节点", systemImage: "network")
                    .font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                Text("切换为代理路由模式后，将通过当前节点自动检查应用状态。")
                    .font(.callout).foregroundStyle(.secondary)
            } else if isConnected, let status = abnormalStatuses.first {
                Label(status.title(verdict: .abnormal), systemImage: status == .reconnecting ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle")
                    .font(.title3.weight(.semibold)).foregroundStyle(.orange)
            } else if isConnected, statusOneVerdict != .unchecked {
                Label(CodexVisibleStatus.inviteCheck.title(verdict: statusOneVerdict),
                      systemImage: statusIcon(statusOneVerdict))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(statusColor(statusOneVerdict))
            } else if isConnected {
                Label(CodexVisibleStatus.inviteCheck.title(verdict: .unchecked), systemImage: statusIcon(.unchecked))
                    .font(.title3.weight(.semibold)).foregroundStyle(statusColor(.unchecked))
            } else {
                Label(diagnostic.state.displayName, systemImage: diagnosticSymbol(diagnostic.state))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(diagnosticColor(diagnostic.state))
            }
            if isConnected, connection.applicationHealthSettings?.routingMode != .direct {
                if currentConnectionEvent(runtime.lastCodexInviteLoadAt) == nil {
                    Label(statusOneVerdict == .normal
                          ? "Codex 尚未经当前节点重新检查状态 1；目前依据探测成功判为正常，Codex 实际检查后以其结果为准。"
                          : "Codex 尚未经当前节点重新检查状态 1；Codex 实际检查后以其结果为准。",
                          systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                } else if let loadedAt = runtime.lastCodexInviteLoadAt {
                    Label("Codex 已于 \(loadedAt.formatted(date: .omitted, time: .standard)) 经当前节点检查：状态 1 "
                          + (inviteMenuLoadFailure == nil ? "正常。" : "异常。"),
                          systemImage: inviteMenuLoadFailure == nil ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(inviteMenuLoadFailure == nil ? Color.secondary : Color.orange)
                }
            }
            if isConnected, let checkedAt = inviteCheckedAt {
                LabeledContent("最近状态 1 检查", value: checkedAt.formatted(date: .abbreviated, time: .standard))
            }
            LabeledContent(isConnected ? "最近对话响应（有对话时记录）" : "历史最近收到响应", value: responseAt.map {
                $0.formatted(date: .abbreviated, time: .standard)
            } ?? (isConnected ? "暂无对话响应记录" : "当前环境暂无对话响应记录"))
            if let failure = [diagnostic.lastNetworkFailureAt, pending?.date].compactMap({ $0 }).max() {
                LabeledContent("最近网络异常", value: failure.formatted(date: .abbreviated, time: .standard))
            }
            if isCurrent {
                LabeledContent("自动恢复", value: appState.applicationHealthSwitchStatus)
                    .font(.callout)
            } else {
                Label("此节点当前未连接，以下为该节点当前环境的历史日志状态。", systemImage: "clock")
                    .font(.callout).foregroundStyle(.secondary)
            }
            DisclosureGroup("采集状态与节点归属") {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("监听范围", value: "本机 Codex 日志与会话回复元数据（全部连接）")
                    Text("全局监听：" + appState.codexHealthMonitorStatus)
                    LabeledContent("界面状态检测", value: appState.codexInterfaceMonitorStatus)
                    if appState.codexInterfacePermissionRequired {
                        Text("允许跃界使用“辅助功能”后，可识别状态 2 至 4 的界面提示（出现为异常，完整读取界面确认未出现为正常）；状态 1 只看经当前节点的探测结果，以及 Codex 自身对应请求是否失败。未授权时仍读取明确重连与工作区日志，不把未知状态当故障。")
                        Button("打开辅助功能设置") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                    if let checked = appState.codexHealthLastCheckedAt {
                        LabeledContent("最近检查", value: checked.formatted(date: .abbreviated, time: .standard))
                    }
                    LabeledContent(isConnected ? "本次连接事件 · 最近 15 分钟" : "此节点事件 · 最近 15 分钟",
                                   value: "\(snapshot.diagnosticEventCount) 条")
                    if isCurrent, let updated = runtime.lastUpdatedAt {
                        LabeledContent("应用持续状态更新", value: updated.formatted(date: .abbreviated, time: .standard))
                    }
                    if isCurrent {
                        LabeledContent("状态 1 检查",
                                       value: CodexVisibleStatus.inviteCheck.title(verdict: statusOneVerdict))
                        if let summary = inviteResult?.userFacingSummary {
                            Text(summary)
                        } else if let failure = inviteMenuLoadFailure {
                            Text("Codex \(failure.date.formatted(date: .omitted, time: .standard)) 检查状态 1 异常，之后尚无重新检查成功的记录。")
                        } else if statusOneVerdict == .checking {
                            Text("正在经当前节点检查状态 1。")
                        } else if statusOneVerdict == .unchecked {
                            Text("尚未完成经当前节点的状态 1 检查。")
                        }
                        LabeledContent("连续网络失败", value: "\(invite.network.consecutiveFailures) 次")
                        Text("状态 1：未检测 / 检测中 / 正常 / 异常。只看经当前节点的探测结果；通过为正常，失败或 Codex 自身对应请求失败为异常。状态 2 至 4：出现对应界面提示（如无法加载工作空间设置、正在重新连接、等待网络）为异常；完整读取 Codex 界面确认未出现，或状态 3、4 在本次连接有连接就绪 / 回复记录且之后无故障，才为正常；界面读取中为检测中；读不到界面又无记录为未检测。")
                    }
                    if let node {
                        let capture = appState.applicationHealthCaptureSummary(for: node)
                        Label(capture.ready ? "TUN 接管已就绪" : "节点归属尚未就绪",
                              systemImage: capture.ready ? "checkmark.shield" : "exclamationmark.shield")
                        Text(capture.detail)
                    }
                    Text("全局监听的新事件数量包含全部连接；本次连接只统计连接就绪后、属于本页节点与环境的事件。跨节点保留的未恢复状态只用于应用诊断与恢复判断，不归入新节点的历史评分。")
                }
                .font(.callout).foregroundStyle(.secondary).padding(.top, 8)
            }
        }
        healthCard("状态方案", symbol: "list.number") {
            HStack(spacing: 12) {
                ForEach(CodexVisibleStatus.allCases) { status in
                    let verdict = statusVerdicts[status] ?? .unchecked
                    Label(status.title(verdict: verdict), systemImage: statusIcon(verdict))
                        .foregroundStyle(statusColor(verdict))
                        .font(.callout.weight(.medium))
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(status.title(verdict: verdict))
                }
            }
        }
        diagnosticSummary(snapshot)
    }

    private func statusIcon(_ verdict: CodexVisibleStatus.Verdict) -> String {
        switch verdict {
        case .unchecked: return "questionmark.circle"
        case .checking: return "arrow.triangle.2.circlepath"
        case .normal: return "checkmark.circle.fill"
        case .abnormal: return "exclamationmark.triangle.fill"
        }
    }

    private func statusColor(_ verdict: CodexVisibleStatus.Verdict) -> Color {
        switch verdict {
        case .unchecked: return .secondary
        case .checking: return .secondary
        case .normal: return .green
        case .abnormal: return .orange
        }
    }

    private func codexVisibleStatusVerdicts(
        isConnected: Bool, isCurrent: Bool, diagnostic: AppDiagnosticSnapshot,
        statusOne: CodexVisibleStatus.Verdict, interfaceKinds: [CodexHealthEvent.Kind],
        pendingSettings: CodexHealthEvent?, pendingRecovery: CodexHealthEvent?,
        interfaceSnapshot: CodexInterfaceHealthSnapshot, transportConfirmed: Bool
    ) -> [CodexVisibleStatus: CodexVisibleStatus.Verdict] {
        // 正常 needs positive evidence: a complete UI scan confirming the prompt is absent
        // (`false`), or for 3/4 a transport-ready / response log in this connection with no
        // later failure. A readable but incomplete scan is 检测中; otherwise 未检测.
        func verdict(abnormal: Bool, confirmedAbsent: Bool?, logConfirmed: Bool = false) -> CodexVisibleStatus.Verdict {
            if abnormal { return .abnormal }
            if confirmedAbsent == false || logConfirmed { return .normal }
            return interfaceSnapshot.readable ? .checking : .unchecked
        }
        if isConnected && isCurrent {
            return [
                .inviteCheck: statusOne,
                .workspaceSettings: verdict(
                    abnormal: pendingSettings != nil || interfaceKinds.contains(.workspaceFailure),
                    confirmedAbsent: interfaceSnapshot.workspaceUnavailable),
                .reconnecting: verdict(
                    abnormal: pendingRecovery?.kind == .reconnecting || interfaceKinds.contains(.reconnecting),
                    confirmedAbsent: interfaceSnapshot.reconnecting, logConfirmed: transportConfirmed),
                .waitingForNetwork: verdict(
                    abnormal: pendingRecovery?.kind == .waitingForNetwork || interfaceKinds.contains(.waitingForNetwork),
                    confirmedAbsent: interfaceSnapshot.waitingForNetwork, logConfirmed: transportConfirmed)
            ]
        }
        return [
            .inviteCheck: .unchecked,
            .workspaceSettings: diagnostic.state == .workspaceIssue ? .abnormal : .unchecked,
            .reconnecting: diagnostic.state == .reconnecting ? .abnormal : .unchecked,
            .waitingForNetwork: diagnostic.state == .waitingForNetwork ? .abnormal : .unchecked
        ]
    }

    private func diagnosticSymbol(_ state: AppDiagnosticState) -> String {
        switch state {
        case .responding: return "arrow.down.circle.fill"
        case .reconnecting: return "arrow.triangle.2.circlepath"
        case .waitingForNetwork: return "wifi.slash"
        case .networkFailure: return "exclamationmark.triangle"
        case .transportReady: return "network"
        case .serviceIssue, .workspaceIssue: return "exclamationmark.triangle"
        case .workspaceRecovered: return "folder.badge.checkmark"
        case .idle: return "clock"
        }
    }

    private func diagnosticColor(_ state: AppDiagnosticState) -> Color {
        switch state {
        case .responding, .workspaceRecovered: return .green
        case .networkFailure: return .red
        case .reconnecting, .waitingForNetwork, .serviceIssue, .workspaceIssue: return .orange
        case .transportReady: return .accentColor
        case .idle: return .secondary
        }
    }

    @ViewBuilder private var recordsContent: some View {
        if let node {
            if let application = currentApplication {
                applicationPicker(application)
                if application == .codex {
                    codexRecordsContent(node)
                } else {
                    checkRecordsContent(application, node: node)
                }
            } else {
                noHealthApplication
            }
        } else {
            unavailable("尚未选择节点", symbol: "clock.arrow.circlepath", detail: "点击主窗口顶部的节点评分数值打开健康中心，查看节点的应用事件。")
        }
    }

    private var historyNodePicker: some View {
        Picker("节点", selection: $historyNodeID) {
            Text("跟随当前连接").tag(UUID?.none)
            ForEach(historyNodes) { historical in
                Text(appState.settings.nodeDisplayTitle(historical)).tag(Optional(historical.id))
            }
        }
        .pickerStyle(.menu)
    }

    private func checkRecordsContent(_ application: HealthApplication, node: ProxyNode) -> some View {
        let records = checkRecords(application, node: node)
        return healthCard("\(application.displayName) 应用事件 · 最近 \(NetworkHealthStore.applicationCheckLimit) 条", symbol: "clock.arrow.circlepath") {
            historyNodePicker
            if records.isEmpty {
                Text("尚无该节点的 Claude 模型检查记录；连接后会记录可用状态的变化与自动切换。")
                    .foregroundStyle(.secondary).padding(.vertical, 20)
            }
            ForEach(records) { record in
                HStack(alignment: .top, spacing: 14) {
                    Text(record.date, format: .dateTime.month().day().hour().minute().second())
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 112, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        Label(record.title, systemImage: record.available ? "checkmark.circle.fill" : "exclamationmark.triangle")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(record.available ? Color.green : Color.orange)
                        Text(record.detail).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 5)
                .contextMenu {
                    Button("复制事件摘要", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(record.date.formatted(date: .abbreviated, time: .standard)
                            + "\n" + record.title + "\n" + record.detail, forType: .string)
                    }
                }
                if record.id != records.last?.id { Divider() }
            }
        }
    }

    @ViewBuilder private func codexRecordsContent(_ node: ProxyNode) -> some View {
        let page = currentRecordPage
        let context = appState.healthContext(for: node)
        let savedCount = health.records.filter { $0.belongsToNode(nodeKey: appState.healthNodeKey(node), nodeID: node.id) }.count
        healthCard("Codex 应用事件 · 最近 \(NetworkHealthStore.applicationCheckLimit) 条", symbol: "clock.arrow.circlepath") {
            historyNodePicker
            HStack(spacing: 12) {
                Picker("时间", selection: $recordQuery.period) {
                    ForEach(AppHealthRecordQuery.Period.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("类型", selection: $recordQuery.category) {
                    ForEach(AppHealthRecordQuery.Category.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("环境", selection: $recordQuery.currentEnvironmentOnly) {
                    Text("当前环境").tag(true)
                    Text("全部历史环境").tag(false)
                }
            }
            HStack {
                Text("显示 \(page.totalCount) 条 / 保留最近 \(NetworkHealthStore.applicationCheckLimit) 条（已保存 \(savedCount) 条）")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("重置筛选") { recordQuery = AppHealthRecordQuery() }
                    .disabled(recordQuery == AppHealthRecordQuery())
                Button("导出筛选结果", systemImage: "square.and.arrow.up") { exportRecords() }
                    .disabled(page.totalCount == 0)
            }
            .controlSize(.small)
            if recordQuery.period != .all || recordQuery.currentEnvironmentOnly {
                Text("筛选仅作用于此节点保留的最近 10 条记录；更早记录会自动清理。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let exportMessage {
                Label(exportMessage, systemImage: exportFailed ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.callout).foregroundStyle(exportFailed ? Color.orange : Color.secondary)
            }
            if page.records.isEmpty {
                Text("最近 10 条中没有符合筛选条件的记录，可重置筛选查看。")
                    .foregroundStyle(.secondary).padding(.vertical, 20)
            }
            ForEach(page.records) { record in
                HStack(alignment: .top, spacing: 14) {
                    Text(record.date, format: .dateTime.month().day().hour().minute().second())
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 112, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(record.event.title).font(.callout.weight(.medium))
                            Spacer()
                            Text(record.event.category).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(record.event.provenanceDescription + (record.context == context ? "" : " · 其他历史环境"))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(record.event.detail).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 5)
                .contextMenu {
                    Button("复制事件摘要", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(record.date.formatted(date: .abbreviated, time: .standard)
                            + "\n" + record.event.title + "\n" + record.event.provenanceDescription
                            + "\n" + record.event.detail, forType: .string)
                    }
                }
                if record.id != page.records.last?.id { Divider() }
            }
        }
    }

    private func exportRecords() {
        guard let node else { return }
        let records = nodeRecords
        let context = appState.healthContext(for: node)
        let panel = NSSavePanel()
        panel.title = "导出应用诊断"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "HopWorld-health-\(Int(Date().timeIntervalSince1970)).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try AppHealthRecordQuery.export(records, currentContext: context, generatedAt: Date()).write(to: url, options: .atomic)
            exportFailed = false
            exportMessage = "已导出 \(records.count) 条分类事件，不包含原始日志、节点地址或请求标识。"
        } catch {
            exportFailed = true
            exportMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    @ViewBuilder private var scoringContent: some View {
        if let node, let snapshot {
            let quality = connection.nodeQuality[node.id] ?? AIConnectionQuality()
            let fresh = quality.freshObservations(settings: appState.settings, now: observationDate)
            let score = quality.score(for: .codex, settings: appState.settings, now: observationDate)
            let components = quality.scoringComponents(for: .codex, settings: appState.settings, now: observationDate)
            healthCard("实测链路评分", symbol: "chart.bar.xaxis") {
                if let score {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(score.points)").font(.system(size: 42, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("/ 100 · 已测维度覆盖 \(score.coverage)%").foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(score.points), total: 100)
                    Text("仅累加已测项目，尚有 \(100 - score.coverage) 分的项目未覆盖。缺项不补零分或满分，部分覆盖的分数不放大为百分制满分。")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Label("尚未完成链路采样", systemImage: "waveform.path")
                        .font(.title3.weight(.medium))
                    Text("连接后会自动快速采集 HTTPS，先显示基础分，再补齐约 10 秒的 WebSocket 快检与 UDP 结果。无需等待 6 分钟。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                LabeledContent("有效 HTTPS 样本", value: "\(fresh.samples.count) 条 / 基础项至少 10 条")
                if let date = quality.lastSampleAt {
                    LabeledContent("最近采样", value: date.formatted(date: .abbreviated, time: .standard))
                }
                referenceSamplingControls(for: node)
                if !connection.canTestQuality(nodeID: node.id) {
                    Text("连接此节点后可重新采样；历史应用事件仍可在记录页查看。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            healthCard("各项得分", symbol: "list.bullet.rectangle") {
                let observingLong = connection.qualityTestNodeID == node.id && connection.qualityTestIsDeep
                ForEach(components) { component in
                    let note = component.id == "stream" && component.weight < 35
                        ? (observingLong ? " · 6 分钟观察中，通过后按 35 分计" : " · 长时观察通过后按 35 分计") : ""
                    LabeledContent(component.title, value: (component.points.map {
                        "\($0) / \(component.weight) 分"
                    } ?? "未观测 · 权重 \(component.weight) 分") + note)
                    if component.id != components.last?.id { Divider() }
                }
                Text("HTTPS 相关项目需至少 10 条有效样本，连接后自动采集。快速检查先计入短时证据，随后自动进行 6 分钟长时观测；有效期为 \(max(1, appState.settings.testResultTTLMinutes)) 分钟。各项按整数展示，总分按原始值合计后取整。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("查看测量详情与专项测试") { selection = .node }
            }
            healthCard("完整应用请求验证", symbol: "checkmark.shield") {
                DisclosureGroup(snapshot.score == nil ? "尚无足量完整请求证据，查看采样情况" : "已取得完整请求证据，查看结果") {
                    VStack(alignment: .leading, spacing: 12) {
                        if let score = snapshot.score {
                            LabeledContent("完整请求证据评分", value: "\(score) / \(snapshot.scoreCoverage)")
                        } else if let reason = snapshot.scoreUnavailableReason {
                            Text(reason).font(.callout).foregroundStyle(.secondary)
                        }
                        evidenceRequirement("可核实的独立请求", value: "\(snapshot.verifiedRequestCount) / 至少 5 个",
                                            met: snapshot.verifiedRequestCount >= 5)
                        evidenceRequirement("请求结果时间跨度", value: "\(Int(snapshot.verifiedRequestSpan)) / 至少 20 秒",
                                            met: snapshot.verifiedRequestSpan >= 20)
                        evidenceRequirement("有效连续观测时段", value: snapshot.observedSeconds > 0 ? String(format: "%.1f 秒", snapshot.observedSeconds) : "尚未取得",
                                            met: snapshot.observedSeconds > 0)
                        Divider()
                        LabeledContent("观测时段可用占比", value: percentage(snapshot.observedAvailability))
                        LabeledContent("可核实请求成功占比", value: percentage(snapshot.successRate))
                        LabeledContent("事件稳定性", value: percentage(snapshot.stabilityRatio))
                        Text("上方实测链路分反映参考探测；这里仅使用可归属当前节点的完整请求证据。应用响应片段不计作完整请求成功，自动恢复也无需等待这项评分。")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("查看有效请求事件") {
                            recordQuery = AppHealthRecordQuery(period: .quarterHour, category: .verifiedRequests, currentEnvironmentOnly: true)
                            selection = .records
                            recordsPage = 1
                        }
                    }
                    .padding(.top, 10)
                }
            }
        } else {
            unavailable("尚未选择节点", symbol: "chart.bar.xaxis", detail: "连接节点后，点击主窗口顶部的节点评分数值查看实测链路评分。")
        }
    }

    private func referenceSamplingControls(for node: ProxyNode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if connection.referenceTestNodeID == node.id, connection.referenceTestRunning {
                ProgressView(value: Double(connection.referenceTestCompleted), total: 10) {
                    Text(connection.referenceTestMessage).font(.callout)
                }
                Button("停止检测") { connection.cancelReferenceTest() }
            } else {
                Button("刷新基础评分") { connection.startReferenceTest(nodeID: node.id) }
                    .disabled(!connection.canTestReference(nodeID: node.id))
                if connection.referenceTestNodeID == node.id {
                    Text(connection.referenceTestMessage).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func evidenceRequirement(_ title: String, value: String, met: Bool) -> some View {
        HStack {
            Label(title, systemImage: met ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(met ? Color.green : Color.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
        .accessibilityValue(met ? "已满足" : "未满足")
    }

    private func diagnosticSummary(_ snapshot: AppHealthSnapshot) -> some View {
        let isCurrent = connection.state.status == .connected && node?.id == connection.state.currentNodeID
        return healthCard(isCurrent ? "本次连接诊断 · 最近 15 分钟" : "已采集的应用诊断 · 最近 15 分钟", symbol: "waveform.path.ecg") {
            LabeledContent("已识别日志事件", value: "\(snapshot.diagnosticEventCount) 条")
            LabeledContent("可归属当前节点的事件", value: "\(snapshot.attributedEventCount) 条")
            LabeledContent("日志中的重连", value: "\(snapshot.diagnosticReconnectCount) 次")
            LabeledContent("日志中的连接或请求失败", value: "\(snapshot.diagnosticFailureCount) 次")
            LabeledContent("收到的响应片段", value: "\(snapshot.responseFragmentCount) 条")
            Text("这里显示实际采集的诊断数量；归属未确认的事件不代表当前节点故障，响应片段也不等于完整请求成功。")
                .font(.callout).foregroundStyle(.secondary)
            Button("查看诊断事件") {
                recordQuery = AppHealthRecordQuery(period: .quarterHour, currentEnvironmentOnly: true)
                selection = .records
                recordsPage = 1
            }
        }
    }

    private func percentage(_ value: Double?) -> String {
        value.map { String(format: "%.1f%%", $0 * 100) } ?? "未观测"
    }

    @ViewBuilder private var nodeContent: some View {
        if let node {
            let direct = connection.state.currentNodeID == node.id && connection.state.status == .connected
                && connection.applicationHealthSettings?.routingMode == .direct
            let usability = direct ? NodeUsabilityAssessment(state: .unknown, detail: "当前为直连模式，检测流量没有经过此节点，暂不判断节点是否可用。")
                : (connection.nodeQuality[node.id] ?? AIConnectionQuality()).usability(settings: appState.settings, now: observationDate)
            healthCard("节点连接", symbol: "server.rack") {
                Label(usability.state.displayName, systemImage: usabilitySymbol(usability.state))
                    .font(.title3.weight(.semibold)).foregroundStyle(usabilityColor(usability.state))
                Text(usability.detail).font(.callout).foregroundStyle(.secondary)
                Divider()
                LabeledContent("名称", value: appState.settings.nodeDisplayTitle(node))
                LabeledContent("协议", value: node.protocolType.displayName)
                LabeledContent("测速状态", value: node.resolvedTestStatus.displayName)
                LabeledContent("测速延迟", value: node.latencyText)
                if let date = node.lastTestDate {
                    LabeledContent("最近测速", value: date.formatted(date: .abbreviated, time: .shortened))
                }
            }
            exitInformationCard(for: node, direct: direct)
            healthCard("参考链路观测", symbol: "network") {
                if let original = connection.nodeQuality[node.id] {
                    let quality = original.freshObservations(settings: appState.settings, now: observationDate)
                    LabeledContent("HTTPS 请求成功", value: quality.samples.isEmpty ? "尚无有效样本" : "\(quality.successCount) / \(quality.samples.count)")
                    LabeledContent("HTTPS P95 延迟", value: milliseconds(quality.p95LatencyMs))
                    LabeledContent("相邻请求延迟抖动", value: milliseconds(quality.jitterMs))
                    if let date = original.lastSampleAt {
                        LabeledContent("最近 HTTPS 观测", value: date.formatted(date: .abbreviated, time: .standard))
                    }

                } else {
                    Text("连接该节点后开始采样；本次运行内保留最近 120 次 HTTPS 请求。")
                        .foregroundStyle(.secondary)
                }
                referenceSamplingControls(for: node)
                Button("查看链路评分") { selection = .scoring }
                if !connection.canTestQuality(nodeID: node.id) {
                    Text("连接此节点且使用代理路由后可开始检测。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text("HTTPS 与专项结果按测速有效期（\(max(1, appState.settings.testResultTTLMinutes)) 分钟）显示；手动检测使用连接设置中的测试地址与超时。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("这些观测反映节点的参考链路，不能证明 Codex、Claude 的登录或真实会话持续可用。速度慢、偶发超时会先增加等待时间，只有持续无法使用才按设置自动切换。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            healthCard("自动链路检查", symbol: "waveform.path") {
                let quality = connection.nodeQuality[node.id]?.freshObservations(settings: appState.settings, now: observationDate)
                let isCurrentConnection = node.id == connection.state.currentNodeID && connection.state.status == .connected
                let isPaused = isCurrentConnection && connection.automaticQualityPaused
                Text("连接后自动快速检查，完成后自动在后台观察 6 分钟长连接，不用手动启动；已有结果会持续用于评分。")
                    .font(.callout).foregroundStyle(.secondary)
                if let result = quality?.webSocket {
                    LabeledContent(result.isLongObservation ? "WebSocket 长时观测" : "WebSocket 快速检查", value: result.verified
                        ? "\(result.survived ? "通过" : "中断") · \(Int(result.observedSeconds)) / \(Int(result.requestedSeconds)) 秒"
                        : "端点未验证")
                    measurementDetail(result.detail, at: result.measuredAt)
                } else {
                    LabeledContent("WebSocket 快速检查", value: node.id == connection.state.currentNodeID && connection.state.status == .connected ? "等待自动检查" : "连接后自动检查")
                }
                if let result = quality?.datagrams {
                    LabeledContent("UDP 往返丢包（STUN）", value: result.lossRate.map {
                        "\(String(format: "%.1f", $0 * 100))% · \(result.received) / \(result.sent) 回包"
                    } ?? "未验证")
                    measurementDetail(result.detail, at: result.measuredAt)
                } else {
                    LabeledContent("UDP 往返丢包（STUN）", value: node.id == connection.state.currentNodeID && connection.state.status == .connected ? "等待自动检查" : "连接后自动检查")
                }
                if connection.qualityTestNodeID == node.id {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(connection.qualityTestIsDeep ? "后台长时观测中" : "自动快速检查中")
                        if let started = connection.qualityTestStartedAt {
                            Text(started, style: .timer).monospacedDigit()
                        }
                        Spacer()
                        Button("停止检查") { connection.cancelQualityTest() }
                    }
                    Text(connection.qualityTestMessage).font(.callout).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text(!isCurrentConnection ? "连接此节点后自动检查" : isPaused ? "自动检查已暂停" : connection.canTestQuality(nodeID: node.id) ? "自动检查已开启" : "代理连接就绪后自动检查")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button(isPaused ? "继续快检" : "重新快检") {
                            connection.startQualityTest(nodeID: node.id)
                        }
                        .disabled(!connection.canTestQuality(nodeID: node.id))
                    }
                }
                DisclosureGroup("长时稳定性观察（自动）") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("快速检查完成后自动在后台观察 6 分钟，确认长连接能否持续存活；通过后 WebSocket 项按 35 分计。观察期间基础分和快速检查结果继续显示，结果有效期内不重复观察。")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("重新观察 6 分钟") { connection.startQualityTest(nodeID: node.id, deep: true) }
                            .disabled(!connection.canTestQuality(nodeID: node.id) || connection.qualityTestNodeID != nil)
                    }
                    .padding(.top, 8)
                }
                Text("自动快检仅运行于当前代理节点；到期后自动补测，临时未验证的项目稍后再检查。UDP 回包缺失不等于原始 IP 丢包或 TCP 重传，未验证项目不计分。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else {
            unavailable("尚未选择节点", symbol: "server.rack", detail: "连接节点后，点击主窗口顶部的节点评分数值查看节点观测。")
        }
    }

    private func exitInformationCard(for node: ProxyNode, direct: Bool) -> some View {
        let exit = NetworkHealthExitInfo.resolve(node: node, connection: connection.state,
                                                 showChinese: appState.settings.showChineseNodeMetadata,
                                                 catalog: ChineseCityCatalog.shared)
        let quality = connection.nodeQuality[node.id]
        return healthCard("出口信息", symbol: "mappin.and.ellipse") {
            if exit.isCurrentConnection {
                if exit.awaitingLive {
                    Label(connection.state.lastError?.contains("出口") == true
                          ? (connection.state.lastError ?? "已连接，暂未获取到出口 IP")
                          : "已连接，正在获取出口信息",
                          systemImage: "waveform.path")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.orange)
                } else if let warning = connection.state.lastError, warning.contains("出口") || warning.contains("中国") {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                } else {
                    Label("当前连接出口", systemImage: "checkmark.circle.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.green)
                }
            } else if exit.ip != nil {
                Label("此节点最近测得的出口", systemImage: "clock")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                Label("尚无出口检测结果", systemImage: "mappin.slash")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Divider()
            LabeledContent("出口 IP", value: exit.ip ?? "未知")
                .help(exit.ip.map { "出口 IP：\($0)" } ?? "暂无出口 IP")
            LabeledContent("出口 IP 属性", value: exit.networkType?.displayName ?? "未知")
                .help("属性由 IPQuery 数据库识别，仅供参考；家庭住宅为排除已知机房、移动网络及代理标记后的推测。")
            LabeledContent("出口国家", value: exit.country ?? "未知")
                .help(exit.country.map { "出口国家：\($0)" } ?? "暂无出口国家")
            LabeledContent("出口城市", value: exit.city)
                .help(ExitMetadataLocalization.help(raw: exit.rawCity, displayed: exit.city,
                                                    showChinese: appState.settings.showChineseNodeMetadata))
            LabeledContent("出口运营商", value: exit.networkOperator)
                .help(ExitMetadataLocalization.help(raw: exit.rawOperator, displayed: exit.networkOperator,
                                                    showChinese: appState.settings.showChineseNodeMetadata))
            LabeledContent("ASN", value: exit.asn ?? "未知")
            if let quality {
                LabeledContent("本次运行出口变化 / 观测", value: "\(quality.exitChanges) / \(quality.exitObservations)")
            } else if exit.isCurrentConnection {
                LabeledContent("本次运行出口变化 / 观测", value: "等待采样")
            }
            if direct {
                Text("当前为直连模式：应用流量不经此节点，上方出口来自节点探测端口，不能代表应用实际出口。")
                    .font(.callout).foregroundStyle(.secondary)
            } else if !exit.isCurrentConnection {
                Text("此节点当前未连接，以上为最近一次测速或连接时保存的出口信息。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("出口由国家/地区检测服务识别，仅供参考；与应用真实会话出口可能因分流而不完全一致。同一节点在本次运行内的出口变化会单独计数。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
    }

    private func milliseconds(_ value: Double?) -> String {
        value.map { String(format: "%.0f ms", $0) } ?? "未观测"
    }

    private func usabilitySymbol(_ state: NodeUsabilityState) -> String {
        switch state {
        case .unknown: return "questionmark.circle"
        case .unavailable: return "xmark.circle.fill"
        case .timeoutProne: return "clock.badge.exclamationmark"
        case .slow: return "tortoise.fill"
        case .usable: return "checkmark.circle.fill"
        }
    }

    private func usabilityColor(_ state: NodeUsabilityState) -> Color {
        switch state {
        case .unknown: return .secondary
        case .unavailable: return .red
        case .timeoutProne, .slow: return .orange
        case .usable: return .green
        }
    }

    private func measurementDetail(_ detail: String, at date: Date) -> some View {
        Text(detail + " · " + date.formatted(date: .omitted, time: .standard))
            .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
    }

    private func healthCard<Content: View>(_ title: String, symbol: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.headline)
            Divider()
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5)))
        .labeledContentStyle(HealthMetricStyle())
    }

    private func unavailable(_ title: String, symbol: String, detail: String) -> some View {
        UnavailablePlaceholder(title, systemImage: symbol, description: {
            Text(detail)
        })
        .frame(maxWidth: .infinity, minHeight: 240)
    }
}

private struct HealthMetricStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            configuration.label.foregroundStyle(.secondary)
            Spacer(minLength: 12)
            configuration.content.multilineTextAlignment(.trailing)
        }
    }
}
