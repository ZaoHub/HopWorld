import XCTest
import Network
import Darwin

private final class TunHTTPFixture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "tun-http-fixture")
    private let listener: NWListener
    private var connections: [NWConnection] = []
    let port: Int
    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { $0.cancel() }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success, let port = listener.port else {
            listener.cancel()
            throw ApplicationProxyError.failed("本地 HTTP 测试服务未就绪")
        }
        self.port = Int(port.rawValue)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                let body = "hopworld-selected-app"
                let reply = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
    func stop() { queue.sync { listener.cancel(); connections.forEach { $0.cancel() } } }
}

/// Opt-in smoke test. It routes ONLY one documentation-only IP /32, never the
/// default route or DNS. Requires the normal macOS administrator consent UI.
@MainActor
final class ApplicationProxyPrivilegedTests: XCTestCase {
    func testRealTUNMatchesSelectedProcessAndRestoresRoute() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["HOPWORLD_PRIVILEGED_TUN_TEST"] == "1",
              let core = env["HOPWORLD_TEST_SING_BOX"], let helper = env["HOPWORLD_TEST_TUN_SUPERVISOR"] else {
            throw XCTSkip("真实 TUN 测试需要显式设置 HOPWORLD_PRIVILEGED_TUN_TEST=1 并批准系统管理员弹窗")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let xrayBinary = root.appendingPathComponent("HopWorld/Resources/xray")
        let server = try TunHTTPFixture()
        defer { server.stop() }
        let session = FileManager.default.temporaryDirectory.appendingPathComponent("tun-live-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let leaseURL = session.appendingPathComponent("lease")
        let statusURL = session.appendingPathComponent("status")
        for file in [leaseURL, statusURL] {
            XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data("fixture".utf8), attributes: [.posixPermissions: 0o600]))
        }
        let lease = try FileHandle(forUpdating: leaseURL)
        let heartbeat = Task {
            while !Task.isCancelled {
                var pulse = DispatchTime.now().uptimeNanoseconds
                _ = withUnsafeBytes(of: &pulse) { pwrite(lease.fileDescriptor, $0.baseAddress, $0.count, 0) }
                do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            }
        }
        let xray = XrayProcessManager(binaryURL: xrayBinary)
        var caught: Error?
        let before = try await route()
        do {
            let ports = try LocalTestPorts(count: 3)
            let appPort = ports.ports[2]
            let node = ProxyNode(name: "fixture", protocolType: .vless, server: "127.0.0.1", port: 443,
                                 uuid: "11111111-1111-4111-8111-111111111111")
            var xrayConfig = try XrayConfigBuilder.build(node: node,
                ports: .init(socksHost: "127.0.0.1", socksPort: ports.ports[0], httpHost: "127.0.0.1", httpPort: ports.ports[1]),
                routingMode: .global, applicationProxy: (appPort, "fixture-password"))
            xrayConfig["inbounds"] = (xrayConfig["inbounds"] as? [[String: Any]])?.filter { $0["tag"] as? String != "api" }
            xrayConfig.removeValue(forKey: "api")
            xrayConfig["outbounds"] = [["tag": "proxy", "protocol": "freedom",
                "settings": ["redirect": "127.0.0.1:\(server.port)"]]] as [[String: Any]]
            let xrayFile = session.appendingPathComponent("xray.json")
            try XrayConfigBuilder.writeJSON(xrayConfig, to: xrayFile)
            ports.release()
            try await xray.start(configURL: xrayFile)

            let application = try ProxyApplication(url: URL(fileURLWithPath: "/usr/bin/curl"))
            var config = try ApplicationProxyConfig.build(applications: [application], socksPort: appPort,
                password: "fixture-password", bypassExecutables: [xrayBinary.resolvingSymlinksInPath().path])
            var inbounds = config["inbounds"] as! [[String: Any]]
            inbounds[0]["address"] = ["172.31.255.1/30"]
            inbounds[0]["route_address"] = ["203.0.113.7/32"]
            config["inbounds"] = inbounds
            let configFile = session.appendingPathComponent("tun.json")
            try XrayConfigBuilder.writeJSON(config, to: configFile)
            let script = try TunAuthorizationCommand.make(binary: URL(fileURLWithPath: core),
                supervisor: URL(fileURLWithPath: helper), config: configFile, lease: leaseURL, status: statusURL, uid: getuid())
            let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/osascript"),
                                                    arguments: ["-e", script], timeout: 120)
            if let data = try? Data(contentsOf: statusURL),
               let state = try? JSONDecoder().decode(TunSessionStatus.self, from: data),
               ["failed", "stopped"].contains(state.state) {
                throw ApplicationProxyError.failed(state.message)
            }
            guard result.status == 0, !result.timedOut else {
                throw ApplicationProxyError.failed("管理员授权未完成（超时=\(result.timedOut)，退出码=\(result.status)）：" + String(decoding: result.output, as: UTF8.self))
            }
            var running = false
            for _ in 0..<200 {
                if let data = try? Data(contentsOf: statusURL), let state = try? JSONDecoder().decode(TunSessionStatus.self, from: data) {
                    if state.state == "running" { running = true; break }
                    if state.state == "failed" { throw ApplicationProxyError.failed(state.message) }
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard running else { throw ApplicationProxyError.failed("测试 TUN 未启动") }
            let during = try await route()
            XCTAssertTrue(during.contains("utun"), during)
            let selected = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/curl"),
                arguments: ["--noproxy", "*", "-sS", "--max-time", "4", "http://203.0.113.7/"], timeout: 5)
            XCTAssertEqual(selected.status, 0, String(decoding: selected.output, as: UTF8.self))
            XCTAssertEqual(String(decoding: selected.output, as: UTF8.self), "hopworld-selected-app")
            // Same binary under a DIFFERENT path must not match the whitelist.
            let unselectedBinary = session.appendingPathComponent("unselected-curl")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/curl"), to: unselectedBinary)
            let unselected = try await ProcessRunner.run(executable: unselectedBinary,
                arguments: ["--noproxy", "*", "-sS", "--max-time", "1", "http://203.0.113.7/"], timeout: 2)
            XCTAssertNotEqual(unselected.status, 0)
            XCTAssertFalse(String(decoding: unselected.output, as: UTF8.self).contains("hopworld-selected-app"))
        } catch { caught = error }
        heartbeat.cancel()
        try? FileManager.default.removeItem(at: leaseURL)
        try? lease.close()
        var ended = false
        for _ in 0..<70 {
            if let data = try? Data(contentsOf: statusURL), let state = try? JSONDecoder().decode(TunSessionStatus.self, from: data),
               state.state == "stopped" || state.state == "failed" { ended = true; break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        await xray.stop()
        server.stop()
        let after = try await route()
        XCTAssertEqual(after, before, "测试结束后目的路由应恢复")
        if caught == nil { XCTAssertTrue(ended, "监护程序应确认停止") }
        if ended || caught != nil { try? FileManager.default.removeItem(at: session) }
        if let caught { throw caught }
    }

    private func route() async throws -> String {
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/sbin/route"),
                                                arguments: ["-n", "get", "203.0.113.7"], timeout: 3)
        return String(decoding: result.output, as: UTF8.self).components(separatedBy: .newlines)
            .filter { $0.contains("interface:") || $0.contains("gateway:") }.joined(separator: "\n")
    }
}
