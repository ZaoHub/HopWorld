import XCTest
import Network

private final class SilentTCPServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.silent-tcp")
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private var completed = false // Accessed only on queue.
    init() throws { listener = try NWListener(using: .tcp, on: .any) }

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
}
