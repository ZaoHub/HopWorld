import XCTest

enum CoreValidationFixture {
    static func copyXray(to directory: URL) throws -> URL? {
        let root = ProcessInfo.processInfo.environment["HOPWORLD_TEST_XRAY"]
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("HopWorld/Resources")
        guard FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("xray").path) else { return nil }
        // Child cores cannot read Documents-protected assets under macOS TCC.
        for name in ["xray", "geoip.dat", "geosite.dat"] {
            let bundled = Bundle(for: ConnectionReliabilityTests.self).resourceURL?.appendingPathComponent(name)
            let source = bundled.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
                ?? root.appendingPathComponent(name)
            try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(name))
        }
        return directory.appendingPathComponent("xray")
    }
}

final class ConnectionReliabilityTests: XCTestCase {
    func testXrayAcceptsOmittedAndEmptyGRPCServiceNames() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        guard let binary = try CoreValidationFixture.copyXray(to: directory) else { throw XCTSkip("本地未提供 Xray") }
        for serviceName in [nil, "", "custom-service"] as [String?] {
            let node = ProxyNode(name: "gRPC", protocolType: .vless, server: "127.0.0.1", port: 443,
                                 uuid: "11111111-1111-4111-8111-111111111111",
                                 transport: .grpc, security: .tls, serviceName: serviceName)
            XCTAssertTrue(NodeConfigChecker.validate(node).0)
            let config = try XrayConfigBuilder.buildTestConfig(nodes: [(node, 29001)])
            let outbounds = try XCTUnwrap(config["outbounds"] as? [[String: Any]])
            let outbound = try XCTUnwrap(outbounds.first { $0["tag"] as? String == "proxy-0" })
            let stream = try XCTUnwrap(outbound["streamSettings"] as? [String: Any])
            let grpc = try XCTUnwrap(stream["grpcSettings"] as? [String: Any])
            XCTAssertEqual(grpc["serviceName"] as? String, serviceName)
            let file = directory.appendingPathComponent("grpc.json")
            try XrayConfigBuilder.writeJSON(config, to: file)
            let valid = try await XrayValidator.validateConfigFile(at: file, xrayURL: binary)
            XCTAssertTrue(valid, "Xray rejected serviceName: \(serviceName ?? "nil")")
        }
    }

    func testOutputLargerThanPipeCapacityDoesNotBlockAndKeepsBoundedTail() async throws {
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/awk"),
            arguments: ["BEGIN { for (i = 0; i < 100000; i++) print \"0123456789abcdefghijklmnopqrstuvwxyz\"; print \"FINISHED\" }"],
            timeout: 5, outputLimit: 1024
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertLessThanOrEqual(result.output.count, 1024)
        XCTAssertTrue(String(decoding: result.output, as: UTF8.self).hasSuffix("FINISHED\n"))
    }

    func testProbeTimeoutStopsChild() async throws {
        let start = ProcessInfo.processInfo.systemUptime
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.1)
        XCTAssertTrue(result.timedOut)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
    }

    func testCancellationDoesNotWaitForProbeTimeout() async throws {
        let start = ProcessInfo.processInfo.systemUptime
        let task = Task {
            try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 15)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            let result = try await task.value
            XCTAssertTrue(result.cancelled)
            XCTAssertFalse(result.timedOut)
        } catch is CancellationError { }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
    }

    func testAllModesAndProtocolsHaveBoundedBuffersAndIndependentNodeDNS() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        guard let binary = try CoreValidationFixture.copyXray(to: directory) else { throw XCTSkip("本地未提供 Xray") }
        let ports = XrayConfigBuilder.LocalPorts(socksHost: "127.0.0.1", socksPort: 10808, httpHost: "127.0.0.1", httpPort: 10809)
        for mode in RoutingMode.allCases {
            for proto in [ProxyProtocolType.vless, .vmess, .trojan, .shadowsocks] {
                var node = ProxyNode(name: "Reliability fixture", protocolType: proto, server: "node.example.com", port: 443)
                node.uuid = "11111111-1111-4111-8111-111111111111"
                node.password = "test-only-password"
                node.method = "aes-128-gcm"
                node.security = .tls
                let config = try XrayConfigBuilder.build(node: node, ports: ports, routingMode: mode, probePort: 12000)
                let policy = try XCTUnwrap(config["policy"] as? [String: Any])
                let levels = try XCTUnwrap(policy["levels"] as? [String: [String: Int]])
                XCTAssertEqual(levels["0"]?["bufferSize"], 512)
                let dns = try XCTUnwrap(config["dns"] as? [String: Any])
                let servers = try XCTUnwrap(dns["servers"] as? [Any])
                let bootstrap = try XCTUnwrap(servers.first as? [String: Any])
                XCTAssertEqual(bootstrap["address"] as? String, "localhost")
                XCTAssertEqual(bootstrap["domains"] as? [String], ["full:node.example.com"])
                XCTAssertEqual(bootstrap["finalQuery"] as? Bool, true)
                let file = directory.appendingPathComponent("\(mode)-\(proto).json")
                try XrayConfigBuilder.writeJSON(config, to: file)
                let valid = try await XrayValidator.validateConfigFile(at: file, xrayURL: binary)
                if !valid {
                    var environment = ProcessInfo.processInfo.environment
                    environment["XRAY_LOCATION_ASSET"] = directory.path
                    let diagnostic = try await ProcessRunner.run(executable: binary,
                        arguments: ["run", "-test", "-config", file.path], timeout: 5, environment: environment)
                    XCTFail("\(mode) / \(proto): " + String(decoding: diagnostic.output, as: UTF8.self))
                }
            }
        }
    }
}
