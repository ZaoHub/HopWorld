import Foundation

enum TestRunPhase: Equatable, Sendable {
    case idle
    case running
    case paused
    case finished

    var displayName: String {
        switch self {
        case .idle: return "空闲"
        case .running: return "测试中"
        case .paused: return "已暂停"
        case .finished: return "已完成"
        }
    }
}

struct NodeTestRunSummary: Equatable, Sendable {
    var totalCount: Int
    var availableCount: Int
    /// 连通探测不通。
    var unavailableCount: Int
    /// 配置/客户端无法测。
    var failedCount: Int
    var durationSeconds: Int
    /// 本轮逐条结果（名称 · 档次 · 延迟 / 失败或不可用原因）。
    var detailLines: [String] = []

    var message: String {
        var parts: [String] = []
        if !detailLines.isEmpty {
            let shown = detailLines.prefix(15)
            parts.append(shown.joined(separator: "\n"))
            if detailLines.count > 15 {
                parts.append("…另有 \(detailLines.count - 15) 个")
            }
            parts.append("")
        }
        parts.append("可用：\(availableCount)    不可用：\(unavailableCount)    失败：\(failedCount)")
        parts.append("耗时：\(max(0, durationSeconds)) 秒")
        return parts.joined(separator: "\n")
    }
}

@MainActor
final class NodeTestManager: ObservableObject {
    @Published var phase: TestRunPhase = .idle
    @Published var isTesting = false
    @Published var progress: Double = 0
    @Published var testedCount = 0
    @Published var totalCount = 0
    @Published var availableCount = 0
    @Published var unavailableCount = 0
    @Published var failedCount = 0
    @Published var statusText = ""
    /// 当前会话尚未测完的节点 ID（暂停后用于继续）。
    @Published private(set) var remainingNodeIDs: [UUID] = []
    @Published var lastFinishedSummary: NodeTestRunSummary?
    @Published var showFinishedAlert = false
    /// 为 true 时不弹「测试完成」提示（定时/更新后自动测速）。
    private var suppressFinishedAlert = false

    /// Application reachability through the current local proxy (Google / ChatGPT / …).
    @Published var appProbePhase: AppProbePhase = .idle
    @Published var appProbeResults: [AppProbeResult] = AppProbeTarget.allCases.map(AppProbeResult.placeholder)
    @Published var appProbeStatusText = "请先连接节点后再探测"
    /// Node that was used for the last / in-progress app probe.
    @Published var appProbeNodeLabel: String? = nil

    private var pauseRequested = false
    private var stopRequested = false
    /// Set when the user aborts a run. Callers must not start follow-up probes.
    private var userStopRequested = false
    private var sessionStartedAt: Date?
    private var sessionNodeNames: [UUID: String] = [:]
    private var sessionDetailLines: [String] = []
    private var appProbeTask: Task<Void, Never>?
    private var sessionTask: Task<Void, Never>?
    private let xray: XrayProcessManager
    private let binaryOverride: URL?
    private let testDirectory: URL
    private let baseTestPort = 21001

    init(binaryURL: URL? = nil, testDirectory: URL? = nil) {
        binaryOverride = binaryURL
        xray = XrayProcessManager(binaryURL: binaryURL)
        self.testDirectory = testDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("HopWorld-batch-\(UUID().uuidString)", isDirectory: true)
    }

    var canPause: Bool { phase == .running }
    var canResume: Bool { phase == .paused && !remainingNodeIDs.isEmpty }
    var canRetest: Bool { phase != .running }
    var isProbingApps: Bool { appProbePhase == .running }

    func pause() {
        guard phase == .running else { return }
        pauseRequested = true
        sessionTask?.cancel()
        statusText = "正在暂停…"
    }

    /// Abort the current run. Unfinished nodes are dropped instead of staying paused.
    func stop() {
        guard phase == .running else { return }
        stopRequested = true
        userStopRequested = true
        pauseRequested = false
        sessionTask?.cancel()
        statusText = "正在停止…"
    }

