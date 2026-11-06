import XCTest
import Network
import Combine

private final class SilentTCPServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.silent-tcp")
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private var completed = false // Accessed only on queue.
    private let response: Data?
    init(response: Data? = nil) throws {
        self.response = response
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                guard !completed else { return }
                switch state {
                case .ready:
                    completed = true
                    continuation.resume(returning: Int(listener.port!.rawValue))
                case .failed(let error):
                    completed = true
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                connections.append(connection)
                connection.start(queue: queue) // Accept TCP, never reply to TLS/VLESS.
                if let response {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                        guard data?.isEmpty == false else { connection.cancel(); return }
                        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                    }
                }
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 3) { [self] in
                if !completed {
                    completed = true
                    continuation.resume(throwing: NSError(domain: "fixture-timeout", code: 1))
                }
            }
        }
    }

    func stop() {
        queue.sync {
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            listener.cancel()
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }
}

private actor SchedulerGauge {
    var active = 0
    var maximum = 0
    func enter() { active += 1; maximum = max(active, maximum) }
    func leave() { active -= 1 }
}

@MainActor
final class BatchTestingTests: XCTestCase {
    private func fixture() throws -> (NodeTestManager, URL) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let binary = root.appendingPathComponent("HopWorld/Resources/xray")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw XCTSkip("本地未提供 Xray") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("batch-test-\(UUID().uuidString)")
        return (NodeTestManager(binaryURL: binary, testDirectory: directory), directory)
    }

    private func nodes(count: Int, port: Int, slowProtocol: Bool = false) -> [ProxyNode] {
        (0..<count).map { index in
            var node = ProxyNode(name: "fixture-\(index)", protocolType: .vless, server: "127.0.0.1", port: port,
                                 uuid: "11111111-1111-4111-8111-111111111111")
            if slowProtocol {
                node.security = .tls
                node.flow = "xtls-rprx-vision"
            }
            return node
        }
    }

    private func settings(timeout: Int = 1, concurrency: Int = 4) -> AppSettings {
        var settings = AppSettings()
        settings.batchTestTimeoutSeconds = timeout
        settings.testTimeoutSeconds = 20 // Batch must NOT inherit this value.
        settings.testConcurrency = concurrency
        settings.testURL = "https://fixture.invalid/"
        return settings
    }

    func testApplicationProgressCountsOnlyCompletedTargetsAndResets() {
        let manager = NodeTestManager()
        manager.appProbeResults = [
            AppProbeResult(target: .github, status: .ok, latencyMs: 25, testedAt: Date()),
            AppProbeResult(target: .google, status: .failed, latencyMs: nil, testedAt: Date()),
            AppProbeResult(target: .youtube, status: .testing, latencyMs: nil, testedAt: nil),
            .placeholder(.chatgpt)
        ]
        XCTAssertEqual(manager.appProbeCompletedCount, 2)
        XCTAssertEqual(manager.appProbeResults.count, 4)
        manager.resetAppProbes(targets: [.github, .google])
        XCTAssertEqual(manager.appProbeCompletedCount, 0)
        manager.resetAppProbes(targets: [])
        XCTAssertEqual(manager.appProbeCompletedCount, 0)
    }

    func testUnstartedApplicationProbeDoesNotProduceACachedFailure() async {
        let manager = NodeTestManager(binaryURL: URL(fileURLWithPath: "/nonexistent/hopworld-xray"))
        let node = nodes(count: 1, port: 443)[0]
        let summary = await manager.measureAppProbe(for: node, timeout: 1, targets: [.github])
        XCTAssertNil(summary, "未启动的探测必须保留为未测试，后续才能自动重试")
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await manager.measureAppProbe(for: node, timeout: 1, targets: [.github])
        }
        let cancelledSummary = await cancelled.value
        XCTAssertNil(cancelledSummary)
    }

    func testBackgroundTestConfigPreservesPortsAndPermissions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("config-worker-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("test.json")
        let targets = nodes(count: 128, port: 443)
        let mapped = targets.enumerated().map { (node: $0.element, localPort: 21001 + $0.offset) }
        try await XrayConfigBuilder.writeTestConfig(nodes: mapped, to: file, verbose: true)
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let inbounds = try XCTUnwrap(config["inbounds"] as? [[String: Any]])
        XCTAssertEqual(inbounds.compactMap { $0["port"] as? Int }, Array(21001..<21129))
        XCTAssertEqual((config["log"] as? [String: String])?["loglevel"], "info")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let cancelledFile = directory.appendingPathComponent("cancelled.json")
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await XrayConfigBuilder.writeTestConfig(nodes: mapped, to: cancelledFile)
        }
        cancelled.cancel()
        do {
            try await cancelled.value
            XCTFail("Cancelled configuration preparation should not write a file")
        } catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelledFile.path))
    }

    func testApplicationProbesKeepMainActorResponsiveAndCancel() async throws {
        let server = try SilentTCPServer()
        let port = try await server.start()
        defer { server.stop() }
        let targets: [AppProbeTarget] = (0..<16).map {
            .application(path: "/fixture/app-\($0)", name: "fixture", url: URL(string: "https://fixture.invalid/"))
        }
        var ticks = 0
        var maximumGap: TimeInterval = 0
        let heartbeat = Task { @MainActor in
            var previous = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 20_000_000) } catch { break }
                let now = ProcessInfo.processInfo.systemUptime
                maximumGap = max(maximumGap, now - previous)
                previous = now
                ticks += 1
            }
        }
        var results: [AppProbeResult] = []
        await AppProbeRunner.probeAll(targets: targets, proxyHost: "127.0.0.1", httpPort: port, timeout: 0.3) {
            results.append($0)
        }
        heartbeat.cancel()
        await heartbeat.value
        XCTAssertEqual(Set(results.map { $0.target.id }), Set(targets.map(\.id)))
        XCTAssertEqual(results.count, targets.count)
        XCTAssertGreaterThan(ticks, 2)
        XCTAssertLessThan(maximumGap, 0.5, "应用连通探测不应阻塞主线程")
        var lateResults = 0
        let probing = Task { @MainActor in
            await AppProbeRunner.probeAll(targets: targets, proxyHost: "127.0.0.1", httpPort: port, timeout: 5) { _ in
                lateResults += 1
            }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let cancelledAt = ProcessInfo.processInfo.systemUptime
        probing.cancel()
        await probing.value
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - cancelledAt, 1)
        XCTAssertEqual(lateResults, 0)
        print("APP_PROBE_RESPONSIVENESS ticks=\(ticks), maxGap=\(maximumGap)s")
    }

    func testStoppingNodeTestsDoesNotCancelApplicationProbe() async throws {
        let server = try SilentTCPServer()
        let port = try await server.start()
        defer { server.stop() }
        let (manager, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probing = Task {
            await manager.probeApps(proxyHost: "127.0.0.1", httpPort: port, socksPort: port,
                                    timeout: 5, nodeLabel: "independent-app-probe", targets: [.github])
        }
        let testing = Task {
            await manager.startTest(nodes: nodes(count: 8, port: port), settings: settings(), silent: true) { _, _ in }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(manager.isProbingApps)
        XCTAssertTrue(manager.isTesting)
        manager.stop()
        await testing.value
        XCTAssertTrue(manager.isProbingApps)
        XCTAssertEqual(manager.appProbeNodeLabel, "independent-app-probe")
        manager.resetAppProbes()
        let completed = await probing.value
        XCTAssertFalse(completed)
        XCTAssertEqual(manager.appProbePhase, .idle)
    }

    func testCancellingApplicationProbeDoesNotStopNodeTests() async throws {
        let server = try SilentTCPServer()
        let port = try await server.start()
        defer { server.stop() }
        let (manager, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let testing = Task {
            await manager.startTest(nodes: nodes(count: 8, port: port), settings: settings(timeout: 5), silent: true) { _, _ in }
        }
        let probing = Task {
            await manager.probeApps(proxyHost: "127.0.0.1", httpPort: port, socksPort: port,
                                    timeout: 5, nodeLabel: "cancel-only-app", targets: [.github])
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        manager.resetAppProbes()
        _ = await probing.value
        XCTAssertTrue(manager.isTesting)
        XCTAssertEqual(manager.phase, .running)
        manager.stop()
        await testing.value
    }

    func testReplacedApplicationProbeCannotOverwriteNewResults() async throws {
        let server = try SilentTCPServer()
        let port = try await server.start()
        defer { server.stop() }
        let manager = NodeTestManager()
        let old = Task {
            await manager.probeApps(proxyHost: "127.0.0.1", httpPort: port, socksPort: port,
                                    timeout: 5, nodeLabel: "old", targets: [.github])
        }
        try await Task.sleep(nanoseconds: 80_000_000)
        manager.resetAppProbes()
        let completed = await manager.probeApps(proxyHost: "127.0.0.1", httpPort: port, socksPort: port,
                                               nodeLabel: "new", targets: [])
        let oldCompleted = await old.value
        XCTAssertTrue(completed)
        XCTAssertFalse(oldCompleted)
        XCTAssertEqual(manager.appProbeNodeLabel, "new")
        XCTAssertEqual(manager.appProbePhase, .done)
        XCTAssertTrue(manager.appProbeResults.isEmpty)
    }

    func testConcurrentTemporaryCoresReserveDifferentPorts() async throws {
        let server = try SilentTCPServer()
        let port = try await server.start()
        defer { server.stop() }
        let (manager, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let node = nodes(count: 1, port: port)[0]
        var shortSettings = settings()
        shortSettings.testTimeoutSeconds = 1
        shortSettings.appProbeDisabledTargetIDs = Set(AppProbeTarget.allCases.filter { $0 != .github }.map(\.id))
        let singleSettings = shortSettings
        let first = Task { await manager.measureAppProbe(for: node, timeout: 1, targets: [.github]) }
        let second = Task { await manager.measureAppProbe(for: node, timeout: 1, targets: [.github]) }
        let third = Task { await manager.testSingle(node: node, settings: singleSettings, includeExitIP: false) }
        let fourth = Task { await manager.testSingle(node: node, settings: singleSettings, includeExitIP: false) }
        let manual = Task { await manager.probeApps(for: node, nodeLabel: "independent-snapshot", settings: singleSettings, timeout: 1) }
        let deadline = Date().addingTimeInterval(3)
        var files: [URL] = []
        repeat {
            files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            if files.count >= 5 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline
        var ports: [Int] = []
        for file in files {
            let config = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
            let inbounds = config?["inbounds"] as? [[String: Any]] ?? []
            ports.append(contentsOf: inbounds.compactMap { $0["port"] as? Int })
        }
        XCTAssertEqual(files.count, 5)
        XCTAssertEqual(ports.count, 5)
        XCTAssertEqual(Set(ports).count, 5)
        _ = await first.value
        _ = await second.value
        _ = await third.value
        _ = await fourth.value
        let completed = await manual.value
        XCTAssertTrue(completed)
        XCTAssertFalse(manager.isTesting)
        XCTAssertEqual(manager.appProbePhase, .done)
        XCTAssertEqual(manager.appProbeNodeID, node.id)
        XCTAssertEqual(manager.appProbeNodeLabel, "independent-snapshot", "后台补测不能覆盖手动应用探测界面")
    }

    func testShutdownWaitsForEachIndependentTestTask() async throws {
        let server = try SilentTCPServer()
        let port = try await server.start()
        defer { server.stop() }
        let (manager, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let targets = nodes(count: 8, port: port)
        let testing = Task {
            await manager.startTest(nodes: targets, settings: settings(timeout: 30), silent: true) { _, _ in }
        }
        let single = Task { await manager.testSingle(node: targets[0], settings: settings(), includeExitIP: false) }
        let probing = Task {
            await manager.probeApps(proxyHost: "127.0.0.1", httpPort: port, socksPort: port,
                                    timeout: 30, nodeLabel: "shutdown", targets: [.github])
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let started = ProcessInfo.processInfo.systemUptime
        await manager.shutdown()
        _ = await testing.value
        let singleResult = await single.value
        let completed = await probing.value
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3)
        XCTAssertFalse(manager.isTesting)
        XCTAssertFalse(manager.isProbingApps)
        XCTAssertFalse(singleResult.success)
        XCTAssertFalse(completed)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertTrue(files.isEmpty, "退出必须等待各临时核心清理配置")
    }

    func testSilentSlowProtocolBatchHonorsBudgetAndRecordsEveryNode() async throws {
        let server = try SilentTCPServer()
        let port = try await server.start()
        defer { server.stop() }
        let (manager, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let targets = nodes(count: 8, port: port, slowProtocol: true)
        var results: [NodeTestResult] = []
        let start = ProcessInfo.processInfo.systemUptime
        let heartbeat = Task { @MainActor () -> (Int, TimeInterval) in
            var ticks = 0
            var previous = ProcessInfo.processInfo.systemUptime
            var maximumGap: TimeInterval = 0
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 20_000_000) } catch { break }
                let now = ProcessInfo.processInfo.systemUptime
                maximumGap = max(maximumGap, now - previous)
                previous = now
                ticks += 1
            }
            return (ticks, maximumGap)
        }
        await manager.startTest(nodes: targets, settings: settings(), silent: true) { _, result in results.append(result) }
        heartbeat.cancel()
        let responsiveness = await heartbeat.value
        XCTAssertGreaterThan(responsiveness.0, 30)
        XCTAssertLessThan(responsiveness.1, 0.5, "批量测试不应阻塞主线程")
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertLessThan(elapsed, 9, "隐藏的 12s/单测超时或整轮重试不应进入批量路径")
        XCTAssertEqual(results.count, targets.count)
        XCTAssertEqual(Set(results.map(\.nodeID)).count, targets.count)
        XCTAssertTrue(results.allSatisfy { $0.failureStage == .http && $0.tcpLatency != nil })
        XCTAssertEqual(manager.phase, .finished)
        XCTAssertEqual(manager.progress, 1)
        XCTAssertTrue(manager.remainingNodeIDs.isEmpty)
        print("BATCH_REGRESSION silent 8 nodes: \(String(format: "%.2f", elapsed))s")
    }

    func testPauseCancelsInFlightAndResumeCompletesWithoutDuplicates() async throws {
        let server = try SilentTCPServer()
        let port = try await server.start()
        defer { server.stop() }
        let (manager, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let targets = nodes(count: 8, port: port)
        var results: [NodeTestResult] = []
        let task = Task { await manager.startTest(nodes: targets, settings: settings(timeout: 30), silent: true) { _, r in results.append(r) } }
        try await Task.sleep(nanoseconds: 650_000_000)
        let start = ProcessInfo.processInfo.systemUptime
        manager.pause()
        _ = await task.value
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
        XCTAssertEqual(manager.phase, .paused)
        XCTAssertFalse(manager.remainingNodeIDs.isEmpty)
        XCTAssertEqual(results.count + manager.remainingNodeIDs.count, targets.count)
        XCTAssertTrue(results.isEmpty, "被取消的探测不能记成不可用")
        await manager.resumeTest(nodesByID: { id in targets.first { $0.id == id } }, settings: settings()) { _, r in results.append(r) }
        XCTAssertEqual(manager.phase, .finished)
        XCTAssertEqual(results.count, targets.count)
        XCTAssertEqual(Set(results.map(\.nodeID)).count, targets.count)
        XCTAssertEqual(manager.testedCount, targets.count)
    }

    func testPausedScheduledTestKeepsOnlyCurrentScopeOnResume() async throws {
        let server = try SilentTCPServer()
        let port = try await server.start()
        defer { server.stop() }
        let (manager, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let targets = nodes(count: 8, port: port)
        var results: [NodeTestResult] = []
        let task = Task {
            await manager.startTest(
                nodes: targets,
                settings: settings(timeout: 30),
                silent: true,
                followsScheduledScope: true
            ) { _, result in results.append(result) }
        }
        try await Task.sleep(nanoseconds: 650_000_000)
        manager.pause()
        _ = await task.value
        XCTAssertEqual(manager.phase, .paused)
        XCTAssertGreaterThan(manager.remainingNodeIDs.count, 1)
        let completed = Set(results.map(\.nodeID))
        let allowed = Set(manager.remainingNodeIDs.prefix(1))
        manager.applyScheduledScope(allowed)
        XCTAssertEqual(Set(manager.remainingNodeIDs), allowed)
        XCTAssertEqual(manager.statusText, "已暂停（剩余 1 个，可继续）")
        await manager.resumeTest(
            nodesByID: { id in targets.first { $0.id == id } },
            settings: settings()
        ) { _, result in results.append(result) }
        XCTAssertEqual(manager.phase, .finished)
        XCTAssertEqual(Set(results.map(\.nodeID)), completed.union(allowed))
        XCTAssertEqual(manager.testedCount, completed.count + allowed.count)
    }

    func testStopDropsPendingNodesAndDoesNotStayPaused() async throws {
        let server = try SilentTCPServer()
        let port = try await server.start()
        defer { server.stop() }
        let (manager, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let targets = nodes(count: 8, port: port)
        var results: [NodeTestResult] = []
        let task = Task { await manager.startTest(nodes: targets, settings: settings(timeout: 30), silent: true) { _, r in results.append(r) } }
        try await Task.sleep(nanoseconds: 650_000_000)
        let start = ProcessInfo.processInfo.systemUptime
        manager.stop()
        _ = await task.value
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
        XCTAssertEqual(manager.phase, .idle)
        XCTAssertFalse(manager.isTesting)
        XCTAssertTrue(manager.remainingNodeIDs.isEmpty)
        XCTAssertTrue(manager.consumeUserStop())
        XCTAssertLessThan(results.count, targets.count)
    }

    func testParentCancellationPreservesPendingNodes() async throws {
        let server = try SilentTCPServer()
        let port = try await server.start()
        defer { server.stop() }
        let (manager, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let targets = nodes(count: 4, port: port)
        let task = Task { await manager.startTest(nodes: targets, settings: settings(timeout: 30), silent: true) { _, _ in } }
        try await Task.sleep(nanoseconds: 400_000_000)
        let start = ProcessInfo.processInfo.systemUptime
        task.cancel()
        _ = await task.value
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
        XCTAssertEqual(manager.phase, .paused)
        XCTAssertEqual(manager.remainingNodeIDs.count, targets.count)
    }

    func testBadConfigIsolationDoesNotLoseValidNodes() async throws {
        let server = try SilentTCPServer()
        let port = try await server.start()
        defer { server.stop() }
        let (manager, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var targets = nodes(count: 4, port: port)
        targets[1].protocolType = .shadowsocks
        targets[1].method = "2022-blake3-aes-128-gcm"
        targets[1].password = "not-a-valid-base64-key"
        var results: [NodeTestResult] = []
        await manager.startTest(nodes: targets, settings: settings(), silent: true) { _, r in results.append(r) }
        XCTAssertEqual(results.count, 4)
        XCTAssertEqual(results.filter(\.isConfigFailure).count, 1)
        XCTAssertEqual(results.filter { $0.failureStage == .http }.count, 3)
        XCTAssertEqual(manager.testedCount, 4)
        XCTAssertTrue(manager.remainingNodeIDs.isEmpty)
    }

    func testLargeQueueRefillsSlotsWithoutWaitingForSlowestNode() async {
        let gauge = SchedulerGauge()
        var completed: [Int] = []
        await BatchProbeScheduler.run(Array(0..<500), concurrency: 8) { index in
            await gauge.enter()
            try? await Task.sleep(nanoseconds: index == 0 ? 250_000_000 : 1_000_000)
            await gauge.leave()
            return index
        } onResult: { completed.append($0) }
        XCTAssertEqual(Set(completed), Set(0..<500))
        XCTAssertEqual(completed.count, 500)
        XCTAssertGreaterThan(completed.firstIndex(of: 0) ?? 0, 8)
        let maximum = await gauge.maximum
        XCTAssertEqual(maximum, 8)
    }

    func testEightyUnreachableNodesAcrossBatchesHonorTotalBudget() async throws {
        // On macOS a bound-but-not-listening port can silently drop SYNs.
        // This covers timeout waves, not only fast ECONNREFUSED responses.
        let reservation = try LocalTestPorts(count: 1)
        defer { reservation.release() }
        let (manager, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let targets = nodes(count: 80, port: reservation.ports[0])
        var results: [NodeTestResult] = []
        let start = ProcessInfo.processInfo.systemUptime
        await manager.startTest(nodes: targets, settings: settings(concurrency: 8), silent: true) { _, r in results.append(r) }
        XCTAssertEqual(results.count, 80)
        XCTAssertEqual(Set(results.map(\.nodeID)).count, 80)
        XCTAssertTrue(results.allSatisfy { $0.failureStage == .tcp })
        XCTAssertEqual(manager.phase, .finished)
        XCTAssertEqual(manager.testedCount, 80)
        XCTAssertTrue(manager.remainingNodeIDs.isEmpty)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        // Ten waves x 1s TCP budget + five core starts/stops + scheduling margin.
        XCTAssertLessThan(elapsed, 15)
        print("BATCH_REGRESSION unreachable 80 nodes: \(String(format: "%.2f", elapsed))s")
    }

    func testConcurrencyOneAndDuplicateNodeIDs() async throws {
        let gauge = SchedulerGauge()
        var completed: [Int] = []
        await BatchProbeScheduler.run(Array(0..<20), concurrency: 1) { index in
            await gauge.enter()
            await Task.yield()
            await gauge.leave()
            return index
        } onResult: { completed.append($0) }
        XCTAssertEqual(completed, Array(0..<20))
        let maximum = await gauge.maximum
        XCTAssertEqual(maximum, 1)
        let (manager, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var targets = nodes(count: 2, port: 1)
        targets[0].uuid = nil
        targets[1].uuid = nil
        var results: [UUID] = []
        await manager.startTest(nodes: targets + targets, settings: settings(), silent: true) { id, _ in results.append(id) }
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(manager.totalCount, 2)
    }

    func testTCPDNSCancellationAndRepeatedLocalConnections() async throws {
        let server = try SilentTCPServer()
        let port = try await server.start()
        defer { server.stop() }
        var results: [Int] = []
        await BatchProbeScheduler.run(Array(0..<100), concurrency: 16) { _ in
            await TCPTester.measure(host: "localhost", port: port, timeout: 1)
        } onResult: { results.append($0) }
        XCTAssertEqual(results.count, 100)
        let start = ProcessInfo.processInfo.systemUptime
        let task = Task { await TCPTester.measure(host: "\(UUID().uuidString).invalid", port: 443, timeout: 30) }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        let invalidPort = await TCPTester.measure(host: "127.0.0.1", port: 65536)
        XCTAssertNil(invalidPort)
        let dnsStart = ProcessInfo.processInfo.systemUptime
        // The network may synthesize DNS answers, so assert the deadline, not
        // NXDOMAIN behavior of the user's external resolver.
        _ = await TCPTester.measure(host: "\(UUID().uuidString).invalid", port: 443, timeout: 0.1)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - dnsStart, 1)
    }

    func testMasqueHTTP3SkipsTCPPreflightAndHonorsTwoSecondBudget() async throws {
        let server = try SilentTCPServer()
        let port = try await server.start()
        defer { server.stop() }
        let node = try NodeLinkParser.parse("masque://user:pass@127.0.0.1:1?alpn=h3")
        XCTAssertTrue(node.usesUDPTransport)
        let started = ProcessInfo.processInfo.systemUptime
        let probe = await NodeProbeEngine.batchProxyProbe(node: node, localPort: port,
            testURL: URL(string: "https://fixture.invalid/"), tcpTimeout: 0.1, httpsTimeout: 2)
        let result = try XCTUnwrap(probe)
        XCTAssertEqual(result.failureStage, .http)
        XCTAssertNil(result.tcpLatency)
        XCTAssertEqual(result.errorMessage, "HTTPS 探测超时（2 秒）")
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertGreaterThanOrEqual(elapsed, 1.5)
        XCTAssertLessThan(elapsed, 4)
        let fallback = await NodeProbeEngine.tcpOnly(node: node, timeout: 0.1)
        XCTAssertFalse(fallback.success)
        XCTAssertEqual(fallback.failureStage, .config)
        var h2 = node
        h2.alpn = "h2"
        XCTAssertFalse(h2.usesUDPTransport)
        h2.alpn = "h2,h3"
        XCTAssertTrue(h2.usesUDPTransport)
    }

    func testProxyResponseWinsWhenDirectTCPProbeFails() async throws {
        let server = try SilentTCPServer(response: Data("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n".utf8))
        let port = try await server.start()
        defer { server.stop() }
        let reservation = try LocalTestPorts(count: 1)
        defer { reservation.release() }
        let node = nodes(count: 1, port: reservation.ports[0])[0]
        let url = URL(string: "http://fixture.invalid/generate_204")
        let probe = await NodeProbeEngine.batchProxyProbe(node: node, localPort: port,
            testURL: url, tcpTimeout: 0.1, httpsTimeout: 1)
        let batch = try XCTUnwrap(probe)
        XCTAssertTrue(batch.success)
        XCTAssertNil(batch.tcpLatency)
        XCTAssertNotNil(batch.proxyLatency)
        XCTAssertNil(batch.failureStage)
        let single = await NodeProbeEngine.quickProxyProbe(node: node, localPort: port, testURL: url, timeout: 1)
        XCTAssertTrue(single.success)
        XCTAssertNil(single.tcpLatency)
        XCTAssertNil(single.failureStage)
    }

    func testOpenTCPAndProxyConnectAloneDoNotProveUsability() async throws {
        let server = try SilentTCPServer(response: Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8))
        let port = try await server.start()
        defer { server.stop() }
        let node = nodes(count: 1, port: port)[0]
        let probe = await NodeProbeEngine.batchProxyProbe(node: node, localPort: port,
            testURL: URL(string: "https://fixture.invalid/"), tcpTimeout: 1, httpsTimeout: 1)
        let result = try XCTUnwrap(probe)
        XCTAssertFalse(result.success)
        XCTAssertNotNil(result.tcpLatency)
        XCTAssertEqual(result.failureStage, .http)
    }
}

@MainActor
final class TestCompletionPresentationTests: XCTestCase {
    func testCombinedSubscriptionsProduceOneSummaryAndBackgroundTestStaysSilent() async throws {
        let manager = NodeTestManager(binaryURL: URL(fileURLWithPath: "/usr/bin/false"))
        let firstID = UUID(), secondID = UUID()
        let nodes = (0..<60).map { index in
            var node = ProxyNode(name: "group-node-\(index)", protocolType: .vless, server: "", port: 443)
            node.subscriptionID = index < 30 ? firstID : secondID
            return node
        }
        var completions = 0
        let observation = manager.$showFinishedAlert.filter { $0 }.sink { _ in completions += 1 }
        defer { observation.cancel() }

        await manager.startTest(nodes: nodes, settings: AppSettings()) { _, _ in }
        XCTAssertEqual(completions, 1)
        let summary = try XCTUnwrap(manager.takeFinishedSummary())
        XCTAssertEqual(summary.totalCount, nodes.count)
        XCTAssertEqual(summary.failedCount, nodes.count)
        XCTAssertEqual(summary.detailLines.count, nodes.count)
        XCTAssertEqual(summary.resultCounts.count, 1)
        XCTAssertEqual(summary.resultCounts.values.first, nodes.count)
        XCTAssertNil(manager.takeFinishedSummary())

        await manager.startTest(nodes: Array(nodes.prefix(2)), settings: AppSettings(), silent: true) { _, _ in }
        XCTAssertEqual(completions, 1)
        XCTAssertNil(manager.takeFinishedSummary())
        let backgroundSummary = try XCTUnwrap(manager.lastFinishedSummary)
        XCTAssertEqual(backgroundSummary.totalCount, 2)
        XCTAssertEqual(backgroundSummary.resultCounts.count, 1)
        XCTAssertEqual(backgroundSummary.resultCounts.values.first, 2)
    }

    func testSummaryShowsRepeatedReasonCountAndEveryCategoryWithoutOmission() {
        let timeout = "不可用（HTTPS 探测超时（2 秒））"
        let handshake = "不可用（HTTPS/TLS 握手失败）"
        let otherCategories = (0..<18).map { "不可用（其他原因 \($0)）" }.sorted()
        var counts = Dictionary(uniqueKeysWithValues: otherCategories.map { ($0, 1) })
        counts[timeout] = 60
        counts[handshake] = 2
        let summary = NodeTestRunSummary(totalCount: 80, availableCount: 0,
                                        unavailableCount: 80, failedCount: 0, durationSeconds: 11,
                                        resultCounts: counts)

        let lines = summary.message.components(separatedBy: "\n")
        XCTAssertEqual(Array(lines.prefix(20)), ["\(timeout)：60 个", "\(handshake)：2 个"]
                       + otherCategories.map { "\($0)：1 个" })
        XCTAssertTrue(lines.contains("可用：0    不可用：80    失败：0"))
        XCTAssertTrue(lines.contains("耗时：11 秒"))
        XCTAssertFalse(summary.message.contains("另有"))
        XCTAssertFalse(summary.message.contains("…"))
    }

    func testCategoriesSeparateFailureTypesAndCombineSpeedTiers() {
        func category(success: Bool = false, configValid: Bool = true,
                      latency: Int? = nil, stage: TestStage? = .http, reason: String? = nil) -> String {
            NodeTestRunSummary.category(for: NodeTestResult(
                nodeID: UUID(), configValid: configValid, proxyLatency: latency,
                success: success, failureStage: stage, errorMessage: reason
            ))
        }

        XCTAssertEqual(category(success: true, latency: 100), "可用（特快）")
        XCTAssertEqual(category(success: true, latency: 450), "可用（特快）")
        XCTAssertEqual(category(success: true, latency: 900), "可用（快）")
        XCTAssertEqual(category(reason: " \nHTTPS 探测超时（2 秒）\n "), "不可用（HTTPS 探测超时（2 秒））")
        XCTAssertEqual(category(stage: .config, reason: "相同原因"), "失败（相同原因）")
        XCTAssertEqual(category(reason: "相同原因"), "不可用（相同原因）")
        XCTAssertEqual(category(configValid: false, reason: "配置无效"), "失败（配置无效）")
        for reason in [nil, "", " \n ", "TCP_PASS"] as [String?] {
            XCTAssertEqual(category(reason: reason), "不可用")
            XCTAssertEqual(category(stage: .config, reason: reason), "失败")
        }
    }

    func testEachCompletionIsConsumedOnlyOnce() {
        let manager = NodeTestManager()
        let summary = NodeTestRunSummary(totalCount: 3, availableCount: 2,
                                         unavailableCount: 1, failedCount: 0, durationSeconds: 5)
        manager.lastFinishedSummary = summary
        manager.showFinishedAlert = true
        XCTAssertEqual(manager.takeFinishedSummary(), summary)
        XCTAssertFalse(manager.showFinishedAlert)
        XCTAssertNil(manager.takeFinishedSummary())
        manager.showFinishedAlert = true
        XCTAssertEqual(manager.takeFinishedSummary(), summary)
        XCTAssertNil(manager.takeFinishedSummary())
    }

    func testBackgroundSummaryDoesNotPresentWithoutCompletionEvent() {
        let manager = NodeTestManager()
        manager.lastFinishedSummary = NodeTestRunSummary(totalCount: 1, availableCount: 1,
                                                         unavailableCount: 0, failedCount: 0, durationSeconds: 1)
        XCTAssertNil(manager.takeFinishedSummary())
    }

    func testFinishedSummarySurfacesXrayInstallGuidance() {
        var summary = NodeTestRunSummary(totalCount: 2, availableCount: 0,
                                         unavailableCount: 0, failedCount: 2, durationSeconds: 3)
        summary.installGuidance = XrayInstaller.missingCoreGuidance
        summary.resultCounts = ["失败（\(XrayInstaller.missingCoreGuidance)）": 2]
        let message = summary.message
        XCTAssertTrue(message.hasPrefix(XrayInstaller.missingCoreGuidance))
        XCTAssertTrue(message.contains("失败：2"))
        XCTAssertFalse(XrayInstaller.missingCoreGuidance.isEmpty)
        XCTAssertTrue(XrayInstaller.missingCoreGuidance.contains("管理更新"))
    }
}

final class NodeTestStatisticTests: XCTestCase {
    private func node(_ status: NodeTestStatus, reason: String? = nil, latency: Int? = nil) -> ProxyNode {
        var node = ProxyNode(name: "统计节点", protocolType: .vless, server: "fixture.invalid", port: 443,
                             lastLatency: latency, lastTestStatus: status)
        node.lastTestErrorMessage = reason
        return node
    }

    func testUnavailableReasonsAggregateAndPreserveEveryFullCategory() {
        let timeout = "HTTPS 探测超时（2 秒）"
        let longReason = "HTTPS/TLS 握手失败\n" + String(repeating: "完整错误原因", count: 25)
        let matching = (0..<60).map { _ in node(.unavailable, reason: timeout) }
            + (0..<18).map { node(.unavailable, reason: "其他原因 \($0)") }
            + [node(.unavailable, reason: " \n\(longReason)\n ")]
        let nodes = matching + [node(.failed, reason: timeout), node(.fast, reason: timeout)]
        let section = NodeTestStatistic.unavailable.sections(for: nodes)[0]

        XCTAssertEqual(section.counts[timeout], 60)
        XCTAssertEqual(section.counts[longReason], 1)
        XCTAssertEqual(section.counts.count, 20)
        XCTAssertEqual(section.counts.values.reduce(0, +), matching.count)
        XCTAssertEqual(section.sortedCounts.first?.key, timeout)
        XCTAssertEqual(section.sortedCounts.count, 20)
        XCTAssertEqual(NodeTestStatistic.unavailable.sections(for: [matching[0]])[0].counts, [timeout: 1])
    }

    func testFailureReasonsRemainSeparateAndMissingReasonsAreExplicit() {
        let missing = [nil, "", " \n ", " TCP_PASS\n"] as [String?]
        let nodes = missing.map { node(.failed, reason: $0) }
            + [node(.failed, reason: "缺少 UUID"), node(.unavailable, reason: "缺少 UUID")]
        let counts = NodeTestStatistic.failed.sections(for: nodes)[0].counts

        XCTAssertEqual(counts, ["原因未记录（重新测速后可查看）": 4, "缺少 UUID": 1])
        XCTAssertEqual(NodeTestStatistic.unavailable.sections(for: nodes)[0].counts, ["缺少 UUID": 1])
        XCTAssertTrue(NodeTestStatistic.failed.sections(for: [node(.fast)])[0].counts.isEmpty)
    }

    func testAvailabilityUsesResolvedSpeedTiersAndIndependentApplicationResults() {
        var connected = node(.ultraFast, latency: 100)
        connected.lastAppProbeOkCount = 1
        connected.lastAppProbeLatency = 50
        var notPassed = node(.fast, latency: 450)
        notPassed.lastAppProbeDate = Date()
        notPassed.lastAppProbeOkCount = 0
        var oldApplicationResult = node(.unavailable)
        oldApplicationResult.lastAppProbeOkCount = 2
        oldApplicationResult.lastAppProbeLatency = 60
        let nodes = [connected, notPassed, node(.ultraFast, latency: 900), node(.failed), oldApplicationResult]
        let sections = NodeTestStatistic.available.sections(for: nodes)

        XCTAssertEqual(sections[0].counts, ["特快": 2, "快": 1])
        XCTAssertEqual(sections[1].counts, ["应用已连通": 2, "应用未通过": 1, "应用未测试": 2])
    }

    func testProgressExcludesInFlightNodesFromCompletionAndLimitsRemainingToScope() {
        let nodes = [node(.fast), node(.unavailable), node(.failed), node(.testing), node(.untested)]
        let sections = NodeTestStatistic.progress.sections(
            for: nodes, remainingNodeIDs: [nodes[3].id, nodes[4].id, UUID()]
        )

        XCTAssertEqual(sections[0].counts["测试中"], 1)
        XCTAssertEqual(sections[0].counts["未测试"], 1)
        XCTAssertEqual(sections[1].counts, ["范围节点": 5, "已完成": 3, "测试中": 1, "未测试": 1, "待继续": 2])
        XCTAssertNil(NodeTestStatistic.progress.sections(for: nodes, remainingNodeIDs: [UUID()])[1].counts["待继续"])
        XCTAssertEqual(NodeTestStatistic.progress.sections(for: [])[1].counts,
                       ["范围节点": 0, "已完成": 0, "测试中": 0, "未测试": 0])
    }

    func testDetailRowsSortByCountThenLabelWithoutTruncation() {
        let section = NodeTestStatisticSection(title: "排序", counts: ["B": 1, "A": 1, "C": 2])
        XCTAssertEqual(section.sortedCounts.map(\.key), ["C", "A", "B"])
        XCTAssertEqual(section.sortedCounts.map(\.value), [2, 1, 1])
    }
}
