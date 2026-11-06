import Foundation
import ServiceManagement
import Darwin

@MainActor
final class ConnectionManager: ObservableObject {
    @Published var state = ConnectionState()
    @Published var isBusy = false
    /// 本次连接的出口确认已经结束。状态可能先变成已连接，此标记仍为 false。
    @Published private(set) var sessionReady = false
    /// 当前故障切换进度文案，例如「第 2/5 个节点…」
    @Published var failoverStatus: String?
    @Published private(set) var nodeQuality: [UUID: AIConnectionQuality] = [:]
    private var qualityContexts: [UUID: String] = [:]
    @Published private(set) var qualityTestNodeID: UUID?
    @Published private(set) var qualityTestMessage = ""
    @Published private(set) var qualityTestStartedAt: Date?
    @Published private(set) var qualityTestIsDeep = false
    private var qualityTask: Task<Void, Never>?
    private var qualityRunID = UUID()
    private var automaticQualityTask: Task<Void, Never>?
    private var automaticQualityRunID = UUID()
    @Published private(set) var automaticQualityPaused = false
    @Published private(set) var referenceTestNodeID: UUID?
    @Published private(set) var referenceTestRunning = false
    @Published private(set) var referenceTestCompleted = 0
    @Published private(set) var referenceTestMessage = ""
    private var referenceTask: Task<Void, Never>?
    private var referenceRunID = UUID()
    private var activeQualityProxy: (port: Int, password: String)?
    private var diagnosticSession = "pending"

    private let xray = XrayProcessManager()
    private let proxyManager = SystemProxyManager()
    private let vpnManager = VPNManager()
    private let applicationProxyManager = ApplicationProxyManager()
    private let logger = AppLogger.shared
    private var configURL: URL?
    private let operations = ConnectionOperations()
    private var connectGeneration: Int { operations.generation }
    private var activeSettings: AppSettings?
    private var activeProbePort: Int?
    @Published private(set) var captureCleanupFailed = false
    /// Called after an established connection is unexpectedly torn down and
    /// capture cleanup has completed, so AppState can choose a fresh candidate.
    var isNodeTemporarilyBlocked: ((UUID) -> Bool)?
    var rankAutomaticCandidates: (([ProxyNode]) -> [ProxyNode])?
    var onNodeConnectionFailed: ((UUID) -> Void)?
    var onUnexpectedDisconnect: ((UUID?, String, Bool) -> Void)?
    /// Runtime snapshot, deliberately not read from the editable/saved settings.
    var effectiveCaptureMode: ConnectionCaptureMode? {
        guard state.status == .connected, !captureCleanupFailed else { return nil }
        return activeSettings?.connectionCaptureMode
    }
    /// Use the running route, since saved settings can change before reconnecting.
    var applicationHealthSettings: AppSettings? { activeSettings }
    private var exitTask: Task<Void, Never>?
    private var metricsTask: Task<Void, Never>?
    private var liveLatencyTask: Task<Void, Never>?
    /// Returns `.error` → `.disconnected` after idle so the UI does not stick on「连接异常」.
    private var errorIdleRecoveryTask: Task<Void, Never>?
    private(set) var automaticRecoveryPending = false
    private static let errorIdleRecoveryNanoseconds: UInt64 = 15_000_000_000
    var onLiveLatencySample: (() -> Void)?
    var onExitMetadata: ((UUID, NodeExitMetadata) -> Void)?
    private var lastTrafficSample: (upload: Int64, download: Int64, at: Date)?
    private var trafficBaseline: (upload: Int64, download: Int64)?

    func bootstrapRestore(settings: AppSettings) async {
        applicationProxyManager.onUnexpectedStop = { [weak self] status in
            guard let self, self.state.status == .connected,
                  self.activeSettings?.connectionCaptureMode.usesTun == true else { return }
            let generation = self.connectGeneration
            Task { @MainActor in
                guard generation == self.connectGeneration else { return }
                let failedNodeID = self.state.currentNodeID
                var cleanupGeneration: Int?
                try? await self.operations.perform { operationGeneration in
                    guard let settings = self.activeSettings else { return }
                    // Mark the capture failure before stopping Xray so its
                    // intentional teardown is not reported as a second crash.
                    await self.failAndClearProxy(
                        settings: settings,
                        message: "TUN 已停止：\(status.message)"
                    )
                    cleanupGeneration = operationGeneration
                }
                if let cleanupGeneration, !Task.isCancelled, cleanupGeneration == self.connectGeneration {
                    self.onUnexpectedDisconnect?(failedNodeID, "TUN 已停止：\(status.message)", status.allowsAutomaticRecovery)
                }
            }
        }
        let running = await xray.isRunning()
        do {
            try await proxyManager.restoreIfOrphaned(
                expectedHTTPPort: settings.httpPort,
                expectedSOCKSPort: settings.socksPort,
                xrayRunning: running
            )
        } catch {
            logger.warning("启动恢复代理检查失败：\(error.localizedDescription)", category: .systemProxy)
        }

        // Best-effort: leave a stale HopWorld VPN disconnected on launch if xray is gone.
        if !running {
            await vpnManager.stop()
        }

        vpnManager.setStatusHandler { [weak self] status in
            guard let self else { return }
            // Only mirror unexpected VPN drops while we think we're connected.
            guard self.state.status == .connected, self.activeSettings?.connectionCaptureMode == .systemVPN else { return }
            if status == .disconnected || status == .invalid {
                Task { @MainActor in
                    await self.handleVPNDrop()
                }
            }
        }

        await xray.setTerminationHandler { [weak self] in
            Task { @MainActor in
                self?.handleXrayCrash()
            }
        }
    }

