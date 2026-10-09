import Foundation
import ServiceManagement
import Darwin

@MainActor
final class ConnectionManager: ObservableObject {
    @Published var state = ConnectionState()
    @Published var isBusy = false
    /// 当前故障切换进度文案，例如「第 2/5 个节点…」
    @Published var failoverStatus: String?

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
    var onNodeConnectionFailed: ((UUID) -> Void)?
    var onUnexpectedDisconnect: ((UUID?, String) -> Void)?
    /// Runtime snapshot, deliberately not read from the editable/saved settings.
    var effectiveCaptureMode: ConnectionCaptureMode? {
        guard state.status == .connected, !captureCleanupFailed else { return nil }
        return activeSettings?.connectionCaptureMode
    }
    private var exitTask: Task<Void, Never>?
    private var metricsTask: Task<Void, Never>?
    private var liveLatencyTask: Task<Void, Never>?
    var onLiveLatencySample: (() -> Void)?
    private var lastTrafficSample: (upload: Int64, download: Int64, at: Date)?
    private var trafficBaseline: (upload: Int64, download: Int64)?

    func bootstrapRestore(settings: AppSettings) async {
        applicationProxyManager.onUnexpectedStop = { [weak self] message in
            guard let self, self.state.status == .connected,
                  self.activeSettings?.connectionCaptureMode.usesTun == true else { return }
            let generation = self.connectGeneration
            Task { @MainActor in
                guard generation == self.connectGeneration else { return }
                let failedNodeID = self.state.currentNodeID
                var handled = false
                try? await self.operations.perform { _ in
                    guard let settings = self.activeSettings else { return }
                    // Mark the capture failure before stopping Xray so its
                    // intentional teardown is not reported as a second crash.
                    self.state.status = .error
                    self.state.lastError = "TUN 已停止：\(message)"
                    await self.teardownProxy(settings: settings, restoreSystemProxy: true)
                    self.failoverStatus = nil
                    self.isBusy = false
                    handled = true
                }
                if handled {
                    self.onUnexpectedDisconnect?(failedNodeID, "TUN 已停止")
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
        let generation = connectGeneration
        let nodeID = state.currentNodeID
        var failed = false
        do {
            try await operations.maintainIfIdle {
                guard generation == self.connectGeneration, self.state.status == .connected else { return }
                self.isBusy = true
                defer { self.isBusy = false }
                self.logger.info("网络变化或唤醒，正在复验当前连接", category: .network)
                let running = await self.xray.isRunning()
                let probe = await self.verifyConnectivity(settings: settings, probePort: probePort,
                                                         timeout: 5, generation: generation)
                try Task.checkCancellation()
                guard generation == self.connectGeneration, self.state.status == .connected else { return }
                guard running, probe.primaryOK || probe.browseOK else {
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
                self.state.latency = probe.primaryLatency ?? probe.browseLatency
                let exit = await ExitIPTester.fetch(proxyHost: "127.0.0.1", proxyPort: probePort, timeout: 5, socksPort: nil)
                try Task.checkCancellation()
                self.state.exitIP = exit.ip
                self.state.exitCountry = exit.countryName ?? exit.countryCode
                self.logger.info("网络变化后的连接复验完成", category: .network)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == connectGeneration, state.status == .connected else { return }
            try? await operations.maintainIfIdle {
                self.state.status = .error
                self.state.lastError = "网络变化后连接验证失败，请重新连接"
                await self.teardownProxy(settings: settings, restoreSystemProxy: true)
                failed = true
            }
        }
        if failed, settings.connectionCaptureMode == .systemProxy, !captureCleanupFailed {
            onUnexpectedDisconnect?(nodeID, "网络变化后连接验证失败")
        }
    }

    /// 连接指定节点；开启自动故障切换时，超时后按收藏列表顺序尝试后续节点。
    func connect(
        node: ProxyNode,
        settings: AppSettings,
        allNodes: [ProxyNode] = [],
        countryCode: String? = nil,
        countryName: String? = nil
    ) async throws {
        var settings = settings
        settings.normalizeApplicationProxyMode()
        do {
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
                verify: true
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
        do {
            try await operations.perform { _ in
                if let previous = self.activeSettings, previous.connectionCaptureMode != settings.connectionCaptureMode {
                    await self.teardownProxy(settings: previous, restoreSystemProxy: true)
                }
                try Task.checkCancellation()
                self.activeSettings = settings
                try await self.connectWithFailover(preferred: first, nodes: nodes, settings: settings,
                    countryCode: countryCode, countryName: first.countryName, restrictToCountry: countryCode)
            }
        } catch is CancellationError { throw ConnectionError.cancelled }
    }

    func disconnect(settings: AppSettings) async {
        try? await operations.perform { _ in
            await self.disconnectBody(settings: self.activeSettings ?? settings)
        }
    }

    private func disconnectBody(settings: AppSettings) async {
        isBusy = true
        let disconnectingNode = state.currentNodeID?.uuidString.prefix(8) ?? "unknown"
        logger.info("开始断开连接，节点标识：\(disconnectingNode)，接管方式：\(settings.connectionCaptureMode.displayName)", category: .network)
        // 先抬世代，打断进行中的 connect / failover / 验证。
        failoverStatus = nil
        stopMetrics()
        state.status = .disconnecting

        await teardownProxy(settings: settings, restoreSystemProxy: true)
        if captureCleanupFailed {
            state.status = .error
            state.lastError = "应用代理停止尚未确认，请稍后再次断开；未宣称网络已恢复。"
            isBusy = false
            return
        }
        activeSettings = nil
        state = ConnectionState(autoSelectEnabled: state.autoSelectEnabled)
        state.status = .disconnected
        isBusy = false
        logger.info("已断开连接", category: .network)
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
                // Favorite preference must not prevent fallback to ordinary nodes.
                if settings.favoritePreference == .preferFavorites { return max(1, chain.count) }
                return max(1, min(settings.maxFailoverAttempts, chain.count))
            }
        }()
        let chainDescription = chain.prefix(attempts).enumerated().map { index, candidate in
            "\(index + 1).\(candidate.displayTitle)[\(candidate.protocolType.displayName)/\(candidate.transport.displayName)/\(candidate.security.displayName), \(candidate.server):\(candidate.port)]"
        }.joined(separator: " → ")
        logger.info("自动故障切换候选（共 \(attempts) 个）：\(chainDescription)", category: .network)
        var lastError: Error?
        let sessionGeneration = connectGeneration

        isBusy = true
        defer {
            isBusy = false
            failoverStatus = nil
        }

        state.status = .connecting
        state.lastError = nil

        for (index, node) in chain.prefix(attempts).enumerated() {
            guard connectGeneration == sessionGeneration, !Task.isCancelled else {
                await teardownProxy(settings: settings, restoreSystemProxy: true)
                state.status = .disconnected
                throw ConnectionError.cancelled
            }

            failoverStatus = "正在连接 \(index + 1)/\(attempts)：\(node.displayTitle)"
            logger.info("尝试连接 [\(index + 1)/\(attempts)] \(node.displayTitle)", category: .network)
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
                    verify: true,
                    manageBusyFlag: false
                )
                failoverStatus = nil
                return
            } catch {
                if error is ApplicationProxyError {
                    await teardownProxy(settings: settings, restoreSystemProxy: true)
                    state.status = .error
                    state.lastError = error.localizedDescription
                    failoverStatus = nil
                    throw error // Never repeat administrator prompts across the failover pool.
                }
                if Task.isCancelled || error is CancellationError {
                    await teardownProxy(settings: settings, restoreSystemProxy: true)
                    state.status = .disconnected
                    throw ConnectionError.cancelled
                }
                if case ConnectionError.cancelled = error {
                    await teardownProxy(settings: settings, restoreSystemProxy: true)
                    state.status = .disconnected
                    throw error
                }
                if connectGeneration != sessionGeneration {
                    await teardownProxy(settings: settings, restoreSystemProxy: true)
                    state.status = .disconnected
                    throw ConnectionError.cancelled
                }
                lastError = error
                onNodeConnectionFailed?(node.id)
                logger.warning(
                    "节点超时或失败，切换下一个候选：\(node.displayTitle) — \(error.localizedDescription)",
                    category: .network
                )
                await teardownProxy(settings: settings, restoreSystemProxy: false)
            }
        }

        // 全部失败：恢复系统代理
        await teardownProxy(settings: settings, restoreSystemProxy: true)
        state.status = .error
        state.lastError = lastError?.localizedDescription ?? "连接失败：收藏节点均不可用"
        failoverStatus = nil
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

        pool.sort { lhs, rhs in
            if settings.favoritePreference == .preferFavorites,
               lhs.isFavorite != rhs.isFavorite {
                return lhs.isFavorite && !rhs.isFavorite
            }

            let considerApp = settings.autoAppProbeUsableNodes
            if considerApp {
                let leftTier = lhs.appProbePassTier
                let rightTier = rhs.appProbePassTier
                if leftTier != rightTier { return leftTier > rightTier }
            }

            let leftSame = sameCountry(lhs) ? 0 : 1
            let rightSame = sameCountry(rhs) ? 0 : 1
            if leftSame != rightSame { return leftSame < rightSame }

            return ProxyNode.autoSelectLessThan(lhs, rhs, considerAppProbe: considerApp)
        }

        let limit: Int = {
            switch settings.failoverPoolMode {
            case .allAvailable:
                return pool.count
            case .limited:
                // preferred 已占 1 席，再补 N-1 个可用。
                if settings.favoritePreference == .preferFavorites { return pool.count }
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

        state.status = .connecting
        state.lastError = nil
        state.latency = nil
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
                await teardownProxy(settings: settings, restoreSystemProxy: true)
            }
            if manageBusyFlag,
               state.currentNodeID == node.id {
                if Task.isCancelled || error is CancellationError {
                    state.status = .disconnected
                } else if case ConnectionError.cancelled = error {
                    state.status = .disconnected
                } else {
                    state.status = .error
                    state.lastError = error.localizedDescription
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

        logger.info(
            "连接开始：\(node.displayTitle)；地址=\(node.server):\(node.port)，协议=\(node.protocolType.displayName)，传输=\(node.transport.displayName)，安全=\(node.security.displayName)，接管=\(settings.connectionCaptureMode.displayName)，路由=\(settings.routingMode.displayName)",
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
        let probeReservation = try LocalTestPorts(count: applicationMode ? 2 : 1)
        let probePort = probeReservation.ports[0]
        let applicationPort = applicationMode ? probeReservation.ports[1] : nil
        let applicationPassword = UUID().uuidString + UUID().uuidString

        let config = try XrayConfigBuilder.build(
            node: hydrated,
            ports: ports,
            routingMode: applicationMode ? .global : settings.routingMode,
            routingRules: settings.routingRules,
            probePort: probePort,
            applicationProxy: applicationPort.map { (port: $0, password: applicationPassword) }
        )

        let dir = try XrayProcessManager.configDirectory()
        let file = dir.appendingPathComponent("config-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try XrayConfigBuilder.writeJSON(config, to: file)
        configURL = file
        logger.info("Xray 配置已生成，本地入口 HTTP=\(settings.httpHost):\(settings.httpPort)，SOCKS=\(settings.socksHost):\(settings.socksPort)", category: .xray)

        do {
            _ = try await XrayInstaller.ensureInstalled()
            try Task.checkCancellation()
            guard generation == connectGeneration else { throw ConnectionError.cancelled }
            logger.info("Xray 核心已就绪，正在启动进程", category: .xray)
            probeReservation.release()
            try await xray.start(configURL: file)
            try Task.checkCancellation()
        } catch let error as XrayProcessError {
            logger.error("Xray 启动失败：\(error.localizedDescription)", category: .xray)
            state.status = .error
            state.lastError = error.localizedDescription
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
            logger.error("本地代理端口等待超时：HTTP=\(settings.httpPort)，SOCKS=\(settings.socksPort)", category: .xray)
            throw ConnectionError.startFailed("本地代理端口未就绪（\(settings.httpPort)/\(settings.socksPort)）")
        }
        logger.info("Xray 已启动，本地 HTTP/SOCKS 端口均已就绪", category: .xray)


        var browseWarning: String?
        if verify {
            let base = TimeInterval(max(2, settings.connectTimeoutSeconds))
            let timeout = ProbePolicy.needsRelaxedTimeout(node)
                ? max(base, 12)
                : base
            logger.info("开始 HTTPS 连通性验证，超时=\(Int(timeout)) 秒，主地址=\(settings.testURL)，备用地址=3 个", category: .network)
            let result = await verifyConnectivity(settings: settings, probePort: probePort, timeout: timeout, generation: generation)
            guard generation == connectGeneration else {
                throw ConnectionError.cancelled
            }
            guard result.primaryOK else {
                logger.warning("HTTPS 验证失败：主地址和 3 个备用地址均不可达", category: .network)
                await teardownProxy(settings: settings, restoreSystemProxy: false)
                throw ConnectionError.verifyFailed("连通性验证失败：节点无法完成 HTTPS 访问")
            }
            logger.info(
                "HTTPS 验证完成：主地址=\(result.primaryLatency.map { "\($0) ms" } ?? "失败")，备用地址最快=\(result.browseLatency.map { "\($0) ms" } ?? "失败")",
                category: .network
            )
            if !result.browseOK {
                browseWarning = "节点已连通，但 Google/Cloudflare 探测失败；若打不开网站请换节点"
            }
        }

        try Task.checkCancellation()
        guard generation == connectGeneration else { throw ConnectionError.cancelled }
        do {
            logger.info("正在启用\(settings.connectionCaptureMode.displayName)", category: .systemProxy)
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
                    captureAll: settings.connectionCaptureMode == .globalTun, bootstrapDomains: [node.server])
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
            logger.info("\(settings.connectionCaptureMode.displayName)已启用", category: .systemProxy)
        } catch {
            logger.error("启用\(settings.connectionCaptureMode.displayName)失败：\(error.localizedDescription)", category: .systemProxy)
            await xray.stop()
            if settings.connectionCaptureMode == .systemVPN {
                await vpnManager.stop()
            }
            throw error
        }
        try Task.checkCancellation()
        guard generation == connectGeneration else { throw ConnectionError.cancelled }
        state.status = .connected
        state.currentNodeID = node.id
        state.currentCountryCode = countryCode ?? node.countryCode
        state.currentCountryName = countryName ?? node.countryName
        state.protocolType = node.protocolType
        // Keep verified latency; only fall back to last test result.
        state.latency = state.latency ?? node.lastLatency
        state.connectedAt = Date()
        state.sessionDownloadBytes = 0
        state.sessionUploadBytes = 0
        state.downloadMbps = 0
        state.uploadMbps = 0
        state.exitIP = nil
        state.exitCountry = nil
        state.lastError = browseWarning

        logger.info("连接成功：\(node.displayTitle)，总耗时=\(Int(Date().timeIntervalSince(startedAt) * 1000)) ms，验证延迟=\(state.latency.map { "\($0) ms" } ?? "未知")", category: .network)

        activeProbePort = probePort
        startMetrics(generation: generation)
        startLiveLatency(generation: generation, probePort: probePort, settings: settings)

        // 出口信息异步补充，不阻塞连接成功判定。
        exitTask = Task { @MainActor in
            let exit = await ExitIPTester.fetch(
                proxyHost: "127.0.0.1",
                proxyPort: probePort,
                timeout: 6,
                socksPort: nil
            )
            guard !Task.isCancelled, generation == self.connectGeneration,
                  self.state.currentNodeID == node.id, self.state.status == .connected else { return }
            self.state.exitIP = exit.ip
            self.state.exitCountry = exit.countryName ?? exit.countryCode
            self.logger.info(
                "出口检测完成：IP=\(exit.ip ?? "未获取")，地区=\(exit.countryName ?? exit.countryCode ?? "未知")",
                category: .network
            )

            let exitIsChina = {
                let code = exit.countryCode?.uppercased()
                let name = (exit.countryName ?? "").lowercased()
                return code == "CN" || name.contains("china") || name.contains("中国")
            }()

            if exit.ip == nil, self.state.lastError == nil {
                self.state.lastError = "已连接，但出口 IP 未获取到；若打不开网站请切换节点"
            } else if exitIsChina, settings.routingMode != .direct {
                // 仍走了 Xray，但远端出口在国内 —— 访问海外站点等同未翻墙。
                self.state.lastError = "出口在中国（经代理仍落在国内），无法访问 Google 等站点，请换海外节点"
            } else if exit.ip != nil, self.state.lastError?.contains("出口 IP") == true {
                self.state.lastError = nil
            }
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
        guard let url = URL(string: settings.testURL) else { return }
        liveLatencyTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { return }
                guard let self, generation == self.connectGeneration,
                      self.state.status == .connected else { return }
                let latency = await ProxyHTTPTester.measure(
                    proxyHost: "127.0.0.1", proxyPort: probePort,
                    testURL: url, timeout: 3, socksPort: nil,
                    strict: true, singleURL: true
                )
                guard !Task.isCancelled, generation == self.connectGeneration,
                      self.state.status == .connected else { return }
                self.state.latency = latency
                self.onLiveLatencySample?()
            }
        }
    }

    private func stopMetrics() {
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

    private struct ConnectivityProbeResult: Sendable {
        var primaryOK: Bool
        var browseOK: Bool
        var primaryLatency: Int?
        var browseLatency: Int?
    }

    private func verifyConnectivity(
        settings: AppSettings,
        probePort: Int,
        timeout: TimeInterval,
        generation: Int
    ) async -> ConnectivityProbeResult {
        guard generation == connectGeneration else {
            return ConnectivityProbeResult(primaryOK: false, browseOK: false, primaryLatency: nil, browseLatency: nil)
        }
        guard let primaryURL = URL(string: settings.testURL) else {
            return ConnectivityProbeResult(primaryOK: false, browseOK: false, primaryLatency: nil, browseLatency: nil)
        }

        // Browse targets are soft signals only — many free nodes pass gstatic but not Google.
        let browseURLs: [URL] = [
            URL(string: "https://www.google.com/generate_204"),
            URL(string: "https://www.cloudflare.com/cdn-cgi/trace"),
            URL(string: "https://cp.cloudflare.com/generate_204")
        ].compactMap { $0 }

        let outcome: (primary: Int?, browse: Int?) = await withTaskGroup(of: (String, Int?).self) { group in
            group.addTask {
                let ms = await ProxyHTTPTester.measure(
                    proxyHost: "127.0.0.1",
                    proxyPort: probePort,
                    testURL: primaryURL,
                    timeout: timeout,
                    socksPort: nil,
                    strict: true,
                    singleURL: true
                )
                return ("primary", ms)
            }
            for url in browseURLs {
                group.addTask {
                    let ms = await ProxyHTTPTester.measure(
                        proxyHost: "127.0.0.1",
                        proxyPort: probePort,
                        testURL: url,
                        timeout: timeout,
                        socksPort: nil,
                        strict: true,
                        singleURL: true
                    )
                    return ("browse", ms)
                }
            }
            group.addTask { @MainActor in
                let deadline = Date().addingTimeInterval(timeout + 0.5)
                while !Task.isCancelled && Date() < deadline {
                    if generation != self.connectGeneration {
                        return ("cancel", nil)
                    }
                    do { try await Task.sleep(nanoseconds: 100_000_000) }
                    catch { return ("cancel", nil) }
                }
                return ("cancel", nil)
            }

            var primary: Int?
            var browse: Int?
            var primaryDone = false
            var browseFinished = 0
            let browseTotal = browseURLs.count

            probeResults: for await (kind, ms) in group {
                if generation != connectGeneration {
                    group.cancelAll()
                    return (nil, nil)
                }
                switch kind {
                case "primary":
                    primaryDone = true
                    primary = ms
                    if primary != nil, browse != nil {
                        group.cancelAll()
                        break probeResults
                    }
                    // A single endpoint can be blocked or slow even when the node can
                    // browse normally. Keep waiting for the independent HTTPS fallbacks.
                    if primary == nil {
                        if browse != nil || browseFinished >= browseTotal {
                            group.cancelAll()
                            break probeResults
                        }
                        continue
                    }
                    if browseFinished >= browseTotal {
                        group.cancelAll()
                        break probeResults
                    }
                case "browse":
                    browseFinished += 1
                    if let ms {
                        browse = min(browse ?? ms, ms)
                    }
                    if primaryDone, browse != nil {
                        group.cancelAll()
                        break probeResults
                    }
                    if primaryDone, browseFinished >= browseTotal {
                        group.cancelAll()
                        break probeResults
                    }
                default:
                    group.cancelAll()
                    break probeResults
                }
            }
            return (primary, browse)
        }

        guard generation == connectGeneration else {
            return ConnectivityProbeResult(primaryOK: false, browseOK: false, primaryLatency: nil, browseLatency: nil)
        }
        if let latency = outcome.primary ?? outcome.browse {
            state.latency = latency
        }
        return ConnectivityProbeResult(
            // Every candidate performs a full TLS request through the local proxy, so
            // any success proves the node can carry HTTPS. Do not make gstatic a
            // single point of failure for connection establishment.
            primaryOK: outcome.primary != nil || outcome.browse != nil,
            browseOK: outcome.browse != nil,
            primaryLatency: outcome.primary,
            browseLatency: outcome.browse
        )
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
        if restoreSystemProxy, settings.connectionCaptureMode == .systemProxy {
            do {
                try await proxyManager.restoreFromBackup()
            } catch {
                captureCleanupFailed = true
                logger.error("恢复系统代理失败：\(error.localizedDescription)", category: .systemProxy)
            }
        }
    }

    private func handleVPNDrop() async {
        guard state.status == .connected, activeSettings?.connectionCaptureMode == .systemVPN else { return }
        let failedNodeID = state.currentNodeID
        var handled = false
        try? await operations.perform { _ in
            self.logger.error("系统 VPN 已断开，正在停止 Xray", category: .network)
            self.stopMetrics()
            self.exitTask?.cancel()
            // Prevent the intentional Xray stop below from producing a second
            // unexpected-disconnect callback.
            self.state.status = .error
            self.state.lastError = "连接中断：系统 VPN 已断开"
            await self.xray.stop()
            self.failoverStatus = nil
            self.isBusy = false
            handled = true
        }
        if handled {
            onUnexpectedDisconnect?(failedNodeID, "系统 VPN 已断开")
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

        // Keep quick switch, startup auto-connect, and failover on the same order:
        // favorite policy first, then app reachability tier and measured latency.
        return list.sorted { lhs, rhs in
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

    private func handleXrayCrash() {
        // Ignore exits while connecting / switching nodes — those are intentional stop()+restart.
        guard state.status == .connected else { return }

        let generation = connectGeneration
        Task { @MainActor [weak self] in
            guard let self, generation == self.connectGeneration, let settings = self.activeSettings else { return }
            let failedNodeID = self.state.currentNodeID
            var handled = false
            try? await self.operations.perform { _ in
                self.logger.error("检测到 Xray 进程异常退出，正在恢复系统代理", category: .xray)
                await self.teardownProxy(settings: settings, restoreSystemProxy: true)
                self.state.status = .error
                self.state.lastError = "连接中断：Xray 已退出"
                self.failoverStatus = nil
                self.isBusy = false
                handled = true
            }
            if handled {
                self.onUnexpectedDisconnect?(failedNodeID, "Xray 已退出")
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
    case noCandidates
    case connectFailed
    case timeout(seconds: Int)
    case verifyFailed(String)
    case startFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noCandidates: return "没有可用的收藏/候选节点"
        case .connectFailed: return "连接失败"
        case .timeout(let seconds): return "连接验证超时（\(seconds) 秒）"
        case .verifyFailed(let message): return message
        case .startFailed(let message): return message
        case .cancelled: return "连接已取消"
        }
    }
}
