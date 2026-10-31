import XCTest
import Darwin

private actor ProxyCommands {
    var calls: [[String]] = []
    var failNextSocks = false
    var services = ["Wi-Fi"]
    func addEthernet() { services.append("Ethernet") }
    func failOnce() { failNextSocks = true }
    func run(_ arguments: [String]) throws -> String {
        calls.append(arguments)
        switch arguments.first {
        case "-listallnetworkservices": return "An asterisk (*) denotes that a network service is disabled.\n" + services.joined(separator: "\n") + "\n"
        case "-getwebproxy", "-getsecurewebproxy", "-getsocksfirewallproxy":
            return "Enabled: Yes\nServer: original.example.com\nPort: 8080\n"
        case "-getautoproxyurl": return "URL: https://example.com/original.pac\nEnabled: Yes\n"
        case "-getproxybypassdomains": return "example.internal\n*.lan\n"
        case "-getproxyautodiscovery": return "Auto Proxy Discovery: On\n"
        case "-setsocksfirewallproxy" where failNextSocks:
            failNextSocks = false
            throw SystemProxyError.commandFailed("fixture failure")
        default: return ""
        }
    }
}

@MainActor
final class ConnectionLifecycleTests: XCTestCase {
    func testReplacementWaitsForCancelledOperationCleanup() async throws {
        let operations = ConnectionOperations()
        var events: [String] = []
        let first = Task {
            try await operations.perform { _ in
                events.append("old-start")
                do { try await Task.sleep(nanoseconds: 10_000_000_000) }
                catch {
                    await Task.detached { try? await Task.sleep(nanoseconds: 80_000_000) }.value
                    events.append("old-cleanup")
                    throw error
                }
            }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        try await operations.perform { _ in events.append("new-start") }
        _ = await first.result
        XCTAssertEqual(events, ["old-start", "old-cleanup", "new-start"])
    }

    func testSupersededQueuedRequestNeverTouchesCore() async throws {
        let operations = ConnectionOperations()
        var events: [String] = []
        let first = Task {
            try await operations.perform { _ in
                events.append("first")
                do { try await Task.sleep(nanoseconds: 10_000_000_000) }
                catch {
                    await Task.detached { try? await Task.sleep(nanoseconds: 100_000_000) }.value
                    events.append("cleanup")
                    throw error
                }
            }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let middle = Task { try await operations.perform { _ in events.append("middle") } }
        try await Task.sleep(nanoseconds: 20_000_000)
        try await operations.perform { _ in events.append("latest") }
        _ = await first.result
        _ = await middle.result
        XCTAssertEqual(events, ["first", "cleanup", "latest"])
        XCTAssertEqual(operations.generation, 3)
    }

    func testCallerCancellationStillCompletesCleanupBeforeDisconnect() async throws {
        let operations = ConnectionOperations()
        var events: [String] = []
        let request = Task {
            try await operations.perform { _ in
                do { try await Task.sleep(nanoseconds: 10_000_000_000) }
                catch { events.append("restore-original"); throw error }
            }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        request.cancel()
        try await operations.perform { _ in events.append("disconnect-finished") }
        _ = await request.result
        XCTAssertEqual(events, ["restore-original", "disconnect-finished"])
    }

    func testPortChangesPreserveOriginalProxyBackupAndRestoreBypassAndWPAD() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("backup.json")
        let commands = ProxyCommands()
        let manager = SystemProxyManager(backupURL: file) { _, args in try await commands.run(args) }
        try await manager.enableSystemProxy(httpHost: "127.0.0.1", httpPort: 10809, socksHost: "127.0.0.1", socksPort: 10808)
        try await manager.enableSystemProxy(httpHost: "127.0.0.1", httpPort: 11809, socksHost: "::1", socksPort: 11808)
        let backup = try JSONDecoder().decode([OriginalProxySettings].self, from: Data(contentsOf: file))
        XCTAssertEqual(backup.first?.httpHost, "original.example.com")
        XCTAssertEqual(backup.first?.bypassDomains, ["example.internal", "*.lan"])
        try await manager.restoreFromBackup()
        let calls = await commands.calls
        XCTAssertEqual(calls.filter { $0.first == "-getwebproxy" }.count, 1)
        XCTAssertTrue(calls.contains(["-setproxybypassdomains", "Wi-Fi", "example.internal", "*.lan"]))
        XCTAssertTrue(calls.contains(["-setproxyautodiscovery", "Wi-Fi", "on"]))
        XCTAssertTrue(calls.contains(["-setwebproxy", "Wi-Fi", "original.example.com", "8080"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testNewNetworkServiceIsBackedUpBeforeModificationAndRestored() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("backup.json")
        let commands = ProxyCommands()
        let manager = SystemProxyManager(backupURL: file) { _, args in try await commands.run(args) }
        try await manager.enableSystemProxy(httpHost: "127.0.0.1", httpPort: 10809, socksHost: "127.0.0.1", socksPort: 10808)
        await commands.addEthernet()
        try await manager.enableSystemProxy(httpHost: "127.0.0.1", httpPort: 10809, socksHost: "127.0.0.1", socksPort: 10808)
        let backups = try JSONDecoder().decode([OriginalProxySettings].self, from: Data(contentsOf: file))
        XCTAssertEqual(Set(backups.map(\.serviceName)), Set(["Wi-Fi", "Ethernet"]))
        try await manager.restoreFromBackup()
        let calls = await commands.calls
        XCTAssertEqual(calls.filter { $0 == ["-getwebproxy", "Wi-Fi"] }.count, 1)
        let read = try XCTUnwrap(calls.firstIndex(of: ["-getwebproxy", "Ethernet"]))
        let write = try XCTUnwrap(calls.firstIndex(of: ["-setwebproxy", "Ethernet", "127.0.0.1", "10809"]))
        XCTAssertLessThan(read, write)
        XCTAssertTrue(calls.contains(["-setwebproxy", "Ethernet", "original.example.com", "8080"]))
        XCTAssertTrue(calls.contains(["-setproxyautodiscovery", "Ethernet", "on"]))
    }

    func testPartialProxySetupFailureRollsBack() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("backup.json")
        let commands = ProxyCommands()
        await commands.failOnce()
        let manager = SystemProxyManager(backupURL: file) { _, args in try await commands.run(args) }
        do {
            try await manager.enableSystemProxy(httpHost: "127.0.0.1", httpPort: 10809, socksHost: "127.0.0.1", socksPort: 10808)
            XCTFail("应报告部分启用失败")
        } catch { }
        let calls = await commands.calls
        XCTAssertTrue(calls.contains(["-setwebproxy", "Wi-Fi", "original.example.com", "8080"]))
        XCTAssertEqual(calls.last, ["-setproxyautodiscovery", "Wi-Fi", "on"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testApplicationModeRejectsExistingThirdPartyProxyWithoutWritingSettings() async throws {
        let commands = ProxyCommands()
        let manager = SystemProxyManager { _, args in try await commands.run(args) }
        do {
            try await manager.requireDirectSystemSettings()
            XCTFail("应拒绝已启用的第三方系统代理")
        } catch is ApplicationProxyError { }
        let calls = await commands.calls
        XCTAssertFalse(calls.contains { $0.first?.hasPrefix("-set") == true })
    }

    func testProbeInboundCannotBeOverriddenByUserRouting() throws {
        let node = ProxyNode(name: "fixture", protocolType: .vless, server: "127.0.0.1", port: 443,
                             uuid: "11111111-1111-4111-8111-111111111111")
        var rules = RoutingRules()
        rules.blocked = "gstatic.com"
        rules.direct = "cloudflare.com"
        for mode in RoutingMode.allCases {
            let config = try XrayConfigBuilder.build(node: node,
                ports: .init(socksHost: "::1", socksPort: 10808, httpHost: "127.0.0.1", httpPort: 10809),
                routingMode: mode, routingRules: rules, probePort: 12000)
            let routing = try XCTUnwrap(config["routing"] as? [String: Any])
            let entries = try XCTUnwrap(routing["rules"] as? [[String: Any]])
            XCTAssertEqual(entries.first?["inboundTag"] as? [String], ["probe-in"])
            XCTAssertEqual(entries.first?["outboundTag"] as? String, mode == .direct ? "direct" : "proxy")
        }
    }

    func testLegacyProxyBackupRemainsReadable() throws {
        let json = #"{"serviceName":"Wi-Fi","httpEnabled":false,"httpsEnabled":false,"socksEnabled":false,"autoProxyEnabled":false}"#
        let backup = try JSONDecoder().decode(OriginalProxySettings.self, from: Data(json.utf8))
        XCTAssertNil(backup.bypassDomains)
        XCTAssertNil(backup.autoDiscoveryEnabled)
    }

    func testStartupIntentKeepsManualDisconnectAcrossRelaunch() throws {
        let legacy = #"{"lastConnectedNodeID":"11111111-1111-4111-8111-111111111111","reconnectOnNextLaunch":false}"#
        let decoded = try JSONDecoder().decode(StartupConnectionIntent.self, from: Data(legacy.utf8))
        XCTAssertFalse(decoded.stayDisconnectedUntilConnect)

        var intent = StartupConnectionIntent(
            lastConnectedNodeID: UUID(),
            reconnectOnNextLaunch: false,
            stayDisconnectedUntilConnect: true
        )
        let data = try JSONEncoder().encode(intent)
        intent = try JSONDecoder().decode(StartupConnectionIntent.self, from: data)
        XCTAssertTrue(intent.stayDisconnectedUntilConnect)
        XCTAssertFalse(intent.reconnectOnNextLaunch)
    }

    func testLegacyStartupRecoveryLoadsLastNodeInsteadOfResettingIntent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let legacy = #"{"lastConnectedNodeID":"11111111-1111-4111-8111-111111111111","reconnectOnNextLaunch":true}"#
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("startup-connection.json"))

        let restored = PersistenceStore(directory: directory).loadStartupConnectionIntent()
        XCTAssertEqual(restored.lastConnectedNodeID, id)
        XCTAssertTrue(restored.reconnectOnNextLaunch)
        XCTAssertFalse(restored.stayDisconnectedUntilConnect)
        XCTAssertEqual(try JSONDecoder().decode(StartupConnectionIntent.self, from: Data("{}".utf8)),
                       StartupConnectionIntent())
    }

    func testPersistenceFlushCommitsLatestIntentBeforeRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistenceStore(directory: directory)
        let id = UUID()
        let connected = StartupConnectionIntent(lastConnectedNodeID: id, reconnectOnNextLaunch: true)
        let stopped = StartupConnectionIntent(lastConnectedNodeID: id, reconnectOnNextLaunch: false,
                                             stayDisconnectedUntilConnect: true)
        store.saveStartupConnectionIntent(connected)
        store.saveStartupConnectionIntent(stopped)
        store.saveConnectionState(ConnectionState())
        await store.flush()

        XCTAssertEqual(PersistenceStore(directory: directory).loadStartupConnectionIntent(), stopped)
        for _ in 0..<3 {
            let nextLaunch = PersistenceStore(directory: directory)
            nextLaunch.saveStartupConnectionIntent(connected)
            nextLaunch.saveConnectionState(ConnectionState()) // Quit cleanup resets live state only.
            await nextLaunch.flush()
            XCTAssertEqual(PersistenceStore(directory: directory).loadStartupConnectionIntent(), connected)
        }
    }

    func testLogFlushPersistsLatestEntriesBeforeDebounce() async throws {
        let file = try temporaryLogFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let logger = AppLogger(logFileURL: file)
        logger.info("开始退出断开", category: .network)
        logger.info("退出断开已完成", category: .network)

        await logger.flush()
        XCTAssertEqual(try readLogs(at: file).map(\.message), ["开始退出断开", "退出断开已完成"])
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(AppLogger(logFileURL: file).entries.map(\.message), ["开始退出断开", "退出断开已完成"])
    }

    func testOverlappingLogFlushCannotRestoreEntriesAfterClear() async throws {
        let file = try temporaryLogFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let saved = (0..<128).map { index in
            LogEntry(level: .info, category: .network, message: "\(index):" + String(repeating: "旧日志", count: 2048))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(saved).write(to: file, options: .atomic)
        let logger = AppLogger(logFileURL: file)
        let earlierFlush = Task { await logger.flush() }
        await Task.yield()

        logger.clear()
        await logger.flush()
        await earlierFlush.value

        XCTAssertTrue(try readLogs(at: file).isEmpty)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(try readLogs(at: file).isEmpty)
    }

    func testLoggingAfterFlushStillPersistsAutomatically() async throws {
        let file = try temporaryLogFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let logger = AppLogger(logFileURL: file)
        logger.info("已刷新")
        await logger.flush()

        logger.info("后续日志")
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(try readLogs(at: file).map(\.message), ["已刷新", "后续日志"])
    }

    func testProblemLogsAreFilteredBeforeRecentLimit() throws {
        let file = try temporaryLogFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let warning = LogEntry(level: .warning, category: .network, message: "网络复验失败")
        let error = LogEntry(level: .error, category: .systemProxy, message: "代理清理失败")
        let routine = (0..<120).map { LogEntry(level: .info, category: .network, message: "普通进度 \($0)") }
        try writeLogs([warning, error] + routine, to: file)
        let logger = AppLogger(logFileURL: file)

        XCTAssertEqual(logger.recentEntries(problemsOnly: true).map(\.id), [error.id, warning.id])
        XCTAssertEqual(logger.recentEntries(problemsOnly: false).count, 100)
        XCTAssertEqual(logger.recentEntries(problemsOnly: true, limit: 1).map(\.id), [error.id])
        XCTAssertTrue(logger.recentEntries(problemsOnly: true, limit: -1).isEmpty)
        XCTAssertTrue(logger.exportText(logger.recentEntries(problemsOnly: true)).contains("代理清理失败"))
        XCTAssertFalse(logger.exportText(logger.recentEntries(problemsOnly: true)).contains("普通进度"))
    }

    func testLoadedProblemsStayHistoricalRegardlessOfTheirTimestamps() throws {
        let file = try temporaryLogFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let warning = LogEntry(date: Date().addingTimeInterval(-86_400), level: .warning,
                               category: .network, message: "上次启动的警告")
        let futureError = LogEntry(date: Date().addingTimeInterval(31_536_000), level: .error,
                                   category: .network, message: "时钟异常时保存的错误")
        try writeLogs([warning, futureError], to: file)
        let logger = AppLogger(logFileURL: file)

        XCTAssertTrue(logger.hasHistoricalEntries)
        XCTAssertFalse(logger.hasCurrentSessionProblems)
        XCTAssertTrue(logger.recentEntries(problemsOnly: true, includeHistory: false).isEmpty)
        XCTAssertEqual(logger.recentEntries(problemsOnly: true).map(\.id), [futureError.id, warning.id])

        logger.minimumLevel = .debug
        logger.info("本次启动成功")
        logger.debug("正常调试进度")

        XCTAssertFalse(logger.hasCurrentSessionProblems)
        XCTAssertTrue(logger.recentEntries(problemsOnly: true, includeHistory: false).isEmpty)
        logger.warning("本次启动的新警告")
        XCTAssertTrue(logger.hasCurrentSessionProblems)
        logger.error("本次启动的新错误")
        XCTAssertEqual(logger.recentEntries(problemsOnly: true, includeHistory: false).map(\.message),
                       ["本次启动的新错误", "本次启动的新警告"])
    }

    func testCurrentSessionProblemScopeFiltersBeforeLimitAndCopy() throws {
        let file = try temporaryLogFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let historical = LogEntry(level: .error, category: .network, message: "历史错误")
        try writeLogs([historical], to: file)
        let logger = AppLogger(logFileURL: file)
        logger.warning("本次警告")
        logger.error("本次错误")
        for index in 0..<120 { logger.info("正常进度 \(index)") }

        let currentProblems = logger.recentEntries(problemsOnly: true, includeHistory: false)
        XCTAssertEqual(currentProblems.map(\.message), ["本次错误", "本次警告"])
        XCTAssertEqual(logger.recentEntries(problemsOnly: true, includeHistory: false, limit: 1).map(\.message),
                       ["本次错误"])
        XCTAssertTrue(logger.recentEntries(problemsOnly: true, includeHistory: false, limit: 0).isEmpty)
        XCTAssertTrue(logger.recentEntries(problemsOnly: true, includeHistory: false, limit: -1).isEmpty)
        XCTAssertEqual(logger.recentEntries(problemsOnly: false, includeHistory: false, limit: 3).map(\.message),
                       ["正常进度 119", "正常进度 118", "正常进度 117"])
        XCTAssertEqual(logger.recentEntries(problemsOnly: true, includeHistory: true).map(\.message),
                       ["本次错误", "本次警告", "历史错误"])
        let copied = logger.exportText(currentProblems)
        XCTAssertTrue(copied.contains("本次错误"))
        XCTAssertTrue(copied.contains("本次警告"))
        XCTAssertFalse(copied.contains("历史错误"))
        XCTAssertFalse(copied.contains("正常进度"))
    }

    func testRelaunchMakesSavedProblemsHistoricalAndClearResetsAvailability() async throws {
        let file = try temporaryLogFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let firstLaunch = AppLogger(logFileURL: file)
        XCTAssertFalse(firstLaunch.hasHistoricalEntries)
        XCTAssertFalse(firstLaunch.hasCurrentSessionProblems)
        firstLaunch.error("退出前的错误")
        XCTAssertTrue(firstLaunch.hasCurrentSessionProblems)
        await firstLaunch.flush()

        let nextLaunch = AppLogger(logFileURL: file)
        XCTAssertTrue(nextLaunch.hasHistoricalEntries)
        XCTAssertFalse(nextLaunch.hasCurrentSessionProblems)
        XCTAssertTrue(nextLaunch.recentEntries(problemsOnly: true, includeHistory: false).isEmpty)
        nextLaunch.info("重新启动成功")
        XCTAssertFalse(nextLaunch.hasCurrentSessionProblems)
        nextLaunch.error("重新启动后的新错误")
        XCTAssertTrue(nextLaunch.hasCurrentSessionProblems)

        nextLaunch.clear()
        XCTAssertFalse(nextLaunch.hasHistoricalEntries)
        XCTAssertFalse(nextLaunch.hasCurrentSessionProblems)
        XCTAssertTrue(nextLaunch.recentEntries(problemsOnly: false).isEmpty)
        await nextLaunch.flush()
        let emptyLaunch = AppLogger(logFileURL: file)
        XCTAssertFalse(emptyLaunch.hasHistoricalEntries)
        XCTAssertFalse(emptyLaunch.hasCurrentSessionProblems)
        XCTAssertTrue(emptyLaunch.entries.isEmpty)
    }

    func testRoutineLogsDoNotEvictProblemsAtCapacity() async throws {
        let file = try temporaryLogFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let warning = LogEntry(level: .warning, category: .network, message: "应保留的警告")
        let error = LogEntry(level: .error, category: .network, message: "应保留的错误")
        let routine = (0..<1998).map { LogEntry(level: .info, category: .network, message: "普通进度 \($0)") }
        try writeLogs([warning, error] + routine, to: file)
        let logger = AppLogger(logFileURL: file)

        logger.info("新的普通进度")

        XCTAssertEqual(logger.entries.count, 2000)
        XCTAssertEqual(logger.recentEntries(problemsOnly: true).map(\.id), [error.id, warning.id])
        XCTAssertFalse(logger.entries.contains { $0.id == routine[0].id })
        await logger.flush()
        XCTAssertEqual(AppLogger(logFileURL: file).recentEntries(problemsOnly: true).map(\.id), [error.id, warning.id])
    }

    func testProblemLogBufferRemainsBounded() async throws {
        let file = try temporaryLogFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let problems = (0..<2000).map { LogEntry(level: .warning, category: .test, message: "失败 \($0)") }
        try writeLogs(problems, to: file)
        let logger = AppLogger(logFileURL: file)

        logger.error("新的失败")
        XCTAssertEqual(logger.entries.count, 2000)
        XCTAssertEqual(logger.entries.first?.id, problems[1].id)
        logger.info("已断开连接；原因：用户手动断开")

        XCTAssertEqual(logger.entries.count, 2000)
        XCTAssertEqual(logger.entries.first?.id, problems[2].id)
        XCTAssertEqual(logger.entries.last?.message, "已断开连接；原因：用户手动断开")
        XCTAssertTrue(logger.recentEntries(problemsOnly: true).contains { $0.message == "新的失败" })
        await logger.flush()
        XCTAssertEqual(AppLogger(logFileURL: file).entries.last?.message, "已断开连接；原因：用户手动断开")
    }

    func testTunStopSignalRequiresManualRecoveryAndKeepsDetails() throws {
        let status = TunSessionStatus(state: "stopped", message: "TUN 收到 SIGTERM", stopReason: .systemSignal, signal: SIGTERM)
        let restored = try JSONDecoder().decode(TunSessionStatus.self, from: JSONEncoder().encode(status))
        XCTAssertFalse(restored.allowsAutomaticRecovery)
        XCTAssertEqual(restored.stopReason, .systemSignal)
        XCTAssertEqual(restored.signal, SIGTERM)
        XCTAssertFalse(TunSessionStatus(state: "stopped", message: "会话停止", stopReason: .requested).allowsAutomaticRecovery)

        let legacy = Data(#"{"state":"stopped","message":"TUN 收到停止信号","updatedAt":0}"#.utf8)
        let oldStatus = try JSONDecoder().decode(TunSessionStatus.self, from: legacy)
        XCTAssertNil(oldStatus.stopReason)
        XCTAssertFalse(oldStatus.allowsAutomaticRecovery)
    }

    func testTunSignalSenderMetadataIsCompatibleAndKeepsRecoveryPaused() throws {
        let status = TunSessionStatus(state: "stopped", message: "TUN 收到 SIGTERM", stopReason: .systemSignal,
                                      signal: SIGTERM, signalSenderPID: 12345, signalSenderUID: 0,
                                      signalSenderName: "osascript")
        let restored = try JSONDecoder().decode(TunSessionStatus.self, from: JSONEncoder().encode(status))
        XCTAssertEqual(restored.signal, SIGTERM)
        XCTAssertEqual(restored.signalSenderPID, 12345)
        XCTAssertEqual(restored.signalSenderUID, 0)
        XCTAssertEqual(restored.signalSenderName, "osascript")
        XCTAssertFalse(restored.allowsAutomaticRecovery)

        let legacy = Data(#"{"state":"stopped","message":"TUN 收到 SIGTERM","updatedAt":0,"stopReason":"systemSignal","signal":15}"#.utf8)
        let legacyStatus = try JSONDecoder().decode(TunSessionStatus.self, from: legacy)
        XCTAssertEqual(legacyStatus.signal, SIGTERM)
        XCTAssertNil(legacyStatus.signalSenderPID)
        XCTAssertNil(legacyStatus.signalSenderUID)
        XCTAssertNil(legacyStatus.signalSenderName)
        XCTAssertFalse(legacyStatus.allowsAutomaticRecovery)
    }

    func testTunCoreFailureAndLeaseExpiryStillAllowRecovery() {
        XCTAssertTrue(TunSessionStatus(state: "failed", message: "核心异常退出").allowsAutomaticRecovery)
        XCTAssertTrue(TunSessionStatus(state: "stopped", message: "心跳租约失效", stopReason: .leaseExpired).allowsAutomaticRecovery)
        XCTAssertTrue(TunSessionStatus(state: "stopped", message: "TUN 心跳租约失效，已停止核心").allowsAutomaticRecovery)
    }

    func testHistoricalGroupedFailureDisplayAndCopyAreCompact() async throws {
        let file = try temporaryLogFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let summary = "节点测试失败 · 配置检查：REALITY 缺少 publicKey · 48 个节点"
        let names = (1...48).map { "未知 VLESS-\($0) | free-nodes" }.joined(separator: "、")
        let entry = LogEntry(level: .warning, category: .test, message: summary + "：" + names)
        try writeLogs([entry], to: file)

        let logger = AppLogger(logFileURL: file)
        let loaded = try XCTUnwrap(logger.entries.first)
        XCTAssertEqual(loaded.displayMessage, summary)
        XCTAssertEqual(loaded.id, entry.id)
        XCTAssertEqual(loaded.message, entry.message)
        XCTAssertTrue(logger.exportText().hasSuffix(summary))
        XCTAssertFalse(logger.exportText().contains("未知 VLESS"))
        XCTAssertFalse(logger.exportText().contains("free-nodes"))
        await logger.flush()
        XCTAssertEqual(try readLogs(at: file).first?.message, entry.message)
        XCTAssertEqual(AppLogger(logFileURL: file).entries.first?.displayMessage, summary)
    }

    func testCompactLogDisplayOnlyRemovesGroupedTestNodeLists() {
        let summary = "节点测试失败 · 配置检查：gRPC 缺少 serviceName · 4 个节点"
        for separator in ["：", ":"] {
            XCTAssertEqual(LogEntry(level: .warning, category: .test, message: summary + separator + "节点一、节点二；另有 2 个节点").displayMessage, summary)
        }
        XCTAssertEqual(LogEntry(level: .warning, category: .test, message: summary).displayMessage, summary)
        let networkMessage = summary + "：保留网络错误详情"
        XCTAssertEqual(LogEntry(level: .error, category: .network, message: networkMessage).displayMessage, networkMessage)
        let ordinaryTest = "应用探测失败：请检查网络"
        XCTAssertEqual(LogEntry(level: .warning, category: .test, message: ordinaryTest).displayMessage, ordinaryTest)
    }

    private func writeLogs(_ entries: [LogEntry], to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: file, options: .atomic)
    }

    private func temporaryLogFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("app-logs.json")
    }

    private func readLogs(at file: URL) throws -> [LogEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([LogEntry].self, from: Data(contentsOf: file))
    }
}