    func revalidateAfterNetworkChange() async {
        guard state.status == .connected, !isBusy, !captureCleanupFailed,
              let settings = activeSettings, let probePort = activeProbePort else { return }
        cancelQualityTest()
        cancelReferenceTest()
        stopAutomaticQuality()
        let generation = connectGeneration
        let nodeID = state.currentNodeID
        var failed = false
        var revalidated = false
        var failureMessage = "网络变化后连接验证失败，请重新连接"
        do {
            try await operations.maintainIfIdle {
                guard generation == self.connectGeneration, self.state.status == .connected else { return }
                self.isBusy = true
                defer { self.isBusy = false }
                self.logger.debug("网络变化或唤醒，正在复验当前连接", category: .network)
                let running = await self.xray.isRunning()
                // 直连不走节点；测试地址探测不能当作连接门槛。
                let requiresProbe = settings.routingMode != .direct
                let latency = requiresProbe
                    ? await self.verifyConnectivity(settings: settings, probePort: probePort,
                                                    timeout: ConnectionPatiencePolicy.initialTimeout(configured: settings.connectTimeoutSeconds), generation: generation)
                    : nil
                try Task.checkCancellation()
                guard generation == self.connectGeneration, self.state.status == .connected else { return }
                guard running, !requiresProbe || latency != nil else {
                    throw ConnectionError.noCandidates
                }
                if settings.connectionCaptureMode == .systemProxy {
                    let matches = try await self.proxyManager.matchesSystemProxy(
                        httpHost: settings.httpHost, httpPort: settings.httpPort,
                        socksHost: settings.socksHost, socksPort: settings.socksPort)
                    try Task.checkCancellation()
                    if !matches {
                        try await self.proxyManager.enableSystemProxy(
                            httpHost: settings.httpHost, httpPort: settings.httpPort,
                            socksHost: settings.socksHost, socksPort: settings.socksPort)
                    }
                } else if settings.connectionCaptureMode.usesTun {
                    // No new administrator prompts or silent capture-mode changes.
                    try await self.proxyManager.requireDirectSystemSettings()
                }
                try Task.checkCancellation()
                if let nodeID { self.nodeQuality[nodeID] = AIConnectionQuality() }
                if let latency { self.state.recordLatency(latency) }
                let exit = await ExitIPTester.fetch(proxyHost: "127.0.0.1", proxyPort: probePort, timeout: 5, socksPort: nil)
                try Task.checkCancellation()
                self.state.recordExitIP(exit.ip, type: exit.networkType)
                self.recordExitObservation(exit, nodeID: nodeID)
                self.state.exitCountry = exit.countryName ?? exit.countryCode
                self.state.exitCity = exit.city
                self.state.exitOperator = exit.networkOperator
                self.state.exitASN = exit.asn
                self.state.lastError = nil
                self.logger.debug("网络变化后的连接复验完成", category: .network)
                revalidated = true
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == connectGeneration, state.status == .connected else { return }
            failureMessage = "网络变化后连接验证失败：\(error.localizedDescription)"
            try? await operations.maintainIfIdle {
                await self.failAndClearProxy(
                    settings: settings,
                    message: failureMessage
                )
                failed = true
            }
        }
        if failed, !Task.isCancelled, generation == connectGeneration,
           settings.connectionCaptureMode == .systemProxy, !captureCleanupFailed {
            onUnexpectedDisconnect?(nodeID, failureMessage, true)
        }
        if revalidated, !Task.isCancelled, generation == connectGeneration,
           let nodeID, state.currentNodeID == nodeID, state.status == .connected {
            startAutomaticQuality(nodeID: nodeID, generation: generation)
        }
    }

    /// 连接指定节点；开启自动故障切换时，超时后按收藏列表顺序尝试后续节点。
    func connect(
        node: ProxyNode,
        settings: AppSettings,
        allNodes: [ProxyNode] = [],
        countryCode: String? = nil,
        countryName: String? = nil,
        reason: String? = nil
    ) async throws {
        var settings = settings
        settings.normalizeApplicationProxyMode()
        logConnectionReplacement(node: node, settings: settings, reason: reason)
        do {
            try Task.checkCancellation()
            cancelErrorIdleRecovery()
            sessionReady = false
            state.status = .connecting
            state.lastError = nil
            try await operations.perform { _ in
                try await self.connectBody(node: node, settings: settings, allNodes: allNodes,
                                           countryCode: countryCode, countryName: countryName)
            }
        } catch is CancellationError { throw ConnectionError.cancelled }
    }

    private func connectBody(node: ProxyNode, settings: AppSettings, allNodes: [ProxyNode],
                             countryCode: String?, countryName: String?) async throws {
        if let previous = activeSettings, previous.connectionCaptureMode != settings.connectionCaptureMode {
            await teardownProxy(settings: previous, restoreSystemProxy: true)
        }
        try Task.checkCancellation()
        activeSettings = settings
        // Dashboard「自动优选」off → only the node the user picked.
        let allowFailover = settings.autoFailover && state.autoSelectEnabled
        if allowFailover, !allNodes.isEmpty {
            try await connectWithFailover(
                preferred: node,
                nodes: allNodes,
                settings: settings,
                countryCode: countryCode ?? node.countryCode,
                countryName: countryName ?? node.countryName,
                restrictToCountry: node.countryCode
            )
        } else {
            try await connectOnce(
                node: node,
                settings: settings,
                countryCode: countryCode,
                countryName: countryName,
                verify: false
            )
        }
    }

    func connectBestNode(
        in countryCode: String,
        nodes: [ProxyNode],
        settings: AppSettings
    ) async throws {
        var settings = settings
        settings.normalizeApplicationProxyMode()
        let candidates = selectCandidates(countryCode: countryCode, nodes: nodes, settings: settings)
        guard let first = candidates.first else {
            throw ConnectionError.noCandidates
        }
        try await connect(node: first, settings: settings, allNodes: candidates,
                          countryCode: countryCode, countryName: first.countryName)
    }

    private func logConnectionReplacement(node: ProxyNode, settings: AppSettings, reason: String?) {
        guard state.status == .connected || state.status == .connecting else { return }
        let change: String
        if let reason {
            change = reason
        } else if let previous = activeSettings, previous.connectionCaptureMode != settings.connectionCaptureMode {
            change = "切换接管方式：\(previous.connectionCaptureMode.displayName) → \(settings.connectionCaptureMode.displayName)"
        } else if let previous = activeSettings, previous.routingMode != settings.routingMode {
            change = "切换路由模式：\(previous.routingMode.displayName) → \(settings.routingMode.displayName)"
        } else if state.currentNodeID != node.id {
            change = "切换节点至 \(settings.nodeDisplayTitle(node))"
        } else {
            change = "重新连接当前节点"
        }
        let previousNode = state.currentNodeID?.uuidString.prefix(8) ?? "unknown"
        logger.info("正在替换连接 session=\(diagnosticSession)，旧连接将断开；原因：\(change)；原节点标识：\(previousNode)", category: .network)
    }

    func disconnect(settings: AppSettings, reason: String) async {
        setAutomaticRecoveryPending(false)
        let hadSession = state.status != .disconnected || isBusy || activeSettings != nil || captureCleanupFailed
        // Cancellation can clear the old session before disconnectBody runs.
        if hadSession {
            let node = state.currentNodeID?.uuidString.prefix(8) ?? "unknown"
            let captureMode = (activeSettings ?? settings).connectionCaptureMode.displayName
            logger.info("开始断开连接 session=\(diagnosticSession)；原因：\(reason)；节点标识：\(node)；接管方式：\(captureMode)", category: .network)
        }
        do {
            try await operations.perform { _ in
                await self.disconnectBody(settings: self.activeSettings ?? settings, reason: reason, hadSession: hadSession)
            }
        } catch {
            logger.info("断开请求已被取消或被后续操作取代；原因：\(reason)", category: .network)
        }
    }

    private func disconnectBody(settings: AppSettings, reason: String, hadSession: Bool) async {
        // 上一次断开已完成时，排队进来的第二次断开直接结束，避免状态再闪「断开中」。
        if state.status == .disconnected, activeSettings == nil, !captureCleanupFailed {
            isBusy = false
            failoverStatus = nil
            if hadSession { logger.info("已断开连接；原因：\(reason)", category: .network) }
            return
        }
        isBusy = true
        sessionReady = false
        // 先抬世代，打断进行中的 connect / failover / 验证。
        failoverStatus = nil
        stopMetrics()
        state.status = .disconnecting

        let cleanupSettings = activeSettings ?? settings
        await teardownProxy(settings: cleanupSettings, restoreSystemProxy: true)
        if captureCleanupFailed {
            // Keep「连接异常」until the user retries disconnect — do not auto-idle.
            cancelErrorIdleRecovery()
            state.status = .error
            state.lastError = "代理清理尚未确认，请稍后再次断开；未宣称网络已恢复。"
            isBusy = false
            logger.error("断开连接未完成；原因：\(reason)；代理清理尚未确认，请重试断开", category: .network)
            return
        }
        cancelErrorIdleRecovery()
        activeSettings = nil
        state = ConnectionState(autoSelectEnabled: state.autoSelectEnabled)
        state.status = .disconnected
        isBusy = false
        logger.info("已断开连接；原因：\(reason)", category: .network)
    }

    // MARK: - Failover

    private func connectWithFailover(
        preferred: ProxyNode,
        nodes: [ProxyNode],
        settings: AppSettings,
        countryCode: String?,
        countryName: String?,
        restrictToCountry: String? = nil
    ) async throws {
        let chain = buildFailoverChain(
            preferred: preferred,
            nodes: nodes,
            settings: settings,
            restrictToCountry: restrictToCountry
        )
        guard !chain.isEmpty else {
            throw ConnectionError.noCandidates
        }

        let attempts: Int = {
            switch settings.failoverPoolMode {
            case .allAvailable:
                return max(1, chain.count)
            case .limited:
                return max(1, min(settings.maxFailoverAttempts, chain.count))
            }
        }()
        let chainDescription = chain.prefix(attempts).enumerated().map { index, candidate in
            "\(index + 1).\(settings.nodeDisplayTitle(candidate))[\(candidate.protocolType.displayName)/\(candidate.transport.displayName)/\(candidate.security.displayName), \(candidate.server):\(candidate.port)]"
        }.joined(separator: " → ")
        logger.debug("自动故障切换候选（共 \(attempts) 个）：\(chainDescription)", category: .network)
        var lastError: Error?
        let sessionGeneration = connectGeneration

        isBusy = true
        defer {
            isBusy = false
            failoverStatus = nil
        }

        cancelErrorIdleRecovery()
        sessionReady = false
        state.status = .connecting
        state.lastError = nil

        for (index, node) in chain.prefix(attempts).enumerated() {
            guard connectGeneration == sessionGeneration, !Task.isCancelled else {
                await teardownProxy(settings: settings, restoreSystemProxy: true)
                state.status = .disconnected
                throw ConnectionError.cancelled
            }

            if isNodeTemporarilyBlocked?(node.id) == true { continue }
            failoverStatus = "正在连接 \(index + 1)/\(attempts)：\(settings.nodeDisplayTitle(node))"
            logger.debug("尝试连接 [\(index + 1)/\(attempts)] \(settings.nodeDisplayTitle(node))", category: .network)
            state.currentNodeID = node.id
            state.currentCountryCode = countryCode ?? node.countryCode
            state.currentCountryName = countryName ?? node.countryName
            state.protocolType = node.protocolType

            do {
                try await connectOnce(
                    node: node,
                    settings: settings,
                    countryCode: countryCode ?? node.countryCode,
                    countryName: countryName ?? node.countryName,
                    verify: false,
                    manageBusyFlag: false
                )
                failoverStatus = nil
                return
            } catch {
                if error is ApplicationProxyError {
                    await failAndClearProxy(settings: settings, message: error.localizedDescription)
                    throw error // Never repeat administrator prompts across the failover pool.
                }
                if Task.isCancelled || error is CancellationError {
                    await teardownProxy(settings: settings, restoreSystemProxy: true)
                    clearSessionToDisconnected()
                    throw ConnectionError.cancelled
                }
                if case ConnectionError.cancelled = error {
                    await teardownProxy(settings: settings, restoreSystemProxy: true)
                    clearSessionToDisconnected()
                    throw error
                }
                if connectGeneration != sessionGeneration {
                    await teardownProxy(settings: settings, restoreSystemProxy: true)
                    clearSessionToDisconnected()
                    throw ConnectionError.cancelled
                }
                lastError = error
                if isNodeTemporarilyBlocked?(node.id) != true { onNodeConnectionFailed?(node.id) }
                logger.warning(
                    "节点超时或失败，切换下一个候选：\(settings.nodeDisplayTitle(node)) — \(error.localizedDescription)",
                    category: .network
                )
                await teardownProxy(settings: settings, restoreSystemProxy: false)
            }
        }

        // 全部失败：恢复系统代理并清掉会话，避免残留代理影响本机网络。
        await failAndClearProxy(
            settings: settings,
            message: lastError?.localizedDescription ?? "连接失败：收藏节点均不可用"
        )
        throw lastError ?? ConnectionError.connectFailed
    }

    /// 故障切换队列：
    /// 1) 用户点的节点
    /// 2) 其余可用节点：若开启自动应用连通则按通过数分档，否则按测速延迟；同国家稍优先
    /// 候选数量由 failoverPoolMode / maxFailoverAttempts 截断。
    private func buildFailoverChain(
        preferred: ProxyNode,
        nodes: [ProxyNode],
        settings: AppSettings,
        restrictToCountry: String?
    ) -> [ProxyNode] {
        let countryLock = restrictToCountry ?? preferred.countryCode

        func sameCountry(_ node: ProxyNode) -> Bool {
            guard let code = countryLock else { return true }
            return CountryResolver.effectiveCode(for: node) == code.uppercased()
        }

        func isUsable(_ node: ProxyNode) -> Bool {
            node.enabled &&
            !node.pendingRemoval &&
            (node.lastTestStatus.isUsable)
        }

        var chain: [ProxyNode] = []
        var seen = Set<UUID>()

        func append(_ node: ProxyNode) {
            guard !seen.contains(node.id) else { return }
            seen.insert(node.id)
            chain.append(node)
        }

        append(preferred)

        var pool = nodes.filter {
            isUsable($0) && $0.id != preferred.id &&
            (restrictToCountry == nil || sameCountry($0)) &&
            settings.allowsAutoSelectNode($0)
        }

        switch settings.favoritePreference {
        case .favoritesOnly:
            pool = pool.filter(\.isFavorite)
        case .preferFavorites, .all:
            break
        }

        let appOrder = settings.automaticAppProbeTargets.map(\.id)
        var ranked = pool + [preferred]
        ranked.sort { lhs, rhs in
            ProxyNode.autoSelectLessThan(
                lhs, rhs,
                considerAppProbe: settings.autoAppProbeUsableNodes,
                appOrder: appOrder,
                preferFavorites: settings.favoritePreference == .preferFavorites
            )
        }
        if settings.codexSmartFailover, let rankAutomaticCandidates {
            ranked = rankAutomaticCandidates(ranked)
        }
        let eligible = Dictionary(uniqueKeysWithValues: pool.map { ($0.id, $0) })
        pool = ApplicationHealthFailoverPolicy.orderedCandidates(in: ranked.map(\.id), after: preferred.id)
            .compactMap { eligible[$0] }

        let limit: Int = {
            switch settings.failoverPoolMode {
            case .allAvailable:
                return pool.count
            case .limited:
                // preferred 已占 1 席，再补 N-1 个可用。
                return max(0, settings.maxFailoverAttempts - 1)
            }
        }()
        pool.prefix(limit).forEach(append)

        return chain
    }

    // MARK: - Single attempt

    private func connectOnce(
        node: ProxyNode,
        settings: AppSettings,
        countryCode: String? = nil,
        countryName: String? = nil,
        verify: Bool,
        manageBusyFlag: Bool = true
    ) async throws {
        cancelQualityTest()
        let generation = connectGeneration
        stopMetrics()
        exitTask?.cancel()
        exitTask = nil
        if manageBusyFlag {
            isBusy = true
        }
        defer {
            if manageBusyFlag { isBusy = false }
        }

        cancelErrorIdleRecovery()
        sessionReady = false
        state.status = .connecting
        state.lastError = nil
        state.resetLatency()
        diagnosticSession = String(UUID().uuidString.prefix(12))
        logger.info("连接诊断 session=\(diagnosticSession)；开始尝试；节点标识=\(node.id.uuidString.prefix(8))", category: .network)
        // 连接过程中立刻绑定节点，列表可显示「连接中」。
        state.currentNodeID = node.id
        state.currentCountryCode = countryCode ?? node.countryCode
        state.currentCountryName = countryName ?? node.countryName
        state.protocolType = node.protocolType

        do {
            try await connectOnceBody(
                node: node,
                settings: settings,
                countryCode: countryCode,
                countryName: countryName,
                verify: verify,
                generation: generation
            )
        } catch {
            if manageBusyFlag {
                if Task.isCancelled || error is CancellationError {
                    await teardownProxy(settings: settings, restoreSystemProxy: true)
                    clearSessionToDisconnected()
                } else if case ConnectionError.cancelled = error {
                    await teardownProxy(settings: settings, restoreSystemProxy: true)
                    clearSessionToDisconnected()
                } else if state.currentNodeID == node.id {
                    await failAndClearProxy(settings: settings, message: error.localizedDescription)
                } else {
                    await teardownProxy(settings: settings, restoreSystemProxy: true)
                    activeSettings = nil
                }
            }
            throw error
        }
    }

    private func connectOnceBody(
        node: ProxyNode,
        settings: AppSettings,
        countryCode: String?,
        countryName: String?,
        verify: Bool,
        generation: Int
    ) async throws {
        guard isNodeTemporarilyBlocked?(node.id) != true else { throw ConnectionError.temporarilyBlocked }
        let startedAt = Date()
        // Stop an existing TUN before replacing its local upstream core.
        guard await applicationProxyManager.stop() else {
            throw ApplicationProxyError.failed("旧的 TUN 尚未确认停止，已中止切换。")
        }
        if settings.connectionCaptureMode == .applications {
            guard !settings.proxyApplications.isEmpty else {
                throw ApplicationProxyError.invalid("请在「路由 → 仅指定应用」中添加应用。")
            }
            for app in settings.proxyApplications { try app.validate() }
        }
        var hydrated = node
        KeychainStore.hydrateCredentials(&hydrated)

        logger.debug(
            "连接开始：\(settings.nodeDisplayTitle(node))；地址=\(node.server):\(node.port)，协议=\(node.protocolType.displayName)，传输=\(node.transport.displayName)，安全=\(node.security.displayName)，接管=\(settings.connectionCaptureMode.displayName)，路由=\(settings.routingMode.displayName)",
            category: .network
        )
        if settings.connectionCaptureMode == .applications {
            let applications = settings.proxyApplications
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { "\($0.name) [\($0.path)]" }
                .joined(separator: "，")
            logger.info(
                "当前节点应用代理范围（已配置）：\(applications)",
                category: .network
            )
        }

        let ports = XrayConfigBuilder.LocalPorts(
            socksHost: settings.socksHost,
            socksPort: settings.socksPort,
            httpHost: settings.httpHost,
            httpPort: settings.httpPort
        )

        let applicationMode = settings.connectionCaptureMode.usesTun
        let probeReservation = try LocalTestPorts(count: applicationMode ? 3 : 2)
        let probePort = probeReservation.ports[0]
        let qualityPort = probeReservation.ports[1]
        let applicationPort = applicationMode ? probeReservation.ports[2] : nil
        let applicationPassword = UUID().uuidString + UUID().uuidString

        let config = try XrayConfigBuilder.build(
            node: hydrated,
            ports: ports,
            routingMode: applicationMode ? .global : settings.routingMode,
            routingRules: settings.routingRules,
            probePort: probePort,
            applicationProxy: applicationPort.map { (port: $0, password: applicationPassword) },
            qualityProxy: (port: qualityPort, password: applicationPassword)
        )

        let dir = try XrayProcessManager.configDirectory()
        let file = dir.appendingPathComponent("config-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try XrayConfigBuilder.writeJSON(config, to: file)
        configURL = file
        logger.debug("Xray 配置已生成，本地入口 HTTP=\(settings.httpHost):\(settings.httpPort)，SOCKS=\(settings.socksHost):\(settings.socksPort)", category: .xray)

        do {
            _ = try await XrayInstaller.ensureInstalled()
            try Task.checkCancellation()
            guard generation == connectGeneration else { throw ConnectionError.cancelled }
            logger.debug("Xray 核心已就绪，正在启动进程", category: .xray)
            probeReservation.release()
            try await xray.start(configURL: file)
            try Task.checkCancellation()
        } catch let error as XrayProcessError {
            logger.debug("Xray 启动失败：\(error.localizedDescription)", category: .xray)
            state.status = .error
            state.lastError = error.localizedDescription
            scheduleErrorIdleRecovery()
            throw error
        }

        let ready = await waitForLocalProxy(
            endpoints: [(settings.httpHost, settings.httpPort), (settings.socksHost, settings.socksPort), ("127.0.0.1", probePort)],
            timeout: 3,
            generation: generation
        )
        guard generation == connectGeneration else {
            throw ConnectionError.cancelled
        }
        guard await xray.isRunning() else {
            let log = await xray.readRecentOutput()
            let detail = log.isEmpty ? "Xray 启动后立即退出" : "Xray 启动后立即退出：\(log.suffix(400))"
            throw ConnectionError.startFailed(detail)
        }
        guard ready else {
            logger.debug("本地代理端口等待超时：HTTP=\(settings.httpPort)，SOCKS=\(settings.socksPort)", category: .xray)
            throw ConnectionError.startFailed("本地代理端口未就绪（\(settings.httpPort)/\(settings.socksPort)）")
        }
        logger.debug("Xray 已启动，本地 HTTP/SOCKS 端口均已就绪", category: .xray)


        // 直连模式流量不经节点，测试地址探测不能当作连接门槛（国内直连常打不开默认 Google 探测）。
        if verify, settings.routingMode != .direct {
            let timeout = ConnectionPatiencePolicy.initialTimeout(configured: settings.connectTimeoutSeconds,
                relaxedHandshake: ProbePolicy.needsRelaxedTimeout(node))
            logger.debug("开始连通性验证，超时=\(Int(timeout)) 秒，测试地址=\(settings.testURL)", category: .network)
            let latency = await verifyConnectivity(settings: settings, probePort: probePort, timeout: timeout, generation: generation)
            guard generation == connectGeneration else {
                throw ConnectionError.cancelled
            }
            guard let latency else {
                logger.debug("连通性验证失败：已配置的测试地址不可达", category: .network)
                await teardownProxy(settings: settings, restoreSystemProxy: false)
                throw ConnectionError.verifyFailed("连通性验证失败：无法访问已配置的测试地址")
            }
            logger.debug("连通性验证完成：测试地址=\(settings.testURL)，延迟=\(latency) ms", category: .network)
        } else if verify {
            logger.debug("直连模式跳过连通性验证", category: .network)
        }

        try Task.checkCancellation()
        guard generation == connectGeneration else { throw ConnectionError.cancelled }
        do {
            logger.debug("正在启用\(settings.connectionCaptureMode.displayName)", category: .systemProxy)
            switch settings.connectionCaptureMode {
            case .applications, .globalTun:
                guard let applicationPort, let binary = XrayProcessManager.resolveBinaryURL() else {
                    throw ApplicationProxyError.failed("TUN 缺少本地节点入口。")
                }
                // Restore only HopWorld's own saved proxy session. Never alter
                // unrelated third-party system proxy configuration here.
                try await proxyManager.restoreFromBackup()
                try await proxyManager.requireDirectSystemSettings()
                try await applicationProxyManager.start(applications: settings.proxyApplications,
                    socksPort: applicationPort, password: applicationPassword, xrayBinary: binary,
                    captureAll: settings.connectionCaptureMode == .globalTun, bootstrapDomains: [node.server],
                    additionalBypassExecutables: await xray.connectionCoreExecutables())
            case .systemProxy:
                try await proxyManager.enableSystemProxy(
                    httpHost: settings.httpHost,
                    httpPort: settings.httpPort,
                    socksHost: settings.socksHost,
                    socksPort: settings.socksPort
                )
            case .systemVPN:
                try await vpnManager.start(
                    httpHost: settings.httpHost,
                    httpPort: settings.httpPort,
                    socksHost: settings.socksHost,
                    socksPort: settings.socksPort,
                    generation: generation
                )
            }
            logger.debug("\(settings.connectionCaptureMode.displayName)已启用", category: .systemProxy)
        } catch {
            logger.debug("启用\(settings.connectionCaptureMode.displayName)失败：\(error.localizedDescription)", category: .systemProxy)
            await xray.stop()
            if settings.connectionCaptureMode == .systemVPN {
                await vpnManager.stop()
            }
            throw error
        }
        try Task.checkCancellation()
        guard generation == connectGeneration else { throw ConnectionError.cancelled }
        guard isNodeTemporarilyBlocked?(node.id) != true else { throw ConnectionError.temporarilyBlocked }
        state.status = .connected
        state.currentNodeID = node.id
        state.currentCountryCode = countryCode ?? node.countryCode
        state.currentCountryName = countryName ?? node.countryName
        state.protocolType = node.protocolType
        // Keep verified latency; only fall back to last test result.
        state.recordLatency(state.latency ?? node.lastLatency)
        state.connectedAt = Date()
        state.sessionDownloadBytes = 0
        state.sessionUploadBytes = 0
        state.downloadMbps = 0
        state.uploadMbps = 0
        state.exitIP = nil
        state.exitIPType = nil
        state.exitCountry = nil
        state.exitCity = nil
        state.exitOperator = nil
        state.exitASN = nil
        state.lastError = nil

        let qualityContext = NodeFingerprint.make(from: hydrated) + settings.testURL
            + settings.routingMode.rawValue + settings.connectionCaptureMode.rawValue
        if qualityContexts[node.id] != qualityContext {
            nodeQuality[node.id] = AIConnectionQuality()
            qualityContexts[node.id] = qualityContext
        }
        logger.info("连接诊断 session=\(diagnosticSession)；IPv4/IPv6 同路由；DNS=\(settings.connectionCaptureMode.usesTun ? "TUN 经节点解析系统 DNS（节点引导除外）" : "代理内 DNS 跟随路由；系统 DNS 由 macOS 管理")；TLS 解密=关闭；本地空闲上限=3600s", category: .network)

        logger.info("连接成功：\(settings.nodeDisplayTitle(node))，总耗时=\(Int(Date().timeIntervalSince(startedAt) * 1000)) ms，验证延迟=\(state.latency.map { "\($0) ms" } ?? "未知")", category: .network)
        failoverStatus = nil

        activeProbePort = probePort
        activeQualityProxy = (port: qualityPort, password: applicationPassword)
        startMetrics(generation: generation)
        startLiveLatency(generation: generation, probePort: probePort, settings: settings)
        startAutomaticQuality(nodeID: node.id, generation: generation)

        let exitWait = AppSettings.normalizedMissingExitIPTimeout(settings.missingExitIPTimeoutSeconds)
        if exitWait > 0, settings.routingMode != .direct {
            // The deadline starts only after the session is connected.
            logger.debug("连接已成功，开始等待出口 IP，时限=\(exitWait) 秒", category: .network)
            let exit = await exitIPBeforeDeadline(probePort: probePort, seconds: exitWait)
            try Task.checkCancellation()
            guard generation == connectGeneration else { throw ConnectionError.cancelled }
            guard let exit, exit.ip != nil else {
                logger.warning("无出口 IP（\(exitWait) 秒）；节点：\(settings.nodeDisplayTitle(node))", category: .network)
                await teardownProxy(settings: settings, restoreSystemProxy: false)
                throw ConnectionError.verifyFailed("无出口 IP（\(exitWait) 秒）")
            }
            applyExitResult(exit, node: node, settings: settings, generation: generation)
        } else {
            if exitWait > 0 {
                logger.debug("直连模式跳过无出口 IP 时限", category: .network)
            }
            exitTask = Task { @MainActor in
                let exit = await ExitIPTester.fetch(
                    proxyHost: "127.0.0.1",
                    proxyPort: probePort,
                    timeout: 6,
                    socksPort: nil
                )
                guard !Task.isCancelled else { return }
                self.applyExitResult(exit, node: node, settings: settings, generation: generation)
            }
        }
        guard generation == connectGeneration, state.status == .connected else { return }
        sessionReady = true
    }

    /// Looks up an exit IP for `seconds` measured by the caller. Empty results are retried until that deadline.
    private func exitIPBeforeDeadline(probePort: Int, seconds: Int) async -> ExitIPTester.ExitInfo? {
        await withTaskGroup(of: ExitIPTester.ExitInfo?.self) { group in
            group.addTask {
                let deadline = Date().addingTimeInterval(TimeInterval(seconds))
                while !Task.isCancelled, Date() < deadline {
                    let remaining = deadline.timeIntervalSinceNow
                    guard remaining > 0 else { return nil }
                    let info = await ExitIPTester.fetch(
                        proxyHost: "127.0.0.1",
                        proxyPort: probePort,
                        timeout: min(6, max(1, remaining)),
                        socksPort: nil
                    )
                    if info.ip != nil { return info }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                return nil
            }
            let found = await group.next() ?? nil
            group.cancelAll()
            return found ?? nil
        }
    }

    private func applyExitResult(_ exit: ExitIPTester.ExitInfo, node: ProxyNode, settings: AppSettings, generation: Int) {
        guard generation == connectGeneration, state.currentNodeID == node.id, state.status == .connected else { return }
        state.recordExitIP(exit.ip, type: exit.networkType)
        recordExitObservation(exit, nodeID: node.id)
        state.exitCountry = exit.countryName ?? exit.countryCode
        state.exitCity = exit.city
        state.exitOperator = exit.networkOperator
        state.exitASN = exit.asn
        logger.debug(
            "出口检测完成：IP=\(exit.ip ?? "未获取")，地区=\(exit.countryName ?? exit.countryCode ?? "未知")",
            category: .network
        )

        let exitIsChina = {
            let code = exit.countryCode?.uppercased()
            let name = (exit.countryName ?? "").lowercased()
            return code == "CN" || name.contains("china") || name.contains("中国")
        }()

        if exit.ip == nil {
            logger.warning("出口检测未获取到 IP；节点：\(settings.nodeDisplayTitle(node))", category: .network)
        } else if exitIsChina, settings.routingMode != .direct {
            logger.warning("检测到中国出口；节点：\(settings.nodeDisplayTitle(node))；IP：\(exit.ip ?? "未知")；请切换海外节点", category: .network)
        }

        if exit.ip == nil, state.lastError == nil {
            state.lastError = "已连接，暂未获取到出口 IP"
        } else if exitIsChina, settings.routingMode != .direct {
            state.lastError = "当前出口位于中国大陆，部分海外网站可能无法访问"
        } else if exit.ip != nil, state.lastError?.contains("出口 IP") == true {
            state.lastError = nil
        }
    }

    private func startMetrics(generation: Int) {
        stopMetrics()
        lastTrafficSample = nil
        trafficBaseline = nil
        let binary = XrayProcessManager.resolveBinaryURL()

        metricsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Give stats API a moment after xray start.
            try? await Task.sleep(nanoseconds: 400_000_000)

            while !Task.isCancelled {
                guard generation == self.connectGeneration, self.state.status == .connected else { break }

                if let snap = await XrayStatsClient.queryInboundTraffic(binaryURL: binary) {
                    guard !Task.isCancelled, generation == self.connectGeneration, self.state.status == .connected else { break }
                    self.applyTrafficSnapshot(snap)
                }

                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// Probe the dedicated proxy endpoint, not the node's TCP port, so the
    /// displayed latency reflects an HTTPS request through the active tunnel.
    private func startLiveLatency(generation: Int, probePort: Int, settings: AppSettings) {
        liveLatencyTask?.cancel()
        guard let url = AppSettings.validatedTestURL(settings.testURL) else { return }
        liveLatencyTask = Task { @MainActor [weak self] in
            var consecutiveFailures = 0
            var sampleCount = 0
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { return }
                guard let self, generation == self.connectGeneration,
                      self.state.status == .connected else { return }
                let configuredTimeout = self.activeSettings?.connectTimeoutSeconds ?? settings.connectTimeoutSeconds
                let sampleTimeout = consecutiveFailures > 0
                    ? max(15, ConnectionPatiencePolicy.initialTimeout(configured: configuredTimeout)) : 3
                let outcome = await ProxyHTTPTester.diagnoseHTTPS(
                    url: url, httpProxyHost: "127.0.0.1", httpProxyPort: probePort, timeout: sampleTimeout)

                guard !Task.isCancelled, generation == self.connectGeneration,
                      self.state.status == .connected else { return }
                self.state.recordLatency(outcome.latency)
                if let nodeID = self.state.currentNodeID, settings.routingMode != .direct {
                    self.nodeQuality[nodeID, default: AIConnectionQuality()].record(latencyMs: outcome.latency,
                        timedOut: outcome.timedOut, timeoutSeconds: sampleTimeout)
                }
                if outcome.latency == nil {
                    consecutiveFailures += 1
                    if consecutiveFailures == 1 || consecutiveFailures.isMultiple(of: 6) {
                        self.logger.warning("连接诊断 session=\(self.diagnosticSession)；HTTPS 连续失败=\(consecutiveFailures)；原因=\(outcome.error ?? "未知")；HTTP=\(outcome.statusCode.map(String.init) ?? "无")；不据此推断 WebSocket 断开或丢包", category: .network)
                    }
                } else if consecutiveFailures > 0 {
                    self.logger.info("连接诊断 session=\(self.diagnosticSession)；HTTPS 已恢复；此前连续失败=\(consecutiveFailures)", category: .network)
                    consecutiveFailures = 0
                }
                self.onLiveLatencySample?()
                sampleCount += 1
                if sampleCount.isMultiple(of: 12) {
                    let exit = await ExitIPTester.fetch(proxyHost: "127.0.0.1", proxyPort: probePort,
                                                        timeout: 5, socksPort: nil)
                    guard !Task.isCancelled, generation == self.connectGeneration,
                          self.state.status == .connected else { return }
                    self.recordExitObservation(exit, nodeID: self.state.currentNodeID)
                    if let ip = exit.ip {
                        self.state.recordExitIP(ip, type: exit.networkType)
                        self.state.exitCountry = exit.countryName ?? exit.countryCode
                        self.state.exitCity = exit.city
                        self.state.exitOperator = exit.networkOperator
                        self.state.exitASN = exit.asn
                    }
                }
            }
        }
    }

    private func recordExitObservation(_ exit: ExitIPTester.ExitInfo, nodeID: UUID?) {
        guard let nodeID, let ip = exit.ip else { return }
        if let metadata = exit.nodeMetadata { onExitMetadata?(nodeID, metadata) }
        let identifier = LogRedactor.addressIdentifier(ip)
        if nodeQuality[nodeID, default: AIConnectionQuality()].recordExit(identifier: identifier) {
            logger.warning("连接诊断 session=\(diagnosticSession)；同节点观测到出口变化；新出口=\(identifier)；可能由出口池或网络变化造成，不能单独确定服务商故障", category: .network)
        }
    }

    private func startAutomaticQuality(nodeID: UUID, generation: Int) {
        stopAutomaticQuality()
        automaticQualityPaused = false
        let runID = automaticQualityRunID
        automaticQualityTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.automaticQualityRunID == runID { self.automaticQualityTask = nil }
            }
            var needsInitialHTTPS = true
            var lastDeepStartedAt: Date?
            while !Task.isCancelled, self.automaticQualityRunID == runID,
                  self.connectGeneration == generation, self.state.status == .connected,
                  self.state.currentNodeID == nodeID {
                if self.isBusy {
                    do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                    continue
                }
                guard let settings = self.activeSettings, self.canTestQuality(nodeID: nodeID) else { return }
                let quality = self.nodeQuality[nodeID, default: AIConnectionQuality()]
                let fresh = quality.freshObservations(settings: settings)
                if needsInitialHTTPS {
                    needsInitialHTTPS = false
                    if fresh.samples.count < 10 { self.startReferenceTest(nodeID: nodeID) }
                }
                let due = quality.refreshNeeds(settings: settings)
                if !self.automaticQualityPaused, self.qualityTestNodeID == nil {
                    if due.webSocket || due.datagrams {
                        self.startQualityTest(nodeID: nodeID, onlyDue: true)
                    } else if fresh.webSocket?.isLongObservation != true,
                              lastDeepStartedAt.map({ Date().timeIntervalSince($0) >= TimeInterval(max(1, settings.testResultTTLMinutes)) * 60 }) ?? true {
                        // Quick evidence first; then the 6-minute observation runs once per result TTL.
                        lastDeepStartedAt = Date()
                        self.startQualityTest(nodeID: nodeID, deep: true)
                    }
                }
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            }
        }
    }

    private func stopAutomaticQuality() {
        automaticQualityTask?.cancel()
        automaticQualityTask = nil
        automaticQualityRunID = UUID()
    }

    func updateConnectionTimeout(_ seconds: Int) {
        activeSettings?.connectTimeoutSeconds = min(99, max(1, seconds))
    }

    func updateQualityResultTTL(_ minutes: Int) {
        activeSettings?.testResultTTLMinutes = minutes
    }

    func checkCodexInviteEligibility() async -> CodexInviteCheckResult? {
        guard await LabUtilityProcess.allowInternet(userInitiated: false) else { return nil }
        guard state.status == .connected, !isBusy, let settings = activeSettings else { return nil }
        guard settings.routingMode != .direct, let probePort = activeProbePort else { return .unavailable }
        let generation = connectGeneration
        let nodeID = state.currentNodeID
        let result = await CodexInviteEligibilityProbe.check(
            httpProxyPort: probePort,
            timeout: TimeInterval(min(10, max(1, settings.appProbeTimeoutSeconds))))
        guard !Task.isCancelled, generation == connectGeneration, state.status == .connected,
              state.currentNodeID == nodeID, !isBusy else { return nil }
        return result
    }

    func checkApplicationNetworkPath(_ url: URL) async -> Bool? {
        await diagnoseThroughProxy(url).map { $0.latency != nil }
    }

    /// Anthropic 对不支持的出口地区返回 403；其他 HTTP 响应（如未带密钥的 401）表示 Claude 模型可加载。
    func checkClaudeModelAccess(extendedWait: Bool = false) async -> ClaudeModelAccess? {
        let timeout = extendedWait ? max(15, ConnectionPatiencePolicy.initialTimeout(
            configured: activeSettings?.connectTimeoutSeconds ?? 15)) : nil
        guard let outcome = await diagnoseThroughProxy(URL(string: "https://api.anthropic.com/v1/models")!, timeout: timeout) else { return nil }
        guard outcome.latency != nil, let status = outcome.statusCode else { return .unreachable }
        return status == 403 ? .regionBlocked : .available
    }

    private func diagnoseThroughProxy(_ url: URL, timeout: TimeInterval? = nil) async -> ProxyHTTPTester.HTTPSOutcome? {
        guard await LabUtilityProcess.allowInternet(userInitiated: false) else { return nil }
        guard state.status == .connected, !isBusy, let settings = activeSettings,
              settings.routingMode != .direct, let probePort = activeProbePort else { return nil }
        let generation = connectGeneration
        let nodeID = state.currentNodeID
        let outcome = await ProxyHTTPTester.diagnoseHTTPS(
            url: url,
            httpProxyHost: "127.0.0.1", httpProxyPort: probePort,
            timeout: timeout ?? TimeInterval(min(10, max(1, settings.appProbeTimeoutSeconds))),
            acceptAnyHTTPResponse: true, followRedirects: false)
        guard !Task.isCancelled, generation == connectGeneration, state.status == .connected,
              state.currentNodeID == nodeID, !isBusy else { return nil }
        return outcome
    }

    func canTestQuality(nodeID: UUID) -> Bool {
        state.status == .connected && state.currentNodeID == nodeID && !isBusy
            && activeSettings?.routingMode != .direct && activeQualityProxy != nil && activeProbePort != nil
    }

    func canTestReference(nodeID: UUID) -> Bool {
        canTestQuality(nodeID: nodeID) && !referenceTestRunning
            && activeSettings.flatMap { AppSettings.validatedTestURL($0.testURL) } != nil
    }

    func startReferenceTest(nodeID: UUID) {
        guard canTestReference(nodeID: nodeID), let settings = activeSettings,
              let url = AppSettings.validatedTestURL(settings.testURL), let httpPort = activeProbePort else { return }
        let runID = UUID()
        referenceRunID = runID
        let generation = connectGeneration
        referenceTestNodeID = nodeID
        referenceTestCompleted = 0
        referenceTestRunning = true
        referenceTestMessage = "正在检测 1 / 10"
        referenceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.referenceRunID == runID {
                    self.referenceTestRunning = false
                    self.referenceTask = nil
                }
            }
            var successes = 0
            await withTaskGroup(of: ProxyHTTPTester.HTTPSOutcome.self) { group in
                var launched = 0
                func enqueue() {
                    launched += 1
                    group.addTask {
                        await ProxyHTTPTester.diagnoseHTTPS(url: url, httpProxyHost: "127.0.0.1", httpProxyPort: httpPort,
                            timeout: TimeInterval(max(1, settings.testTimeoutSeconds)))
                    }
                }
                for _ in 0..<3 { enqueue() }
                while let outcome = await group.next() {
                    guard !Task.isCancelled, self.referenceRunID == runID,
                          self.connectGeneration == generation, self.state.status == .connected,
                          self.state.currentNodeID == nodeID, !self.isBusy else {
                        group.cancelAll()
                        if self.referenceRunID == runID { self.referenceTestMessage = "连接已变化，检测已停止；保留已完成的样本" }
                        return
                    }
                    self.nodeQuality[nodeID, default: AIConnectionQuality()].record(latencyMs: outcome.latency,
                        timedOut: outcome.timedOut, timeoutSeconds: TimeInterval(max(1, settings.testTimeoutSeconds)))
                    if outcome.latency != nil { successes += 1 }
                    self.referenceTestCompleted += 1
                    self.referenceTestMessage = "快速采样 \(self.referenceTestCompleted) / 10"
                    if launched < 10 { enqueue() }
                }
            }
            guard !Task.isCancelled, self.referenceRunID == runID,
                  self.referenceTestCompleted == 10, self.connectGeneration == generation,
                  self.state.status == .connected, self.state.currentNodeID == nodeID, !self.isBusy else { return }

            self.referenceTestMessage = "检测完成：\(successes) 次成功，\(10 - successes) 次失败"
        }
    }