    func consumeUserStop() -> Bool {
        let value = userStopRequested
        userStopRequested = false
        return value
    }

    /// 静默测应用连通，不改测试中心 UI；供自动优选补数据。
    func measureAppProbe(
        for node: ProxyNode,
        timeout: TimeInterval,
        targets: [AppProbeTarget] = AppProbeTarget.allCases
    ) async -> (okCount: Int, bestLatencyMs: Int?) {
        let xray = XrayProcessManager()
        let (valid, _) = NodeConfigChecker.validate(node)
        guard valid else { return (0, nil) }

        _ = try? await XrayInstaller.ensureInstalled()
        guard XrayProcessManager.resolveBinaryURL() != nil else { return (0, nil) }

        let port = baseTestPort + 901
        do {
            let config = try XrayConfigBuilder.buildTestConfig(nodes: [(node, port)])
            let dir = try XrayProcessManager.configDirectory()
            let file = dir.appendingPathComponent("app-probe-auto-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: file) }
            try XrayConfigBuilder.writeJSON(config, to: file)
            try await xray.start(configURL: file)
            try await Task.sleep(nanoseconds: 150_000_000)

            var collected: [AppProbeTarget: AppProbeResult] = [:]
            await AppProbeRunner.probeAll(
                targets: targets,
                proxyHost: "127.0.0.1",
                httpPort: port,
                socksPort: nil,
                timeout: timeout
            ) { result in
                collected[result.target] = result
            }
            await xray.stop()

            let ok = targets.compactMap { collected[$0] }.filter { $0.status == .ok }
            return (ok.count, ok.compactMap(\.latencyMs).min())
        } catch {
            await xray.stop()
            return (0, nil)
        }
    }

    /// Probe popular apps through a temporary local proxy for the given node.
    /// Does **not** change the system proxy / active connection — selection-only testing.
    func probeApps(
        for node: ProxyNode,
        nodeLabel: String,
        settings: AppSettings,
        timeout: TimeInterval = 4
    ) async {
        let targets = settings.automaticAppProbeTargets
        appProbeTask?.cancel()
        let task = Task { @MainActor in
            let xray = XrayProcessManager()
            appProbePhase = .running
            appProbeNodeLabel = nodeLabel
            appProbeStatusText = "正在探测…"
            appProbeResults = targets.map {
                AppProbeResult(target: $0, status: .testing, latencyMs: nil, testedAt: nil)
            }

            let (valid, error) = NodeConfigChecker.validate(node)
            guard valid else {
                appProbePhase = .done
                appProbeStatusText = error ?? "节点配置无效"
                appProbeResults = targets.map {
                    AppProbeResult(target: $0, status: .failed, latencyMs: nil, testedAt: Date())
                }
                return
            }

            _ = try? await XrayInstaller.ensureInstalled()
            guard XrayProcessManager.resolveBinaryURL() != nil else {
                appProbePhase = .done
                appProbeStatusText = "未找到 xray，无法探测应用"
                return
            }

            // Dedicated port so app probes never collide with batch test inbounds.
            let port = baseTestPort + 900
            do {
                let config = try XrayConfigBuilder.buildTestConfig(nodes: [(node, port)])
                let dir = try XrayProcessManager.configDirectory()
                let file = dir.appendingPathComponent("app-probe-\(UUID().uuidString).json")
                defer { try? FileManager.default.removeItem(at: file) }
                try XrayConfigBuilder.writeJSON(config, to: file)
                try await xray.start(configURL: file)
                try await Task.sleep(nanoseconds: 150_000_000)

                await AppProbeRunner.probeAll(
                    targets: targets,
                    proxyHost: "127.0.0.1",
                    httpPort: port,
                    socksPort: nil,
                timeout: timeout
            ) { result in
                    if let index = self.appProbeResults.firstIndex(where: { $0.target == result.target }) {
                        self.appProbeResults[index] = result
                    }
                }
                await xray.stop()
            } catch {
                await xray.stop()
                appProbePhase = .done
                appProbeStatusText = "探测启动失败：\(error.localizedDescription)"
                appProbeResults = targets.map {
                    AppProbeResult(target: $0, status: .failed, latencyMs: nil, testedAt: Date())
                }
                return
            }

            guard !Task.isCancelled else { return }
            let ok = appProbeResults.filter { $0.status == .ok }.count
            let total = appProbeResults.count
            appProbePhase = .done
            appProbeStatusText = "\(ok)/\(total) 通过（未切换系统代理）"
        }
        appProbeTask = task
        await task.value
    }

    /// Probe through the live system proxy (current connection).
    func probeApps(
        proxyHost: String,
        httpPort: Int,
        socksPort: Int,
        timeout: TimeInterval = 4,
        nodeLabel: String,
        targets: [AppProbeTarget] = AppProbeTarget.allCases
    ) async {
        appProbeTask?.cancel()
        let task = Task { @MainActor in
            appProbePhase = .running
            appProbeNodeLabel = nodeLabel
            appProbeStatusText = "正在探测…"
            appProbeResults = targets.map {
                AppProbeResult(target: $0, status: .testing, latencyMs: nil, testedAt: nil)
            }

            await AppProbeRunner.probeAll(
                    targets: targets,
                proxyHost: proxyHost,
                httpPort: httpPort,
                socksPort: socksPort,
                timeout: timeout
            ) { result in
                if let index = self.appProbeResults.firstIndex(where: { $0.target == result.target }) {
                    self.appProbeResults[index] = result
                }
            }

            guard !Task.isCancelled else { return }
            let ok = appProbeResults.filter { $0.status == .ok }.count
            let total = appProbeResults.count
            appProbePhase = .done
            appProbeStatusText = "\(ok)/\(total) 通过"
        }
        appProbeTask = task
        await task.value
    }

    func resetAppProbes(targets: [AppProbeTarget] = AppProbeTarget.allCases) {
        appProbeTask?.cancel()
        appProbeTask = nil
        appProbePhase = .idle
        appProbeNodeLabel = nil
        appProbeResults = targets.map(AppProbeResult.placeholder)
        appProbeStatusText = "未连接时请选中节点；已连接时可直接探测当前代理"
    }

    /// 重新开始：清空进度，测试传入的全部节点。
    /// - Parameter silent: 为 true 时后台跑完不弹完成提示。
    /// - Returns: 是否真正启动了本轮测速（已在测速中时返回 false）。
    @discardableResult
    func startTest(
        nodes: [ProxyNode],
        settings: AppSettings,
        silent: Bool = false,
        updateNode: @escaping (UUID, NodeTestResult) -> Void
    ) async -> Bool {
        guard !nodes.isEmpty else { return false }
        guard phase != .running else { return false }
        var seen = Set<UUID>()
        let nodes = nodes.filter { seen.insert($0.id).inserted }

        pauseRequested = false
        stopRequested = false
        userStopRequested = false
        suppressFinishedAlert = silent
        remainingNodeIDs = nodes.map(\.id)
        sessionNodeNames = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.displayTitle) })
        sessionDetailLines = []
        testedCount = 0
        totalCount = nodes.count
        availableCount = 0
        unavailableCount = 0
        failedCount = 0
        progress = 0
        statusText = silent ? "后台测速中…" : "准备测试…"
        sessionStartedAt = Date()
        showFinishedAlert = false

        await executeSession(nodes: nodes, settings: settings, single: nodes.count == 1, updateNode: updateNode)
        return true
    }

    private func executeSession(nodes: [ProxyNode], settings: AppSettings, single: Bool,
                                updateNode: @escaping (UUID, NodeTestResult) -> Void) async {
        phase = .running
        isTesting = true
        let task = Task { @MainActor in
            if single, let node = nodes.first {
                await runSingleNodeSession(node: node, settings: settings, updateNode: updateNode)
            } else {
                await runSession(nodes: nodes, settings: settings, updateNode: updateNode)
            }
        }
        sessionTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        sessionTask = nil
    }

    /// 单个节点：使用 `testTimeoutSeconds`，与设置里「单测超时」一致。
    private func runSingleNodeSession(
        node: ProxyNode,
        settings: AppSettings,
        updateNode: @escaping (UUID, NodeTestResult) -> Void
    ) async {
        phase = .running
        isTesting = true
        remainingNodeIDs = [node.id]
        statusText = "正在测试 \(node.displayTitle)…"

        let result = await testSingle(node: node, settings: settings, includeExitIP: false)
        if !Task.isCancelled { record(result, updateNode: updateNode) }

        isTesting = false
        if stopRequested {
            endStoppedSession()
        } else if pauseRequested || Task.isCancelled {
            phase = .paused
            statusText = "已暂停"
        } else {
            phase = .finished
            statusText = result.success
                ? "测试完成"
                : (result.isConfigFailure ? "测试完成（失败）" : "测试完成（不可用）")
            presentFinishedAlert()
        }
    }

    /// 继续上次未测完的节点。
    func resumeTest(
        nodesByID: (UUID) -> ProxyNode?,
        settings: AppSettings,
        updateNode: @escaping (UUID, NodeTestResult) -> Void
    ) async {
        guard canResume else { return }
        let nodes = remainingNodeIDs.compactMap(nodesByID)
        guard !nodes.isEmpty else {
            phase = .finished
            remainingNodeIDs = []
            statusText = "没有可继续的节点"
            presentFinishedAlert()
            return
        }

        if sessionStartedAt == nil {
            sessionStartedAt = Date()
        }
        for node in nodes {
            sessionNodeNames[node.id] = node.displayTitle
        }
        pauseRequested = false
        stopRequested = false
        userStopRequested = false
        statusText = "继续测试…"
        totalCount -= remainingNodeIDs.count - nodes.count
        await executeSession(nodes: nodes, settings: settings, single: false, updateNode: updateNode)
    }

    func testSingle(
        node: ProxyNode,
        settings: AppSettings,
        includeExitIP: Bool = true
    ) async -> NodeTestResult {
        let xray = XrayProcessManager()
        let timeout = TimeInterval(max(1, settings.testTimeoutSeconds))

        _ = try? await XrayInstaller.ensureInstalled()
        if XrayProcessManager.resolveBinaryURL() == nil {
            return await NodeProbeEngine.tcpOnly(node: node, timeout: min(timeout, 2))
        }

        let (configValid, configError) = NodeConfigChecker.validate(node)
        guard configValid else {
            return NodeTestResult(
                nodeID: node.id,
                configValid: false,
                success: false,
                failureStage: .config,
                errorMessage: configError
            )
        }

        do {
            let port = baseTestPort + 500
            let config = try XrayConfigBuilder.buildTestConfig(nodes: [(node, port)])
            let dir = try XrayProcessManager.configDirectory()
            let file = dir.appendingPathComponent("test-single-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: file) }
            try XrayConfigBuilder.writeJSON(config, to: file)
            try await xray.start(configURL: file)
            // REALITY / Vision / FinalMask 首次拨号更慢，单测多等一会再探测。
            let warmUpNs: UInt64 = ProbePolicy.needsRelaxedTimeout(node) ? 400_000_000 : 150_000_000
            try await Task.sleep(nanoseconds: warmUpNs)

            let probeTimeout = ProbePolicy.httpsTimeout(
                for: node,
                batchTimeout: timeout,
                singleTimeout: timeout
            )
            var result = await NodeProbeEngine.quickProxyProbe(
                node: node,
                localPort: port,
                testURL: URL(string: settings.testURL),
                timeout: probeTimeout
            )

            // 慢握手节点：首次 HTTPS 偶发超时，再试一次（拨号已预热）。
            if !result.success,
               !Task.isCancelled,
               result.failureStage == .http,
               ProbePolicy.needsRelaxedTimeout(node) {
                result = await NodeProbeEngine.quickProxyProbe(
                    node: node,
                    localPort: port,
                    testURL: URL(string: settings.testURL),
                    timeout: probeTimeout
                )
            }

            if includeExitIP, result.success {
                let exit = await ExitIPTester.fetch(
                    proxyHost: "127.0.0.1",
                    proxyPort: port,
                    timeout: 4
                )
                result.exitIP = exit.ip
                result.exitCountryCode = exit.countryCode
                result.exitCountryName = exit.countryName
                result.asn = exit.asn
            }

            await xray.stop()
            return result
        } catch {
            await xray.stop()
            if Task.isCancelled {
                return NodeTestResult(nodeID: node.id, configValid: true, errorMessage: "测试已取消")
            }
            return await NodeProbeEngine.tcpOnly(node: node, timeout: timeout)
        }
    }

    // MARK: - Session

    private func runSession(
        nodes: [ProxyNode],
        settings: AppSettings,
        updateNode: @escaping (UUID, NodeTestResult) -> Void
    ) async {
        phase = .running
        isTesting = true
        // 仅覆盖本轮待测集合；已完成的不在 nodes 中。
        remainingNodeIDs = nodes.map(\.id)

        let httpsConcurrency = min(16, max(1, settings.testConcurrency))
        let batchSize = max(16, httpsConcurrency * 2)
        let timeout = TimeInterval(max(1, settings.batchTestTimeoutSeconds))
        let tcpTimeout = min(timeout, 3.0)

        statusText = "正在准备测速核心…"
        if binaryOverride == nil { _ = try? await XrayInstaller.ensureInstalled() }
        let useXray = binaryOverride != nil || XrayProcessManager.resolveBinaryURL() != nil
        AppLogger.shared.info(
            "批量测速启动：\(nodes.count) 个节点，HTTPS 超时 \(settings.batchTestTimeoutSeconds)s，单测参考 \(settings.testTimeoutSeconds)s，并发 \(httpsConcurrency)，批大小 \(batchSize)",
            category: .network
        )

        if !useXray {
            statusText = "未检测到 xray，使用 TCP 快速探测…"
            await runConcurrentTCP(
                nodes: nodes,
                concurrency: max(16, httpsConcurrency),
                timeout: tcpTimeout,
                updateNode: updateNode
            )
        } else {
            let batches = stride(from: 0, to: nodes.count, by: batchSize).map {
                Array(nodes[$0..<min($0 + batchSize, nodes.count)])
            }
            for batch in batches {
                if pauseRequested || Task.isCancelled { break }
                await testBatch(
                    batch,
                    settings: settings,
                    timeout: timeout,
                    tcpTimeout: tcpTimeout,
                    httpsConcurrency: httpsConcurrency,
                    updateNode: updateNode
                )
                if pauseRequested || Task.isCancelled { break }
            }
            await xray.stop()
            try? FileManager.default.removeItem(at: testDirectory.appendingPathComponent("test-batch.json"))
        }

        isTesting = false
        if stopRequested {
            endStoppedSession()
        } else if pauseRequested || Task.isCancelled {
            phase = .paused
            statusText = "已暂停（剩余 \(remainingNodeIDs.count) 个，可继续）"
        } else {
            // 未出结果的节点不能一直停在「测试中」
            let leftover = remainingNodeIDs
            for id in leftover {
                record(
                    NodeTestResult(
                        nodeID: id,
                        configValid: true,
                        success: false,
                        failureStage: .http,
                        errorMessage: "测试未完成"
                    ),
                    updateNode: updateNode
                )
            }
            remainingNodeIDs = []
            progress = 1
            phase = .finished
            statusText = "测试完成"
            presentFinishedAlert()
        }
    }

    private func endStoppedSession() {
        stopRequested = false
        pauseRequested = false
        remainingNodeIDs = []
        phase = .idle
        statusText = "已停止"
    }

    private func presentFinishedAlert() {
        let elapsed = Int(Date().timeIntervalSince(sessionStartedAt ?? Date()))
        lastFinishedSummary = NodeTestRunSummary(
            totalCount: totalCount,
            availableCount: availableCount,
            unavailableCount: unavailableCount,
            failedCount: failedCount,
            durationSeconds: max(0, elapsed),
            detailLines: sessionDetailLines
        )
        if suppressFinishedAlert {
            statusText = "后台测速完成"
            suppressFinishedAlert = false
            return
        }
        showFinishedAlert = true
    }

    private func markCompleted(id: UUID) {
        remainingNodeIDs.removeAll { $0 == id }
    }

    private func record(_ result: NodeTestResult, updateNode: (UUID, NodeTestResult) -> Void) {
        guard !Task.isCancelled, remainingNodeIDs.contains(result.nodeID) else { return }
        applyCounts(result)
        updateNode(result.nodeID, result)
        testedCount += 1
        markCompleted(id: result.nodeID)
        progress = Double(testedCount) / Double(max(totalCount, 1))
        statusText = "正在测试 \(testedCount) / \(totalCount)"
        sessionDetailLines.append(detailLine(for: result))
    }

    private func detailLine(for result: NodeTestResult) -> String {
        let name = sessionNodeNames[result.nodeID] ?? "节点"
        if result.success {
            let ms = result.primaryLatency ?? 0
            let tier = NodeTestStatus.from(latencyMs: ms).displayName
            return "\(name) · \(tier) · \(LatencyFormat.seconds(ms))"
        }
        if result.isConfigFailure {
            let err = result.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let err, !err.isEmpty {
                return "\(name) · 失败（\(err)）"
            }
            return "\(name) · 失败"
        }
        if let err = result.errorMessage, !err.isEmpty, err != "TCP_PASS" {
            return "\(name) · 不可用（\(err)）"
        }
        if let tcp = result.tcpLatency {
            return "\(name) · 不可用（TCP \(LatencyFormat.seconds(tcp))）"
        }
        return "\(name) · 不可用"
    }

    private func runConcurrentTCP(
        nodes: [ProxyNode],
        concurrency: Int,
        timeout: TimeInterval,
        updateNode: @escaping (UUID, NodeTestResult) -> Void
    ) async {
        await BatchProbeScheduler.run(nodes, concurrency: concurrency) { node in
            var result = await NodeProbeEngine.tcpOnly(node: node, timeout: timeout)
            result.success = false
            result.configValid = false
            result.failureStage = .config
            result.errorMessage = "Xray 未就绪，仅 TCP 探测无法确认代理可用"
            return result
        } onResult: { result in
            record(result, updateNode: updateNode)
        }
    }

    private func testBatch(
        _ nodes: [ProxyNode],
        settings: AppSettings,
        timeout: TimeInterval,
        tcpTimeout: TimeInterval,
        httpsConcurrency: Int,
        updateNode: @escaping (UUID, NodeTestResult) -> Void
    ) async {
        statusText = "正在测试 \(testedCount) / \(totalCount)（HTTPS \(Int(timeout))s）"
        guard !Task.isCancelled, !pauseRequested else { return }
        let testURL = URL(string: settings.testURL)

        // 先剔除会使整份 Xray 配置无法启动的节点（如公网无 TLS 的 VLESS）。
        var usableNodes: [ProxyNode] = []
        usableNodes.reserveCapacity(nodes.count)
        for node in nodes {
            let (valid, error) = NodeConfigChecker.validate(node)
            if valid {
                usableNodes.append(node)
            } else {
                record(
                    NodeTestResult(
                        nodeID: node.id,
                        configValid: false,
                        success: false,
                        failureStage: .config,
                        errorMessage: error
                    ),
                    updateNode: updateNode
                )
            }
        }
        guard !usableNodes.isEmpty else { return }

        do {
            let reservation = try LocalTestPorts(count: usableNodes.count)
            let mapped = Array(zip(usableNodes, reservation.ports))
            let config = try XrayConfigBuilder.buildTestConfig(nodes: mapped)
            let file = testDirectory.appendingPathComponent("test-batch.json")
            try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
            try XrayConfigBuilder.writeJSON(config, to: file)
            try Task.checkCancellation()
            reservation.release()
            try await xray.start(configURL: file)
            try Task.checkCancellation()
            let ready = await waitForTestPorts(mapped.map(\.1), timeout: 3.0)
            guard ready else {
                let log = await xray.readRecentOutput()
                await xray.stop()
                let detail = log.isEmpty ? "本地测速端口未监听" : String(log.suffix(300))
                for (node, _) in mapped {
                    record(
                        NodeTestResult(
                            nodeID: node.id,
                            configValid: false,
                            success: false,
                            failureStage: .config,
                            errorMessage: "Xray 未就绪：\(detail)"
                        ),
                        updateNode: updateNode
                    )
                }
                return
            }

            await BatchProbeScheduler.run(mapped, concurrency: httpsConcurrency) { item in
                await NodeProbeEngine.batchProxyProbe(
                    node: item.0, localPort: item.1, testURL: testURL,
                    tcpTimeout: tcpTimeout, httpsTimeout: timeout
                )
            } onResult: { result in
                record(result, updateNode: updateNode)
            }
        } catch {
            if Task.isCancelled || pauseRequested { return }
            let detail = error.localizedDescription
            AppLogger.shared.warning(
                "批量测速 xray 失败：\(detail)",
                category: .network
            )
            await xray.stop()

            // Runtime/resource failures affect the whole core; recursively
            // splitting them would repeat the same expensive failure N times.
            let binary = binaryOverride ?? XrayProcessManager.resolveBinaryURL()
            let coreAvailable = binary.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false
            let sharedFailure = !coreAvailable || error is POSIXError
            // Only isolate node-specific config failures.
            if usableNodes.count <= 1 || sharedFailure {
                for node in usableNodes where remainingNodeIDs.contains(node.id) {
                    record(
                        NodeTestResult(
                            nodeID: node.id,
                            configValid: false,
                            success: false,
                            failureStage: .config,
                            errorMessage: "Xray 启动失败：\(detail)"
                        ),
                        updateNode: updateNode
                    )
                }
                return
            }

            let mid = usableNodes.count / 2
            await testBatch(
                Array(usableNodes[..<mid]),
                settings: settings,
                timeout: timeout,
                tcpTimeout: tcpTimeout,
                httpsConcurrency: httpsConcurrency,
                updateNode: updateNode
            )
            guard !pauseRequested, !Task.isCancelled else { return }
            await testBatch(
                Array(usableNodes[mid...]),
                settings: settings,
                timeout: timeout,
                tcpTimeout: tcpTimeout,
                httpsConcurrency: httpsConcurrency,
                updateNode: updateNode
            )
        }
    }

    private func waitForTestPorts(_ ports: [Int], timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !Task.isCancelled && Date() < deadline {
            let ready = await withTaskGroup(of: Bool.self) { group in
                for port in ports {
                    group.addTask { await TCPTester.measure(host: "127.0.0.1", port: port, timeout: 0.25) != nil }
                }
                var allReady = true
                for await ready in group { allReady = allReady && ready }
                return allReady
            }
            if ready && !Task.isCancelled { return true }
            do { try await Task.sleep(nanoseconds: 80_000_000) }
            catch { return false }
        }
        return false
    }

    private func applyCounts(_ result: NodeTestResult) {
        if result.success {
            availableCount += 1
        } else if result.isConfigFailure {
            failedCount += 1
        } else {
            unavailableCount += 1
        }
    }
}
