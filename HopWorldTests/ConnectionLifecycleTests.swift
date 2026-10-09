import XCTest

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
}
