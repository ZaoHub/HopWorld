import Foundation
import SwiftUI
import Combine
import Network
import AppKit
import CoreWLAN
import SystemConfiguration

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case dashboard
    case countries
    case nodes
    case subscriptions
    case testing
    case routing
    case settings
    case logs
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "概览"
        case .countries: return "国家"
        case .nodes: return "节点"
        case .subscriptions: return "订阅"
        case .testing: return "测试"
        case .routing: return "路由"
        case .settings: return "设置"
        case .logs: return "日志"
        case .about: return "关于"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .countries: return "globe.asia.australia"
        case .nodes: return "server.rack"
        case .subscriptions: return "link"
        case .testing: return "speedometer"
        case .routing: return "arrow.triangle.branch"
        case .settings: return "gearshape"
        case .logs: return "doc.text"
        case .about: return "info.circle"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    let xrayUpdater = XrayUpdateManager()
    let singBoxUpdater = ComponentUpdateManager(.singBox)
    let geoFilesUpdater = ComponentUpdateManager(.geoFiles)
    let codexUsageMonitor = CodexUsageMonitor()
    let codexNotifications = CodexResetNotificationController()

    @Published var selectedSidebar: SidebarItem = .dashboard
    @Published var nodes: [ProxyNode] = []
    @Published private(set) var countryGroups: [CountryGroup] = []
    @Published var subscriptions: [Subscription] = []
    @Published var updateLogs: [SubscriptionUpdateLog] = []
    @Published var settings = AppSettings()
    @Published var recentNodeIDs: [UUID] = []
    /// 置顶节点（靠前显示），单独持久化以免破坏旧 nodes.json。
    @Published var pinnedNodeIDs: [UUID] = []
    /// 概览「今日流量」：按自然日累计的代理上下行。
    // Persisted accounting has no UI consumers; traffic must not invalidate every page.
    private(set) var dailyUsage = DailyUsageStats()
    /// 概览「当前网络」：系统网络是否可用 / 当前网络名称（Wi-Fi SSID 或接口类型）。
    @Published private(set) var networkAvailable = true
    @Published private(set) var networkName: String?
    /// 本次连接会话已见的流量计数，用于把会话增量折算进按日累计。
    private var lastSessionTraffic: (upload: Int64, download: Int64) = (0, 0)
    private var pendingTestResults: [UUID: (result: NodeTestResult, strict: Bool, fingerprint: String?)] = [:]
    private var testResultFlushTask: Task<Void, Never>?
    private var cityLocalizationTasks: [UUID: Task<Void, Never>] = [:]
    private var scheduledTestRunning = false
    private var lastFullNodeTestAt: Date?

    @Published var showAddSubscription = false
    @Published var showImportLinks = false
    @Published var importText = ""
    @Published var statusBanner: String?
    @Published var subscriptionTestPromptIDs: Set<UUID> = []
    @Published private(set) var subscriptionTestPromptSelectsAll = false
    @Published private(set) var isRefreshingAllSubscriptions = false
    private var pendingSubscriptionTestPromptIDs: Set<UUID> = []
    @Published private(set) var flashToastMessage: String?
    private var flashToastID = UUID()

    func flashToast(_ message: String) {
        let id = UUID()
        flashToastID = id
        flashToastMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.flashToastID == id else { return }
            self.flashToastMessage = nil
        }
    }

    func dismissFlashToast() {
        flashToastID = UUID()
        flashToastMessage = nil
    }

    @Published var persistenceError: String?
    private var librarySaveRetryTask: Task<Void, Never>?
    private var librarySaveRetryAttempt = 0
    @Published private(set) var libraryAvailable = false
    /// True when encrypted library could not be read; mutations stay in memory only.
    var isLibraryReady: Bool { libraryAvailable }
    /// 正在查看的订阅；与编辑分流。
    @Published var viewingSubscriptionID: UUID?
    @Published var editingSubscriptionID: UUID?
    /// 节点详情 / 分享。
    @Published var viewingNodeID: UUID?
    @Published var viewingHealthNodeID: UUID?
    @Published var networkHealthTab: NetworkHealthTab = .application
    private var networkHealthWindowController: NSWindowController?
    let health = NetworkHealthStore()
    /// Avoid re-hashing / SystemConfiguration reads on every SwiftUI invalidation.
    private var cachedHealthNetworkContext: (at: Date, value: String)?
    private var cachedHealthContext: (nodeID: UUID, isCurrent: Bool, exit: String?, route: [String], network: String, value: String)?
    private var cachedHealthNodeKey: (node: ProxyNode, value: String)?
    @Published private(set) var codexHealthMonitorStatus = "正在启动日志监测"
    @Published private(set) var codexInterfaceMonitorStatus = "等待 Codex 界面状态"
    @Published private(set) var codexInterfacePermissionRequired = false
    @Published private(set) var codexInterfaceObservation = CodexInterfaceObservation()
    /// Latest AX scan; `false` fields mean a complete scan confirmed the prompt is absent.
    @Published private(set) var codexInterfaceSnapshot = CodexInterfaceHealthSnapshot()
    @Published private(set) var codexHealthLastCheckedAt: Date?
    @Published private(set) var applicationHealthSwitchStatus = "智能应用优选未开启"
    private let codexHealthMonitor = CodexHealthMonitor()
    private var applicationHealthTask: Task<Void, Never>?
    private var applicationHealthSwitchTask: Task<Void, Never>?
    private var applicationHealthSwitchRunID = UUID()
    @Published private(set) var codexApplicationObservation = CodexApplicationObservation()
    @Published private(set) var codexInviteObservation = CodexInviteCheckObservation()
    @Published private(set) var codexInviteCheckInProgress = false
    private var codexInviteTask: Task<Void, Never>?
    private var codexInviteScope: String?
    private var codexInviteLastStartedAt: Date?
    /// Claude / Cursor 的模型加载持续失败时，先延长等待并复验。
    @Published private(set) var claudeModelObservations: [HealthApplication: CodexPathObservation] = [:]
    @Published private(set) var claudeModelDetails: [HealthApplication: String] = [:]
    private var claudeModelTasks: [HealthApplication: (id: UUID, task: Task<Void, Never>)] = [:]
    private var claudeModelCheckScope: String?
    private var claudeModelLastStartedAt: [HealthApplication: Date] = [:]
    private var cursorModelCatalog: (signature: Int, changedAt: Date)?
    private var codexObservedLaunchDate: Date?
    private var codexProcessObserved = false
    private var pendingApplicationFailureSince: Date?
    private var pendingApplicationFailureScope: String?
    private var codexRecoveryTiming = CodexRecoveryTiming()
    private var applicationRecoveryRetryAt: Date?
    private var applicationHealthScope: String?
    private var applicationHealthScopeSince = Date()
    private var applicationRecovery = CodexRecoveryTracker()
    private var applicationRecoveryConnectionAt: Date?
    /// 连接「不可用」节点前的确认（点确定后再真正连接）。
    @Published var pendingUnavailableConnectID: UUID?
    /// 节点列表滚动并选中该节点（添加重复节点时跳转）。
    @Published var focusNodeID: UUID?
    /// 测试完成后跳转到国家页并选中「可用」等分类。
    @Published var preferredNodeCategory: String?
    /// 打开「关于 → 管理更新」组件安装页（测速缺核心时也可由此进入）。
    @Published var showComponentUpdates = false

    let connection = ConnectionManager()
    let subscriptionManager = SubscriptionManager()
    let testManager = NodeTestManager()
    let logger = AppLogger.shared

    private let store = PersistenceStore()
    private var startupConnectionIntent = StartupConnectionIntent()
    private var schedulerTimer: Timer?
    private var backgroundActivity: NSObjectProtocol?
    private let networkMonitor = NWPathMonitor()
    private lazy var networkRecovery = NetworkRecoveryCoordinator { [weak self] in
        guard let self, !self.userStoppedConnection else { return }
        if (self.connection.automaticRecoveryPending || self.connection.state.status == .error),
           !self.connection.captureCleanupFailed {
            self.scheduleUnexpectedReconnect(avoiding: nil, reason: "网络已恢复")
        } else {
            await self.connection.revalidateAfterNetworkChange()
        }
    }
    private lazy var screenLockDisconnect = ScreenLockDisconnectCoordinator { [weak self] in
        guard let self else { return }
        guard self.connection.state.status != .disconnected || self.connection.isBusy else { return }
        await self.disconnect(manual: false, reason: "锁屏达到设定时间（\(self.settings.screenLockDisconnectDelayMinutes) 分钟）")
    }
    private var cancellables = Set<AnyCancellable>()
    private var subscriptionRefreshInProgress = false
    private struct PendingSubscriptionRefresh {
        var id: UUID
        var focusInNodeList: Bool
        var fetchYesterdayFirst: Bool
        var automatic: Bool
    }

    private var pendingSubscriptionRefresh: [PendingSubscriptionRefresh] = []
    /// Automatic tests requested while another test is running. Subscription
    /// refreshes can overlap, so silently dropping the later request loses nodes.
    private var pendingSilentTestNodeIDs: Set<UUID> = []
    private var testSessionIncludesAppProbes = false
    private var pendingAutomaticAppProbeNodeIDs: Set<UUID> = []
    private var pendingManualAppProbeNodeIDs: Set<UUID> = []
    private var automaticAppProbeTask: Task<Void, Never>?
    @Published private(set) var appProbeBatch = AppProbeBatchProgress()
    private var unexpectedReconnectTask: Task<Void, Never>?
    private var unexpectedReconnectRunID = UUID()
    private var eligibilitySwitchTask: Task<Void, Never>?
    private var unhealthySince: Date?
    private var unhealthyNodeID: UUID?
    private var recoveryAttemptedIDs: Set<UUID> = []
    private var recoveryNodeOrder: [UUID] = []
    private var recoveryHealthySince: Date?
    private var recoveryRunning = false
    private var automaticRecoveryNeedsUserAction = false
    private var userStoppedConnection = false
    private var isTerminating = false
    private var connectionRequestGeneration = 0
    private var connectionCountryCode: String?

    private var connectionScopedNodes: [ProxyNode] {
        guard let code = connectionCountryCode else { return nodes }
        return nodes.filter { CountryResolver.effectiveCode(for: $0) == code }
    }

    private func beginConnectionRequest(preservingNodeID: UUID? = nil, countryCode: String? = nil) -> Int {
        applicationHealthSwitchTask?.cancel()
        connectionCountryCode = countryCode?.uppercased()
        recoveryNodeOrder = automaticallyRankedNodes(connectionScopedNodes, preservingNodeID: preservingNodeID).map(\.id)
        recoveryAttemptedIDs.removeAll()
        applicationRecoveryRetryAt = nil
        automaticRecoveryNeedsUserAction = false
        userStoppedConnection = false
        connectionRequestGeneration += 1
        return connectionRequestGeneration
    }

    /// Freeze a recovery pass before a failed node's measurements can reorder it.
    private func orderedRecoveryNodes(after nodeID: UUID?) -> [ProxyNode] {
        let ranked = automaticallyRankedNodes(connectionScopedNodes)
        if recoveryNodeOrder.isEmpty || nodeID.map({ !recoveryNodeOrder.contains($0) }) == true {
            recoveryNodeOrder = automaticallyRankedNodes(connectionScopedNodes, preservingNodeID: nodeID).map(\.id)
        }
        for node in ranked where !recoveryNodeOrder.contains(node.id) { recoveryNodeOrder.append(node.id) }
        let eligible = Dictionary(uniqueKeysWithValues: ranked.map { ($0.id, $0) })
        return ApplicationHealthFailoverPolicy.orderedCandidates(in: recoveryNodeOrder, after: nodeID,
            excluding: recoveryAttemptedIDs).compactMap { eligible[$0] }
    }

    /// One ordered pass, followed by one full refresh and one fresh pass.
    /// Individual attempts deliberately bypass ConnectionManager's separate
    /// failover chain, which could otherwise reinsert already failed nodes.
    private func recoverAutomatically(avoiding failedID: UUID?) async {
        guard !userStoppedConnection, !automaticRecoveryNeedsUserAction, settings.autoFailover,
              connection.state.autoSelectEnabled, networkRecovery.canRecover, !recoveryRunning,
              applicationHealthSwitchTask == nil else { return }
        recoveryRunning = true
        connection.setAutomaticRecoveryPending(true)
        var waitingForNetwork = false
        var waitingForRetry = false
        defer {
            recoveryRunning = false
            connection.setAutomaticRecoveryPending(waitingForNetwork || waitingForRetry)
        }
        if let failedID { recoveryAttemptedIDs.insert(failedID) }
        recoveryHealthySince = nil
        var refreshed = false
        while !Task.isCancelled, !userStoppedConnection, networkRecovery.canRecover,
              settings.autoFailover, connection.state.autoSelectEnabled {
            guard !connection.captureCleanupFailed else {
                statusBanner = "代理清理未完成，已暂停自动切换"
                return
            }
            let candidate = orderedRecoveryNodes(after: failedID).first
            guard let candidate else {
                // Wait for an existing test to finish before requesting a new
                // full run, rather than consuming its incomplete results.
                while testManager.isTesting {
                    do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                }
                guard !Task.isCancelled else { return }
                let interval = TimeInterval(max(5, settings.scheduledTestIntervalMinutes) * 60)
                let recentlyTested = lastFullNodeTestAt.map { Date().timeIntervalSince($0) < interval } ?? false
                guard !refreshed, !recentlyTested else {
                    statusBanner = recentlyTested
                        ? "近期已完成全量测速，30 秒后重试现有节点"
                        : "本轮节点已全部尝试，30 秒后重新检查连接"
                    applicationRecoveryRetryAt = Date().addingTimeInterval(ApplicationHealthFailoverPolicy.exhaustedRetryDelay)
                    waitingForRetry = settings.autoFailover && connection.state.autoSelectEnabled
                    return
                }
                statusBanner = "合格节点已全部尝试，正在重新测试全部节点"
                logger.info("异常连接恢复触发全量测速：合格候选已全部尝试", category: .network)
                let testing = Task { @MainActor in
                    await self.testNodes(self.nodes.filter { $0.enabled && !$0.pendingRemoval }, silent: true, strictResults: true)
                }
                await testing.value
                guard !Task.isCancelled, testManager.phase != .paused else { return }
                recoveryAttemptedIDs.removeAll()
                recoveryNodeOrder.removeAll()
                refreshed = true
                continue
            }
            recoveryAttemptedIDs.insert(candidate.id)
            statusBanner = "自动切换：\(self.settings.nodeDisplayTitle(candidate))"
            logger.info("自动恢复依次尝试：\(self.settings.nodeDisplayTitle(candidate))", category: .network)
            do {
                try await connection.connect(node: candidate, settings: settings, allNodes: [],
                                             countryCode: candidate.countryCode, countryName: candidate.countryName)
                guard !Task.isCancelled else { return }
                pushRecent(candidate.id)
                markConnectedForNextLaunch(candidate.id)
                persist()
                return
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                if case ConnectionError.cancelled = error { return }
                if error is ApplicationProxyError {
                    automaticRecoveryNeedsUserAction = true
                    statusBanner = error.localizedDescription
                    return
                }
                logger.warning("自动恢复节点失败：\(self.settings.nodeDisplayTitle(candidate)) — \(error.localizedDescription)", category: .network)
                persist()
            }
        }
        waitingForNetwork = !Task.isCancelled && !userStoppedConnection && !networkRecovery.canRecover
            && settings.autoFailover && connection.state.autoSelectEnabled
            && !connection.captureCleanupFailed
    }

    private func currentNodeNeedsEligibilityRecovery(_ node: ProxyNode, now: Date = Date()) -> Bool {
        if !node.enabled || node.pendingRemoval || settings.isTemporarilyBlocked(node.id)
            || !settings.allowsAutoSelectCountry(CountryResolver.effectiveCode(for: node)) { return true }
        // Speed and candidate ranking must not disconnect a node that is still usable.
        return connection.nodeQuality[node.id]?.usability(settings: settings, now: now).state == .unavailable
    }

    private func checkConnectedNodeEligibility(liveSample: Bool = false) {
        guard !userStoppedConnection, networkRecovery.canRecover, !scheduledTestRunning else { return }
        guard !recoveryRunning, eligibilitySwitchTask == nil, applicationHealthSwitchTask == nil,
              settings.autoFailover, connection.state.autoSelectEnabled,
              connection.state.status == .connected, !connection.isBusy,
              let current = currentNode else {
            unhealthySince = nil
            unhealthyNodeID = nil
            return
        }
        guard currentNodeNeedsEligibilityRecovery(current) else {
            if liveSample, connection.state.latency != nil {
                if recoveryHealthySince == nil { recoveryHealthySince = Date() }
                if !settings.codexSmartFailover,
                   Date().timeIntervalSince(recoveryHealthySince!) >= Double(max(1, settings.autoSelectUnhealthySeconds)) {
                    recoveryAttemptedIDs.removeAll()
                }
            }
            unhealthySince = nil
            unhealthyNodeID = nil
            return
        }
        recoveryHealthySince = nil
        if unhealthyNodeID != current.id || unhealthySince == nil {
            unhealthyNodeID = current.id
            unhealthySince = Date()
        }
        let wait = max(Double(max(1, settings.autoSelectUnhealthySeconds)),
            ConnectionPatiencePolicy.applicationFailureDuration(configuredTimeout: settings.connectTimeoutSeconds,
                                                               needsExtendedObservation: false))
        guard let since = unhealthySince, Date().timeIntervalSince(since) >= wait else { return }
        eligibilitySwitchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.eligibilitySwitchTask = nil }
            guard !Task.isCancelled,
                  self.settings.autoFailover, self.connection.state.autoSelectEnabled,
                  self.connection.state.status == .connected,
                  !self.connection.isBusy,
                  let latest = self.currentNode, latest.id == current.id,
                  self.currentNodeNeedsEligibilityRecovery(latest),
                  self.unhealthyNodeID == current.id,
                  self.unhealthySince == since else { return }
            self.unhealthySince = nil
            self.unhealthyNodeID = nil
            self.logger.warning("当前节点持续无法使用或已被排除，复验后切换；节点：\(self.settings.nodeDisplayTitle(current))；判定等待：\(Int(wait)) 秒", category: .network)
            await self.recoverAutomatically(avoiding: current.id)
        }
    }

    var currentNode: ProxyNode? {
        guard let id = connection.state.currentNodeID else { return nil }
        return nodes.first { $0.id == id }
    }

    /// 启动 / 进入概览时刷新网络名称；不覆盖路径监视给出的接口类型回退。
    func refreshNetworkName() {
        if let ssid = CWWiFiClient.shared().interface()?.ssid() {
            networkName = ssid
        }
    }

    /// 把会话流量增量折算进按日累计；会话清零（新连接）时增量为负直接忽略。
    private func accumulateDailyTraffic(upload: Int64, download: Int64) {
        var usage = dailyUsage.rolledForwardToToday()
        let deltaUp = max(0, upload - lastSessionTraffic.upload)
        let deltaDown = max(0, download - lastSessionTraffic.download)
        lastSessionTraffic = (upload, download)
        guard deltaUp > 0 || deltaDown > 0 || usage != dailyUsage else { return }
        usage.uploadBytes += deltaUp
        usage.downloadBytes += deltaDown
        dailyUsage = usage
    }

    /// 连接中的当前节点；断开后仍返回最近一次连接的节点。
    var activeOrLastNode: ProxyNode? {
        if connection.state.status == .connected || connection.state.status == .connecting || connection.state.status == .disconnecting,
           let currentNode {
            return currentNode
        }
        return recentNodes.first
    }

    var recentNodes: [ProxyNode] {
        recentNodeIDs.compactMap { id in nodes.first { $0.id == id } }
    }

    var autoSelectCountryGroups: [CountryGroup] {
        countryGroups.filter { group in
            !isCountryExcludedFromAutoSelect(group.code) &&
            group.nodes.contains { settings.allowsAutoSelectNode($0) }
        }
    }

    func isCountryExcludedFromAutoSelect(_ code: String?) -> Bool {
        !settings.allowsAutoSelectCountry(code)
    }

    func healthNodeKey(_ node: ProxyNode) -> String {
        if let cached = cachedHealthNodeKey, cached.node == node { return cached.value }
        let value = NodeFingerprint.make(from: node)
        cachedHealthNodeKey = (node, value)
        return value
    }

    func openNetworkHealthCenter(for nodeID: UUID) {
        guard nodes.contains(where: { $0.id == nodeID }) else { return }
        viewingHealthNodeID = nodeID
        if networkHealthWindowController == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "网络健康中心"
            window.contentMinSize = NSSize(width: 720, height: 520)
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.contentView = NSHostingView(rootView: NetworkHealthView()
                .environmentObject(self).environmentObject(connection))
            window.center()
            networkHealthWindowController = NSWindowController(window: window)
        }
        networkHealthWindowController?.window?.deminiaturize(nil)
        networkHealthWindowController?.showWindow(nil)
        networkHealthWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    private func healthNetworkContext() -> String {
        // SCDynamicStore + SHA256 is too expensive for SwiftUI body / 2s polls; reuse briefly.
        if let cached = cachedHealthNetworkContext, Date().timeIntervalSince(cached.at) < 2 {
            return cached.value
        }
        let store = SCDynamicStoreCreate(nil, "HopWorldHealth" as CFString, nil, nil)
        let route = store.flatMap { SCDynamicStoreCopyValue($0, "State:/Network/Global/IPv4" as CFString) as? [String: Any] }
        let routeIdentity = ["PrimaryService", "PrimaryInterface", "Router"].map { route?[$0] as? String ?? "" }
        // Persist only opaque identities; network names and addresses stay in memory.
        let value = CryptoUtil.sha256Hex(([networkName ?? "未知网络"] + routeIdentity).joined(separator: "|"))
        cachedHealthNetworkContext = (Date(), value)
        return value
    }

    func healthContext(for node: ProxyNode) -> String {
        let isCurrent = connection.state.status == .connected && connection.state.currentNodeID == node.id
        let running = isCurrent ? connection.applicationHealthSettings ?? settings : settings
        let route = [running.connectionCaptureMode.rawValue, running.routingMode.rawValue,
                     running.routingRules.direct, running.routingRules.proxy, running.routingRules.blocked,
                     String(running.routingRules.bypassChina), running.proxyApplications.map(\.path).sorted().joined(separator: "|")]
        let network = healthNetworkContext()
        let exit = isCurrent ? connection.state.exitIP : node.exitMetadata?.ip
        if let cached = cachedHealthContext, cached.nodeID == node.id, cached.isCurrent == isCurrent,
           cached.exit == exit, cached.route == route, cached.network == network {
            return cached.value
        }
        let base = CryptoUtil.sha256Hex(network + route.joined(separator: "|"))
        let value = base + "/" + CryptoUtil.sha256Hex(exit ?? "出口未确认")
        cachedHealthContext = (node.id, isCurrent, exit, route, network, value)
        return value
    }

    private var codexTrafficIsCaptured: Bool { trafficIsCaptured(.codex) }

    private func trafficIsCaptured(_ application: HealthApplication) -> Bool {
        guard let active = connection.applicationHealthSettings,
              connection.effectiveCaptureMode?.usesTun == true else { return false }
        if active.connectionCaptureMode == .globalTun { return true }
        return active.proxyApplications.contains { application.matches($0) }
    }

    func applicationHealthCaptureSummary(for node: ProxyNode, application: HealthApplication = .codex) -> (ready: Bool, detail: String) {
        let name = application.displayName
        guard connection.state.status == .connected else {
            if connection.isBusy || connection.automaticRecoveryPending || applicationHealthSwitchTask != nil {
                return (false, "正在连接或按顺序恢复节点；新连接就绪后开始本次采集，跨节点应用状态仍单独保留。")
            }
            return (false, "代理尚未连接；连接后才会将新事件关联到节点。")
        }
        guard node.id == connection.state.currentNodeID else {
            return (false, "此节点当前未连接，仅可查看历史；不会将其他节点的新事件归入此处。")
        }
        guard currentApplicationHealthScope() != nil else {
            return (false, "网络恢复或接管状态尚未就绪，暂不关联新事件。")
        }
        guard connection.effectiveCaptureMode?.usesTun == true else {
            return (false, "当前未使用 TUN 接管，无法确认 \(name) 流量经过此节点。可在设置中的连接项检查接管模式。")
        }
        guard trafficIsCaptured(application) else {
            return (false, "当前应用接管名单未包含 \(name)；将 \(name) 加入名单并应用连接设置后，才可验证流量归属。")
        }
        return (true, application == .codex
            ? "当前 TUN 已覆盖 Codex 应用包；仍需日志提供公网路径和完整请求结果，才能计算真实应用评分。"
            : "当前 TUN 已覆盖 \(name) 应用包；应用流量经过此节点。")
    }

    func isApplicationRunning(_ application: HealthApplication) -> Bool {
        application.bundleIdentifiers.contains { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
    }

    /// 「应用连通」中启用、正在运行且流量经 TUN 接管的 Claude / Cursor；它们必须能加载 Claude 模型。
    private var activeClaudeModelApplications: [HealthApplication] {
        settings.healthApplications.filter { $0 != .codex && isApplicationRunning($0) && trafficIsCaptured($0) }
    }

    private func claudeModelScope() -> String? {
        guard currentApplicationHealthScope() != nil, let node = currentNode,
              let connectedAt = connection.state.connectedAt else { return nil }
        // Exit metadata may arrive after connect; it must not restart the observation window.
        let environment = healthContext(for: node).split(separator: "/").first.map(String.init) ?? ""
        return healthNodeKey(node) + environment + String(connectedAt.timeIntervalSince1970)
    }

    /// Claude / Cursor 只按 Claude 模型加载判定，不涉及 Codex 的重连与邀请检查。
    func applicationSwitchStatus(for application: HealthApplication, now: Date = Date()) -> String {
        let name = application.displayName
        guard application != .codex, applicationHealthSwitchTask == nil, applicationRecoveryRetryAt == nil,
              settings.codexSmartFailover, settings.autoFailover, connection.state.autoSelectEnabled,
              !automaticRecoveryNeedsUserAction, connection.state.status == .connected else { return applicationHealthSwitchStatus }
        guard isApplicationRunning(application) else { return "\(name) 未运行，启动后继续监测" }
        guard trafficIsCaptured(application) else { return "\(name) 流量未经 TUN 接管，暂不自动切换" }
        if let since = claudeModelObservations[application]?.failureSince {
            let elapsed = max(0, Int(now.timeIntervalSince(since)))
            let wait = ConnectionPatiencePolicy.applicationFailureDuration(configuredTimeout: settings.connectTimeoutSeconds,
                                                                          needsExtendedObservation: true)
            let remaining = max(0, Int(ceil(wait - now.timeIntervalSince(since))))
            return "无法加载 Claude 模型已持续 \(elapsed) 秒，\(remaining) 秒后直接切换下一节点"
        }
        return "监测中：无法加载 Claude 模型持续无法恢复并完成等待后按顺序切换"
    }

    private func claudeModelFailure(now: Date = Date()) -> HealthApplication? {
        guard claudeModelScope() != nil else { return nil }
        let wait = ConnectionPatiencePolicy.applicationFailureDuration(configuredTimeout: settings.connectTimeoutSeconds,
                                                                      needsExtendedObservation: true)
        return activeClaudeModelApplications.first {
            guard let observation = claudeModelObservations[$0], observation.needsRecovery(now: now),
                  let since = observation.failureSince else { return false }
            return now.timeIntervalSince(since) >= wait
        }
    }

    private func scheduleClaudeModelChecks() {
        let scope = claudeModelScope()
        let selected = Set(settings.healthApplications.filter { $0 != .codex })
        if scope != claudeModelCheckScope {
            claudeModelTasks.values.forEach { $0.task.cancel() }
            claudeModelTasks.removeAll()
            claudeModelLastStartedAt.removeAll()
            claudeModelObservations.removeAll()
            claudeModelDetails.removeAll()
            claudeModelCheckScope = scope
        }
        for application in Set(claudeModelObservations.keys).union(claudeModelTasks.keys) where !selected.contains(application) {
            claudeModelTasks.removeValue(forKey: application)?.task.cancel()
            claudeModelLastStartedAt[application] = nil
            claudeModelObservations[application] = nil
            claudeModelDetails[application] = nil
        }
        guard let scope, let node = currentNode, let connectedAt = connection.state.connectedAt else { return }
        for application in selected where claudeModelTasks[application] == nil {
            guard claudeModelLastStartedAt[application].map({ Date().timeIntervalSince($0) >= 10 }) ?? true else { continue }
            let startedAt = Date()
            let runID = UUID()
            claudeModelLastStartedAt[application] = startedAt
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { if self.claudeModelTasks[application]?.id == runID { self.claudeModelTasks[application] = nil } }
                guard let result = await self.checkClaudeModels(for: application, connectedAt: connectedAt),
                      !Task.isCancelled, self.claudeModelTasks[application]?.id == runID,
                      self.claudeModelCheckScope == scope else { return }
                let previous = self.claudeModelObservations[application]?.reachable
                self.claudeModelObservations[application, default: CodexPathObservation()].record(reachable: result.available, at: startedAt)
                self.claudeModelDetails[application] = result.detail
                if previous != result.available {
                    let name = application.displayName
                    self.health.recordCheck(ApplicationCheckRecord(
                        date: startedAt, application: application, nodeKey: self.healthNodeKey(node), nodeID: node.id,
                        available: result.available,
                        title: result.available ? "\(name) 可加载 Claude 模型" : "\(name) 无法加载 Claude 模型",
                        detail: result.detail))
                }
                self.considerApplicationHealthSwitch()
            }
            claudeModelTasks[application] = (runID, task)
        }
    }

    /// Cursor 本地模型列表在本次连接后刷新过时以它为准；否则经当前代理检查 Anthropic 是否允许当前出口。
    private func checkClaudeModels(for application: HealthApplication, connectedAt: Date) async -> (available: Bool, detail: String)? {
        if application == .cursor, let names = await Task.detached(priority: .utility, operation: {
            CursorUsageReader.readAvailableModelNames()
        }).value {
            let signature = names.joined(separator: "\n").hashValue
            if let catalog = cursorModelCatalog, catalog.signature != signature {
                cursorModelCatalog = (signature, Date())
            } else if cursorModelCatalog == nil {
                cursorModelCatalog = (signature, .distantPast)
            }
            if let catalog = cursorModelCatalog, catalog.changedAt >= connectedAt {
                let claude = names.filter { $0.hasPrefix("claude-") }.count
                return claude > 0
                    ? (true, "Cursor 模型列表已加载 \(claude) 个 Claude 模型")
                    : (false, "Cursor 模型列表未包含 Claude 模型")
            }
        }
        switch await connection.checkClaudeModelAccess(extendedWait: claudeModelObservations[application]?.reachable == false) {
        case nil: return nil
        case .available?: return (true, "经当前代理访问 Anthropic 正常，当前出口可加载 Claude 模型")
        case .regionBlocked?: return (false, "Anthropic 拒绝当前出口地区（HTTP 403），Claude 模型无法加载")
        case .unreachable?: return (false, "经当前代理无法连接 Anthropic，Claude 模型无法加载")
        }
    }

    private func currentApplicationHealthScope() -> String? {
        guard networkRecovery.canRecover, connection.state.status == .connected,
              !connection.captureCleanupFailed, let node = currentNode,
              let connectedAt = connection.state.connectedAt else { return nil }
        return healthNodeKey(node) + healthContext(for: node) + String(connectedAt.timeIntervalSince1970)
    }

    private func currentApplicationRecoveryScope() -> String? {
        guard settings.codexSmartFailover, settings.autoFailover, connection.state.autoSelectEnabled,
              codexTrafficIsCaptured, currentApplicationHealthScope() != nil,
              let node = currentNode, let connectedAt = connection.state.connectedAt,
              let codexLaunchDate = codexObservedLaunchDate else { return nil }
        // Exit metadata may arrive after connect; it must not erase the new bridge's recovery signal.
        let environment = healthContext(for: node).split(separator: "/").first.map(String.init) ?? ""
        return healthNodeKey(node) + environment + String(connectedAt.timeIntervalSince1970)
            + "/codex/" + String(codexLaunchDate.timeIntervalSince1970)
    }

    @discardableResult
    private func synchronizeApplicationRecoveryScope(now: Date = Date()) -> String? {
        let scope = currentApplicationRecoveryScope()
        let connectedAt = connection.state.status == .connected ? connection.state.connectedAt : nil
        let since = connectedAt != applicationRecoveryConnectionAt ? connectedAt ?? now : now
        applicationRecovery.setScope(scope, since: since)
        if pendingApplicationFailureScope != scope {
            pendingApplicationFailureScope = scope
            pendingApplicationFailureSince = nil
        }
        let interfaceFailure = codexInterfaceObservation.pendingFailure(now: now)
        let pending = [codexApplicationObservation.pendingRecoveryFailure, interfaceFailure].compactMap { $0 }.max { $0.date < $1.date }
        let recoveredAt = codexApplicationObservation.pendingSettingsFailure == nil && interfaceFailure == nil
            ? codexApplicationObservation.lastResponseAt : nil
        if let recoveredAt { codexInviteObservation.observeApplicationResponse(at: recoveredAt) }
        if let recoveredAt, let since = pendingApplicationFailureSince, recoveredAt >= since {
            pendingApplicationFailureSince = nil
        }
        if scope == nil || pending == nil {
            pendingApplicationFailureSince = nil
        } else if pendingApplicationFailureSince == nil {
            pendingApplicationFailureSince = max(connectedAt ?? now, pending!.date)
        }
        let inviteIsCurrent = codexInviteScope == currentApplicationHealthScope()
        let failureSince = [applicationRecovery.failureSince, pendingApplicationFailureSince].compactMap { $0 }
            .filter { date in recoveredAt.map { date > $0 } ?? true }.min()
        let usability = currentNode.flatMap { connection.nodeQuality[$0.id]?.usability(settings: settings, now: now).state }
        let needsExtendedObservation = usability == .slow || usability == .timeoutProne
            || pending?.kind == .reconnecting || pending?.kind == .waitingForNetwork
        let minimumFailureDuration = ConnectionPatiencePolicy.applicationFailureDuration(
            configuredTimeout: settings.connectTimeoutSeconds, needsExtendedObservation: needsExtendedObservation)
        codexRecoveryTiming.synchronize(scope: scope, failureSince: failureSince,
            inviteReachableAt: inviteIsCurrent && codexInviteObservation.result?.isAvailable == true
                ? codexInviteObservation.lastCheckedAt : nil, recoveredAt: recoveredAt,
            minimumFailureDuration: minimumFailureDuration)
        applicationRecoveryConnectionAt = connectedAt
        return scope
    }

    private func scheduleCodexInviteCheck() {
        let scope = connection.applicationHealthSettings?.routingMode == .direct || codexObservedLaunchDate == nil
            ? nil : currentApplicationHealthScope()
        if scope != codexInviteScope {
            codexInviteTask?.cancel()
            codexInviteTask = nil
            codexInviteCheckInProgress = false
            codexInviteScope = scope
            codexInviteLastStartedAt = nil
            codexInviteObservation = CodexInviteCheckObservation()
        }
        guard let scope, codexInviteTask == nil,
              codexInviteLastStartedAt.map({ Date().timeIntervalSince($0) >= 10 }) ?? true else { return }
        let startedAt = Date()
        codexInviteLastStartedAt = startedAt
        codexInviteCheckInProgress = true
        codexInviteTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.codexInviteScope == scope {
                    self.codexInviteTask = nil
                    self.codexInviteCheckInProgress = false
                }
            }
            let result = await self.connection.checkCodexInviteEligibility()
            guard !Task.isCancelled, self.codexInviteScope == scope,
                  self.currentApplicationHealthScope() == scope, let result, let node = self.currentNode else { return }
            if case .available(true) = result {
                // Board shows 正常 from the observation; skip repeating「状态 1 正常」records every 10s.
            } else if case .available = result {
                // available(false) is a completed check worth recording.
            } else {
                self.logger.warning("Codex 状态 1：\(result.userFacingSummary)", category: .network)
            }
            let checkedAt = Date()
            let event = result.healthEvent(at: checkedAt)
            let nodeKey = self.healthNodeKey(node)
            let context = self.healthContext(for: node)
            await self.codexHealthMonitor.observeInviteCheck(event)
            let observation = await self.codexHealthMonitor.applicationObservation
            guard !Task.isCancelled, self.codexInviteScope == scope,
                  self.currentApplicationHealthScope() == scope else { return }
            self.codexInviteObservation.record(result: result, at: checkedAt)
            self.codexApplicationObservation = observation
            if case .available(true) = result {
                // Keep observation/recovery signals without a premature normal record.
            } else {
                self.health.record(event: event, nodeKey: nodeKey, context: context, nodeID: node.id)
            }
            self.synchronizeApplicationRecoveryScope()
            self.considerApplicationHealthSwitch()
        }
    }

    private func startApplicationHealthMonitoring() {
        applicationHealthTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, !self.isTerminating else { return }
                let scope = self.currentApplicationHealthScope()
                if scope != self.applicationHealthScope {
                    self.applicationHealthScope = scope
                    self.applicationHealthScopeSince = Date()
                }
                self.synchronizeApplicationRecoveryScope()
                let codexApplication = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first
                let launchDate = codexApplication?.launchDate
                if !self.codexProcessObserved || launchDate != self.codexObservedLaunchDate {
                    self.codexProcessObserved = true
                    self.codexObservedLaunchDate = launchDate
                    self.codexInviteTask?.cancel()
                    self.codexInviteTask = nil
                    self.codexInviteCheckInProgress = false
                    self.codexInviteScope = nil
                    self.codexInviteObservation = CodexInviteCheckObservation()
                    await self.codexHealthMonitor.resetApplicationObservation(since: launchDate ?? Date())
                }
                let events = await self.codexHealthMonitor.poll(codexPID: codexApplication?.processIdentifier)
                let interface = await self.codexHealthMonitor.interfaceSnapshot
                let nextInterface = await self.codexHealthMonitor.interfaceObservation
                let nextApplication = await self.codexHealthMonitor.applicationObservation
                let nextInterfaceStatus = interface.status.displayName
                let nextPermission = interface.status == .permissionRequired
                let nextMonitorStatus = await self.codexHealthMonitor.status
                // Idle polls must not republish; Network Health Center rebuilds on every AppState tick.
                var published = false
                if self.codexInterfaceObservation != nextInterface {
                    self.codexInterfaceObservation = nextInterface
                    published = true
                }
                if self.codexInterfaceSnapshot != interface {
                    self.codexInterfaceSnapshot = interface
                    published = true
                }
                if self.codexInterfaceMonitorStatus != nextInterfaceStatus {
                    self.codexInterfaceMonitorStatus = nextInterfaceStatus
                    published = true
                }
                if self.codexInterfacePermissionRequired != nextPermission {
                    self.codexInterfacePermissionRequired = nextPermission
                    published = true
                }
                if self.codexApplicationObservation != nextApplication {
                    self.codexApplicationObservation = nextApplication
                    published = true
                }
                if self.codexHealthMonitorStatus != nextMonitorStatus {
                    self.codexHealthMonitorStatus = nextMonitorStatus
                    published = true
                }
                if published || !events.isEmpty {
                    self.codexHealthLastCheckedAt = Date()
                }
                if self.synchronizeApplicationRecoveryScope() != nil {
                    for event in events { self.applicationRecovery.observe(event) }
                }
                // Reject events spanning a reconnect, route change, sleep, or exit change.
                if let scope, scope == self.currentApplicationHealthScope(), let node = self.currentNode {
                    let nodeKey = self.healthNodeKey(node)
                    let context = self.healthContext(for: node)
                    for event in events where event.date >= self.applicationHealthScopeSince {
                        var attributed = event
                        if !self.codexTrafficIsCaptured { attributed.scope = "unconfirmed-route" }
                        self.health.record(event: attributed, nodeKey: nodeKey, context: context, nodeID: node.id)
                    }
                }
                if let current = self.currentNode, self.connection.state.status == .connected {
                    _ = self.orderedRecoveryNodes(after: current.id)
                }
                self.scheduleCodexInviteCheck()
                self.scheduleClaudeModelChecks()
                if self.currentApplicationRecoveryScope() != nil, self.applicationHealthSwitchTask == nil,
                   self.codexApplicationObservation.pendingRecoveryFailure == nil,
                   self.codexInterfaceObservation.pendingFailure() == nil,
                   let connectedAt = self.connection.state.connectedAt,
                   self.applicationRecovery.hasRecovered(since: connectedAt, allowTransportReady: true) {
                    self.applicationRecoveryRetryAt = nil
                    self.recoveryAttemptedIDs.removeAll()
                }
                let claudeApplications = self.activeClaudeModelApplications
                if self.currentApplicationRecoveryScope() == nil, self.applicationHealthSwitchTask == nil,
                   !claudeApplications.isEmpty,
                   claudeApplications.allSatisfy({ self.claudeModelObservations[$0]?.reachable == true }) {
                    self.applicationRecoveryRetryAt = nil
                    self.recoveryAttemptedIDs.removeAll()
                }
                self.considerApplicationHealthSwitch()
                self.resumePendingConnectionRecoveryIfNeeded()
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            }
        }
    }

    private func applicationNeedsRecovery(for node: ProxyNode, context: String, now: Date = Date()) -> Bool {
        if claudeModelFailure(now: now) != nil { return true }
        let scope = synchronizeApplicationRecoveryScope(now: now)
        if let switchAt = codexRecoveryTiming.switchAt, now < switchAt { return false }
        if scope != nil, applicationRecovery.scope == scope, applicationRecovery.shouldRecover(now: now) { return true }
        return scope != nil && pendingApplicationFailureSince.map {
            now.timeIntervalSince($0) >= ApplicationHealthFailoverPolicy.failureDuration
        } == true
    }

    private func considerApplicationHealthSwitch() {
        guard settings.codexSmartFailover else {
            applicationHealthSwitchStatus = "智能应用优选未开启"
            return
        }
        let claudeApplications = activeClaudeModelApplications
        guard codexObservedLaunchDate != nil || !claudeApplications.isEmpty else {
            applicationHealthSwitchStatus = "Codex、Claude、Cursor 均未运行或未接管，等待启动后继续监测"
            return
        }
        guard !automaticRecoveryNeedsUserAction else {
            applicationHealthSwitchStatus = "代理接管需要手动处理，请修复后重新连接"
            return
        }
        guard settings.autoFailover else {
            applicationHealthSwitchStatus = "自动故障切换未开启，请在设置中的连接项开启"
            return
        }
        guard connection.state.autoSelectEnabled else {
            applicationHealthSwitchStatus = "自动优选未开启，当前暂停自动选择备用节点"
            return
        }
        guard !userStoppedConnection, settings.autoFailover, connection.state.autoSelectEnabled,
              networkRecovery.canRecover, !connection.isBusy, !recoveryRunning,
              eligibilitySwitchTask == nil, !connection.automaticRecoveryPending,
              applicationHealthSwitchTask == nil, let current = currentNode,
              connection.state.status == .connected, codexTrafficIsCaptured || !claudeApplications.isEmpty else {
            if applicationHealthSwitchTask == nil {
                applicationHealthSwitchStatus = "等待代理连接、自动优选与应用 TUN 接管就绪"
            }
            return
        }
        let now = Date()
        if let retryAt = applicationRecoveryRetryAt {
            if now < retryAt {
                applicationHealthSwitchStatus = "本轮备用节点已尝试，\(max(0, Int(ceil(retryAt.timeIntervalSince(now))))) 秒后重新检查"
                return
            }
            applicationRecoveryRetryAt = nil
            recoveryAttemptedIDs.removeAll()
        }
        let currentContext = healthContext(for: current)
        guard applicationNeedsRecovery(for: current, context: currentContext, now: now) else {
            if let observationUntil = codexRecoveryTiming.observationUntil, now < observationUntil {
                let remaining = max(0, Int(ceil(observationUntil.timeIntervalSince(now))))
                applicationHealthSwitchStatus = "状态 1 检查已完成，继续观察 \(remaining) 秒；持续无法使用时再切换"
                return
            }
            if let switchAt = codexRecoveryTiming.switchAt {
                let remaining = max(0, Int(ceil(switchAt.timeIntervalSince(now))))
                applicationHealthSwitchStatus = "正在延长等待并观察恢复，仍无法使用则在 \(remaining) 秒后尝试备用节点"
                return
            }
            let claudeFailureSince = claudeApplications.compactMap { claudeModelObservations[$0]?.failureSince }.min()
            let since = [applicationRecovery.failureSince, pendingApplicationFailureSince, claudeFailureSince].compactMap { $0 }.min()
            if let since, applicationRecovery.bridgeRecoveryDeadline != nil || pendingApplicationFailureSince != nil
                || claudeFailureSince != nil
                || (applicationRecovery.failureCount >= 3
                    && applicationRecovery.lastFailureAt.map({ now.timeIntervalSince($0) <= 20 }) == true) {
                let wait = ConnectionPatiencePolicy.applicationFailureDuration(configuredTimeout: settings.connectTimeoutSeconds,
                                                                              needsExtendedObservation: true)
                let remaining = max(0, Int(ceil(wait - now.timeIntervalSince(since))))
                applicationHealthSwitchStatus = "应用异常已持续 \(max(0, Int(now.timeIntervalSince(since)))) 秒，\(remaining) 秒后直接切换下一节点"
            } else {
                let codexMonitored = codexObservedLaunchDate != nil && codexTrafficIsCaptured
                let conditions = (codexMonitored ? ["Codex 无法加载工作空间设置、正在重新连接或等待网络"] : [])
                    + (claudeApplications.isEmpty ? [] : [claudeApplications.map(\.displayName).joined(separator: "、") + " 无法加载 Claude 模型"])
                applicationHealthSwitchStatus = "监测中：" + conditions.joined(separator: "，或 ") + "持续无法恢复并完成等待后按顺序切换"
            }
            return
        }
        let networkContext = String(currentContext.split(separator: "/")[0])
        let networkIdentity = healthNetworkContext()
        let generation = connectionRequestGeneration
        let configuredRoute = settings
        let initialScope = currentApplicationRecoveryScope()
        let processLaunchDate = codexObservedLaunchDate
        let claudeFailure = claudeModelFailure(now: now)
        let reason = claudeFailure.map { "\($0.displayName) 无法加载 Claude 模型，延长等待并复验后仍无法恢复，切换备用节点" }
            ?? "Codex 持续无法恢复，延长等待后尝试备用节点"
        _ = orderedRecoveryNodes(after: current.id)
        recoveryAttemptedIDs.insert(current.id)
        let ordered = orderedRecoveryNodes(after: current.id)
        let candidates = settings.failoverPoolMode == .limited
            ? Array(ordered.prefix(max(1, settings.maxFailoverAttempts))) : ordered
        guard !candidates.isEmpty else {
            applicationRecoveryRetryAt = now.addingTimeInterval(ApplicationHealthFailoverPolicy.exhaustedRetryDelay)
            applicationHealthSwitchStatus = "本轮合格节点已尝试完，30 秒后重新检查；请检查节点或服务状态"
            return
        }
        if let claudeFailure {
            health.recordCheck(ApplicationCheckRecord(
                date: now, application: claudeFailure, nodeKey: healthNodeKey(current), nodeID: current.id,
                available: false, title: "自动切换节点",
                detail: reason + "；" + (claudeModelDetails[claudeFailure] ?? "")))
        }
        let runID = UUID()
        applicationHealthSwitchRunID = runID
        applicationHealthSwitchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.applicationHealthSwitchRunID == runID {
                    self.applicationHealthSwitchTask = nil
                }
            }
            @MainActor func record(_ candidate: ProxyNode, _ result: String) {
                self.health.recordSwitch(from: self.healthNodeKey(current), to: self.healthNodeKey(candidate),
                    context: networkContext, reason: reason, result: result)
                self.logger.info("应用自动恢复：" + result, category: .network)
            }
            @MainActor func stillAuthorized() -> Bool {
                !Task.isCancelled && !self.isTerminating && !self.userStoppedConnection
                    && self.applicationHealthSwitchRunID == runID
                    && self.connectionRequestGeneration == generation && self.settings.codexSmartFailover
                    && self.settings.autoFailover && self.connection.state.autoSelectEnabled
                    && self.settings.connectionCaptureMode == configuredRoute.connectionCaptureMode
                    && self.settings.proxyApplications == configuredRoute.proxyApplications
                    && self.settings.routingMode == configuredRoute.routingMode
                    && self.settings.routingRules == configuredRoute.routingRules
                    && self.networkRecovery.canRecover && self.healthNetworkContext() == networkIdentity
                    && self.codexObservedLaunchDate == processLaunchDate
            }
            @MainActor func candidateIsAllowed(_ candidate: ProxyNode) -> Bool {
                guard let latest = self.nodes.first(where: { $0.id == candidate.id }) else { return false }
                return latest.enabled && !latest.pendingRemoval
                    && (self.connectionCountryCode == nil || CountryResolver.effectiveCode(for: latest) == self.connectionCountryCode)
                    && self.healthNodeKey(latest) == self.healthNodeKey(candidate)
                    && self.settings.allowsAutoSelectNode(latest)
                    && (self.settings.favoritePreference != .favoritesOnly || latest.isFavorite)
            }
            var attemptedConnection = false
            for (index, candidate) in candidates.enumerated() {
                guard stillAuthorized() else { return }
                if !attemptedConnection {
                    guard initialScope == self.currentApplicationRecoveryScope(),
                          self.applicationNeedsRecovery(for: current, context: currentContext) else {
                        self.applicationHealthSwitchStatus = "应用已恢复或连接条件变化，取消自动切换"
                        return
                    }
                }
                guard candidateIsAllowed(candidate) else { continue }
                self.recoveryAttemptedIDs.insert(candidate.id)
                self.applicationHealthSwitchStatus = "延长等待后仍无法恢复，正在切换备用节点 \(index + 1)/\(candidates.count)"
                record(candidate, "开始直接切换下一个节点")
                do {
                    attemptedConnection = true
                    try await self.connection.connect(node: candidate, settings: self.settings, allNodes: [],
                        countryCode: candidate.countryCode, countryName: candidate.countryName)
                    guard stillAuthorized() else { return }
                    guard self.connection.state.status == .connected,
                          self.connection.state.currentNodeID == candidate.id else { continue }
                    self.synchronizeApplicationRecoveryScope()
                    record(candidate, "已切换节点，继续后台故障监测")
                    self.applicationHealthSwitchStatus = "已切换节点，继续观察连接与应用恢复情况"
                    self.pushRecent(candidate.id)
                    self.markConnectedForNextLaunch(candidate.id)
                    self.persist()
                    return
                } catch {
                    guard stillAuthorized() else { return }
                    if error is CancellationError { return }
                    if case ConnectionError.cancelled = error { return }
                    if error is ApplicationProxyError || self.connection.captureCleanupFailed {
                        self.automaticRecoveryNeedsUserAction = true
                        self.applicationHealthSwitchStatus = "代理接管或清理失败，请修复后重新连接"
                        return
                    }
                    record(candidate, "候选连接失败，继续下一节点")
                }
            }
            guard stillAuthorized() else { return }
            let remaining = self.orderedRecoveryNodes(after: self.connection.state.currentNodeID)
            if remaining.isEmpty {
                self.applicationRecoveryRetryAt = Date().addingTimeInterval(ApplicationHealthFailoverPolicy.exhaustedRetryDelay)
                self.applicationHealthSwitchStatus = "本轮节点未确认恢复，30 秒后重新检查；保留最后的连接结果"
            } else {
                self.applicationHealthSwitchStatus = "本批节点未恢复，继续后续候选"
            }
        }
    }

    init() {
        load()
        bind()
        startCodexUsageMonitoring()
        NotificationCenter.default.publisher(for: .hopWorldWillTerminate)
            .sink { [weak self] notification in
                guard let self, let application = notification.object as? NSApplication else { return }
                Task { @MainActor in
                    await self.disconnectForTermination()
                    application.reply(toApplicationShouldTerminate: true)
                }
            }
            .store(in: &cancellables)
        Task {
            await xrayUpdater.checkForUpdates(automatic: true)
            // Rule validation requires an installed Xray; keep startup checks ordered.
            await geoFilesUpdater.checkForUpdates(automatic: true)
        }
        Task { await singBoxUpdater.checkForUpdates(automatic: true) }
        startNetworkMonitoring()
        startApplicationHealthMonitoring()
        Task {
            await connection.bootstrapRestore(settings: settings)
            if libraryAvailable {
                await connectOnLaunchIfNeeded()
                if !isTerminating { startScheduler() }
            }
        }
    }

    private func startNetworkMonitoring() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            let usesWiFi = path.usesInterfaceType(.wifi)
            let usesWired = path.usesInterfaceType(.wiredEthernet)
            Task { @MainActor in
                guard let self else { return }
                self.networkAvailable = available
                if usesWiFi {
                    // macOS 14+ 未授权定位服务时 SSID 可能为空，退化为接口类型。
                    self.networkName = CWWiFiClient.shared().interface()?.ssid() ?? "Wi-Fi"
                } else if usesWired {
                    self.networkName = "以太网"
                } else {
                    self.networkName = nil
                }
                self.networkRecovery.pathChanged(available: available)
            }
        }
        networkMonitor.start(queue: DispatchQueue(label: "com.hopworld.network-monitor"))
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.networkRecovery.willSleep() }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.networkRecovery.didWake()
                self?.retryLibraryPersistenceIfNeeded()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.retryLibraryPersistenceIfNeeded() }
            .store(in: &cancellables)
    }

    private func startCodexUsageMonitoring() {
        codexUsageMonitor.onSnapshot = { [weak self] snapshot in
            self?.codexNotifications.observe(snapshot)
        }
        Publishers.CombineLatest(connection.$state.map(\.status).removeDuplicates(),
                                 $settings.map { ($0.httpHost, $0.httpPort) }.removeDuplicates { $0 == $1 })
            .sink { [weak self] status, proxy in
                guard let self else { return }
                var url = URLComponents()
                url.scheme = "http"
                url.host = ["0.0.0.0", "::"].contains(proxy.0) ? "127.0.0.1" : proxy.0
                url.port = proxy.1
                self.codexUsageMonitor.proxyURL = url.url
                self.codexUsageMonitor.proxyConnected = status == .connected
                if status == .connected { Task { await self.codexUsageMonitor.refresh() } }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in Task { await self?.codexUsageMonitor.refresh() } }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in Task { await self?.codexUsageMonitor.refresh() } }
            .store(in: &cancellables)
    }

    deinit {
        applicationHealthTask?.cancel()
        codexInviteTask?.cancel()
        applicationHealthSwitchTask?.cancel()
        if let backgroundActivity { ProcessInfo.processInfo.endActivity(backgroundActivity) }
        networkMonitor.cancel()
    }

    /// Apply the persisted startup policy after stale proxy/VPN state has been
    /// cleaned up. This is also the path used for each fresh Xcode Run.
    private func connectOnLaunchIfNeeded() async {
        guard !isTerminating, connectionRequestGeneration == 0 else { return }
        let previouslySelectedID = connection.state.currentNodeID
        let autoSelectEnabled = connection.state.autoSelectEnabled
        connection.state = ConnectionState(autoSelectEnabled: autoSelectEnabled)
        connection.state.status = .disconnected

        // 启动设置优先于上次会话的恢复／手动断开标记。
        switch settings.connectOnLaunch {
        case .none:
            userStoppedConnection = true
            persist()
            return
        case .fastest:
            logger.info("启动自动连接：自动优选", category: .network)
            await connectWithAutoSelect()
            persist()
            return
        case .lastNode:
            let lastID = startupConnectionIntent.lastConnectedNodeID ?? recentNodeIDs.first ?? previouslySelectedID
            guard let target = lastID.flatMap(restorableConnectedNode) else {
                persist()
                return
            }
            logger.info("启动自动连接：\(self.settings.nodeDisplayTitle(target))", category: .network)
            await connect(to: target)
            persist()
        }
    }

    /// “连接上次节点”恢复指定节点，不套用自动优选的国家筛选。
    private func restorableConnectedNode(_ id: UUID) -> ProxyNode? {
        nodes.first { $0.id == id && $0.enabled && !$0.pendingRemoval && !settings.isTemporarilyBlocked($0.id) }
    }

    /// Retry Keychain / disk read without restarting the app.
    func retryLoadLibrary() {
        do {
            let snapshot = try store.reloadLibrary()
            nodes = snapshot.nodes
            subscriptions = snapshot.subscriptions
            updateLogs = snapshot.updateLogs
            countryGroups = CountryResolver.group(nodes.filter { !$0.pendingRemoval })
            libraryAvailable = true
            persistenceError = nil
            if store.recoveredLibraryBackup {
                statusBanner = "数据文件损坏，已恢复上一次完整保存"
            } else {
                statusBanner = "节点与订阅读取成功"
            }
            startScheduler()
            logger.info("数据重新读取成功：节点 \(nodes.count)，订阅 \(subscriptions.count)")
        } catch {
            libraryAvailable = false
            persistenceError = "节点与订阅读取失败：\(error.localizedDescription)"
            logger.error(persistenceError!)
        }
    }

    private func warnUnsavedIfLibraryLocked() {
        guard !libraryAvailable else { return }
        statusBanner = "更改未保存：本地数据尚未读取成功，请点顶部「重新读取」"
    }

    func exportLibraryBackup(
        passphrase: String,
        includeCredentials: Bool,
        subscriptionIDs: Set<UUID>? = nil,
        includeManualNodes: Bool = true,
        includeSettings: Bool = false
    ) throws -> Data {
        let snapshot = LibrarySnapshot(nodes: nodes, subscriptions: subscriptions, updateLogs: updateLogs)
        return try LibraryBackup.export(
            snapshot: snapshot,
            passphrase: passphrase,
            includeCredentials: includeCredentials,
            subscriptionIDs: subscriptionIDs,
            includeManualNodes: includeManualNodes,
            settings: includeSettings ? settings : nil
        )
    }

    func importLibraryBackup(from data: Data, passphrase: String, replaceExisting: Bool) throws {
        let imported = try LibraryBackup.importBackup(from: data, passphrase: passphrase)
        let library = imported.snapshot
        let hasLibrary = !library.nodes.isEmpty || !library.subscriptions.isEmpty
        if hasLibrary {
            guard replaceExisting || nodes.isEmpty else {
                throw LibraryBackupError.requiresReplaceConfirmation
            }
            nodes = library.nodes
            subscriptions = library.subscriptions
            updateLogs = library.updateLogs
            for index in nodes.indices {
                KeychainStore.storeNodeCredentials(&nodes[index])
            }
            countryGroups = CountryResolver.group(nodes.filter { !$0.pendingRemoval })
            libraryAvailable = true
            persistenceError = nil
            if imported.settings == nil {
                persist()
            }
            startScheduler()
        }
        if let restored = imported.settings {
            updateSettings { $0 = restored }
        }
        var parts: [String] = []
        if hasLibrary { parts.append("\(nodes.count) 个节点、\(subscriptions.count) 个订阅") }
        if imported.settings != nil { parts.append("应用配置") }
        statusBanner = parts.isEmpty ? "备份已恢复" : "已从备份恢复 \(parts.joined(separator: "，"))"
    }

    func load() {
        // Perform startup migrations on a local value. Mutating @Published nodes
        // element-by-element used to emit hundreds of changes and rebuild every
        // country group for each of the 600+ loaded nodes before the first window.
        var loadedNodes: [ProxyNode] = []
        do {
            let snapshot = try store.loadLibrary()
            loadedNodes = snapshot.nodes
            subscriptions = snapshot.subscriptions
            updateLogs = snapshot.updateLogs
            libraryAvailable = true
            if store.recoveredLibraryBackup {
                statusBanner = "数据文件损坏，已恢复上一次完整保存；损坏文件已保留"
                logger.warning("已从加密备份恢复节点与订阅，最近一次修改可能需要重新操作")
            }
        } catch {
            libraryAvailable = false
            subscriptions = []
            updateLogs = []
            loadedNodes = []
            persistenceError = "节点与订阅读取失败：\(error.localizedDescription)"
            logger.error(persistenceError!)
        }
        settings = store.loadSettings()
        applyTheme()
        // Ad-hoc builds cannot start the Packet Tunnel — fall back to system proxy.
        if settings.connectionCaptureMode == .systemVPN, !HopWorldAppGroup.isSystemVPNAvailable {
            settings.connectionCaptureMode = .systemProxy
            store.saveSettings(settings)
        }
        // Invalidate CONNECT-only "可用" results so UI matches real HTTPS connectability.
        if !settings.httpsProbeMigrated {
            for index in loadedNodes.indices {
                if loadedNodes[index].lastTestStatus.isUsable {
                    loadedNodes[index].lastTestStatus = .untested
                    loadedNodes[index].lastTestErrorMessage = nil
                    loadedNodes[index].lastLatency = nil
                    loadedNodes[index].lastTestDate = nil
                }
            }
            settings.httpsProbeMigrated = true
            store.saveSettings(settings)
        }
        // Share links often set security=tls while still providing REALITY pbk/sid.
        var realityFixed = 0
        for index in loadedNodes.indices {
            if let key = loadedNodes[index].publicKey, !key.isEmpty, loadedNodes[index].security != .reality {
                loadedNodes[index].security = .reality
                loadedNodes[index].nodeFingerprint = NodeFingerprint.make(from: loadedNodes[index])
                loadedNodes[index].lastTestErrorMessage = nil
                if loadedNodes[index].lastTestStatus == .unavailable {
                    loadedNodes[index].lastTestStatus = .untested
                    loadedNodes[index].lastLatency = nil
                }
                realityFixed += 1
            }
        }
        if realityFixed > 0 {
            logger.info("已修正 \(realityFixed) 个误标为 TLS 的 REALITY 节点")
        }
        // Backfill country from remark (_CN_ 中国 / 🇪🇸 …) so filters aren't stuck in「其他」.
        var countryFixed = 0
        for index in loadedNodes.indices {
            let before = loadedNodes[index].countryCode
            CountryResolver.applyNameHeuristics(to: &loadedNodes[index])
            if loadedNodes[index].countryCode != before, loadedNodes[index].countryCode != nil {
                countryFixed += 1
            }
        }
        if countryFixed > 0 {
            logger.info("已从节点名称补全 \(countryFixed) 个国家信息")
        }
        // 按当前延迟阈值重算可用档次（改阈值后无需重测即可对齐）。
        var tierFixed = 0
        for index in loadedNodes.indices {
            let before = loadedNodes[index].lastTestStatus
            loadedNodes[index].refreshLatencyTier()
            if loadedNodes[index].lastTestStatus != before {
                tierFixed += 1
            }
        }
        if tierFixed > 0 {
            logger.info("已按当前阈值重算 \(tierFixed) 个节点延迟档次")
        }
        // 启动时清掉异常残留的「测试中」（上次测速中断）。
        var testingFixed = 0
        for index in loadedNodes.indices where loadedNodes[index].lastTestStatus == .testing {
            loadedNodes[index].lastTestStatus = .untested
            loadedNodes[index].lastTestErrorMessage = nil
            loadedNodes[index].lastLatency = nil
            testingFixed += 1
        }
        if testingFixed > 0 {
            logger.info("已将 \(testingFixed) 个卡住的「测试中」恢复为未测试")
        }
        if !settings.testSpeedTuned {
            settings.testConcurrency = max(settings.testConcurrency, 16)
            settings.testSpeedTuned = true
            store.saveSettings(settings)
        }
        connection.state = store.loadConnectionState()
        startupConnectionIntent = store.loadStartupConnectionIntent()
        userStoppedConnection = settings.connectOnLaunch == .none
        pinnedNodeIDs = store.loadPinnedNodeIDs()
        dailyUsage = store.loadDailyUsage().rolledForwardToToday()
        refreshNetworkName()
        var localizedCities = false
        for index in loadedNodes.indices {
            guard var metadata = loadedNodes[index].exitMetadata else { continue }
            metadata.countryCode = metadata.countryCode ?? loadedNodes[index].countryCode
            if settings.showChineseNodeMetadata {
                metadata.localizedCity = ChineseCityCatalog.shared.name(for: metadata.city, countryCode: metadata.countryCode,
                    region: metadata.region, latitude: metadata.latitude, longitude: metadata.longitude)
                    ?? ChineseCityCatalog.chineseName(metadata.localizedCity)
            }
            if metadata != loadedNodes[index].exitMetadata {
                loadedNodes[index].exitMetadata = metadata
                localizedCities = true
            }
        }
        nodes = loadedNodes
        countryGroups = CountryResolver.group(loadedNodes.filter { !$0.pendingRemoval })
        logger.minimumLevel = settings.logLevel
        if localizedCities, libraryAvailable { persist() }
        if libraryAvailable {
            logger.info("跃界已启动，节点 \(nodes.count)，订阅 \(subscriptions.count)")
        } else {
            logger.warning("跃界已启动，但数据尚未读取，已暂停自动更新和自动连接；列表为空不代表原数据被删除")
        }
    }

    func persist() {
        if libraryAvailable {
            store.saveLibrary(LibrarySnapshot(nodes: nodes, subscriptions: subscriptions,
                                              updateLogs: Array(updateLogs.prefix(500)))) { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    let previousError = self.persistenceError
                    self.persistenceError = error
                    if let error {
                        if error != previousError { self.logger.error(error) }
                        self.scheduleLibrarySaveRetry()
                    } else {
                        self.librarySaveRetryTask?.cancel()
                        self.librarySaveRetryTask = nil
                        self.librarySaveRetryAttempt = 0
                        if previousError != nil {
                            self.logger.info("节点与订阅重新保存成功，本地数据访问已恢复")
                        }
                    }
                }
            }
        }
        store.saveSettings(settings)
        store.saveConnectionState(connection.state)
        store.savePinnedNodeIDs(pinnedNodeIDs)
        store.saveDailyUsage(dailyUsage)
    }

    private func scheduleLibrarySaveRetry() {
        let delays: [UInt64] = [2, 5, 15, 30, 60]
        guard !isTerminating, libraryAvailable, librarySaveRetryTask == nil,
              librarySaveRetryAttempt < delays.count else { return }
        let delay = delays[librarySaveRetryAttempt] * 1_000_000_000
        librarySaveRetryAttempt += 1
        librarySaveRetryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) }
            catch { return }
            guard !Task.isCancelled, let self else { return }
            self.librarySaveRetryTask = nil
            guard !self.isTerminating, self.libraryAvailable, self.persistenceError != nil else { return }
            // Retry the current in-memory library so edits made during the wait are retained.
            self.persist()
        }
    }

    private func retryLibraryPersistenceIfNeeded() {
        guard !isTerminating else { return }
        if !libraryAvailable {
            retryLoadLibrary()
        } else if persistenceError != nil {
            librarySaveRetryTask?.cancel()
            librarySaveRetryTask = nil
            librarySaveRetryAttempt = 0
            persist()
        }
    }

    /// Backfill cached usable nodes without reconnecting or rerunning their speed tests.
    func refreshMissingExitTypes(nodeIDs: [UUID]) async {
        var attemptedIPs = Set<String>()
        for id in nodeIDs {
            guard !Task.isCancelled, !isTerminating else { return }
            guard let node = nodes.first(where: { $0.id == id }), node.enabled, !node.pendingRemoval,
                  node.resolvedTestStatus.isUsable, let metadata = node.exitMetadata,
                  metadata.networkType == nil, attemptedIPs.insert(metadata.ip).inserted else { continue }
            let info = await ExitIPTester.lookupExitInfo(ip: metadata.ip)
            guard !Task.isCancelled, !isTerminating else { return }
            if let type = info?.networkType {
                var updated = nodes
                var changed = false
                for index in updated.indices where updated[index].enabled && !updated[index].pendingRemoval
                    && updated[index].resolvedTestStatus.isUsable
                    && updated[index].exitMetadata?.ip == metadata.ip && updated[index].exitMetadata?.networkType == nil {
                    updated[index].exitMetadata?.networkType = type
                    changed = true
                }
                if changed {
                    nodes = updated
                    if connection.state.status == .connected, connection.state.exitIP == metadata.ip {
                        connection.state.recordExitIP(metadata.ip, type: type)
                    }
                    persist()
                }
            }
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
        }
    }

    private func localizeCity(nodeID: UUID, metadata: NodeExitMetadata, eligible: Bool? = nil) {
        cityLocalizationTasks.removeValue(forKey: nodeID)?.cancel()
        let node = nodes.first { $0.id == nodeID }
        guard !isTerminating, settings.showChineseNodeMetadata,
              eligible ?? node.map({ settings.shouldResolveChineseCity(for: $0) }) ?? false,
              metadata.localizedCity == nil else { return }
        cityLocalizationTasks[nodeID] = Task { [weak self] in
            guard !Task.isCancelled, let node = self?.nodes.first(where: { $0.id == nodeID }),
                  self?.settings.shouldResolveChineseCity(for: node) == true else { return }
            let localized = await ChineseCityResolver.shared.resolve(metadata) { @MainActor [weak self] in
                guard let self, let node = self.nodes.first(where: { $0.id == nodeID }) else { return false }
                return !self.isTerminating && self.settings.shouldResolveChineseCity(for: node) && node.exitMetadata?.hasSameCityObservation(as: metadata) == true
            }
            guard let self, !Task.isCancelled else { return }
            self.cityLocalizationTasks[nodeID] = nil
            guard !self.isTerminating, localized != metadata,
                  let index = self.nodes.firstIndex(where: { $0.id == nodeID }),
                  self.settings.shouldResolveChineseCity(for: self.nodes[index]),
                  self.nodes[index].exitMetadata?.hasSameCityObservation(as: metadata) == true else { return }
            var updated = self.nodes
            updated[index].exitMetadata?.localizedCity = localized.localizedCity
            self.nodes = updated
            self.persist()
        }
    }

    private func refreshChineseCities() {
        for node in nodes where settings.shouldResolveChineseCity(for: node) {
            if let metadata = node.exitMetadata { localizeCity(nodeID: node.id, metadata: metadata) }
        }
    }

    private func bind() {
        NotificationCenter.default.publisher(for: ChineseCityLibrary.didInstall)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshChineseCities() }
            .store(in: &cancellables)
        refreshChineseCities()
        connection.onExitMetadata = { [weak self] nodeID, metadata in
            guard let self, let index = self.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
            let metadata = metadata.retainingKnownDetails(from: self.nodes[index].exitMetadata)
            if self.nodes[index].exitMetadata == metadata {
                if self.cityLocalizationTasks[nodeID] == nil { self.localizeCity(nodeID: nodeID, metadata: metadata) }
                return
            }
            var updated = self.nodes
            updated[index].exitMetadata = metadata
            self.nodes = updated
            self.persist()
            self.localizeCity(nodeID: nodeID, metadata: metadata)
        }
        connection.isNodeTemporarilyBlocked = { [weak self] id in
            self?.settings.isTemporarilyBlocked(id) == true
        }
        connection.rankAutomaticCandidates = { [weak self] candidates in
            self?.automaticallyRankedNodes(candidates) ?? candidates
        }
        connection.onNodeConnectionFailed = { [weak self] id in
            guard let self, let index = self.nodes.firstIndex(where: { $0.id == id }) else { return }
            var updated = self.nodes
            updated[index].lastTestStatus = .unavailable
            updated[index].lastTestErrorMessage = nil
            updated[index].lastTestDate = Date()
            updated[index].unavailableSince = updated[index].unavailableSince ?? Date()
            self.nodes = updated
            self.persist()
        }
        connection.onLiveLatencySample = { [weak self] in
            self?.checkConnectedNodeEligibility(liveSample: true)
        }
        connection.$state
            .sink { [weak self] state in
                if !state.autoSelectEnabled {
                    self?.unexpectedReconnectTask?.cancel()
                    self?.eligibilitySwitchTask?.cancel()
                    self?.connection.setAutomaticRecoveryPending(false)
                }
                if state.status != .connected || !state.autoSelectEnabled {
                    self?.recoveryHealthySince = nil
                    self?.unhealthySince = nil
                    self?.unhealthyNodeID = nil
                }
            }
            .store(in: &cancellables)
        connection.onUnexpectedDisconnect = { [weak self] failedNodeID, reason, allowsRecovery in
            guard let self else { return }
            guard allowsRecovery else {
                // Pause this run without changing the saved startup recovery intent.
                self.userStoppedConnection = true
                self.connectionRequestGeneration += 1
                self.unexpectedReconnectTask?.cancel()
                self.eligibilitySwitchTask?.cancel()
                self.applicationHealthSwitchTask?.cancel()
                self.connection.setAutomaticRecoveryPending(false)
                self.connection.state.lastError = "\(reason)；已暂停自动重连，请手动连接恢复"
                self.statusBanner = "TUN 辅助服务已停止，已暂停自动重连；请手动连接恢复"
                self.logger.warning("TUN 停止后已暂停自动重连；原因：\(reason)；请手动连接恢复", category: .network)
                return
            }
            if self.applicationHealthSwitchTask != nil {
                self.applicationHealthSwitchTask?.cancel()
                self.applicationHealthSwitchRunID = UUID()
                self.applicationHealthSwitchTask = nil
            }
            self.scheduleUnexpectedReconnect(avoiding: failedNodeID, reason: reason)
        }

        // Accumulate per-session traffic deltas into the daily total shown on the dashboard.
        connection.$state
            .map { ($0.sessionUploadBytes, $0.sessionDownloadBytes) }
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] upload, download in
                self?.accumulateDailyTraffic(upload: upload, download: download)
            }
            .store(in: &cancellables)

        // Coalesce bulk mutations into one country regroup. This preserves live
        // dashboard updates without O(n²) work during imports or mass edits.
        $nodes
            .dropFirst()
            .throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] nodes in
                self?.countryGroups = CountryResolver.group(nodes.filter { !$0.pendingRemoval })
            }
            .store(in: &cancellables)

        // Forward connection changes that matter for menus / chrome — NOT live traffic.
        // Traffic updates every ~1s while connected; rebuilding MenuBarExtra closes「节点」submenu.
        Publishers.CombineLatest3(
            connection.$state,
            connection.$isBusy,
            connection.$failoverStatus
        )
        .map { state, busy, failover in
            ConnectionUIFingerprint(
                status: state.status,
                currentNodeID: state.currentNodeID,
                currentCountryCode: state.currentCountryCode,
                currentCountryName: state.currentCountryName,
                latency: state.latency,
                exitIP: state.exitIP,
                exitCountry: state.exitCountry,
                lastError: state.lastError,
                autoSelectEnabled: state.autoSelectEnabled,
                protocolType: state.protocolType,
                isBusy: busy,
                failoverStatus: failover
            )
        }
        .removeDuplicates()
        .sink { [weak self] _ in self?.objectWillChange.send() }
        .store(in: &cancellables)

        Publishers.CombineLatest4(testManager.$phase, testManager.$isTesting,
                                  testManager.$appProbePhase, testManager.$showFinishedAlert)
            .removeDuplicates { old, new in
                old.0 == new.0 && old.1 == new.1 && old.2 == new.2 && old.3 == new.3
            }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        subscriptionManager.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        DistributedNotificationCenter.default()
            .publisher(for: Notification.Name("com.apple.screenIsLocked"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.screenLockDisconnect.configure(
                    enabled: self.settings.disconnectOnScreenLock,
                    delaySeconds: TimeInterval(max(0, self.settings.screenLockDisconnectDelayMinutes)) * 60
                )
                self.screenLockDisconnect.screenLocked()
            }
            .store(in: &cancellables)

        DistributedNotificationCenter.default()
            .publisher(for: Notification.Name("com.apple.screenIsUnlocked"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.screenLockDisconnect.screenUnlocked()
                self?.retryLibraryPersistenceIfNeeded()
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.screenLockDisconnect.configure(
                    enabled: self.settings.disconnectOnScreenLock,
                    delaySeconds: TimeInterval(max(0, self.settings.screenLockDisconnectDelayMinutes)) * 60
                )
            }
            .store(in: &cancellables)
    }

    /// Fields that should refresh app-wide UI (excluding Mbps / session bytes).
    private struct ConnectionUIFingerprint: Equatable {
        var status: ConnectionStatus
        var currentNodeID: UUID?
        var currentCountryCode: String?
        var currentCountryName: String?
        var latency: Int?
        var exitIP: String?
        var exitCountry: String?
        var lastError: String?
        var autoSelectEnabled: Bool
        var protocolType: ProxyProtocolType?
        var isBusy: Bool
        var failoverStatus: String?
    }

    // MARK: - Nodes / Subscriptions

    func addSubscription(
        name: String,
        url: String,
        urlMode: SubscriptionURLMode,
        template: String?,
        autoUpdate: Bool = true,
        fetchAfterInsert: Bool = true
    ) {
        var sub = Subscription(
            name: name.isEmpty ? URL(string: url)?.host ?? "订阅" : name,
            originalURL: url,
            urlTemplate: template,
            resolvedURL: url,
            urlMode: urlMode,
            sourceKind: .remoteURL,
            autoUpdate: autoUpdate,
            updateHour: settings.defaultUpdateHour,
            updateMinute: settings.defaultUpdateMinute,
            timeZoneID: settings.defaultTimeZoneID,
            urlDateTimeZoneID: settings.defaultTimeZoneID,
            fallbackDays: settings.defaultFallbackDays,
            updateMode: settings.defaultUpdateMode
        )
        sub.nextUpdateAt = subscriptionManager.computeNextUpdateAt(for: sub)
        subscriptions.insert(sub, at: 0)
        persist()
        warnUnsavedIfLibraryLocked()
        if fetchAfterInsert {
            Task { await refreshSubscription(sub.id) }
        }
    }

    /// Create a subscription group from pasted ss/vless/vmess/trojan share links.
    func addShareLinkSubscription(name: String, shareText: String) {
        let trimmed = shareText.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = NodeLinkParser.parseLines(trimmed)
        guard !preview.validNodes.isEmpty else {
            statusBanner = "未解析到有效节点" + preview.skippedLinksSummary
            return
        }

        let displayName: String = {
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !n.isEmpty { return n }
            return "分享节点 \(preview.validNodes.count)"
        }()

        let sub = Subscription(
            name: displayName,
            originalURL: "share://links",
            resolvedURL: "share://links",
            urlMode: .fixed,
            sourceKind: .shareLinks,
            shareLinksText: trimmed,
            autoUpdate: false,
            updateInterval: .manual,
            updateMode: settings.defaultUpdateMode,
            testAfterUpdate: true
        )
        subscriptions.insert(sub, at: 0)
        let imported = subscriptionManager.importShareLinks(
            trimmed,
            sourceName: displayName,
            subscriptionID: sub.id
        )
        guard !imported.isEmpty else {
            subscriptions.removeAll { $0.id == sub.id }
            statusBanner = "未解析到有效节点（支持 ss / vless / vmess / trojan / hysteria2）"
            return
        }

        nodes.append(contentsOf: imported)
        if let index = subscriptions.firstIndex(where: { $0.id == sub.id }) {
            subscriptions[index].nodeCount = imported.count
            subscriptions[index].lastSuccessAt = Date()
            subscriptions[index].lastError = nil
            subscriptions[index].statusMessage = "已导入 \(imported.count) 个分享节点" + preview.skippedLinksSummary
        }
        persist()
        warnUnsavedIfLibraryLocked()
        focusNodeList(source: .subscription(sub.id), nodeID: imported.first?.id, openDetail: false)
        statusBanner = "已导入 \(imported.count) 个节点，已在节点列表中显示"
        statusBanner = (statusBanner ?? "") + preview.skippedLinksSummary
        scheduleImportedNodeTests(ids: Set(imported.map(\.id)))
    }

    /// Combine stored share links with newly pasted lines according to the subscription merge mode.
    func mergeShareLinksText(existing: String?, pasted: String, mode: SubscriptionUpdateMode) -> String? {
        let incoming = NodeLinkParser.extractShareLinks(from: pasted)
        guard !incoming.isEmpty else { return nil }
        switch mode {
        case .overwrite:
            return incoming.joined(separator: "\n")
        case .merge, .smartMerge:
            var combined = NodeLinkParser.extractShareLinks(from: existing ?? "")
            var seen = Set(combined)
            for link in incoming where !seen.contains(link) {
                combined.append(link)
                seen.insert(link)
            }
            return combined.joined(separator: "\n")
        }
    }

    /// Apply pasted share links to an existing share-link subscription (no remote fetch).
    func applyShareLinkPaste(subscriptionID: UUID, pastedText: String) async {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscriptionID }) else { return }
        var sub = subscriptions[index]
        guard sub.isShareLinksBundle else { return }
        let preview = NodeLinkParser.parseLines(pastedText)
        guard !preview.validNodes.isEmpty else {
            statusBanner = "未解析到有效节点" + preview.skippedLinksSummary
            return
        }
        guard let composed = mergeShareLinksText(
            existing: sub.shareLinksText,
            pasted: pastedText,
            mode: sub.updateMode
        ) else { return }
        sub.shareLinksText = composed
        sub.testAfterUpdate = true
        subscriptions[index] = sub
        persist()
        statusBanner = "正在处理分享链接…"
        await refreshSubscription(subscriptionID)
    }

    func removeSubscription(_ id: UUID) {
        subscriptionTestPromptIDs.remove(id)
        pendingSubscriptionTestPromptIDs.remove(id)
        subscriptions.removeAll { $0.id == id }
        nodes.removeAll { $0.subscriptionID == id }
        if viewingSubscriptionID == id { viewingSubscriptionID = nil }
        if editingSubscriptionID == id { editingSubscriptionID = nil }
        persist()
    }

    func updateSubscription(_ subscription: Subscription, refreshAfterSave: Bool = false) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) else { return }
        let previous = subscriptions[index]
        var updated = subscription
        updated.cleanupHistory = previous.cleanupHistory
        updated.nextUpdateAt = subscriptionManager.computeNextUpdateAt(for: updated)
        subscriptions[index] = updated
        persist()
        if updated.autoCleanupUnavailableNodes != previous.autoCleanupUnavailableNodes {
            logger.info(
                "\(updated.name)：长期不可用节点自动清理已\(updated.autoCleanupUnavailableNodes == true ? "开启" : "关闭")",
                category: .subscription
            )
        }
        if updated.autoCleanupUnavailableNodes == true && previous.autoCleanupUnavailableNodes != true {
            cleanupUnavailableNodes(subscriptionID: updated.id, automatic: true)
        }
        if refreshAfterSave {
            Task { await refreshSubscription(updated.id) }
        }
    }

    func subscription(for id: UUID) -> Subscription? {
        subscriptions.first { $0.id == id }
    }

    func logs(for subscriptionID: UUID, limit: Int = 20) -> [SubscriptionUpdateLog] {
        Array(updateLogs.filter { $0.subscriptionID == subscriptionID }.prefix(limit))
    }

    func currentSubscriptionShareLinks(_ subscription: Subscription) -> [String] {
        let fingerprints = Set(nodes.filter {
            $0.subscriptionID == subscription.id && !$0.pendingRemoval
        }.map { $0.nodeFingerprint ?? NodeFingerprint.make(from: $0) })
        return NodeLinkParser.extractShareLinks(from: subscription.shareLinksText ?? "").filter { link in
            NodeLinkParser.parseLines(link).validNodes.contains {
                fingerprints.contains(NodeFingerprint.make(from: $0))
            }
        }
    }

    func refreshSubscription(_ id: UUID, focusInNodeList: Bool = false, fetchYesterdayFirst: Bool = false, automatic: Bool = false) async {
        guard !isTerminating else { return }
        guard let sub = subscriptions.first(where: { $0.id == id }) else { return }
        if !libraryAvailable && !sub.isShareLinksBundle {
            statusBanner = "本地数据未就绪，无法拉取远程订阅"
            return
        }
        if subscriptionRefreshInProgress {
            if let index = pendingSubscriptionRefresh.firstIndex(where: { $0.id == id }) {
                if focusInNodeList {
                    pendingSubscriptionRefresh[index].focusInNodeList = true
                }
                pendingSubscriptionRefresh[index].fetchYesterdayFirst = pendingSubscriptionRefresh[index].fetchYesterdayFirst || fetchYesterdayFirst
                pendingSubscriptionRefresh[index].automatic = pendingSubscriptionRefresh[index].automatic && automatic
            } else {
                pendingSubscriptionRefresh.append(
                    PendingSubscriptionRefresh(id: id, focusInNodeList: focusInNodeList, fetchYesterdayFirst: fetchYesterdayFirst, automatic: automatic)
                )
            }
            return
        }
        guard subscriptionManager.updateState == .idle else {
            statusBanner = "订阅地址测试进行中，请稍后再更新"
            return
        }
        subscriptionRefreshInProgress = true
        defer {
            subscriptionRefreshInProgress = false
            presentSubscriptionTestPromptIfNeeded()
        }
        var next: PendingSubscriptionRefresh? = PendingSubscriptionRefresh(
            id: id, focusInNodeList: focusInNodeList, fetchYesterdayFirst: fetchYesterdayFirst, automatic: automatic
        )
        // Drain on this task so a batch waits for queued refreshes and never publishes midway.
        while let request = next, !isTerminating {
            await performSubscriptionRefresh(request)
            next = pendingSubscriptionRefresh.isEmpty ? nil : pendingSubscriptionRefresh.removeFirst()
        }
    }

    private func performSubscriptionRefresh(_ request: PendingSubscriptionRefresh) async {
        let id = request.id
        let focusInNodeList = request.focusInNodeList
        let fetchYesterdayFirst = request.fetchYesterdayFirst
        let automatic = request.automatic
        guard !isTerminating, let sub = subscription(for: id) else { return }
        if !libraryAvailable && !sub.isShareLinksBundle {
            statusBanner = "本地数据未就绪，无法拉取远程订阅"
            return
        }
        let initialNodes = nodes.filter { $0.subscriptionID == id }
        let offsets = sub.initialFetchOffsets(includeYesterday: fetchYesterdayFirst)
        var latestFailure: String?
        for offset in offsets {
            guard let sub = subscriptions.first(where: { $0.id == id }) else { return }
            let baseline = nodes.filter { $0.subscriptionID == id }
            let previousNodeIDs = Set(baseline.map(\.id))
            let previousDigests = Dictionary(uniqueKeysWithValues: baseline.map {
                ($0.id, NodeFingerprint.make(from: $0))
            })
            let preserveIDs: Set<UUID> = {
                if let id = connection.state.currentNodeID { return [id] }
                return []
            }()
            var fetchInput = sub
            if fetchYesterdayFirst, sub.urlMode == .dateTemplate {
                fetchInput.dateOffset = offset
                fetchInput.fallbackDays = 0
            }
            let (updated, proposedNodes, log) = await subscriptionManager.update(
                fetchInput, existingNodes: nodes, preserveNodeIDs: preserveIDs
            )
            guard !isTerminating else { return }
            // MainActor is reentrant across the download. Never reuse its old index,
            // resurrect a deleted subscription or overwrite a newer edit.
            guard let index = subscriptions.firstIndex(where: { $0.id == id }) else {
                statusBanner = "订阅已删除，本次下载结果未应用"
                return
            }
            guard subscriptions[index].hasSameFetchSource(as: sub) else {
                statusBanner = "订阅地址已修改，本次下载结果未应用，请重新更新"
                return
            }
            guard let committed = SubscriptionMerger.commitRefresh(
                subscriptionID: id, baseline: baseline, proposed: proposedNodes, current: nodes,
                preserveNodeIDs: connection.state.currentNodeID.map { [$0] } ?? []
            ) else {
                statusBanner = "更新期间节点发生变化，已保留最新修改，请重新更新订阅"
                return
            }
            var merged = updated
            let current = subscriptions[index]
            merged.dateOffset = current.dateOffset
            merged.fallbackDays = current.fallbackDays
            merged.name = current.name
            merged.isEnabled = current.isEnabled
            merged.autoUpdate = current.autoUpdate
            merged.updateHour = current.updateHour
            merged.updateMinute = current.updateMinute
            merged.updateInterval = current.updateInterval
            merged.timeZoneID = current.timeZoneID
            merged.updateMode = current.updateMode
            merged.testAfterUpdate = current.testAfterUpdate
            merged.removeUnavailableNodes = current.removeUnavailableNodes
            merged.autoCleanupUnavailableNodes = current.autoCleanupUnavailableNodes
            merged.unavailableCleanupDays = current.unavailableCleanupDays
            merged.cleanupHistory = current.cleanupHistory
            merged.smartMergeMissingLimit = current.smartMergeMissingLimit
            merged.nextUpdateAt = subscriptionManager.computeNextUpdateAt(for: merged)
            subscriptions[index] = merged
            nodes = committed
            updateLogs.insert(log, at: 0)
            if updateLogs.count > 500 { updateLogs = Array(updateLogs.prefix(500)) }
            latestFailure = log.success ? nil : merged.lastError ?? log.errorMessage ?? "未取得有效节点"
            persist()
            markPendingConfigUpdates(subscriptionID: id, previousDigests: previousDigests)

            if merged.testAfterUpdate, log.success, automatic || merged.isShareLinksBundle {
                let targets = nodes.filter { node in
                    guard node.subscriptionID == id, node.enabled, !node.pendingRemoval else { return false }
                    if merged.isShareLinksBundle { return !previousNodeIDs.contains(node.id) }
                    if node.lastTestStatus == .untested { return true }
                    if !previousNodeIDs.contains(node.id) { return true }
                    if let before = previousDigests[node.id],
                       before != NodeFingerprint.make(from: node) {
                        return true
                    }
                    return node.pendingConfigUpdate
                }
                scheduleImportedNodeTests(ids: Set(targets.map(\.id)))
            }

            if focusInNodeList, log.success {
                let imported = nodes.filter { $0.subscriptionID == id && !$0.pendingRemoval }
                if !imported.isEmpty {
                    focusNodeList(source: .subscription(id), nodeID: imported.first?.id, openDetail: false)
                    statusBanner = "已导入 \(imported.count) 个节点，已在节点列表中显示"
                }
            } else if log.success, merged.isShareLinksBundle {
                statusBanner = merged.statusMessage
            } else if !log.success, let error = merged.lastError ?? log.errorMessage {
                statusBanner = error
            }
        }
        if let latestFailure, let current = subscriptions.first(where: { $0.id == id }) {
            let retry = current.isEnabled && current.autoUpdate
                ? current.nextRetryAt.map { "；下次重试：\($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
                : ""
            logger.warning("订阅 \(current.name) 更新失败，保留上次数据：\(latestFailure)\(retry)", category: .subscription)
        } else if !automatic, let current = subscription(for: id), !current.isShareLinksBundle,
                  SubscriptionMerger.hasNodeChanges(before: initialNodes, after: nodes.filter { $0.subscriptionID == id }) {
            pendingSubscriptionTestPromptIDs.insert(id)
        }
    }

    private func presentSubscriptionTestPromptIfNeeded(selectAllSubscriptions: Bool = false) {
        guard !isRefreshingAllSubscriptions, !subscriptionRefreshInProgress, !isTerminating else { return }
        let ids = pendingSubscriptionTestPromptIDs.filter { subscription(for: $0) != nil }
        pendingSubscriptionTestPromptIDs.removeAll()
        guard !ids.isEmpty else { return }
        subscriptionTestPromptSelectsAll = selectAllSubscriptions
            || (!subscriptionTestPromptIDs.isEmpty && subscriptionTestPromptSelectsAll)
        subscriptionTestPromptIDs.formUnion(ids)
    }

    func refreshAllSubscriptions() async {
        guard !isTerminating, !isRefreshingAllSubscriptions else { return }
        guard !subscriptionRefreshInProgress, subscriptionManager.updateState == .idle else {
            statusBanner = "订阅更新或地址测试进行中，请稍后再更新"
            return
        }
        isRefreshingAllSubscriptions = true
        defer {
            isRefreshingAllSubscriptions = false
            presentSubscriptionTestPromptIfNeeded(selectAllSubscriptions: true)
        }
        let ids = subscriptions.filter { $0.isEnabled && !$0.isShareLinksBundle }.map(\.id)
        for id in ids {
            guard !isTerminating, !Task.isCancelled else { break }
            await refreshSubscription(id)
        }
        guard !isTerminating, !Task.isCancelled, isLibraryReady else { return }
        let beforeDeduplication = nodes
        let removedCount = removeDuplicateNodes(reportEmptyResult: false)
        if removedCount > 0 {
            let remainingIDs = Set(nodes.map(\.id))
            let removedFingerprints = Set(beforeDeduplication.filter { !remainingIDs.contains($0.id) }
                .map { $0.nodeFingerprint ?? NodeFingerprint.make(from: $0) })
            let testableNodes = nodes.filter { $0.enabled && !$0.pendingRemoval }
            let survivingSubscriptions = Set(testableNodes.filter {
                removedFingerprints.contains($0.nodeFingerprint ?? NodeFingerprint.make(from: $0))
            }.compactMap(\.subscriptionID))
            pendingSubscriptionTestPromptIDs.formUnion(survivingSubscriptions)
            pendingSubscriptionTestPromptIDs.formIntersection(Set(testableNodes.compactMap(\.subscriptionID)))
            statusBanner = "已自动删除 \(removedCount) 个重复节点（全部节点去重）"
            logger.info("全部订阅更新后，自动删除 \(removedCount) 个重复节点", category: .subscription)
        }
    }

    func testSubscriptionNodes(_ ids: Set<UUID>, selectAllSubscriptions: Bool = false) async {
        guard isLibraryReady, !isTerminating else { return }
        let ids = ids.filter { subscription(for: $0) != nil }
        guard !ids.isEmpty else { return }
        guard !testManager.isTesting else {
            statusBanner = "测速进行中，请稍后再试"
            return
        }
        let targets = nodes.filter { node in
            guard let id = node.subscriptionID, ids.contains(id) else { return false }
            return node.enabled && !node.pendingRemoval
        }
        guard !targets.isEmpty else {
            statusBanner = "当前订阅没有可测试的节点，请先更新订阅"
            return
        }
        let source: NodeListFilter.Source
        if !selectAllSubscriptions, ids.count == 1, let id = ids.first {
            source = .subscription(id)
        } else {
            source = .all
        }
        updateSettings {
            let filter = NodeListFilter.decode($0.nodeListCategoryRaw)
            $0.nodeListCategoryRaw = NodeListFilter.encode(scope: filter.scope, source: source)
        }
        await testNodes(targets, strictResults: true)
    }

    /// 当前节点列表选中的订阅范围（全部 / 某个订阅 / 手动导入）。
    var currentNodeListSource: NodeListFilter.Source {
        NodeListFilter.decode(settings.nodeListCategoryRaw).source
    }

    func importLinksFromText() {
        importLinksFromText(into: currentNodeListSource)
    }

    /// 把分享链接加入当前选中的订阅；分享链接型订阅会同时写入 `shareLinksText`，刷新后仍保留。
    func importLinksFromText(into source: NodeListFilter.Source) {
        let preview = NodeLinkParser.parseLines(importText)
        guard !preview.validNodes.isEmpty else {
            statusBanner = "未解析到有效节点" + preview.skippedLinksSummary
            return
        }

        let (subscriptionID, sourceName) = resolveImportTarget(source)
        var existingFingerprints = Set(nodes.map { $0.nodeFingerprint ?? NodeFingerprint.make(from: $0) })
        var imported = subscriptionManager.importShareLinks(
            importText,
            sourceName: sourceName,
            subscriptionID: subscriptionID
        )
        imported = imported.filter { node in
            let fp = node.nodeFingerprint ?? NodeFingerprint.make(from: node)
            return existingFingerprints.insert(fp).inserted
        }

        var refreshed = 0
        let existingIDs = preview.validNodes.compactMap { candidate -> UUID? in
            let fp = candidate.nodeFingerprint ?? NodeFingerprint.make(from: candidate)
            guard let index = nodes.firstIndex(where: {
                !$0.pendingRemoval &&
                ($0.nodeFingerprint ?? NodeFingerprint.make(from: $0)) == fp
            }) else { return nil }
            // 重复导入时刷新传输参数（尤其是 fm/FinalMask），避免旧节点缺少抗干扰配置。
            if refreshShareLinkParams(&nodes[index], from: candidate) {
                refreshed += 1
            }
            return nodes[index].id
        }

        if imported.isEmpty {
            importText = ""
            showImportLinks = false
            if refreshed > 0 {
                persist()
            }
            if let id = existingIDs.first {
                revealNode(id)
                if refreshed > 0 {
                    statusBanner = existingIDs.count == 1
                        ? "节点已存在，已更新参数（含 FinalMask）"
                        : "这些节点已存在，已更新参数并跳转"
                } else {
                    statusBanner = existingIDs.count == 1
                        ? "节点已存在，已跳转到该节点"
                        : "这些节点已存在，已跳转到其中一条"
                }
            } else {
                statusBanner = "这些节点已存在，未重复添加"
            }
            statusBanner = (statusBanner ?? "") + preview.skippedLinksSummary
            return
        }

        nodes.append(contentsOf: imported)

        if let id = subscriptionID, let index = subscriptions.firstIndex(where: { $0.id == id }) {
            if subscriptions[index].isShareLinksBundle {
                appendShareLinks(to: &subscriptions[index], from: importText)
            }
            subscriptions[index].nodeCount = nodes.filter {
                $0.subscriptionID == id && !$0.pendingRemoval
            }.count
            subscriptions[index].statusMessage = "已追加 \(imported.count) 个节点" + preview.skippedLinksSummary
            subscriptions[index].lastSuccessAt = Date()
            subscriptions[index].lastError = nil
        }

        importText = ""
        showImportLinks = false
        let listSource: NodeListFilter.Source = subscriptionID.map { .subscription($0) } ?? .manual
        if imported.count == 1, let id = imported.first?.id {
            revealNode(id)
            statusBanner = "已向「\(sourceName)」添加节点"
        } else {
            focusNodeList(source: listSource, nodeID: imported.first?.id, openDetail: false)
            statusBanner = "已向「\(sourceName)」添加 \(imported.count) 个节点（已切换到节点列表）"
        }
        statusBanner = (statusBanner ?? "") + preview.skippedLinksSummary
        persist()
        warnUnsavedIfLibraryLocked()
        scheduleImportedNodeTests(ids: Set(imported.map(\.id)))
    }

    private func scheduleImportedNodeTests(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let targets = self.nodes.filter { ids.contains($0.id) && $0.enabled && !$0.pendingRemoval }
            await self.testNodes(targets, silent: true)
        }
    }

    private func markPendingConfigUpdates(subscriptionID: UUID, previousDigests: [UUID: String]) {
        guard let currentID = connection.state.currentNodeID,
              let index = nodes.firstIndex(where: { $0.id == currentID }),
              nodes[index].subscriptionID == subscriptionID
        else { return }
        let before = previousDigests[currentID] ?? NodeFingerprint.make(from: nodes[index])
        let after = NodeFingerprint.make(from: nodes[index])
        guard before != after else { return }
        nodes[index].pendingConfigUpdate = true
        if connection.state.status == .connected {
            statusBanner = "当前连接节点参数已更新，仍使用旧配置；可立即应用或下次连接生效"
        }
    }

    func dismissPendingConfigUpdate(for nodeID: UUID? = nil) {
        let target = nodeID ?? connection.state.currentNodeID
        guard let target, let index = nodes.firstIndex(where: { $0.id == target }) else { return }
        nodes[index].pendingConfigUpdate = false
        persist()
    }

    func applyPendingConfigForCurrentNode() async {
        guard let node = currentNode, node.pendingConfigUpdate else {
            statusBanner = "当前节点没有待应用的参数更新"
            return
        }
        dismissPendingConfigUpdate(for: node.id)
        guard connection.state.status == .connected else {
            statusBanner = "已标记为下次连接时应用新参数"
            return
        }
        await connect(to: node, restrictToCountry: connectionCountryCode)
        statusBanner = "已应用节点最新参数并重连"
    }

    private func purgePendingRemovalNodes() {
        let retiring = nodes.filter(\.pendingRemoval)
        guard !retiring.isEmpty else { return }
        let ids = Set(retiring.map(\.id))
        deleteNodes(ids)
    }

    /// 切换到节点页并放宽筛选（状态=全部），避免新节点因「可用」等筛选被隐藏。
    func focusNodeList(source: NodeListFilter.Source, nodeID: UUID?, openDetail: Bool) {
        selectedSidebar = .nodes
        updateSettings {
            $0.nodeListCategoryRaw = NodeListFilter.encode(scope: .all, source: source)
        }
        if let nodeID {
            focusNodeID = nodeID
            viewingNodeID = openDetail ? nodeID : nil
        }
    }

    /// 切换到节点页，按订阅筛选、选中并滚动到指定节点，同时打开详情。
    func revealNode(_ id: UUID) {
        guard let node = nodes.first(where: { $0.id == id && !$0.pendingRemoval }) else { return }
        let source: NodeListFilter.Source = {
            if let sid = node.subscriptionID,
               subscriptions.contains(where: { $0.id == sid }) {
                return .subscription(sid)
            }
            if node.subscriptionID == nil {
                return .manual
            }
            if let name = node.sourceName, !name.isEmpty {
                return .namedSource(name)
            }
            return .all
        }()
        focusNodeList(source: source, nodeID: id, openDetail: true)
    }

    /// 用新解析结果刷新已有节点的传输/安全参数；返回是否有变更。
    @discardableResult
    private func refreshShareLinkParams(_ node: inout ProxyNode, from incoming: ProxyNode) -> Bool {
        var changed = false
        func assign<T: Equatable>(_ keyPath: WritableKeyPath<ProxyNode, T>, _ value: T) {
            if node[keyPath: keyPath] != value {
                node[keyPath: keyPath] = value
                changed = true
            }
        }
        assign(\.transport, incoming.transport)
        assign(\.security, incoming.security)
        assign(\.sni, incoming.sni)
        assign(\.host, incoming.host)
        assign(\.path, incoming.path)
        assign(\.serviceName, incoming.serviceName)
        assign(\.fingerprint, incoming.fingerprint)
        assign(\.spiderX, incoming.spiderX)
        assign(\.alpn, incoming.alpn)
        assign(\.flow, incoming.flow)
        assign(\.encryption, incoming.encryption)
        assign(\.publicKey, incoming.publicKey)
        assign(\.shortID, incoming.shortID)
        if let fm = FinalMaskCodec.normalize(incoming.finalMaskJSON) {
            assign(\.finalMaskJSON, fm)
        } else if incoming.finalMaskJSON == nil, node.finalMaskJSON != nil {
            // Keep existing fm when re-import omits it.
        }
        if changed { node.lastTestErrorMessage = nil }
        return changed
    }

    private func resolveImportTarget(_ source: NodeListFilter.Source) -> (UUID?, String) {
        switch source {
        case .all, .manual:
            return (nil, "手动导入")
        case .subscription(let id):
            if let sub = subscription(for: id) {
                return (id, sub.name)
            }
            return (id, "订阅")
        case .namedSource(let name):
            if let sub = subscriptions.first(where: { $0.name == name }) {
                return (sub.id, sub.name)
            }
            return (nil, name)
        }
    }

    private func appendShareLinks(to subscription: inout Subscription, from text: String) {
        let existing = NodeLinkParser.extractShareLinks(from: subscription.shareLinksText ?? "")
        let existingSet = Set(existing)
        let extra = NodeLinkParser.extractShareLinks(from: text).filter { !existingSet.contains($0) }
        guard !extra.isEmpty else { return }
        var combined = subscription.shareLinksText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !combined.isEmpty { combined += "\n" }
        combined += extra.joined(separator: "\n")
        subscription.shareLinksText = combined
    }

    func toggleFavorite(_ id: UUID) {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
        nodes[index].isFavorite.toggle()
        persist()
    }

    func setFavorites(_ ids: Set<UUID>, isFavorite: Bool) {
        guard !ids.isEmpty else { return }
        for index in nodes.indices where ids.contains(nodes[index].id) {
            nodes[index].isFavorite = isFavorite
        }
        persist()
        statusBanner = isFavorite ? "已收藏 \(ids.count) 个节点" : "已取消收藏 \(ids.count) 个节点"
    }

    func isPinned(_ id: UUID) -> Bool {
        pinnedNodeIDs.contains(id)
    }

    func pinNode(_ id: UUID) {
        pinnedNodeIDs.removeAll { $0 == id }
        pinnedNodeIDs.insert(id, at: 0)
        persist()
        statusBanner = "已置顶"
    }

    func unpinNode(_ id: UUID) {
        pinnedNodeIDs.removeAll { $0 == id }
        persist()
        statusBanner = "已取消置顶"
    }

    func togglePin(_ id: UUID) {
        if isPinned(id) {
            unpinNode(id)
        } else {
            pinNode(id)
        }
    }

    func pinNodes(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for id in ids.reversed() {
            pinnedNodeIDs.removeAll { $0 == id }
            pinnedNodeIDs.insert(id, at: 0)
        }
        persist()
        statusBanner = "已置顶 \(ids.count) 个节点"
    }

    func unpinNodes(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        pinnedNodeIDs.removeAll { ids.contains($0) }
        persist()
        statusBanner = "已取消置顶 \(ids.count) 个节点"
    }

    func unavailableCleanupCandidates(subscriptionID: UUID, now: Date = Date(), includingFavorites: Bool = false) -> Set<UUID> {
        guard isLibraryReady, !testManager.isTesting, !testManager.isProbingApps,
              !subscriptionRefreshInProgress,
              let sub = subscription(for: subscriptionID) else { return [] }
        let cutoff = now.addingTimeInterval(-Double(min(30, max(1, sub.unavailableCleanupDays ?? 3))) * 86400)
        return Set(nodes.filter {
            guard $0.subscriptionID == subscriptionID, !$0.pendingRemoval,
                  includingFavorites || !$0.isFavorite,
                  (includingFavorites && $0.isFavorite) || $0.id != connection.state.currentNodeID,
                  $0.lastTestStatus == .unavailable
            else { return false }
            let unavailableStart = $0.unavailableSince ?? $0.lastTestDate
            guard let unavailableStart, unavailableStart <= cutoff,
                  let lastTest = $0.lastTestDate, lastTest >= cutoff
            else { return false }
            return true
        }.map(\.id))
    }

    func protectedCleanupFavoriteCount(subscriptionID: UUID) -> Int {
        let eligible = unavailableCleanupCandidates(subscriptionID: subscriptionID, includingFavorites: true)
        return nodes.filter { $0.isFavorite && eligible.contains($0.id) }.count
    }

    func clearSubscriptionUpdateHistory(_ subscriptionID: UUID, recordIDs: Set<UUID>) {
        guard isLibraryReady else {
            statusBanner = "本地数据未就绪，无法清除历史记录"
            return
        }
        guard let sub = subscription(for: subscriptionID) else { return }
        let previousCount = updateLogs.count
        updateLogs.removeAll { $0.subscriptionID == subscriptionID && recordIDs.contains($0.id) }
        let removedCount = previousCount - updateLogs.count
        guard removedCount > 0 else {
            statusBanner = "所选更新记录已不存在"
            return
        }
        persist()
        let result = "已清除 \(removedCount) 条更新历史"
        statusBanner = result
        logger.info("\(sub.name)：\(result)", category: .subscription)
    }

    func clearSubscriptionCleanupHistory(_ subscriptionID: UUID, recordIDs: Set<UUID>) {
        guard isLibraryReady else {
            statusBanner = "本地数据未就绪，无法清除历史记录"
            return
        }
        guard let index = subscriptions.firstIndex(where: { $0.id == subscriptionID }) else { return }
        var updated = subscriptions[index]
        let removedCount = updated.removeCleanupHistory(recordIDs: recordIDs)
        guard removedCount > 0 else {
            statusBanner = "所选清理记录已不存在"
            return
        }
        subscriptions[index] = updated
        persist()
        let result = "已清除 \(removedCount) 条清理历史"
        statusBanner = result
        logger.info("\(updated.name)：\(result)", category: .subscription)
    }

    func cleanupUnavailableNodes(subscriptionID: UUID, automatic: Bool = false) {
        let ids = unavailableCleanupCandidates(subscriptionID: subscriptionID)
        guard !ids.isEmpty else {
            if !automatic { statusBanner = "没有符合期限的不可用节点，或正在更新/测试" }
            return
        }
        let subscriptionName = subscription(for: subscriptionID)?.name ?? "未知订阅"
        if let index = subscriptions.firstIndex(where: { $0.id == subscriptionID }) {
            subscriptions[index].nodeCount = nodes.filter {
                $0.subscriptionID == subscriptionID && !ids.contains($0.id)
            }.count
            var history = subscriptions[index].cleanupHistory ?? []
            history.insert(SubscriptionCleanupRecord(cleanedAt: Date(), automatic: automatic,
                                                      removedCount: ids.count), at: 0)
            subscriptions[index].cleanupHistory = history
            // An unchanged remote payload must be allowed to repopulate cleaned nodes.
            subscriptions[index].contentHash = nil
            subscriptions[index].etag = nil
            subscriptions[index].lastModified = nil
        }
        deleteNodes(ids)
        let result = "\(automatic ? "自动" : "手动")清理了 \(ids.count) 个长期不可用节点"
        statusBanner = result
        logger.info("\(subscriptionName)：\(result)", category: .subscription)
    }

    func deleteNode(_ id: UUID) {
        deleteNodes([id])
    }

    func deleteNodes(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let removed = nodes.filter { ids.contains($0.id) }
        let affectedSubscriptions = Set(removed.compactMap(\.subscriptionID))
        nodes.removeAll { ids.contains($0.id) }
        for index in subscriptions.indices where affectedSubscriptions.contains(subscriptions[index].id) {
            let subscriptionID = subscriptions[index].id
            let remaining = nodes.filter { $0.subscriptionID == subscriptionID }
            subscriptions[index].nodeCount = remaining.filter { !$0.pendingRemoval }.count
            if subscriptions[index].isShareLinksBundle {
                let remainingFingerprints = Set(remaining.map { $0.nodeFingerprint ?? NodeFingerprint.make(from: $0) })
                let removedFingerprints = Set(removed.filter { $0.subscriptionID == subscriptionID }
                    .map { $0.nodeFingerprint ?? NodeFingerprint.make(from: $0) })
                    .subtracting(remainingFingerprints)
                subscriptions[index].shareLinksText = NodeLinkParser.extractShareLinks(
                    from: subscriptions[index].shareLinksText ?? ""
                ).filter { link in
                    !NodeLinkParser.parseLines(link).validNodes.contains {
                        removedFingerprints.contains(NodeFingerprint.make(from: $0))
                    }
                }.joined(separator: "\n")
            }
        }
        pinnedNodeIDs.removeAll { ids.contains($0) }
        if let current = connection.state.currentNodeID, ids.contains(current) {
            connection.state.currentNodeID = nil
        }
        recentNodeIDs.removeAll { ids.contains($0) }
        if let viewing = viewingNodeID, ids.contains(viewing) {
            viewingNodeID = nil
        }
        persist()
        statusBanner = "已删除 \(ids.count) 个节点"
    }

    /// 全库或指定集合按连接指纹去重；优先保留当前连接、启用和评分更高的副本。
    @discardableResult
    func removeDuplicateNodes(among ids: Set<UUID>? = nil, reportEmptyResult: Bool = true) -> Int {
        var buckets: [String: [Int]] = [:]
        for (index, node) in nodes.enumerated() {
            guard !node.pendingRemoval else { continue }
            if let ids, !ids.contains(node.id) { continue }
            let fp = node.nodeFingerprint ?? NodeFingerprint.make(from: node)
            buckets[fp, default: []].append(index)
        }

        var removeIDs = Set<UUID>()
        for indices in buckets.values where indices.count > 1 {
            let ranked = indices.sorted { lhs, rhs in
                let lhsIsCurrent = nodes[lhs].id == connection.state.currentNodeID
                let rhsIsCurrent = nodes[rhs].id == connection.state.currentNodeID
                if lhsIsCurrent != rhsIsCurrent { return lhsIsCurrent }
                if nodes[lhs].enabled != nodes[rhs].enabled { return nodes[lhs].enabled }
                let lhsScore = duplicateKeepScore(nodes[lhs])
                let rhsScore = duplicateKeepScore(nodes[rhs])
                return lhsScore == rhsScore ? lhs < rhs : lhsScore > rhsScore
            }
            let keptIndex = ranked[0]
            if !nodes[keptIndex].isFavorite, indices.contains(where: { nodes[$0].isFavorite }) {
                nodes[keptIndex].isFavorite = true
            }
            for index in ranked.dropFirst() {
                removeIDs.insert(nodes[index].id)
            }
        }

        guard !removeIDs.isEmpty else {
            if reportEmptyResult { statusBanner = "没有发现重复节点" }
            return 0
        }
        deleteNodes(removeIDs)
        statusBanner = "已删除 \(removeIDs.count) 个重复节点"
        return removeIDs.count
    }

    private func duplicateKeepScore(_ node: ProxyNode) -> Int {
        var score = 0
        if node.isFavorite { score += 1_000_000 }
        switch node.lastTestStatus {
        case .ultraFast: score += 60_000
        case .fast: score += 50_000
        case .fairlyFast: score += 40_000
        case .fairlySlow: score += 30_000
        case .slow: score += 20_000
        case .ultraSlow: score += 10_000
        case .testing: score += 8_000
        case .untested: score += 5_000
        case .failed: score += 1_000
        case .unavailable: score += 0
        }
        if let latency = node.lastLatency {
            score += max(0, 10_000 - latency)
        }
        return score
    }

    // MARK: - Connection

    @Published var showsNoConnectionCandidates = false

    var noConnectionCandidatesMessage: String {
        let blockedCount = nodes.filter { !$0.pendingRemoval && settings.isTemporarilyBlocked($0.id) }.count
        return AppSettings.connectionCandidatesGuidance(blockedCount: blockedCount, hasNodes: nodes.contains { !$0.pendingRemoval })
    }

    func presentNoConnectionCandidates() {
        showsNoConnectionCandidates = true
    }

    func toggleConnection() async {
        switch connection.state.status {
        case .disconnecting:
            // 断开已在进行，再点一次会排队第二次断开，状态会再闪一次「断开中」。
            return
        case .connected, .connecting:
            await disconnect()
        case .disconnected, .error:
            // 异常清理仍在进行时也提交重连，由连接队列等待清理后接续。
            if connection.state.autoSelectEnabled {
                await connectWithAutoSelect(showGuidance: true)
            } else if let node = preferredConnectNode() {
                await connect(to: node)
            } else {
                presentNoConnectionCandidates()
            }
        }
    }

    private var autoSelectResultsGeneration = 0

    @Published private(set) var isClearingAutoSelectResults = false

    /// Disconnect before removing measurements so live updates cannot restore old results.
    func clearAutoSelectResults() async {
        guard !isClearingAutoSelectResults,
              !testManager.isTesting, !testManager.isProbingApps else { return }
        isClearingAutoSelectResults = true
        defer { isClearingAutoSelectResults = false }
        automaticAppProbeTask?.cancel()
        pendingAutomaticAppProbeNodeIDs.removeAll()
        pendingManualAppProbeNodeIDs.removeAll()
        autoSelectResultsGeneration += 1
        await disconnect(manual: false, reason: "清空自动优选列表")
        guard connection.state.status == .disconnected, !connection.captureCleanupFailed else {
            statusBanner = "断开连接未完成，请重试后清除列表"
            return
        }
        var cleared = nodes
        for index in cleared.indices {
            cleared[index].lastTestStatus = .untested
            cleared[index].lastTestErrorMessage = nil
            cleared[index].lastTestDate = nil
            cleared[index].lastLatency = nil
            cleared[index].lastAppProbePassedIDs = nil
            cleared[index].lastAppProbeDate = nil
            cleared[index].lastAppProbeOkCount = nil
            cleared[index].lastAppProbeLatency = nil
        }
        nodes = cleared
        countryGroups = CountryResolver.group(cleared.filter { !$0.pendingRemoval })
        testManager.resetAppProbes(targets: settings.automaticAppProbeTargets)
        persist()
        statusBanner = "已清除自动优选列表，重新测试节点后将按当前规则加入列表"
    }

    /// 使用已有排序立即连接，应用探测由独立任务补齐。
    func connectWithAutoSelect(showGuidance: Bool = false, restrictToCountry: String? = nil) async {
        guard !isTerminating else { return }
        let requestGeneration = beginConnectionRequest(countryCode: restrictToCountry)
        eligibilitySwitchTask?.cancel()
        unexpectedReconnectTask?.cancel()
        connection.setAutomaticRecoveryPending(false)
        recoveryAttemptedIDs.removeAll()

        guard let target = automaticallyRankedNodes(connectionScopedNodes).first else {
            statusBanner = "暂无符合优选条件的可用节点"
            if showGuidance { presentNoConnectionCandidates() }
            return
        }

        do {
            try Task.checkCancellation()
            guard !userStoppedConnection, requestGeneration == connectionRequestGeneration else { return }
            try await connection.connect(
                node: target,
                settings: settings,
                allNodes: connectionScopedNodes,
                countryCode: target.countryCode,
                countryName: target.countryName
            )
            guard !userStoppedConnection, requestGeneration == connectionRequestGeneration else { return }
            if let id = connection.state.currentNodeID {
                pushRecent(id)
                markConnectedForNextLaunch(id)
            } else {
                pushRecent(target.id)
                markConnectedForNextLaunch(target.id)
            }
            persist()
            Task { await probeCurrentAppsIfNeeded() }
            if let id = connection.state.currentNodeID,
               let index = nodes.firstIndex(where: { $0.id == id }) {
                nodes[index].pendingConfigUpdate = false
            }
        } catch {
            if case ConnectionError.cancelled = error {
                if connection.state.status != .connected {
                    statusBanner = nil
                }
                persist()
                return
            }
            if error is ApplicationProxyError { automaticRecoveryNeedsUserAction = true }
            statusBanner = error.localizedDescription
            persist()
        }
    }

    /// 首页一键连接：开启自动优选时严格使用优选排序；关闭时沿用当前/最近节点。
    private func preferredConnectNode() -> ProxyNode? {
        if connection.state.autoSelectEnabled {
            return automaticallyRankedNodes(nodes).first
        }
        if let current = currentNode, !settings.isTemporarilyBlocked(current.id),
           !isCountryExcludedFromAutoSelect(CountryResolver.effectiveCode(for: current)) {
            return current
        }
        if let recent = recentNodes.first(where: {
            $0.enabled && !settings.isTemporarilyBlocked($0.id) && !isChinaExit($0) &&
            !isCountryExcludedFromAutoSelect(CountryResolver.effectiveCode(for: $0))
        }) {
            return recent
        }
        if let recent = recentNodes.first(where: {
            $0.enabled && !settings.isTemporarilyBlocked($0.id) && !isCountryExcludedFromAutoSelect(CountryResolver.effectiveCode(for: $0))
        }) {
            return recent
        }

        let usable = automaticallyRankedNodes(nodes)
        let overseas = usable
            .filter { !isChinaExit($0) }
        if let best = overseas.first { return best }

        return usable.first
    }

    func automaticallyRankedNodes(_ candidates: [ProxyNode], includingTemporarilyBlocked: Bool = false,
                                  preservingNodeID: UUID? = nil) -> [ProxyNode] {
        var usable = candidates.filter {
            $0.id == preservingNodeID || ($0.enabled && !$0.pendingRemoval
                && settings.allowsAutoSelectNode($0, includingTemporarilyBlocked: includingTemporarilyBlocked))
        }
        if settings.favoritePreference == .favoritesOnly {
            usable = usable.filter { $0.id == preservingNodeID || $0.isFavorite }
        }
        var applicationHealth: [UUID: AppHealthSnapshot] = [:]
        if settings.codexSmartFailover {
            let observed = Set(health.records.map(\.nodeKey))
            for node in usable where observed.contains(healthNodeKey(node)) {
                applicationHealth[node.id] = health.snapshot(nodeKey: healthNodeKey(node), context: healthContext(for: node))
            }
            usable.removeAll { $0.id != preservingNodeID && applicationHealth[$0.id]?.quarantined == true }
        }
        let appOrder = settings.automaticAppProbeTargets.map(\.id)
        let displayTitles = Dictionary(usable.map { ($0.id, $0.displayTitle) }, uniquingKeysWith: { first, _ in first })
        return usable.sorted { lhs, rhs in
            let left = applicationHealth[lhs.id]
            let right = applicationHealth[rhs.id]
            let leftVerified = left?.score != nil && (left?.status == .healthy || left?.status == .mild)
            let rightVerified = right?.score != nil && (right?.status == .healthy || right?.status == .mild)
            if leftVerified != rightVerified { return leftVerified }
            if leftVerified, let a = left?.score, let b = right?.score, a != b { return a > b }
            return ProxyNode.autoSelectLessThan(
                lhs,
                rhs,
                considerAppProbe: settings.autoAppProbeUsableNodes,
                appOrder: appOrder,
                preferFavorites: settings.favoritePreference == .preferFavorites,
                displayTitles: displayTitles
            )
        }
    }

    private func resumePendingConnectionRecoveryIfNeeded() {
        guard !isTerminating, !userStoppedConnection, !automaticRecoveryNeedsUserAction, settings.autoFailover,
              connection.state.autoSelectEnabled, networkRecovery.canRecover,
              !connection.isBusy, !connection.captureCleanupFailed, !recoveryRunning,
              applicationHealthSwitchTask == nil, eligibilitySwitchTask == nil,
              connection.state.status == .error || (connection.state.status == .disconnected && connection.automaticRecoveryPending)
        else { return }
        if let retryAt = applicationRecoveryRetryAt {
            guard Date() >= retryAt else { return }
            applicationRecoveryRetryAt = nil
            recoveryAttemptedIDs.removeAll()
        }
        scheduleUnexpectedReconnect(avoiding: connection.state.currentNodeID, reason: "连接异常后继续恢复")
    }

    /// Only one recovery pass owns the connection; an exhausted pass retries after a short pause.
    private func scheduleUnexpectedReconnect(avoiding failedNodeID: UUID?, reason: String) {
        guard !isTerminating, !userStoppedConnection, !automaticRecoveryNeedsUserAction,
              settings.autoFailover, connection.state.autoSelectEnabled, !connection.captureCleanupFailed else { return }
        connection.setAutomaticRecoveryPending(true)
        guard networkRecovery.canRecover, !recoveryRunning, applicationHealthSwitchTask == nil,
              unexpectedReconnectTask == nil else { return }
        if let retryAt = applicationRecoveryRetryAt, Date() < retryAt { return }
        logger.info("已安排异常连接的顺序恢复；原因：\(reason)", category: .network)
        let runID = UUID()
        unexpectedReconnectRunID = runID
        let generation = connectionRequestGeneration
        unexpectedReconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.unexpectedReconnectRunID == runID { self.unexpectedReconnectTask = nil }
            }
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            guard !Task.isCancelled, !self.isTerminating,
                  generation == self.connectionRequestGeneration,
                  !self.userStoppedConnection, self.settings.autoFailover,
                  self.connection.state.autoSelectEnabled, self.connection.automaticRecoveryPending,
                  self.connection.state.status == .error || self.connection.state.status == .disconnected,
                  !self.connection.isBusy else { return }
            await self.recoverAutomatically(avoiding: failedNodeID)
        }
    }

    private func isChinaExit(_ node: ProxyNode) -> Bool {
        if node.countryCode?.uppercased() == "CN" { return true }
        let name = (node.countryName ?? node.name).lowercased()
        return name.contains("中国") || name.contains("china") || name.contains("_cn_")
    }

    /// 用户发起连接：不可用 / 配置失败节点先弹确认，其余直接连。
    func requestConnect(to node: ProxyNode) {
        if node.lastTestStatus == .unavailable || node.lastTestStatus == .failed {
            pendingUnavailableConnectID = node.id
            return
        }
        Task { await connect(to: node) }
    }

    var pendingUnavailableConnectNode: ProxyNode? {
        guard let id = pendingUnavailableConnectID else { return nil }
        return nodes.first { $0.id == id }
    }

    func confirmUnavailableConnect() {
        guard let id = pendingUnavailableConnectID,
              let node = nodes.first(where: { $0.id == id })
        else {
            pendingUnavailableConnectID = nil
            return
        }
        pendingUnavailableConnectID = nil
        Task { await connect(to: node) }
    }

    func cancelUnavailableConnect() {
        pendingUnavailableConnectID = nil
    }

    func connect(to node: ProxyNode, restrictToCountry: String? = nil) async {
        guard !isTerminating else { return }
        let requestGeneration = beginConnectionRequest(preservingNodeID: node.id, countryCode: restrictToCountry)
        eligibilitySwitchTask?.cancel()
        unexpectedReconnectTask?.cancel()
        connection.setAutomaticRecoveryPending(false)
        recoveryAttemptedIDs.removeAll()
        do {
            try Task.checkCancellation()
            guard !userStoppedConnection, requestGeneration == connectionRequestGeneration else { return }
            try await connection.connect(
                node: node,
                settings: settings,
                allNodes: connectionScopedNodes,
                countryCode: node.countryCode,
                countryName: node.countryName
            )
            guard !userStoppedConnection, requestGeneration == connectionRequestGeneration else { return }
            // Record the node that actually connected (failover may switch).
            if let id = connection.state.currentNodeID {
                pushRecent(id)
                markConnectedForNextLaunch(id)
            } else {
                pushRecent(node.id)
                markConnectedForNextLaunch(node.id)
            }
            persist()
            // Failover may connect a node without cached application results.
            Task { await probeCurrentAppsIfNeeded() }
            if let id = connection.state.currentNodeID,
               let index = nodes.firstIndex(where: { $0.id == id }) {
                nodes[index].pendingConfigUpdate = false
            }
        } catch {
            if case ConnectionError.cancelled = error {
                // 用户主动取消，不弹失败提示。
                if connection.state.status != .connected {
                    statusBanner = nil
                }
                persist()
                return
            }
            if error is ApplicationProxyError { automaticRecoveryNeedsUserAction = true }
            statusBanner = error.localizedDescription
            persist()
        }
    }

    func connectCountry(_ code: String) async {
        guard !isTerminating else { return }
        let requestGeneration = beginConnectionRequest(countryCode: code)
        eligibilitySwitchTask?.cancel()
        unexpectedReconnectTask?.cancel()
        connection.setAutomaticRecoveryPending(false)
        recoveryAttemptedIDs.removeAll()
        do {
            try Task.checkCancellation()
            guard !userStoppedConnection, requestGeneration == connectionRequestGeneration else { return }
            try await connection.connectBestNode(
                in: code,
                nodes: nodes,
                settings: settings
            )
            guard !userStoppedConnection, requestGeneration == connectionRequestGeneration else { return }
            if let id = connection.state.currentNodeID {
                pushRecent(id)
                markConnectedForNextLaunch(id)
            }
            persist()
            Task { await probeCurrentAppsIfNeeded() }
        } catch {
            if case ConnectionError.cancelled = error {
                return
            }
            if error is ApplicationProxyError { automaticRecoveryNeedsUserAction = true }
            statusBanner = error.localizedDescription
        }
    }

    func disconnect(manual: Bool = true, reason: String? = nil) async {
        guard !isTerminating else { return }
        applicationHealthSwitchTask?.cancel()
        let disconnectReason = reason ?? (manual
            ? (connection.state.status == .connecting ? "用户取消连接" : "用户手动断开")
            : "自动断开")
        if manual {
            userStoppedConnection = true
            connectionCountryCode = nil
            startupConnectionIntent.reconnectOnNextLaunch = false
            startupConnectionIntent.stayDisconnectedUntilConnect = true
            store.saveStartupConnectionIntent(startupConnectionIntent)
        }
        connectionRequestGeneration += 1
        unexpectedReconnectTask?.cancel()
        eligibilitySwitchTask?.cancel()
        connection.setAutomaticRecoveryPending(false)
        // 已断开且无清理任务时不要再进断开流程，否则会再显示一次「断开中」。
        if connection.state.status == .disconnected, !connection.isBusy, !connection.captureCleanupFailed {
            return
        }
        recoveryAttemptedIDs.removeAll()
        recoveryHealthySince = nil
        unexpectedReconnectTask = nil
        if connection.state.status == .connected
            || connection.state.status == .connecting
            || connection.state.status == .error {
            connection.state.status = .disconnecting
        }
        await connection.disconnect(settings: settings, reason: disconnectReason)
        purgePendingRemovalNodes()
        persist()
    }

    /// Quit cleanup must restore the system proxy without turning the preceding
    /// connected session into a user-requested disconnect.
    func disconnectForTermination() async {
        guard !isTerminating else { return }
        isTerminating = true
        applicationHealthTask?.cancel()
        codexInviteTask?.cancel()
        codexInviteCheckInProgress = false
        applicationHealthSwitchTask?.cancel()
        cityLocalizationTasks.values.forEach { $0.cancel() }
        cityLocalizationTasks.removeAll()
        librarySaveRetryTask?.cancel()
        librarySaveRetryTask = nil
        if connection.state.status == .connected, let id = connection.state.currentNodeID {
            markConnectedForNextLaunch(id)
        }
        // Stop recovery for this process without changing the saved launch intent.
        userStoppedConnection = true
        connectionRequestGeneration += 1
        schedulerTimer?.invalidate()
        eligibilitySwitchTask?.cancel()
        unexpectedReconnectTask?.cancel()
        automaticAppProbeTask?.cancel()
        let automaticProbes = automaticAppProbeTask
        pendingAutomaticAppProbeNodeIDs.removeAll()
        pendingManualAppProbeNodeIDs.removeAll()
        let testingCleanup = Task { await self.testManager.shutdown() }
        connection.setAutomaticRecoveryPending(false)
        if connection.state.status != .disconnected {
            connection.state.status = .disconnecting
        }
        await connection.disconnect(settings: settings, reason: "退出应用")
        await automaticProbes?.value
        await testingCleanup.value
        await health.flush()
        persist()
        await store.flush()
        await logger.flush()
        stopBackgroundActivity()
    }

    private func markConnectedForNextLaunch(_ id: UUID) {
        guard !userStoppedConnection else { return }
        startupConnectionIntent.lastConnectedNodeID = id
        startupConnectionIntent.reconnectOnNextLaunch = true
        startupConnectionIntent.stayDisconnectedUntilConnect = false
        store.saveStartupConnectionIntent(startupConnectionIntent)
    }

    // MARK: - Testing

    /// - Parameter silent: 定时/更新后等自动测速时为 true，不弹横幅与完成提示。
    func testNodes(_ targets: [ProxyNode], silent: Bool = false, strictResults: Bool = false) async {
        guard !isTerminating, !targets.isEmpty else { return }
        if testManager.isTesting {
            if silent {
                pendingSilentTestNodeIDs.formUnion(targets.map(\.id))
                logger.info(
                    "测速进行中，已排队等待自动测试：\(targets.count) 个节点",
                    category: .network
                )
            } else {
                statusBanner = "测速进行中，请稍后再试"
            }
            return
        }

        let ids = Set(targets.map(\.id))
        if silent, Set(targets.map(\.subscriptionID)).count > 1
            || nodes.allSatisfy({ !$0.enabled || $0.pendingRemoval || ids.contains($0.id) }) {
            updateSettings {
                let filter = NodeListFilter.decode($0.nodeListCategoryRaw)
                $0.nodeListCategoryRaw = NodeListFilter.encode(scope: filter.scope, source: .all)
            }
        }
        testSessionIncludesAppProbes = !silent
        let fingerprints = Dictionary(targets.map { ($0.id, NodeFingerprint.make(from: $0)) }, uniquingKeysWith: { first, _ in first })
        // 开始新一轮前，清掉上一轮遗留的「测试中」（暂停残留 / 中断）。
        clearStuckTestingStatuses(except: ids)
        resetNodesForRetest(ids: ids)

        let started = await testManager.startTest(nodes: targets, settings: settings, silent: silent) { [weak self] id, result in
            self?.enqueueTestResult(id: id, result: result, strictResults: strictResults, fingerprint: fingerprints[id])
        }
        flushTestResults()
        let stoppedByUser = testManager.consumeUserStop()
        if !started {
            // 开测失败：把刚标成「测试中」的节点退回未测试。
            clearStuckTestingStatuses(except: [])
        }
        // 结束后再扫一次，防止个别节点漏结算。停止时未测完的不能继续显示「测试中」。
        if !testManager.isTesting {
            clearStuckTestingStatuses(except: testManager.phase == .paused ? Set(testManager.remainingNodeIDs) : [])
        }
        if stoppedByUser {
            statusBanner = "测速已停止"
        } else if testManager.needsXrayInstall {
            statusBanner = XrayInstaller.missingCoreShortGuidance
        }
        persist()
        if stoppedByUser { return }

        // 手动/后台测速结束后的应用连通都遵循自动检测开关；显式「测试可用节点」不受此限。
        if started, !Task.isCancelled, testManager.phase == .finished {
            if nodes.allSatisfy({ !$0.enabled || $0.pendingRemoval || ids.contains($0.id) }) {
                lastFullNodeTestAt = Date()
            }
            enqueueAutomaticAppProbes(onlyIDs: ids, forceRetest: !silent)
            checkConnectedNodeEligibility()
        }

        await drainPendingSilentNodeTests()
    }

    private func drainPendingSilentNodeTests() async {
        // Drain automatic requests accumulated during this run. Resolve IDs against
        // the latest node array because another subscription refresh may have merged
        // or removed nodes while the current test was awaiting network work.
        if !testManager.isTesting,
           testManager.phase != .paused,
           !pendingSilentTestNodeIDs.isEmpty {
            let pendingIDs = pendingSilentTestNodeIDs
            pendingSilentTestNodeIDs.removeAll()
            let pendingNodes = nodes.filter { pendingIDs.contains($0.id) && $0.enabled && !$0.pendingRemoval }
            if !pendingNodes.isEmpty {
                await testNodes(pendingNodes, silent: true)
            }
        }
    }

    /// 自动应用探测单独排队，不占用节点检测、连接或手动应用探测任务。
    /// 测速后的补测（含 forceRetest）都要求开启自动应用连通；`testUsableNodeApps` 可直接写入 pendingManual。
    private func enqueueAutomaticAppProbes(onlyIDs: Set<UUID>, forceRetest: Bool = false) {
        guard !isTerminating else { return }
        if settings.autoAppProbeUsableNodes {
            if forceRetest {
                pendingManualAppProbeNodeIDs.formUnion(onlyIDs)
            } else {
                pendingAutomaticAppProbeNodeIDs.formUnion(onlyIDs)
            }
        }
        guard !pendingAutomaticAppProbeNodeIDs.isEmpty || !pendingManualAppProbeNodeIDs.isEmpty else { return }
        guard automaticAppProbeTask == nil else { return }
        automaticAppProbeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.automaticAppProbeTask = nil
                if !self.pendingAutomaticAppProbeNodeIDs.isEmpty || !self.pendingManualAppProbeNodeIDs.isEmpty {
                    self.enqueueAutomaticAppProbes(onlyIDs: [])
                }
            }
            while !Task.isCancelled,
                  !self.pendingAutomaticAppProbeNodeIDs.isEmpty || !self.pendingManualAppProbeNodeIDs.isEmpty {
                let manualIDs = self.pendingManualAppProbeNodeIDs
                let ids = self.pendingAutomaticAppProbeNodeIDs.union(manualIDs)
                self.pendingAutomaticAppProbeNodeIDs.removeAll()
                self.pendingManualAppProbeNodeIDs.removeAll()
                await self.ensureAppProbesForUsableNodes(onlyIDs: ids, forceRetestIDs: manualIDs)
            }
        }
    }

    func usableNodesForAppProbe(in source: NodeListFilter.Source) -> [ProxyNode] {
        NodeListFilter.nodes(in: nodes, source: source, subscriptions: subscriptions)
            .filter { $0.lastTestStatus.isUsable }
    }

    /// 显式测试所选组的全部可用节点，包括已有探测结果的节点。
    func testUsableNodeApps(in source: NodeListFilter.Source) {
        guard !isTerminating else { return }
        guard !settings.automaticAppProbeTargets.isEmpty else {
            statusBanner = "请先配置应用连通测试目标"
            return
        }
        let targets = usableNodesForAppProbe(in: source)
        guard !targets.isEmpty else {
            statusBanner = "所选组暂无可用节点，请先测试节点延迟"
            return
        }
        pendingManualAppProbeNodeIDs.formUnion(targets.map(\.id))
        enqueueAutomaticAppProbes(onlyIDs: [])
    }

    func stopAppProbeBatch() {
        automaticAppProbeTask?.cancel()
        pendingAutomaticAppProbeNodeIDs.removeAll()
        pendingManualAppProbeNodeIDs.removeAll()
    }

    /// 对尚未做过应用连通的可用节点自动探测并写回，供自动优选排序。
    /// - Parameters:
    ///   - onlyIDs: 非空时只处理这些 ID（通常为本轮刚测速的节点）
    ///   - preferIDs: 排序时优先
    ///   - countryCode: 若指定，只处理该国家
    ///   - limit: 单次最多探测个数；`nil` 表示不截断
    ///   - silent: 不刷状态横幅
    func ensureAppProbesForUsableNodes(
        onlyIDs: Set<UUID>? = nil,
        preferIDs: Set<UUID> = [],
        countryCode: String? = nil,
        limit: Int? = nil,
        silent: Bool = true,
        forceRetestIDs: Set<UUID> = []
    ) async {
        guard settings.autoAppProbeUsableNodes || !forceRetestIDs.isEmpty else { return }
        guard !settings.automaticAppProbeTargets.isEmpty else {
            appProbeBatch.statusText = "未开始应用连通：请先配置测试目标"
            logger.warning(appProbeBatch.statusText, category: .test)
            if !silent { statusBanner = appProbeBatch.statusText }
            return
        }

        var pending = nodes.filter { node in
            node.enabled &&
            !node.pendingRemoval &&
            node.lastTestStatus.isUsable &&
            (forceRetestIDs.contains(node.id) ||
             (settings.autoAppProbeUsableNodes && (node.lastAppProbeDate == nil || node.lastAppProbePassedIDs == nil)))
        }
        if let onlyIDs {
            pending = pending.filter { onlyIDs.contains($0.id) }
        }
        if let countryCode {
            let code = countryCode.uppercased()
            pending = pending.filter { CountryResolver.effectiveCode(for: $0) == code }
        }
        guard !pending.isEmpty else { return }

        pending.sort { lhs, rhs in
            let leftPrefer = preferIDs.contains(lhs.id)
            let rightPrefer = preferIDs.contains(rhs.id)
            if leftPrefer != rightPrefer { return leftPrefer && !rightPrefer }
            return (lhs.lastLatency ?? Int.max) < (rhs.lastLatency ?? Int.max)
        }

        let cap = limit ?? pending.count
        let targets = Array(pending.prefix(max(0, cap)))
        guard !targets.isEmpty else { return }

        let generation = autoSelectResultsGeneration
        let probeTargets = settings.automaticAppProbeTargets
        appProbeBatch = AppProbeBatchProgress(isRunning: true, total: targets.count)
        logger.info("应用连通批量测试开始：\(targets.count) 个可用节点", category: .test)
        defer {
            appProbeBatch.isRunning = false
            let completed = !Task.isCancelled && generation == autoSelectResultsGeneration && appProbeBatch.completed == targets.count
            appProbeBatch.statusText = "应用连通\(completed ? "测试完成" : "已停止")：\(appProbeBatch.completed)/\(targets.count) 个节点，\(appProbeBatch.connected) 个至少一项通过，\(appProbeBatch.failed) 个未完成探测"
            if appProbeBatch.failed > 0 {
                logger.warning(appProbeBatch.statusText, category: .test)
            } else {
                logger.info(appProbeBatch.statusText, category: .test)
            }
            if !silent { statusBanner = appProbeBatch.statusText }
            persist()
        }
        let timeout = TimeInterval(max(1, settings.appProbeTimeoutSeconds))
        for (index, node) in targets.enumerated() {
            if Task.isCancelled || generation != autoSelectResultsGeneration || probeTargets != settings.automaticAppProbeTargets { break }
            guard settings.autoAppProbeUsableNodes || forceRetestIDs.contains(node.id) else { continue }
            // 期间节点可能被删或状态变了。
            guard let latest = nodes.first(where: { $0.id == node.id }),
                  latest.enabled, !latest.pendingRemoval,
                  latest.lastTestStatus.isUsable,
                  (forceRetestIDs.contains(node.id) || latest.lastAppProbeDate == nil || latest.lastAppProbePassedIDs == nil)
            else { continue }

            appProbeBatch.statusText = "应用连通 \(index + 1)/\(targets.count)：\(self.settings.nodeDisplayTitle(latest))"
            if !silent {
                statusBanner = appProbeBatch.statusText
            }

            let summary = await testManager.measureAppProbe(for: latest, timeout: timeout, targets: probeTargets)
            guard !Task.isCancelled, generation == autoSelectResultsGeneration,
                  probeTargets == settings.automaticAppProbeTargets else { break }
            guard settings.autoAppProbeUsableNodes || forceRetestIDs.contains(node.id) else { break }
            appProbeBatch.completed += 1
            guard let current = nodes.first(where: { $0.id == latest.id }),
                  current.enabled, !current.pendingRemoval,
                  current.lastTestDate == latest.lastTestDate,
                  NodeFingerprint.make(from: current) == NodeFingerprint.make(from: latest),
                  let summary else {
                appProbeBatch.failed += 1
                continue
            }
            if summary.okCount > 0 { appProbeBatch.connected += 1 }
            applyAppProbeSummary(
                nodeID: latest.id,
                okCount: summary.okCount,
                bestLatencyMs: summary.bestLatencyMs,
                passedIDs: summary.passedIDs
            )
        }
    }

    private func applyAppProbeSummary(nodeID: UUID, okCount: Int, bestLatencyMs: Int?, passedIDs: Set<String>) {
        guard let index = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        var copy = nodes
        copy[index].lastAppProbePassedIDs = passedIDs
        copy[index].lastAppProbeOkCount = okCount
        copy[index].lastAppProbeLatency = bestLatencyMs
        copy[index].lastAppProbeDate = Date()
        if okCount >= 3 {
            copy[index].lastAvailableAt = copy[index].lastAppProbeDate
            copy[index].unavailableSince = nil
        }
        nodes = copy
    }

    /// 把卡住的「测试中」恢复为「未测试」（可保留仍在本轮队列里的节点）。
    private func clearStuckTestingStatuses(except keep: Set<UUID>) {
        var copy = nodes
        var changed = false
        for index in copy.indices where copy[index].lastTestStatus == .testing {
            if keep.contains(copy[index].id) { continue }
            copy[index].lastTestStatus = .untested
            copy[index].lastTestErrorMessage = nil
            copy[index].lastLatency = nil
            changed = true
        }
        if changed {
            nodes = copy
        }
    }

    /// 按设置筛选定时/批量测速目标。
    func nodesForScheduledOrScopedTest(
        scope: ScheduledTestNodeScope,
        subscriptionRaw: String
    ) -> [ProxyNode] {
        var list = nodes.filter { $0.enabled && !$0.pendingRemoval }
        if subscriptionRaw.hasPrefix("subscription:"),
           let id = UUID(uuidString: String(subscriptionRaw.dropFirst("subscription:".count))) {
            list = list.filter { $0.subscriptionID == id }
        }
        if scope == .availableOnly {
            list = list.filter { $0.lastTestStatus.isUsable }
        } else if scope == .favoritesOnly {
            list = list.filter(\.isFavorite)
        }
        return list
    }

    /// Clear stale status/latency so the UI doesn't show previous-run numbers while retesting.
    /// Keep usable latency tiers frozen when connected, or when the node is favorited.
    private func resetNodesForRetest(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let connected = connection.state.status == .connected
        var copy = nodes
        var changed = false
        for index in copy.indices where ids.contains(copy[index].id) {
            if copy[index].lastTestErrorMessage != nil {
                copy[index].lastTestErrorMessage = nil
                changed = true
            }
            if settings.autoAppProbeUsableNodes {
                copy[index].lastAppProbePassedIDs = nil
                copy[index].lastAppProbeDate = nil
                copy[index].lastAppProbeOkCount = nil
                copy[index].lastAppProbeLatency = nil
                changed = true
            }
            if copy[index].lastTestStatus.isUsable, connected || copy[index].isFavorite {
                continue
            }
            copy[index].lastTestStatus = .testing
            copy[index].lastLatency = nil
            copy[index].lastTestDate = nil
            changed = true
        }
        if changed {
            nodes = copy
        }
    }

    private func enqueueTestResult(id: UUID, result: NodeTestResult, strictResults: Bool = false, fingerprint: String? = nil) {
        pendingTestResults[id] = (result, strictResults, fingerprint)
        guard testResultFlushTask == nil else { return }
        // Publish one snapshot per interval instead of rebuilding every page for each node.
        testResultFlushTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 200_000_000) }
            catch { return }
            self?.flushTestResults()
        }
    }

    private func flushTestResults() {
        testResultFlushTask?.cancel()
        testResultFlushTask = nil
        guard !pendingTestResults.isEmpty else { return }
        let results = pendingTestResults
        pendingTestResults.removeAll(keepingCapacity: true)
        var updated = nodes
        var changed = false
        for index in updated.indices {
            guard let entry = results[updated[index].id] else { continue }
            if let fingerprint = entry.fingerprint,
               fingerprint != NodeFingerprint.make(from: updated[index]) { continue }
            applyTestResult(to: &updated, index: index, result: entry.result, strictResults: entry.strict)
            changed = true
        }
        if changed { nodes = updated }
    }

    private func applyTestResult(id: UUID, result: NodeTestResult, strictResults: Bool = false) {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
        var updated = nodes
        applyTestResult(to: &updated, index: index, result: result, strictResults: strictResults)
        nodes = updated
    }

    private func applyTestResult(to updated: inout [ProxyNode], index: Int,
                                 result: NodeTestResult, strictResults: Bool) {
        let id = updated[index].id
        let previous = updated[index].lastTestStatus
        let connected = connection.state.status == .connected && connection.state.currentNodeID == id
        let isFavorite = updated[index].isFavorite
        let wasUsable = previous.isUsable

        updated[index].lastTestDate = result.finishedAt
        if let metadata = result.exitMetadata {
            let metadata = metadata.retainingKnownDetails(from: updated[index].exitMetadata)
            updated[index].exitMetadata = metadata
        }
        if result.success {
            updated[index].lastAvailableAt = result.finishedAt
            updated[index].lastLatency = result.proxyLatency ?? result.primaryLatency
            updated[index].lastTestStatus = NodeTestStatus.from(latencyMs: updated[index].lastLatency ?? 0)
        } else if result.isConfigFailure {
            // 配置/客户端无法测 →「失败」，不是「不可用」。
            updated[index].lastLatency = nil
            if !strictResults, wasUsable, connected {
                updated[index].lastTestStatus = previous
            } else {
                updated[index].lastTestStatus = .failed
            }
        } else {
            updated[index].lastLatency = result.proxyLatency ?? result.tcpLatency ?? result.primaryLatency
            // 仅保护当前正在连接的节点；收藏标记不豁免失败结果。
            if !strictResults, wasUsable, connected {
                updated[index].lastTestStatus = previous
            } else {
                updated[index].lastTestStatus = .unavailable
            }
        }
        let reason = result.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        updated[index].lastTestErrorMessage = updated[index].lastTestStatus.isUsable || reason.isEmpty || reason == "TCP_PASS"
            ? nil : reason
        if result.success {
            updated[index].unavailableSince = nil
        } else if !result.isConfigFailure, updated[index].lastTestStatus == .unavailable {
            updated[index].unavailableSince = updated[index].unavailableSince ?? result.finishedAt
        } else {
            updated[index].unavailableSince = nil
        }
        if let metadata = updated[index].exitMetadata {
            localizeCity(nodeID: id, metadata: metadata, eligible: settings.shouldResolveChineseCity(for: updated[index]))
        }
        // Favorites are never cleared by test outcomes.
        updated[index].isFavorite = isFavorite
        if let code = result.exitCountryCode {
            CountryResolver.applyExitIP(
                to: &updated[index],
                countryCode: code,
                countryName: result.exitCountryName
            )
        }
    }

    func testAllNodes() async {
        await retestAllNodes()
    }

    /// 重新测试全部启用节点（从头开始）。
    func retestAllNodes() async {
        let targets = nodes.filter { $0.enabled && !$0.pendingRemoval }
        await testNodes(targets)
    }

    func pauseTesting() {
        testManager.pause()
    }

    func stopTesting() {
        guard testManager.isTesting else { return }
        statusBanner = "正在停止测速…"
        testManager.stop()
    }

    /// 继续上次未测完的节点。
    func resumeTesting() async {
        guard !isTerminating, testManager.canResume else { return }
        let ids = testManager.sessionNodeIDs
        let fingerprints = Dictionary(uniqueKeysWithValues: nodes.filter { ids.contains($0.id) }.map { ($0.id, NodeFingerprint.make(from: $0)) })
        await testManager.resumeTest(
            nodesByID: { [weak self] id in
                self?.nodes.first { $0.id == id && $0.enabled && !$0.pendingRemoval }
            },
            settings: settings
        ) { [weak self] id, result in
            self?.enqueueTestResult(id: id, result: result, fingerprint: fingerprints[id])
        }
        flushTestResults()
        let stoppedByUser = testManager.consumeUserStop()
        if !testManager.isTesting {
            clearStuckTestingStatuses(except: testManager.phase == .paused ? Set(testManager.remainingNodeIDs) : [])
        }
        if stoppedByUser {
            statusBanner = "测速已停止"
        }
        persist()
        if !stoppedByUser, !Task.isCancelled, testManager.phase == .finished {
            if nodes.allSatisfy({ !$0.enabled || $0.pendingRemoval || ids.contains($0.id) }) {
                lastFullNodeTestAt = Date()
            }
            enqueueAutomaticAppProbes(onlyIDs: ids, forceRetest: testSessionIncludesAppProbes)
            checkConnectedNodeEligibility()
            await drainPendingSilentNodeTests()
        }
    }

    func testCurrentConnection() async {
        guard !isTerminating else { return }
        guard let node = currentNode else {
            statusBanner = "当前未连接"
            return
        }
        guard connection.state.status == .connected else {
            statusBanner = "请先连接节点后再测试"
            return
        }
        resetNodesForRetest(ids: [node.id])
        let requestGeneration = connectionRequestGeneration
        let result = await testManager.testSingle(node: node, settings: settings, includeExitIP: true)
        guard let current = nodes.first(where: { $0.id == node.id }),
              NodeFingerprint.make(from: current) == NodeFingerprint.make(from: node) else { return }
        applyTestResult(id: node.id, result: result)
        if result.success {
            if requestGeneration == connectionRequestGeneration,
               connection.state.status == .connected, connection.state.currentNodeID == node.id {
                connection.state.recordLatency(result.primaryLatency)
                connection.state.exitIP = result.exitIP
                connection.state.exitCountry = result.exitCountryName ?? result.exitCountryCode
                if let metadata = result.exitMetadata {
                    connection.state.exitCity = metadata.city
                    connection.state.exitOperator = metadata.networkOperator
                    connection.state.exitASN = metadata.asn
                }
            }
            statusBanner = "节点测试完成：\(result.primaryLatency.map { LatencyFormat.display($0) } ?? "可用")"
        } else if testManager.needsXrayInstall {
            statusBanner = XrayInstaller.missingCoreShortGuidance
        } else {
            statusBanner = result.errorMessage ?? "测试失败"
        }
        if !Task.isCancelled {
            enqueueAutomaticAppProbes(onlyIDs: [node.id], forceRetest: true)
        }
        persist()
    }

    /// Probe apps for a node selected in Test Center — does **not** switch system proxy.
    func probeApps(forSelectedNode node: ProxyNode) async {
        guard !isTerminating else { return }
        let label = appProbeNodeDescription(for: node, useOriginalName: true)
        let generation = autoSelectResultsGeneration
        let targets = settings.automaticAppProbeTargets
        let completed = await testManager.probeApps(
            for: node,
            nodeLabel: label,
            settings: settings,
            timeout: TimeInterval(max(1, settings.appProbeTimeoutSeconds))
        )
        guard completed, !Task.isCancelled, generation == autoSelectResultsGeneration,
              targets == settings.automaticAppProbeTargets,
              let current = nodes.first(where: { $0.id == node.id }),
              NodeFingerprint.make(from: current) == NodeFingerprint.make(from: node) else { return }
        syncNodeStatusFromAppProbe(nodeID: node.id)
    }

    /// 按当前连接节点的快照独立探测，连接切换或断开不取消本次探测。
    func probeCurrentConnectionNodeApps() async {
        guard connection.state.status == .connected else {
            statusBanner = "当前未连接代理；可在节点结果中选中节点做应用探测（不切换系统代理）"
            return
        }
        guard let node = currentNode else {
            statusBanner = "未识别当前连接节点"
            return
        }
        await probeApps(forSelectedNode: node)
    }

    /// 把应用连通结果写回节点，供自动优选排序使用。
    private func persistAppProbeSummary(nodeID: UUID) {
        let ok = testManager.appProbeResults.filter { $0.status == .ok }
        applyAppProbeSummary(
            nodeID: nodeID,
            okCount: ok.count,
            bestLatencyMs: ok.compactMap(\.latencyMs).min(),
            passedIDs: Set(ok.map { $0.target.id })
        )
        persist()
    }

    /// 应用连通多数通过时，纠正「不可用」残留（应用探测本身不改测速结果，否则列表一直红叉）。
    private func syncNodeStatusFromAppProbe(nodeID: UUID) {
        persistAppProbeSummary(nodeID: nodeID)

        let okCount = nodes.first(where: { $0.id == nodeID })?.lastAppProbeOkCount ?? 0
        guard okCount >= 3 else { return }
        guard let index = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        guard nodes[index].lastTestStatus != .testing else { return }
        guard !nodes[index].lastTestStatus.isUsable else { return }

        let ms = nodes[index].lastAppProbeLatency ?? 3_000
        var copy = nodes
        copy[index].lastLatency = ms
        copy[index].lastTestStatus = NodeTestStatus.from(latencyMs: ms)
        copy[index].lastTestErrorMessage = nil
        copy[index].unavailableSince = nil
        copy[index].lastTestDate = Date()
        nodes = copy
        persist()
    }

    /// Reuse completed node probes; explicit manual probes always run again.
    private func probeCurrentAppsIfNeeded() async {
        guard settings.autoAppProbeUsableNodes,
              connection.state.status == .connected,
              let node = currentNode,
              node.lastAppProbeDate == nil || node.lastAppProbePassedIDs == nil else { return }
        enqueueAutomaticAppProbes(onlyIDs: [node.id])
    }

    func appProbeNodeDescription(for node: ProxyNode, useOriginalName: Bool = false) -> String {
        let flag = FlagResolver.flag(for: node.countryCode)
        let country = node.countryName ?? node.countryCode ?? ""
        let title = useOriginalName ? node.name : settings.nodeDisplayTitle(node)
        if country.isEmpty {
            return "\(flag) \(title)"
        }
        return "\(flag) \(country) · \(title)"
    }

    private func pushRecent(_ id: UUID) {
        recentNodeIDs.removeAll { $0 == id }
        recentNodeIDs.insert(id, at: 0)
        if recentNodeIDs.count > 8 {
            recentNodeIDs = Array(recentNodeIDs.prefix(8))
        }
    }

    // MARK: - Scheduler

    private func startBackgroundActivityIfNeeded() {
        guard !isTerminating, backgroundActivity == nil else { return }
        // Keep proxy maintenance and scheduled work responsive while the screen is locked.
        backgroundActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "跃界后台代理、定时检测与订阅更新"
        )
        logger.info("后台运行保护已启用，锁屏后继续处理连接与定时任务")
    }

    private func stopBackgroundActivity() {
        guard let backgroundActivity else { return }
        ProcessInfo.processInfo.endActivity(backgroundActivity)
        self.backgroundActivity = nil
    }

    private func startScheduler() {
        startBackgroundActivityIfNeeded()
        schedulerTimer?.invalidate()
        schedulerTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.schedulerTick()
            }
        }
        Task { await schedulerTick() }
    }

    private func schedulerTick() async {
        guard !isTerminating else { return }
        let now = Date()
        Task { await self.runScheduledTestIfDue(now: now) }
        for sub in subscriptions.filter({ $0.isEnabled && $0.autoUpdate }) {
            if let retryAt = sub.nextRetryAt, retryAt <= now {
                await refreshSubscription(sub.id, automatic: true)
                continue
            }
            // Missed update catch-up
            let due: Bool = {
                if let next = sub.nextUpdateAt { return next <= now }
                if let last = sub.lastSuccessAt {
                    guard let interval = sub.updateInterval.seconds else { return false }
                    return now.timeIntervalSince(last) >= interval
                }
                return true
            }()
            if due {
                await refreshSubscription(sub.id, automatic: true)
            }
        }

        for sub in subscriptions where sub.isEnabled && sub.autoCleanupUnavailableNodes == true {
            cleanupUnavailableNodes(subscriptionID: sub.id, automatic: true)
        }
    }

    private func runScheduledTestIfDue(now: Date) async {
        guard !isTerminating, settings.scheduledTestEnabled else { return }
        guard !scheduledTestRunning, !testManager.isTesting else { return }

        let interval = TimeInterval(max(5, settings.scheduledTestIntervalMinutes) * 60)
        if let last = [settings.lastScheduledTestAt, lastFullNodeTestAt].compactMap({ $0 }).max(),
           now.timeIntervalSince(last) < interval {
            return
        }

        let targets = nodesForScheduledOrScopedTest(
            scope: settings.scheduledTestScope,
            subscriptionRaw: settings.scheduledTestSubscriptionRaw
        )
        guard !targets.isEmpty else {
            updateSettings { $0.lastScheduledTestAt = now }
            return
        }

        scheduledTestRunning = true
        defer { scheduledTestRunning = false }
        let requestGeneration = connectionRequestGeneration
        let initialStatus = connection.state.status
        let initialNodeID = connection.state.currentNodeID
        let generation = autoSelectResultsGeneration
        let probeTargets = settings.automaticAppProbeTargets
        logger.info("定时测速触发：间隔 \(settings.scheduledTestIntervalMinutes) 分钟，\(targets.count) 个节点", category: .network)
        await testNodes(targets, silent: true)
        await automaticAppProbeTask?.value
        updateSettings { $0.lastScheduledTestAt = Date() }

        // Respect manual connection changes and never select from an interrupted run.
        guard !Task.isCancelled, !userStoppedConnection,
              requestGeneration == connectionRequestGeneration, testManager.phase == .finished,
              !testManager.isTesting,
              settings.scheduledTestEnabled, connection.state.autoSelectEnabled,
              !connection.isBusy, !recoveryRunning, applicationHealthSwitchTask == nil,
              connection.state.status == initialStatus,
              connection.state.currentNodeID == initialNodeID,
              generation == autoSelectResultsGeneration,
              probeTargets == settings.automaticAppProbeTargets else { return }
        if settings.autoAppProbeUsableNodes {
            guard !probeTargets.isEmpty,
                  targets.allSatisfy({ target in
                      guard let latest = nodes.first(where: { $0.id == target.id }),
                            latest.lastTestStatus.isUsable else { return true }
                      return latest.lastAppProbeDate != nil && latest.lastAppProbePassedIDs != nil
                  }) else { return }
        }
        if settings.codexSmartFailover, connection.state.status == .connected {
            considerApplicationHealthSwitch()
            return
        }
        guard let best = automaticallyRankedNodes(connectionScopedNodes).first else { return }
        if connection.state.status == .connected, connection.state.currentNodeID == best.id { return }
        logger.info("定时测速及应用连通完成，连接快速切换首位节点：\(self.settings.nodeDisplayTitle(best))", category: .network)
        await connect(to: best, restrictToCountry: connectionCountryCode)
    }

    /// Controls can invoke their bindings during a SwiftUI update.
    /// Commit on the next main-queue turn so the dependent published state is safe to reset.
    func updateSettingsFromView(_ mutate: @escaping (inout AppSettings) -> Void) {
        DispatchQueue.main.async { [weak self] in
            self?.updateSettings(mutate)
        }
    }

    func toggleTemporaryBlock(for id: UUID) {
        updateSettings { settings in
            var blocked = settings.temporarilyBlockedNodeIDs ?? []
            if !blocked.insert(id).inserted { blocked.remove(id) }
            settings.temporarilyBlockedNodeIDs = blocked
        }
        guard settings.isTemporarilyBlocked(id), connection.state.currentNodeID == id else { return }
        eligibilitySwitchTask?.cancel()
        unexpectedReconnectTask?.cancel()
        connection.setAutomaticRecoveryPending(false)
        Task { @MainActor [weak self] in
            guard let self, self.settings.isTemporarilyBlocked(id),
                  self.connection.state.currentNodeID == id else { return }
            let expectedGeneration = self.connectionRequestGeneration + 1
            await self.disconnect(manual: false, reason: "临时屏蔽当前节点")
            guard self.connectionRequestGeneration == expectedGeneration,
                  self.settings.autoFailover,
                  self.connection.state.autoSelectEnabled,
                  !self.connection.captureCleanupFailed else { return }
            await self.connectWithAutoSelect(restrictToCountry: self.connectionCountryCode)
        }
    }

    private func applyTheme() {
        switch settings.theme {
        case .system: NSApplication.shared.appearance = nil
        case .light: NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        let previousSettings = settings
        let previousLaunchAtLogin = settings.launchAtLogin
        // Reassign the value as a whole so @Published always emits. Mutating a
        // nested Set through the wrapper's inout accessor can leave SwiftUI views
        // (notably Dashboard's filtered quick-switch list) showing stale data.
        var updated = settings
        mutate(&updated)
        updated.connectTimeoutSeconds = min(99, max(1, updated.connectTimeoutSeconds))
        updated.screenLockDisconnectDelayMinutes = min(1440, max(0, updated.screenLockDisconnectDelayMinutes))
        updated.scheduledTestIntervalMinutes = min(1440, max(5, updated.scheduledTestIntervalMinutes))
        guard updated != previousSettings else { return }
        let probeTargetsChanged = Set(previousSettings.automaticAppProbeTargets) != Set(updated.automaticAppProbeTargets)
        if probeTargetsChanged {
            var updatedNodes = nodes
            for index in updatedNodes.indices {
                updatedNodes[index].lastAppProbePassedIDs = nil
                updatedNodes[index].lastAppProbeDate = nil
                updatedNodes[index].lastAppProbeOkCount = nil
                updatedNodes[index].lastAppProbeLatency = nil
            }
            nodes = updatedNodes
        }
        settings = updated
        connection.updateQualityResultTTL(settings.testResultTTLMinutes)
        connection.updateConnectionTimeout(settings.connectTimeoutSeconds)
        if previousSettings.showChineseNodeMetadata != settings.showChineseNodeMetadata {
            cityLocalizationTasks.values.forEach { $0.cancel() }
            cityLocalizationTasks.removeAll()
            Task { [weak self] in
                await ChineseCityResolver.shared.cancelPending()
                if self?.settings.showChineseNodeMetadata == true { self?.refreshChineseCities() }
            }
        }
        if previousSettings.theme != settings.theme {
            applyTheme()
            logger.info("主题已切换为\(settings.theme.displayName)", category: .app)
        }
        if previousSettings.filterNodeNameAds != settings.filterNodeNameAds {
            logger.info("节点名称广告过滤已\(settings.filterNodeNameAds ? "开启" : "关闭")", category: .app)
        }
        if previousSettings.nodeNameAdFilterText != settings.nodeNameAdFilterText {
            logger.info("节点名称额外过滤文字已更新", category: .app)
        }
        if previousSettings.autoFailover && !settings.autoFailover {
            unexpectedReconnectTask?.cancel()
            eligibilitySwitchTask?.cancel()
            connection.setAutomaticRecoveryPending(false)
        }
        if probeTargetsChanged {
            stopAppProbeBatch()
        } else if previousSettings.autoAppProbeUsableNodes && !settings.autoAppProbeUsableNodes {
            pendingAutomaticAppProbeNodeIDs.removeAll()
            pendingManualAppProbeNodeIDs.removeAll()
        }
        if previousSettings.autoAppProbeUsableNodes != settings.autoAppProbeUsableNodes {
            logger.info("测速后自动应用连通测试已\(settings.autoAppProbeUsableNodes ? "开启" : "关闭")", category: .test)
        }
        if settings.autoAppProbeUsableNodes,
           probeTargetsChanged || !previousSettings.autoAppProbeUsableNodes {
            enqueueAutomaticAppProbes(onlyIDs: Set(nodes.map(\.id)))
        }
        if probeTargetsChanged {
            testManager.resetAppProbes(targets: settings.automaticAppProbeTargets)
        } else if previousSettings.automaticAppProbeTargets != settings.automaticAppProbeTargets {
            let results = testManager.appProbeResults
            testManager.appProbeResults = settings.automaticAppProbeTargets.map { target in
                results.first { $0.target == target } ?? .placeholder(target)
            }
        }
        if previousSettings.disconnectOnScreenLock != settings.disconnectOnScreenLock ||
            previousSettings.screenLockDisconnectDelayMinutes != settings.screenLockDisconnectDelayMinutes {
            screenLockDisconnect.configure(
                enabled: settings.disconnectOnScreenLock,
                delaySeconds: TimeInterval(settings.screenLockDisconnectDelayMinutes) * 60
            )
        }
        logger.minimumLevel = settings.logLevel
        if settings.launchAtLogin != previousLaunchAtLogin {
            connection.setLaunchAtLogin(settings.launchAtLogin)
        }
        persist()
        if previousSettings.autoSelectMinimumSpeed != settings.autoSelectMinimumSpeed ||
            previousSettings.autoSelectCountryScope != settings.autoSelectCountryScope ||
            previousSettings.autoSelectIncludedCountryCodes != settings.autoSelectIncludedCountryCodes ||
            previousSettings.autoSelectExcludedCountryCodes != settings.autoSelectExcludedCountryCodes {
            checkConnectedNodeEligibility()
        }
    }

    /// 保存自定义规则，并在规则代理已连接时重新应用。
    func saveRoutingRules(_ rules: RoutingRules) async throws {
        guard !isTerminating else { throw ConnectionError.cancelled }
        try rules.validate()
        updateSettings { $0.routingRules = rules }
        statusBanner = "规则已保存"
        if settings.routingMode == .rules,
           connection.state.status == .connected || connection.state.status == .connecting,
           let node = currentNode {
            do {
                try await connection.connect(node: node, settings: settings, allNodes: connectionScopedNodes,
                                             countryCode: node.countryCode, countryName: node.countryName,
                                             reason: "保存路由规则后重新连接")
                statusBanner = "规则已保存并生效"
            } catch {
                statusBanner = "规则已保存，但重连失败：\(error.localizedDescription)"
                throw error
            }
        }
    }

    /// 切换路由模式；若当前已连接则用新模式重连当前节点。
    func setRoutingMode(_ mode: RoutingMode) async {
        guard !isTerminating else { return }
        guard settings.routingMode != mode else { return }
        updateSettings { $0.selectRoutingMode(mode) }
        statusBanner = "路由已切换为\(mode.displayName)"

        guard connection.state.status == .connected || connection.state.status == .connecting,
              let node = currentNode
        else { return }

        do {
            try await connection.connect(
                node: node,
                settings: settings,
                allNodes: connectionScopedNodes,
                countryCode: node.countryCode,
                countryName: node.countryName
            )
            persist()
        } catch {
            statusBanner = "路由已切换，但重连失败：\(error.localizedDescription)"
            persist()
        }
    }

    func applyApplicationProxy(_ applications: [ProxyApplication]) async throws {
        guard settings.supportsApplicationProxy else {
            throw ApplicationProxyError.invalid("按应用代理仅在规则代理模式下可用，请先切换为规则代理。")
        }
        guard !applications.isEmpty else { throw ApplicationProxyError.invalid("请至少添加一个应用。") }
        for application in applications { try application.validate() }
        let wasConnected = connection.state.status == .connected
        let node = currentNode
        let expectedGeneration = connectionRequestGeneration + (wasConnected ? 1 : 0)
        if wasConnected { await disconnect(manual: false, reason: "修改应用代理设置") }
        updateSettings {
            $0.proxyApplications = Array(Set(applications)).sorted { $0.path < $1.path }
            $0.connectionCaptureMode = .applications
        }
        statusBanner = wasConnected
            ? "应用代理设置已保存，正在重新连接；成功后才生效。"
            : "应用代理设置已保存，尚未生效；请连接节点并完成管理员授权。"
        if wasConnected, let node, !userStoppedConnection,
           connectionRequestGeneration == expectedGeneration {
            await connect(to: node, restrictToCountry: connectionCountryCode)
        }
    }

    /// 切换连接方式；已连接时先断开再按新模式重连。
    func setConnectionCaptureMode(_ mode: ConnectionCaptureMode) async {
        guard mode != .applications || settings.supportsApplicationProxy else {
            statusBanner = "按应用代理仅在规则代理模式下可用。"
            return
        }
        guard settings.routingMode != .global || mode == .globalTun else {
            statusBanner = "全局代理使用全量 TUN；如需按应用代理，请先切换为规则代理。"
            return
        }
        guard mode != .globalTun || settings.routingMode == .global else { return }
        guard mode != .systemVPN || HopWorldAppGroup.isSystemVPNAvailable else {
            statusBanner = "当前构建未包含 Network Extension 权限，无法使用系统 VPN。"
            return
        }
        guard settings.connectionCaptureMode != mode else { return }
        let wasConnected = connection.state.status == .connected
        let node = currentNode
        let expectedGeneration = connectionRequestGeneration + (wasConnected ? 1 : 0)

        if wasConnected {
            await disconnect(manual: false, reason: "切换接管方式：\(settings.connectionCaptureMode.displayName) → \(mode.displayName)")
        }

        updateSettings { $0.connectionCaptureMode = mode }
        statusBanner = "连接方式已切换为\(mode.displayName)"

        guard wasConnected, let node, !userStoppedConnection,
              connectionRequestGeneration == expectedGeneration else { return }
        await connect(to: node, restrictToCountry: connectionCountryCode)
    }
}
