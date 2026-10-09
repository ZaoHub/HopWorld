import Foundation
import SwiftUI
import Combine
import Network
import AppKit

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
    @Published var selectedSidebar: SidebarItem = .dashboard
    @Published var nodes: [ProxyNode] = []
    @Published private(set) var countryGroups: [CountryGroup] = []
    @Published var subscriptions: [Subscription] = []
    @Published var updateLogs: [SubscriptionUpdateLog] = []
    @Published var settings = AppSettings()
    @Published var recentNodeIDs: [UUID] = []
    /// 置顶节点（靠前显示），单独持久化以免破坏旧 nodes.json。
    @Published var pinnedNodeIDs: [UUID] = []

    @Published var showAddSubscription = false
    @Published var showImportLinks = false
    @Published var importText = ""
    @Published var statusBanner: String?
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
    @Published private(set) var libraryAvailable = false
    /// True when encrypted library could not be read; mutations stay in memory only.
    var isLibraryReady: Bool { libraryAvailable }
    /// 正在查看的订阅；与编辑分流。
    @Published var viewingSubscriptionID: UUID?
    @Published var editingSubscriptionID: UUID?
    /// 节点详情 / 分享。
    @Published var viewingNodeID: UUID?
    /// 连接「不可用」节点前的确认（点确定后再真正连接）。
    @Published var pendingUnavailableConnectID: UUID?
    /// 节点列表滚动并选中该节点（添加重复节点时跳转）。
    @Published var focusNodeID: UUID?
    /// 测试完成后跳转到国家页并选中「可用」等分类。
    @Published var preferredNodeCategory: String?

    let connection = ConnectionManager()
    let subscriptionManager = SubscriptionManager()
    let testManager = NodeTestManager()
    let logger = AppLogger.shared

    private let store = PersistenceStore()
    private var startupConnectionIntent = StartupConnectionIntent()
    private var schedulerTimer: Timer?
    private let networkMonitor = NWPathMonitor()
    private lazy var networkRecovery = NetworkRecoveryCoordinator { [weak self] in
        guard let self else { return }
        if self.connection.state.status == .error,
           self.settings.connectionCaptureMode == .systemProxy,
           !self.connection.captureCleanupFailed {
            self.scheduleUnexpectedReconnect(avoiding: nil, reason: "网络已恢复")
        } else {
            await self.connection.revalidateAfterNetworkChange()
        }
    }
    private lazy var screenLockDisconnect = ScreenLockDisconnectCoordinator { [weak self] in
        guard let self else { return }
        guard self.connection.state.status != .disconnected || self.connection.isBusy else { return }
        self.logger.info("锁屏已达到设定时间，正在自动断开连接", category: .network)
        await self.disconnect()
    }
    private var cancellables = Set<AnyCancellable>()
    private var subscriptionRefreshInProgress = false
    private struct PendingSubscriptionRefresh {
        var id: UUID
        var focusInNodeList: Bool
    }

    private var pendingSubscriptionRefresh: [PendingSubscriptionRefresh] = []
    /// Automatic tests requested while another test is running. Subscription
    /// refreshes can overlap, so silently dropping the later request loses nodes.
    private var pendingSilentTestNodeIDs: Set<UUID> = []
    private var unexpectedReconnectDates: [Date] = []
    private var unexpectedReconnectTask: Task<Void, Never>?
    private var eligibilitySwitchTask: Task<Void, Never>?
    private var unhealthySince: Date?
    private var unhealthyNodeID: UUID?
    private var recoveryAttemptedIDs: Set<UUID> = []
    private var recoveryHealthySince: Date?
    private var recoveryRunning = false

    /// One ordered pass, followed by one full refresh and one fresh pass.
    /// Individual attempts deliberately bypass ConnectionManager's separate
    /// failover chain, which could otherwise reinsert already failed nodes.
    private func recoverAutomatically(avoiding failedID: UUID?) async {
        guard networkRecovery.canRecover, !recoveryRunning else { return }
        recoveryRunning = true
        defer { recoveryRunning = false }
        if let failedID { recoveryAttemptedIDs.insert(failedID) }
        recoveryHealthySince = nil
        var refreshed = false
        while !Task.isCancelled, networkRecovery.canRecover, connection.state.autoSelectEnabled {
            guard !connection.captureCleanupFailed else {
                statusBanner = "代理清理未完成，已暂停自动切换"
                return
            }
            let candidate = automaticallyRankedNodes(nodes).first { !recoveryAttemptedIDs.contains($0.id) }
            guard let candidate else {
                guard !refreshed else {
                    statusBanner = "全量测速后仍无可连接的合格节点，已暂停重试"
                    return
                }
                // Wait for an existing test to finish before requesting a new
                // full run, rather than consuming its incomplete results.
                while testManager.isTesting {
                    do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                }
                guard !Task.isCancelled else { return }
                statusBanner = "合格节点已全部尝试，正在重新测试全部节点"
                await testNodes(nodes.filter { $0.enabled && !$0.pendingRemoval }, silent: true, strictResults: true)
                guard !Task.isCancelled, testManager.phase != .paused else { return }
                recoveryAttemptedIDs.removeAll()
                refreshed = true
                continue
            }
            recoveryAttemptedIDs.insert(candidate.id)
            statusBanner = "自动切换：\(candidate.displayTitle)"
            logger.info("自动恢复依次尝试：\(candidate.displayTitle)", category: .network)
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
                    statusBanner = error.localizedDescription
                    return
                }
                logger.warning("自动恢复节点失败：\(candidate.displayTitle) — \(error.localizedDescription)", category: .network)
                persist()
            }
        }
    }

    /// Re-evaluate only after complete test results or a filter edit, not on
    /// traffic updates or transient testing states.
    private func checkConnectedNodeEligibility(liveSample: Bool = false) {
        guard networkRecovery.canRecover else { return }
        guard !recoveryRunning, eligibilitySwitchTask == nil,
              connection.state.autoSelectEnabled,
              connection.state.status == .connected, !connection.isBusy,
              let current = currentNode else {
            unhealthySince = nil
            unhealthyNodeID = nil
            return
        }
        var measured = current
        if liveSample {
            measured.lastLatency = connection.state.latency
            measured.lastTestStatus = connection.state.latency.map { NodeTestStatus.from(latencyMs: $0) } ?? .unavailable
        }
        guard !settings.allowsAutoSelectNode(measured) else {
            if liveSample {
                if recoveryHealthySince == nil { recoveryHealthySince = Date() }
                if Date().timeIntervalSince(recoveryHealthySince!) >= Double(max(1, settings.autoSelectUnhealthySeconds)) {
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
        guard let since = unhealthySince,
              Date().timeIntervalSince(since) >= Double(max(1, settings.autoSelectUnhealthySeconds)) else { return }
        eligibilitySwitchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.eligibilitySwitchTask = nil }
            guard !Task.isCancelled,
                  self.connection.state.autoSelectEnabled,
                  self.connection.state.status == .connected,
                  !self.connection.isBusy,
                  self.currentNode?.id == current.id,
                  self.unhealthyNodeID == current.id,
                  self.unhealthySince == since else { return }
            self.unhealthySince = nil
            self.unhealthyNodeID = nil
            await self.recoverAutomatically(avoiding: current.id)
        }
    }

    var currentNode: ProxyNode? {
        guard let id = connection.state.currentNodeID else { return nil }
        return nodes.first { $0.id == id }
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

    init() {
        load()
        bind()
        startNetworkMonitoring()
        if libraryAvailable { startScheduler() }
        Task {
            await connection.bootstrapRestore(settings: settings)
            if libraryAvailable { await connectOnLaunchIfNeeded() }
        }
    }

    private func startNetworkMonitoring() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in self?.networkRecovery.pathChanged(available: available) }
        }
        networkMonitor.start(queue: DispatchQueue(label: "com.hopworld.network-monitor"))
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.networkRecovery.willSleep() }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.networkRecovery.didWake() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.libraryAvailable else { return }
                self.retryLoadLibrary()
            }
            .store(in: &cancellables)
    }

    deinit { networkMonitor.cancel() }

    /// Apply the persisted startup policy after stale proxy/VPN state has been
    /// cleaned up. This is also the path used for each fresh Xcode Run.
    private func connectOnLaunchIfNeeded() async {
        let previouslySelectedID = connection.state.currentNodeID
        let autoSelectEnabled = connection.state.autoSelectEnabled
        connection.state = ConnectionState(autoSelectEnabled: autoSelectEnabled)
        connection.state.status = .disconnected

        if startupConnectionIntent.reconnectOnNextLaunch {
            if let target = startupConnectionIntent.lastConnectedNodeID.flatMap(restorableConnectedNode) {
                logger.info("启动自动连接：\(target.displayTitle)", category: .network)
                await connect(to: target)
            }
            if startupConnectionIntent.reconnectOnNextLaunch {
                startupConnectionIntent.reconnectOnNextLaunch = false
                store.saveStartupConnectionIntent(startupConnectionIntent)
            }
            persist()
            return
        }

        switch settings.connectOnLaunch {
        case .none:
            persist()
            return
        case .fastest:
            logger.info("启动自动连接：自动优选", category: .network)
            await connectWithAutoSelect()
            persist()
            return
        case .lastNode:
            let lastID = startupConnectionIntent.lastConnectedNodeID ?? recentNodeIDs.first ?? previouslySelectedID
            guard let target = lastID.flatMap(validStartupNode) else {
                persist()
                return
            }
            logger.info("启动自动连接：\(target.displayTitle)", category: .network)
            await connect(to: target)
            persist()
        }
    }

    private func validStartupNode(_ id: UUID) -> ProxyNode? {
        nodes.first {
            $0.id == id && $0.enabled && !$0.pendingRemoval &&
            !isCountryExcludedFromAutoSelect(CountryResolver.effectiveCode(for: $0))
        }
    }

    /// Restoring an active session is an exact-node operation, so automatic
    /// selection exclusions do not replace the node the user had connected.
    private func restorableConnectedNode(_ id: UUID) -> ProxyNode? {
        nodes.first { $0.id == id && $0.enabled && !$0.pendingRemoval         }
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

    func exportLibraryBackup(passphrase: String, includeCredentials: Bool) throws -> Data {
        let snapshot = LibrarySnapshot(nodes: nodes, subscriptions: subscriptions, updateLogs: updateLogs)
        return try LibraryBackup.export(snapshot: snapshot, passphrase: passphrase, includeCredentials: includeCredentials)
    }

    func importLibraryBackup(from data: Data, passphrase: String, replaceExisting: Bool) throws {
        let imported = try LibraryBackup.importBackup(from: data, passphrase: passphrase)
        guard replaceExisting || nodes.isEmpty else {
            throw LibraryBackupError.requiresReplaceConfirmation
        }
        nodes = imported.nodes
        subscriptions = imported.subscriptions
        updateLogs = imported.updateLogs
        for index in nodes.indices {
            KeychainStore.storeNodeCredentials(&nodes[index])
        }
        countryGroups = CountryResolver.group(nodes.filter { !$0.pendingRemoval })
        libraryAvailable = true
        persistenceError = nil
        persist()
        startScheduler()
        statusBanner = "已从备份恢复 \(nodes.count) 个节点、\(subscriptions.count) 个订阅"
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
        // System VPN UI is hidden without a Developer account — always stay on system proxy.
        if settings.connectionCaptureMode == .systemVPN {
            settings.connectionCaptureMode = .systemProxy
            store.saveSettings(settings)
        }
        // ATS blocks cleartext HTTP probes; migrate legacy http:// test URLs.
        if settings.testURL.lowercased().hasPrefix("http://") {
            settings.testURL = "https://" + settings.testURL.dropFirst("http://".count)
        }
        // Invalidate CONNECT-only "可用" results so UI matches real HTTPS connectability.
        if !settings.httpsProbeMigrated {
            for index in loadedNodes.indices {
                if loadedNodes[index].lastTestStatus.isUsable {
                    loadedNodes[index].lastTestStatus = .untested
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
        pinnedNodeIDs = store.loadPinnedNodeIDs()
        nodes = loadedNodes
        countryGroups = CountryResolver.group(loadedNodes.filter { !$0.pendingRemoval })
        logger.minimumLevel = settings.logLevel
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
                    self?.persistenceError = error
                    if let error { self?.logger.error(error) }
                }
            }
        }
        store.saveSettings(settings)
        store.saveConnectionState(connection.state)
        store.savePinnedNodeIDs(pinnedNodeIDs)
    }

    private func bind() {
        connection.onNodeConnectionFailed = { [weak self] id in
            guard let self, let index = self.nodes.firstIndex(where: { $0.id == id }) else { return }
            var updated = self.nodes
            updated[index].lastTestStatus = .unavailable
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
                if state.status != .connected || !state.autoSelectEnabled {
                    self?.recoveryHealthySince = nil
                    self?.unhealthySince = nil
                    self?.unhealthyNodeID = nil
                }
            }
            .store(in: &cancellables)
        connection.onUnexpectedDisconnect = { [weak self] failedNodeID, reason in
            self?.scheduleUnexpectedReconnect(avoiding: failedNodeID, reason: reason)
        }

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

        testManager.objectWillChange
            .throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true)
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
            .sink { [weak self] _ in self?.screenLockDisconnect.screenUnlocked() }
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
            statusBanner = "未解析到有效节点（支持 ss / vless / vmess / trojan）"
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
            testAfterUpdate: false
        )
        subscriptions.insert(sub, at: 0)
        let imported = subscriptionManager.importShareLinks(
            trimmed,
            sourceName: displayName,
            subscriptionID: sub.id
        )
        guard !imported.isEmpty else {
            subscriptions.removeAll { $0.id == sub.id }
            statusBanner = "未解析到有效节点（支持 ss / vless / vmess / trojan）"
            return
        }

        nodes.append(contentsOf: imported)
        if let index = subscriptions.firstIndex(where: { $0.id == sub.id }) {
            subscriptions[index].nodeCount = imported.count
            subscriptions[index].lastSuccessAt = Date()
            subscriptions[index].lastError = nil
            subscriptions[index].statusMessage = "已导入 \(imported.count) 个分享节点"
        }
        persist()
        warnUnsavedIfLibraryLocked()
        focusNodeList(source: .subscription(sub.id), nodeID: imported.first?.id, openDetail: false)
        statusBanner = "已导入 \(imported.count) 个节点，已在节点列表中显示"
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
        guard let composed = mergeShareLinksText(
            existing: sub.shareLinksText,
            pasted: pastedText,
            mode: sub.updateMode
        ) else { return }
        sub.shareLinksText = composed
        subscriptions[index] = sub
        persist()
        await refreshSubscription(subscriptionID)
        let count = nodes.filter { $0.subscriptionID == subscriptionID && !$0.pendingRemoval }.count
        if count > 0 {
            statusBanner = "已处理分享链接，当前 \(count) 个节点"
        }
    }

    func removeSubscription(_ id: UUID) {
        subscriptions.removeAll { $0.id == id }
        nodes.removeAll { $0.subscriptionID == id }
        if viewingSubscriptionID == id { viewingSubscriptionID = nil }
        if editingSubscriptionID == id { editingSubscriptionID = nil }
        persist()
    }

    func updateSubscription(_ subscription: Subscription, refreshAfterSave: Bool = false) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) else { return }
        var updated = subscription
        updated.nextUpdateAt = subscriptionManager.computeNextUpdateAt(for: updated)
        subscriptions[index] = updated
        persist()
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

    func refreshSubscription(_ id: UUID, focusInNodeList: Bool = false) async {
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
            } else {
                pendingSubscriptionRefresh.append(
                    PendingSubscriptionRefresh(id: id, focusInNodeList: focusInNodeList)
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
            if !pendingSubscriptionRefresh.isEmpty {
                let next = pendingSubscriptionRefresh.removeFirst()
                Task { await refreshSubscription(next.id, focusInNodeList: next.focusInNodeList) }
            }
        }

        let baseline = nodes.filter { $0.subscriptionID == id }
        let previousNodeIDs = Set(baseline.map(\.id))
        let previousDigests = Dictionary(uniqueKeysWithValues: baseline.map {
            ($0.id, NodeFingerprint.make(from: $0))
        })
        let preserveIDs: Set<UUID> = {
            if let id = connection.state.currentNodeID { return [id] }
            return []
        }()
        let (updated, proposedNodes, log) = await subscriptionManager.update(
            sub, existingNodes: nodes, preserveNodeIDs: preserveIDs
        )
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
            subscriptionID: id, baseline: baseline, proposed: proposedNodes, current: nodes
        ) else {
            statusBanner = "更新期间节点发生变化，已保留最新修改，请重新更新订阅"
            return
        }
        var merged = updated
        let current = subscriptions[index]
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
        merged.smartMergeMissingLimit = current.smartMergeMissingLimit
        merged.nextUpdateAt = subscriptionManager.computeNextUpdateAt(for: merged)
        subscriptions[index] = merged
        nodes = committed
        updateLogs.insert(log, at: 0)
        if updateLogs.count > 500 { updateLogs = Array(updateLogs.prefix(500)) }
        persist()
        markPendingConfigUpdates(subscriptionID: id, previousDigests: previousDigests)

        if updated.testAfterUpdate, log.success {
            let addedOrChanged = nodes.filter { node in
                guard node.subscriptionID == id, !node.pendingRemoval else { return false }
                if !previousNodeIDs.contains(node.id) { return true }
                if let before = previousDigests[node.id],
                   before != NodeFingerprint.make(from: node) {
                    return true
                }
                return node.pendingConfigUpdate
            }
            if !addedOrChanged.isEmpty {
                await testNodes(addedOrChanged, silent: true)
            }
        }

        if focusInNodeList, log.success {
            let imported = nodes.filter { $0.subscriptionID == id && !$0.pendingRemoval }
            if !imported.isEmpty {
                focusNodeList(source: .subscription(id), nodeID: imported.first?.id, openDetail: false)
                statusBanner = "已导入 \(imported.count) 个节点，已在节点列表中显示"
            }
        } else if !log.success, let error = merged.lastError ?? log.errorMessage {
            statusBanner = error
        }
    }

    func refreshAllSubscriptions() async {
        for sub in subscriptions where sub.isEnabled && !sub.isShareLinksBundle {
            await refreshSubscription(sub.id)
        }
    }

    func testSubscriptionAddress(_ id: UUID) async {
        guard let sub = subscriptions.first(where: { $0.id == id }) else { return }
        guard subscriptionManager.updateState == .idle, !subscriptionRefreshInProgress else {
            statusBanner = "订阅更新或地址测试进行中，请稍后再试"
            return
        }
        let report = await subscriptionManager.testAddress(sub)
        if let error = report.errorMessage {
            flashToast("订阅地址测试失败：\(error)")
        } else {
            flashToast("订阅地址可用，解析出 \(report.validCount) 个有效节点（未进行节点测速）")
        }
    }

    func testSubscriptionNodes(_ id: UUID) async {
        guard isLibraryReady, subscription(for: id) != nil else { return }
        guard !subscriptionRefreshInProgress, subscriptionManager.updateState == .idle else {
            statusBanner = "订阅更新或地址测试进行中，请稍后再试"
            return
        }
        let targets = nodes.filter { $0.subscriptionID == id && !$0.pendingRemoval }
        guard !targets.isEmpty else {
            statusBanner = "当前订阅没有可测试的节点，请先更新订阅"
            return
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
            statusBanner = "未解析到有效节点（支持 ss / vless / vmess / trojan）"
            return
        }

        let (subscriptionID, sourceName) = resolveImportTarget(source)
        let existingFingerprints = Set(nodes.map { $0.nodeFingerprint ?? NodeFingerprint.make(from: $0) })
        var imported = subscriptionManager.importShareLinks(
            importText,
            sourceName: sourceName,
            subscriptionID: subscriptionID
        )
        imported = imported.filter { node in
            let fp = node.nodeFingerprint ?? NodeFingerprint.make(from: node)
            return !existingFingerprints.contains(fp)
        }

        if imported.isEmpty {
            importText = ""
            showImportLinks = false
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
            subscriptions[index].statusMessage = "已追加 \(imported.count) 个节点"
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
        persist()
        warnUnsavedIfLibraryLocked()
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
        await connect(to: node)
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

    func unavailableCleanupCandidates(subscriptionID: UUID, now: Date = Date()) -> Set<UUID> {
        guard isLibraryReady, !testManager.isTesting, !testManager.isProbingApps,
              !subscriptionRefreshInProgress,
              let sub = subscription(for: subscriptionID) else { return [] }
        let cutoff = now.addingTimeInterval(-Double(min(30, max(1, sub.unavailableCleanupDays ?? 3))) * 86400)
        return Set(nodes.filter {
            $0.subscriptionID == subscriptionID && !$0.pendingRemoval && !$0.isFavorite &&
            $0.id != connection.state.currentNodeID && $0.lastTestStatus == .unavailable &&
            $0.unavailableSince.map { $0 <= cutoff } == true &&
            $0.lastTestDate.map { $0 >= cutoff } == true
        }.map(\.id))
    }

    func cleanupUnavailableNodes(subscriptionID: UUID, automatic: Bool = false) {
        let ids = unavailableCleanupCandidates(subscriptionID: subscriptionID)
        guard !ids.isEmpty else {
            if !automatic { statusBanner = "没有符合期限的不可用节点，或正在更新/测试" }
            return
        }
        if let index = subscriptions.firstIndex(where: { $0.id == subscriptionID }) {
            subscriptions[index].nodeCount = nodes.filter {
                $0.subscriptionID == subscriptionID && !ids.contains($0.id)
            }.count
            // An unchanged remote payload must be allowed to repopulate cleaned nodes.
            subscriptions[index].contentHash = nil
            subscriptions[index].etag = nil
            subscriptions[index].lastModified = nil
        }
        deleteNodes(ids)
        statusBanner = "\(automatic ? "自动" : "手动")清理了 \(ids.count) 个长期不可用节点"
    }

    func deleteNode(_ id: UUID) {
        nodes.removeAll { $0.id == id }
        pinnedNodeIDs.removeAll { $0 == id }
        if connection.state.currentNodeID == id {
            connection.state.currentNodeID = nil
        }
        if viewingNodeID == id { viewingNodeID = nil }
        persist()
    }

    func deleteNodes(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        nodes.removeAll { ids.contains($0.id) }
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

    /// 按 fingerprint 去重；同组保留优先级更高的一条。返回删除数量。
    @discardableResult
    func removeDuplicateNodes(among ids: Set<UUID>? = nil) -> Int {
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
                duplicateKeepScore(nodes[lhs]) > duplicateKeepScore(nodes[rhs])
            }
            for index in ranked.dropFirst() {
                removeIDs.insert(nodes[index].id)
            }
        }

        guard !removeIDs.isEmpty else {
            statusBanner = "没有发现重复节点"
            return 0
        }
        deleteNodes(removeIDs)
        statusBanner = "已删除 \(removeIDs.count) 个重复节点"
        return removeIDs.count
    }

    private func duplicateKeepScore(_ node: ProxyNode) -> Int {
        var score = 0
        if node.isFavorite { score += 1_000_000 }
        if connection.state.currentNodeID == node.id { score += 500_000 }
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

    func toggleConnection() async {
        switch connection.state.status {
        case .connected, .connecting, .disconnecting:
            await disconnect()
        case .disconnected, .error:
            if connection.isBusy {
                // 故障切换 / 连接过程中仍允许取消。
                await connection.disconnect(settings: settings)
                persist()
                return
            }
            if connection.state.autoSelectEnabled {
                await connectWithAutoSelect()
            } else if let node = preferredConnectNode() {
                await connect(to: node)
            } else {
                statusBanner = "请先添加订阅或选择海外可用节点"
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
        autoSelectResultsGeneration += 1
        await disconnect()
        guard connection.state.status == .disconnected, !connection.captureCleanupFailed else {
            statusBanner = "断开连接未完成，请重试后清除列表"
            return
        }
        var cleared = nodes
        for index in cleared.indices {
            cleared[index].lastTestStatus = .untested
            cleared[index].lastTestDate = nil
            cleared[index].lastLatency = nil
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

    /// 自动优选连接：先对头部候选做应用连通补测，再按最新排序连接第一名（与按国家连接逻辑一致）。
    func connectWithAutoSelect() async {
        eligibilitySwitchTask?.cancel()
        unexpectedReconnectTask?.cancel()
        recoveryAttemptedIDs.removeAll()

        let initialRanked = automaticallyRankedNodes(nodes)
        guard initialRanked.first != nil else {
            statusBanner = "请先添加订阅或选择海外可用节点"
            return
        }

        if settings.autoAppProbeUsableNodes {
            let probeLimit = max(settings.maxFailoverAttempts * 2, 10)
            let prefer = Set(initialRanked.prefix(probeLimit).map(\.id))
            await ensureAppProbesForUsableNodes(
                preferIDs: prefer,
                limit: probeLimit,
                silent: true
            )
        }

        guard let target = automaticallyRankedNodes(nodes).first else {
            statusBanner = "请先添加订阅或选择海外可用节点"
            return
        }

        do {
            try Task.checkCancellation()
            try await connection.connect(
                node: target,
                settings: settings,
                allNodes: nodes,
                countryCode: target.countryCode,
                countryName: target.countryName
            )
            if let id = connection.state.currentNodeID {
                pushRecent(id)
                markConnectedForNextLaunch(id)
            } else {
                pushRecent(target.id)
                markConnectedForNextLaunch(target.id)
            }
            persist()
            Task { await probeCurrentApps() }
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
            statusBanner = error.localizedDescription
            persist()
        }
    }

    /// 首页一键连接：开启自动优选时严格使用优选排序；关闭时沿用当前/最近节点。
    private func preferredConnectNode() -> ProxyNode? {
        if connection.state.autoSelectEnabled {
            return automaticallyRankedNodes(nodes).first
        }
        if let current = currentNode,
           !isCountryExcludedFromAutoSelect(CountryResolver.effectiveCode(for: current)) {
            return current
        }
        if let recent = recentNodes.first(where: {
            $0.enabled && !isChinaExit($0) &&
            !isCountryExcludedFromAutoSelect(CountryResolver.effectiveCode(for: $0))
        }) {
            return recent
        }
        if let recent = recentNodes.first(where: {
            $0.enabled && !isCountryExcludedFromAutoSelect(CountryResolver.effectiveCode(for: $0))
        }) {
            return recent
        }

        let usable = automaticallyRankedNodes(nodes)
        let overseas = usable
            .filter { !isChinaExit($0) }
        if let best = overseas.first { return best }

        return usable.first
    }

    func automaticallyRankedNodes(_ candidates: [ProxyNode]) -> [ProxyNode] {
        var usable = candidates.filter {
            $0.enabled && !$0.pendingRemoval && settings.allowsAutoSelectNode($0)
        }
        if settings.favoritePreference == .favoritesOnly {
            usable = usable.filter(\.isFavorite)
        }
        return usable.sorted { lhs, rhs in
            if settings.favoritePreference == .preferFavorites,
               lhs.isFavorite != rhs.isFavorite {
                return lhs.isFavorite && !rhs.isFavorite
            }
            return ProxyNode.autoSelectLessThan(
                lhs,
                rhs,
                considerAppProbe: settings.autoAppProbeUsableNodes
            )
        }
    }

    /// Recover an established connection that died at runtime. Limit retries in
    /// a rolling window so a repeatedly crashing core cannot spin forever.
    private func scheduleUnexpectedReconnect(avoiding failedNodeID: UUID?, reason: String) {
        guard networkRecovery.canRecover else { return }
        guard settings.autoFailover, connection.state.autoSelectEnabled else { return }

        let now = Date()
        unexpectedReconnectDates.removeAll { now.timeIntervalSince($0) > 60 }
        let retryLimit = max(1, min(settings.maxFailoverAttempts, 5))
        guard unexpectedReconnectDates.count < retryLimit else {
            statusBanner = "连接连续异常，已暂停自动重连"
            logger.error("60 秒内自动重连已达到 \(retryLimit) 次，停止重试", category: .network)
            return
        }
        unexpectedReconnectDates.append(now)

        unexpectedReconnectTask?.cancel()
        unexpectedReconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self,
                  self.connection.state.status == .error,
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

    func connect(to node: ProxyNode) async {
        eligibilitySwitchTask?.cancel()
        unexpectedReconnectTask?.cancel()
        recoveryAttemptedIDs.removeAll()
        do {
            // 用户点选单个节点：仅对该节点所在国家补测，不改成全局自动优选第一名。
            if connection.state.autoSelectEnabled, settings.autoAppProbeUsableNodes {
                let probeLimit = max(settings.maxFailoverAttempts * 2, 10)
                await ensureAppProbesForUsableNodes(
                    preferIDs: [node.id],
                    countryCode: node.countryCode,
                    limit: probeLimit,
                    silent: true
                )
            }
            try Task.checkCancellation()
            try await connection.connect(
                node: node,
                settings: settings,
                allNodes: nodes,
                countryCode: node.countryCode,
                countryName: node.countryName
            )
            // Record the node that actually connected (failover may switch).
            if let id = connection.state.currentNodeID {
                pushRecent(id)
                markConnectedForNextLaunch(id)
            } else {
                pushRecent(node.id)
                markConnectedForNextLaunch(node.id)
            }
            persist()
            // Refresh app reachability for the live proxy.
            Task { await probeCurrentApps() }
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
            statusBanner = error.localizedDescription
            persist()
        }
    }

    func connectCountry(_ code: String) async {
        eligibilitySwitchTask?.cancel()
        unexpectedReconnectTask?.cancel()
        recoveryAttemptedIDs.removeAll()
        do {
            // Optionally refresh stale tests first for top candidates.
            let groupNodes = nodes.filter {
                CountryResolver.effectiveCode(for: $0) == code.uppercased() &&
                $0.enabled && !$0.pendingRemoval
            }
            let ttl = TimeInterval(settings.testResultTTLMinutes * 60)
            let stale = groupNodes.filter { node in
                guard let date = node.lastTestDate else { return true }
                return Date().timeIntervalSince(date) > ttl
            }.prefix(5)

            if !stale.isEmpty {
                await testNodes(Array(stale), silent: true)
            }

            // 开启「自动应用连通」且自动优选时：该国未探测可用节点先补测再排序连接。
            if connection.state.autoSelectEnabled, settings.autoAppProbeUsableNodes {
                let probeLimit = max(settings.maxFailoverAttempts * 2, 10)
                await ensureAppProbesForUsableNodes(
                    preferIDs: Set(groupNodes.map(\.id)),
                    countryCode: code,
                    limit: probeLimit,
                    silent: true
                )
            }

            try await connection.connectBestNode(
                in: code,
                nodes: nodes,
                settings: settings
            )
            if let id = connection.state.currentNodeID {
                pushRecent(id)
                markConnectedForNextLaunch(id)
            }
            persist()
        } catch {
            if case ConnectionError.cancelled = error {
                return
            }
            statusBanner = error.localizedDescription
        }
    }

    func disconnect() async {
        recoveryAttemptedIDs.removeAll()
        recoveryHealthySince = nil
        eligibilitySwitchTask?.cancel()
        unexpectedReconnectTask?.cancel()
        unexpectedReconnectTask = nil
        startupConnectionIntent.reconnectOnNextLaunch = false
        store.saveStartupConnectionIntent(startupConnectionIntent)
        await connection.disconnect(settings: settings)
        testManager.resetAppProbes()
        purgePendingRemovalNodes()
        persist()
    }

    /// Quit cleanup must restore the system proxy without turning the preceding
    /// connected session into a user-requested disconnect.
    func disconnectForTermination() async {
        eligibilitySwitchTask?.cancel()
        unexpectedReconnectTask?.cancel()
        await connection.disconnect(settings: settings)
        persist()
    }

    private func markConnectedForNextLaunch(_ id: UUID) {
        startupConnectionIntent.lastConnectedNodeID = id
        startupConnectionIntent.reconnectOnNextLaunch = true
        store.saveStartupConnectionIntent(startupConnectionIntent)
    }

    // MARK: - Testing

    /// - Parameter silent: 定时/更新后等自动测速时为 true，不弹横幅与完成提示。
    func testNodes(_ targets: [ProxyNode], silent: Bool = false, strictResults: Bool = false) async {
        guard !targets.isEmpty else { return }
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
        // 开始新一轮前，清掉上一轮遗留的「测试中」（暂停残留 / 中断）。
        clearStuckTestingStatuses(except: ids)
        resetNodesForRetest(ids: ids)

        let started = await testManager.startTest(nodes: targets, settings: settings, silent: silent) { [weak self] id, result in
            self?.applyTestResult(id: id, result: result, strictResults: strictResults)
        }
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
        }
        persist()
        if stoppedByUser { return }

        // 测速结束后：对本轮测成「可用」且尚未做过应用连通的节点自动补测，再按通过数排序。
        if !testManager.isTesting, testManager.phase != .paused {
            await ensureAppProbesForUsableNodes(onlyIDs: ids, silent: silent)
            checkConnectedNodeEligibility()
        }

        // Drain automatic requests accumulated during this run. Resolve IDs against
        // the latest node array because another subscription refresh may have merged
        // or removed nodes while the current test was awaiting network work.
        if !testManager.isTesting,
           testManager.phase != .paused,
           !pendingSilentTestNodeIDs.isEmpty {
            let pendingIDs = pendingSilentTestNodeIDs
            pendingSilentTestNodeIDs.removeAll()
            let pendingNodes = nodes.filter { pendingIDs.contains($0.id) }
            if !pendingNodes.isEmpty {
                await testNodes(pendingNodes, silent: true)
            }
        }
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
        silent: Bool = true
    ) async {
        guard settings.autoAppProbeUsableNodes else { return }
        guard !settings.automaticAppProbeTargets.isEmpty else {
            if !silent { statusBanner = "请先为规则代理中的应用配置测试地址" }
            return
        }
        guard !testManager.isTesting, !testManager.isProbingApps else { return }

        var pending = nodes.filter { node in
            node.enabled &&
            !node.pendingRemoval &&
            node.lastTestStatus.isUsable &&
            node.lastAppProbeDate == nil
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

        let timeout = TimeInterval(max(1, settings.appProbeTimeoutSeconds))
        for (index, node) in targets.enumerated() {
            // 用户又开了测速 / 手动探测时让出。
            if testManager.isTesting || testManager.isProbingApps { break }
            // 期间节点可能被删或状态变了。
            guard let latest = nodes.first(where: { $0.id == node.id }),
                  latest.lastTestStatus.isUsable,
                  latest.lastAppProbeDate == nil
            else { continue }

            if !silent {
                statusBanner = "应用连通补测 \(index + 1)/\(targets.count)：\(latest.displayTitle)"
            }

            let generation = autoSelectResultsGeneration
            let probeTargets = settings.automaticAppProbeTargets
            let summary = await testManager.measureAppProbe(for: latest, timeout: timeout, targets: probeTargets)
            guard generation == autoSelectResultsGeneration,
                  probeTargets == settings.automaticAppProbeTargets else { break }
            applyAppProbeSummary(
                nodeID: latest.id,
                okCount: summary.okCount,
                bestLatencyMs: summary.bestLatencyMs
            )
        }

        if !silent {
            statusBanner = "应用连通补测完成，已按通过数重排优选顺序"
        }
        persist()
    }

    private func applyAppProbeSummary(nodeID: UUID, okCount: Int, bestLatencyMs: Int?) {
        guard let index = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        var copy = nodes
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

    private func applyTestResult(id: UUID, result: NodeTestResult, strictResults: Bool = false) {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
        // Reassign the array so @Published reliably notifies SwiftUI (in-place
        // `nodes[i].x =` often does not).
        var copy = nodes
        let previous = copy[index].lastTestStatus
        let connected = connection.state.status == .connected && connection.state.currentNodeID == id
        let isFavorite = copy[index].isFavorite
        let wasUsable = previous.isUsable

        copy[index].lastTestDate = result.finishedAt
        if result.success {
            copy[index].lastAvailableAt = result.finishedAt
            copy[index].lastLatency = result.proxyLatency ?? result.primaryLatency
            copy[index].lastTestStatus = NodeTestStatus.from(latencyMs: copy[index].lastLatency ?? 0)
        } else if result.isConfigFailure {
            // 配置/客户端无法测 →「失败」，不是「不可用」。
            copy[index].lastLatency = nil
            if !strictResults, wasUsable, connected {
                copy[index].lastTestStatus = previous
            } else {
                copy[index].lastTestStatus = .failed
            }
        } else {
            copy[index].lastLatency = result.proxyLatency ?? result.tcpLatency ?? result.primaryLatency
            // 仅保护当前正在连接的节点；收藏标记不豁免失败结果。
            if !strictResults, wasUsable, connected {
                copy[index].lastTestStatus = previous
            } else {
                copy[index].lastTestStatus = .unavailable
            }
        }
        if result.success {
            copy[index].unavailableSince = nil
        } else if !result.isConfigFailure, copy[index].lastTestStatus == .unavailable {
            copy[index].unavailableSince = copy[index].unavailableSince ?? result.finishedAt
        } else {
            copy[index].unavailableSince = nil
        }
        // Favorites are never cleared by test outcomes.
        copy[index].isFavorite = isFavorite
        if let code = result.exitCountryCode {
            CountryResolver.applyExitIP(
                to: &copy[index],
                countryCode: code,
                countryName: result.exitCountryName
            )
        }
        nodes = copy
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
        await testManager.resumeTest(
            nodesByID: { [weak self] id in
                self?.nodes.first { $0.id == id && $0.enabled && !$0.pendingRemoval }
            },
            settings: settings
        ) { [weak self] id, result in
            self?.applyTestResult(id: id, result: result)
        }
        let stoppedByUser = testManager.consumeUserStop()
        if !testManager.isTesting {
            clearStuckTestingStatuses(except: testManager.phase == .paused ? Set(testManager.remainingNodeIDs) : [])
        }
        if stoppedByUser {
            statusBanner = "测速已停止"
        }
        persist()
    }

    func testCurrentConnection() async {
        guard let node = currentNode else {
            statusBanner = "当前未连接"
            return
        }
        guard connection.state.status == .connected else {
            statusBanner = "请先连接节点后再测试"
            return
        }
        resetNodesForRetest(ids: [node.id])
        let result = await testManager.testSingle(node: node, settings: settings, includeExitIP: true)
        applyTestResult(id: node.id, result: result)
        if result.success {
            connection.state.latency = result.primaryLatency
            connection.state.exitIP = result.exitIP
            connection.state.exitCountry = result.exitCountryName ?? result.exitCountryCode
            statusBanner = "节点测试完成：\(result.primaryLatency.map { LatencyFormat.seconds($0) } ?? "可用")"
        } else {
            statusBanner = result.errorMessage ?? "测试失败"
        }
        // Always run app probes against the live system proxy after a current-connection test.
        await probeLiveConnectionApps()
        persist()
    }

    /// Probe apps for a node selected in Test Center — does **not** switch system proxy.
    func probeApps(forSelectedNode node: ProxyNode) async {
        let label = appProbeNodeDescription(for: node)
        await testManager.probeApps(
            for: node,
            nodeLabel: label,
            settings: settings,
            timeout: TimeInterval(max(1, settings.appProbeTimeoutSeconds))
        )
        syncNodeStatusFromAppProbe(nodeID: node.id)
    }

    /// Probe Google / Cloudflare / ChatGPT … through the **live** system proxy.
    func probeLiveConnectionApps() async {
        guard connection.state.status == .connected else {
            testManager.resetAppProbes()
            statusBanner = "当前未连接代理；可在节点结果中选中节点做应用探测（不切换系统代理）"
            return
        }
        guard let node = currentNode else {
            testManager.resetAppProbes()
            statusBanner = "未识别当前连接节点"
            return
        }
        let label = appProbeNodeDescription(for: node)
        await testManager.probeApps(
            proxyHost: settings.httpHost,
            httpPort: settings.httpPort,
            socksPort: settings.socksPort,
            timeout: TimeInterval(max(1, settings.appProbeTimeoutSeconds)),
            nodeLabel: label,
            targets: settings.automaticAppProbeTargets
        )
        syncNodeStatusFromAppProbe(nodeID: node.id)
    }

    /// 把应用连通结果写回节点，供自动优选排序使用。
    private func persistAppProbeSummary(nodeID: UUID) {
        let ok = testManager.appProbeResults.filter { $0.status == .ok }
        applyAppProbeSummary(
            nodeID: nodeID,
            okCount: ok.count,
            bestLatencyMs: ok.compactMap(\.latencyMs).min()
        )
        persist()
    }

    /// 应用连通多数通过时，纠正「不可用」残留（应用探测本身不改测速结果，否则列表一直红叉）。
    private func syncNodeStatusFromAppProbe(nodeID: UUID) {
        persistAppProbeSummary(nodeID: nodeID)

        let okCount = nodes.first(where: { $0.id == nodeID })?.lastAppProbeOkCount ?? 0
        guard okCount >= 3 else { return }
        guard let index = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        guard !nodes[index].lastTestStatus.isUsable else { return }

        let ms = nodes[index].lastAppProbeLatency ?? 3_000
        var copy = nodes
        copy[index].lastLatency = ms
        copy[index].lastTestStatus = NodeTestStatus.from(latencyMs: ms)
        copy[index].unavailableSince = nil
        copy[index].lastTestDate = Date()
        nodes = copy
        persist()
    }

    /// Backward-compatible name used by older call sites.
    func probeCurrentApps() async {
        await probeLiveConnectionApps()
    }

    func appProbeNodeDescription(for node: ProxyNode) -> String {
        let flag = FlagResolver.flag(for: node.countryCode)
        let country = node.countryName ?? node.countryCode ?? ""
        if country.isEmpty {
            return "\(flag) \(node.displayTitle)"
        }
        return "\(flag) \(country) · \(node.displayTitle)"
    }

    private func pushRecent(_ id: UUID) {
        recentNodeIDs.removeAll { $0 == id }
        recentNodeIDs.insert(id, at: 0)
        if recentNodeIDs.count > 8 {
            recentNodeIDs = Array(recentNodeIDs.prefix(8))
        }
    }

    // MARK: - Scheduler

    private func startScheduler() {
        schedulerTimer?.invalidate()
        schedulerTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.schedulerTick()
            }
        }
        Task { await schedulerTick() }
    }

    private func schedulerTick() async {
        let now = Date()
        for index in subscriptions.indices where subscriptions[index].isEnabled && subscriptions[index].autoUpdate {
            let sub = subscriptions[index]
            if let retryAt = sub.nextRetryAt, retryAt <= now {
                await refreshSubscription(sub.id)
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
                await refreshSubscription(sub.id)
            }
        }

        for sub in subscriptions where sub.isEnabled && sub.autoCleanupUnavailableNodes == true {
            cleanupUnavailableNodes(subscriptionID: sub.id, automatic: true)
        }
        await runScheduledTestIfDue(now: now)
    }

    private func runScheduledTestIfDue(now: Date) async {
        guard settings.scheduledTestEnabled else { return }
        guard !testManager.isTesting else { return }

        let interval = TimeInterval(max(5, settings.scheduledTestIntervalMinutes) * 60)
        if let last = settings.lastScheduledTestAt, now.timeIntervalSince(last) < interval {
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

        await testNodes(targets, silent: true)
        updateSettings { $0.lastScheduledTestAt = Date() }
    }

    /// App probe controls can invoke their bindings during a SwiftUI update.
    /// Commit on the next main-queue turn so the dependent published state is safe to reset.
    func updateAppProbeSettings(_ mutate: @escaping (inout AppSettings) -> Void) {
        DispatchQueue.main.async { [weak self] in
            self?.updateSettings(mutate)
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
        updated.screenLockDisconnectDelayMinutes = min(1440, max(0, updated.screenLockDisconnectDelayMinutes))
        updated.scheduledTestIntervalMinutes = min(1440, max(5, updated.scheduledTestIntervalMinutes))
        let probeTargetsChanged = previousSettings.automaticAppProbeTargets != updated.automaticAppProbeTargets
        if probeTargetsChanged {
            var updatedNodes = nodes
            for index in updatedNodes.indices {
                updatedNodes[index].lastAppProbeDate = nil
                updatedNodes[index].lastAppProbeOkCount = nil
                updatedNodes[index].lastAppProbeLatency = nil
            }
            nodes = updatedNodes
        }
        settings = updated
        if probeTargetsChanged { testManager.resetAppProbes(targets: settings.automaticAppProbeTargets) }
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
        try rules.validate()
        updateSettings { $0.routingRules = rules }
        statusBanner = "规则已保存"
        if settings.routingMode == .rules,
           connection.state.status == .connected || connection.state.status == .connecting,
           let node = currentNode {
            do {
                try await connection.connect(node: node, settings: settings, allNodes: nodes,
                                             countryCode: node.countryCode, countryName: node.countryName)
                statusBanner = "规则已保存并生效"
            } catch {
                statusBanner = "规则已保存，但重连失败：\(error.localizedDescription)"
                throw error
            }
        }
    }

    /// 切换路由模式；若当前已连接则用新模式重连当前节点。
    func setRoutingMode(_ mode: RoutingMode) async {
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
                allNodes: nodes,
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
        if wasConnected { await disconnect() }
        updateSettings {
            $0.proxyApplications = Array(Set(applications)).sorted { $0.path < $1.path }
            $0.connectionCaptureMode = .applications
        }
        statusBanner = wasConnected
            ? "应用代理设置已保存，正在重新连接；成功后才生效。"
            : "应用代理设置已保存，尚未生效；请连接节点并完成管理员授权。"
        if wasConnected, let node { await connect(to: node) }
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
        guard settings.connectionCaptureMode != mode else { return }
        let wasConnected = connection.state.status == .connected
        let node = currentNode

        if wasConnected {
            await disconnect()
        }

        updateSettings { $0.connectionCaptureMode = mode }
        statusBanner = "连接方式已切换为\(mode.displayName)"

        guard wasConnected, let node else { return }
        await connect(to: node)
    }
}