    func cancelReferenceTest() {
        guard referenceTestRunning else { return }
        referenceTask?.cancel()
        referenceTask = nil
        referenceRunID = UUID()
        referenceTestRunning = false
        referenceTestMessage = "已停止，完成 \(referenceTestCompleted) / 10 次；未完成项目不记失败"
    }

    func startQualityTest(nodeID: UUID, deep: Bool = false, onlyDue: Bool = false) {
        guard canTestQuality(nodeID: nodeID), let socks = activeQualityProxy,
              let httpPort = activeProbePort, let settings = activeSettings else { return }
        let due = nodeQuality[nodeID, default: AIConnectionQuality()].refreshNeeds(settings: settings)
        let measureWebSocket = deep || !onlyDue || due.webSocket
        let measureDatagrams = deep || !onlyDue || due.datagrams
        guard measureWebSocket || measureDatagrams else { return }
        cancelQualityTest(pauseAutomatic: false)
        automaticQualityPaused = false
        let runID = qualityRunID
        let generation = connectGeneration
        qualityTestNodeID = nodeID
        qualityTestStartedAt = Date()
        qualityTestIsDeep = deep
        qualityTestMessage = deep ? "深度稳定性观测中，已有评分继续显示"
            : (measureWebSocket ? "快速检查中：WebSocket 约 10 秒，UDP 并行采样" : "快速检查中：补测 UDP")
        let timeout = TimeInterval(min(30, max(1, settings.testTimeoutSeconds)))
        logger.info("专项观测开始 session=\(diagnosticSession)；mode=\(deep ? "deep" : "quick")；经当前节点的专用入口", category: .test)
        qualityTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.qualityRunID == runID {
                    self.qualityTestNodeID = nil
                    self.qualityTestStartedAt = nil
                    self.qualityTask = nil
                }
            }
            do {
                async let webSocket: WebSocketQualityResult? = measureWebSocket ? try await WebSocketQualityProbe.run(proxyPort: httpPort,
                    duration: deep ? WebSocketQualityProbe.deepObservationSeconds : WebSocketQualityProbe.quickObservationSeconds,
                    timeout: timeout) : nil
                if measureDatagrams {
                    let datagrams = try await DatagramLossProbe.run(socksPort: socks.port, password: socks.password,
                        count: deep ? 30 : DatagramLossProbe.quickCount,
                        interval: deep ? 0.2 : DatagramLossProbe.quickInterval,
                        responseWait: deep ? 2 : DatagramLossProbe.quickResponseWait, timeout: timeout)
                    try Task.checkCancellation()
                    guard self.qualityRunID == runID, self.connectGeneration == generation,
                          self.state.currentNodeID == nodeID, self.state.status == .connected else { return }
                    self.nodeQuality[nodeID, default: AIConnectionQuality()].datagrams = datagrams
                    self.qualityTestMessage = "UDP \(datagrams.verified ? "\(datagrams.received)/\(datagrams.sent) 回包" : "预检未验证")"
                        + (measureWebSocket ? "；WebSocket 仍在观测" : "")
                    self.logger.info("专项 UDP session=\(self.diagnosticSession)；verified=\(datagrams.verified)；sent=\(datagrams.sent)；received=\(datagrams.received)；\(datagrams.detail)", category: .test)
                }
                if let result = try await webSocket {
                    try Task.checkCancellation()
                    guard self.qualityRunID == runID, self.connectGeneration == generation,
                          self.state.currentNodeID == nodeID, self.state.status == .connected else { return }
                    self.nodeQuality[nodeID, default: AIConnectionQuality()].webSocket = result
                    self.logger.info("专项 WSS session=\(self.diagnosticSession)；verified=\(result.verified)；survived=\(result.survived)；observed=\(Int(result.observedSeconds))s；\(result.detail)", category: .test)
                }
                self.qualityTestMessage = deep ? "深度观测完成" : "快速检查完成"

            } catch is CancellationError {
                self.logger.info("专项观测已取消；未完成项目不记失败分", category: .test)
            } catch {
                self.logger.warning("专项观测未完成；error=\((error as NSError).code)", category: .test)
            }
        }
    }

    func cancelQualityTest(pauseAutomatic: Bool = true) {
        if pauseAutomatic { automaticQualityPaused = true }
        qualityTask?.cancel()
        qualityTask = nil
        qualityRunID = UUID()
        qualityTestNodeID = nil
        qualityTestStartedAt = nil
    }

    private func stopMetrics() {
        stopAutomaticQuality()
        cancelReferenceTest()
        liveLatencyTask?.cancel()
        liveLatencyTask = nil
        metricsTask?.cancel()
        metricsTask = nil
        lastTrafficSample = nil
        trafficBaseline = nil
    }

    private func applyTrafficSnapshot(_ snap: XrayTrafficSnapshot) {
        if trafficBaseline == nil {
            trafficBaseline = (snap.uploadBytes, snap.downloadBytes)
        }
        let baseline = trafficBaseline ?? (0, 0)
        let sessionUp = max(0, snap.uploadBytes - baseline.upload)
        let sessionDown = max(0, snap.downloadBytes - baseline.download)
        state.sessionUploadBytes = sessionUp
        state.sessionDownloadBytes = sessionDown

        let now = Date()
        if let last = lastTrafficSample {
            let dt = now.timeIntervalSince(last.at)
            if dt >= 0.5 {
                let upDelta = Double(max(0, snap.uploadBytes - last.upload))
                let downDelta = Double(max(0, snap.downloadBytes - last.download))
                // bytes/sec → Mbps
                state.uploadMbps = (upDelta * 8.0) / dt / 1_000_000.0
                state.downloadMbps = (downDelta * 8.0) / dt / 1_000_000.0
            }
        }
        lastTrafficSample = (snap.uploadBytes, snap.downloadBytes, now)
    }

    private func verifyConnectivity(
        settings: AppSettings,
        probePort: Int,
        timeout: TimeInterval,
        generation: Int
    ) async -> Int? {
        guard !Task.isCancelled, generation == connectGeneration,
              let testURL = AppSettings.validatedTestURL(settings.testURL) else { return nil }
        let previousFailoverStatus = failoverStatus
        defer { if generation == connectGeneration { failoverStatus = previousFailoverStatus } }
        let started = ProcessInfo.processInfo.systemUptime
        let initialTimeout = min(99, max(1, timeout))
        var outcome = await ProxyHTTPTester.diagnoseHTTPS(url: testURL,
            httpProxyHost: "127.0.0.1", httpProxyPort: probePort, timeout: initialTimeout)
        guard !Task.isCancelled, generation == connectGeneration else { return nil }
        if outcome.latency == nil {
            let remaining = ConnectionPatiencePolicy.remainingWait(initialTimeout: initialTimeout,
                elapsed: ProcessInfo.processInfo.systemUptime - started)
            if remaining >= 1 {
                failoverStatus = "连接暂未响应，延长等待并复验当前节点"
                outcome = await ProxyHTTPTester.diagnoseHTTPS(url: testURL,
                    httpProxyHost: "127.0.0.1", httpProxyPort: probePort, timeout: remaining)
                guard !Task.isCancelled, generation == connectGeneration else { return nil }
            }
        }
        if let latency = outcome.latency { state.recordLatency(latency) }
        return outcome.latency
    }

    /// Poll until local inbound ports accept TCP connections.
    private func waitForLocalProxy(
        endpoints: [(String, Int)],
        timeout: TimeInterval,
        generation: Int
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !Task.isCancelled && Date() < deadline {
            if generation != connectGeneration { return false }
            var allOpen = true
            for (host, port) in endpoints {
                if await TCPTester.measure(host: host, port: port, timeout: 0.2) == nil {
                    allOpen = false
                    break
                }
            }
            if allOpen { return true }
            do { try await Task.sleep(nanoseconds: 80_000_000) }
            catch { return false }
        }
        return false
    }


    private func teardownProxy(settings: AppSettings, restoreSystemProxy: Bool) async {
        cancelQualityTest()
        activeQualityProxy = nil
        activeProbePort = nil
        exitTask?.cancel()
        exitTask = nil
        stopMetrics()
        captureCleanupFailed = !(await applicationProxyManager.stop())
        if captureCleanupFailed {
            logger.error("TUN 停止尚未确认，监护程序将继续按失效心跳清理。", category: .network)
        }
        if settings.connectionCaptureMode == .systemVPN {
            await vpnManager.stop()
        }
        await xray.stop()
        guard restoreSystemProxy else { return }

        // 系统代理模式：先按连接前备份恢复。
        if settings.connectionCaptureMode == .systemProxy {
            do {
                try await proxyManager.restoreFromBackup()
            } catch {
                captureCleanupFailed = true
                logger.error("恢复系统代理失败：\(error.localizedDescription)", category: .systemProxy)
            }
        }

        // 任意接管方式都再扫一遍：若系统代理仍指向本机已死端口，强制关掉，避免断网。
        do {
            try await proxyManager.restoreIfOrphaned(
                expectedHTTPPort: settings.httpPort,
                expectedSOCKSPort: settings.socksPort,
                xrayRunning: false
            )
        } catch {
            captureCleanupFailed = true
            logger.warning("清理残留系统代理失败：\(error.localizedDescription)", category: .systemProxy)
        }
    }

    /// 连接异常：停掉代理并清空会话，避免残留影响本机网络。
    private func failAndClearProxy(settings: AppSettings, message: String) async {
        let established = state.status == .connected
        let duration = established ? state.connectedAt.map { max(0, Int(Date().timeIntervalSince($0))) } ?? 0 : 0
        logger.warning("连接诊断 session=\(diagnosticSession)；\(established ? "异常断开" : "连接失败")；会话持续=\(duration)s；原因=\(message)", category: .network)
        let coreTail = await xray.readRecentOutput(maxBytes: 2048)
        if !coreTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            logger.warning("连接诊断 session=\(diagnosticSession)；核心尾部：\(coreTail)", category: .xray)
        }
        let node = state.currentNodeID?.uuidString.prefix(8) ?? "unknown"
        logger.error("连接异常，正在断开；原因：\(message)；节点标识：\(node)；接管方式：\(settings.connectionCaptureMode.displayName)", category: .network)
        await teardownProxy(settings: settings, restoreSystemProxy: true)
        activeSettings = nil
        failoverStatus = nil
        isBusy = false
        sessionReady = false
        state.status = .error
        state.lastError = message
        if captureCleanupFailed {
            logger.error("异常断开后代理清理尚未确认；原因：\(message)；请重试断开", category: .network)
            cancelErrorIdleRecovery()
        } else {
            logger.info("异常连接已断开，代理清理完成；原因：\(message)", category: .network)
            scheduleErrorIdleRecovery()
        }
    }

    private func clearSessionToDisconnected() {
        cancelErrorIdleRecovery()
        activeSettings = nil
        failoverStatus = nil
        isBusy = false
        sessionReady = false
        let autoSelect = state.autoSelectEnabled
        state = ConnectionState(autoSelectEnabled: autoSelect)
        state.status = .disconnected
    }

    func setAutomaticRecoveryPending(_ pending: Bool) {
        guard automaticRecoveryPending != pending else { return }
        automaticRecoveryPending = pending
        if pending {
            cancelErrorIdleRecovery()
        } else if state.status == .error, !captureCleanupFailed {
            scheduleErrorIdleRecovery()
        }
    }

    private func scheduleErrorIdleRecovery() {
        cancelErrorIdleRecovery()
        guard !automaticRecoveryPending else { return }
        errorIdleRecoveryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.errorIdleRecoveryNanoseconds)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            guard self.state.status == .error, !self.isBusy, !self.captureCleanupFailed,
                  !self.automaticRecoveryPending else { return }
            self.logger.info("连接异常已空闲 15 秒，自动恢复为未连接", category: .network)
            self.clearSessionToDisconnected()
        }
    }

    private func cancelErrorIdleRecovery() {
        errorIdleRecoveryTask?.cancel()
        errorIdleRecoveryTask = nil
    }

    private func handleVPNDrop() async {
        guard state.status == .connected, activeSettings?.connectionCaptureMode == .systemVPN else { return }
        let failedNodeID = state.currentNodeID
        var cleanupGeneration: Int?
        try? await operations.perform { operationGeneration in
            guard let settings = self.activeSettings else { return }
            await self.failAndClearProxy(settings: settings, message: "连接中断：系统 VPN 已断开")
            cleanupGeneration = operationGeneration
        }
        if let cleanupGeneration, !Task.isCancelled, cleanupGeneration == connectGeneration {
            onUnexpectedDisconnect?(failedNodeID, "系统 VPN 已断开", true)
        }
    }

    private func selectCandidates(countryCode: String, nodes: [ProxyNode], settings: AppSettings) -> [ProxyNode] {
        var list = nodes.filter {
            $0.enabled &&
            !$0.pendingRemoval &&
            (CountryResolver.effectiveCode(for: $0) == countryCode.uppercased()) &&
            settings.allowsAutoSelectNode($0)
        }

        switch settings.favoritePreference {
        case .all, .preferFavorites:
            break
        case .favoritesOnly:
            list = list.filter(\.isFavorite)
        }
        if settings.codexSmartFailover, let rankAutomaticCandidates {
            return rankAutomaticCandidates(list)
        }

        // Keep quick switch, startup auto-connect, and failover on the same order:
        // favorite policy first, then app reachability tier and measured latency.
        let appOrder = settings.automaticAppProbeTargets.map(\.id)
        return list.sorted { lhs, rhs in
            return ProxyNode.autoSelectLessThan(
                lhs,
                rhs,
                considerAppProbe: settings.autoAppProbeUsableNodes,
                appOrder: appOrder,
                preferFavorites: settings.favoritePreference == .preferFavorites
            )
        }
    }

    private func handleXrayCrash() {
        // Ignore exits while connecting / switching nodes — those are intentional stop()+restart.
        guard state.status == .connected else { return }

        let generation = connectGeneration
        Task { @MainActor [weak self] in
            guard let self, generation == self.connectGeneration, let settings = self.activeSettings else { return }
            let failedNodeID = self.state.currentNodeID
            var cleanupGeneration: Int?
            try? await self.operations.perform { operationGeneration in
                await self.failAndClearProxy(settings: settings, message: "连接中断：Xray 已退出")
                cleanupGeneration = operationGeneration
            }
            if let cleanupGeneration, !Task.isCancelled, cleanupGeneration == self.connectGeneration {
                self.onUnexpectedDisconnect?(failedNodeID, "Xray 已退出", true)
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        // SMAppService can block briefly; never do it on the UI thread.
        Task.detached(priority: .utility) {
            let service = SMAppService.mainApp
            let status = service.status
            if enabled, status == .enabled { return }
            if !enabled, status == .notRegistered || status == .notFound { return }

            do {
                if enabled {
                    try service.register()
                } else {
                    try await service.unregister()
                }
            } catch {
                await MainActor.run {
                    AppLogger.shared.warning("登录启动设置失败：\(error.localizedDescription)")
                }
            }
        }
    }
}

enum ConnectionError: LocalizedError {
    case temporarilyBlocked
    case noCandidates
    case connectFailed
    case timeout(seconds: Int)
    case verifyFailed(String)
    case startFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .temporarilyBlocked: return "节点已临时屏蔽"
        case .noCandidates: return "没有可用的收藏/候选节点"
        case .connectFailed: return "连接失败"
        case .timeout(let seconds): return "连接验证超时（\(seconds) 秒）"
        case .verifyFailed(let message): return message
        case .startFailed(let message): return message
        case .cancelled: return "连接已取消"
        }
    }
}
