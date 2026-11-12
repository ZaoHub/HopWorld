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

    func testLanForwardIsASeparateListener() async throws {
        let node = ProxyNode(name: "LAN", protocolType: .shadowsocks, server: "node.example.com", port: 443,
                             password: "test-only-password", method: "aes-128-gcm")
        let config = try XrayConfigBuilder.buildLanForward(node: node, httpPort: 17_890, socksPort: 17_891)
        let inbounds = try XCTUnwrap(config["inbounds"] as? [[String: Any]])
        XCTAssertEqual(inbounds.map { $0["listen"] as? String }, ["0.0.0.0", "0.0.0.0"])
        XCTAssertEqual(Set(inbounds.compactMap { $0["port"] as? Int }), [17_890, 17_891])
        XCTAssertNil(config["api"])
        XCTAssertFalse(inbounds.contains { $0["port"] as? Int == XrayConfigBuilder.apiPort })
        let rules = try XCTUnwrap((config["routing"] as? [String: Any])?["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.first?["outboundTag"] as? String, "direct")
        XCTAssertEqual(rules.last?["outboundTag"] as? String, "proxy")
        let dns = try XCTUnwrap(config["dns"] as? [String: Any])
        let bootstrap = try XCTUnwrap((dns["servers"] as? [Any])?.first as? [String: Any])
        XCTAssertEqual(bootstrap["domains"] as? [String], ["full:node.example.com"])
        XCTAssertEqual(LanAddresses.usable([
            LanInterface(address: "127.0.0.1", isUp: true, isLoopback: true),
            LanInterface(address: "192.168.1.8", isUp: true, isLoopback: false),
            LanInterface(address: "169.254.1.1", isUp: true, isLoopback: false),
            LanInterface(address: "10.0.0.4", isUp: false, isLoopback: false),
            LanInterface(address: "192.168.1.8", isUp: true, isLoopback: false)
        ]), ["192.168.1.8"])

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        guard let binary = try CoreValidationFixture.copyXray(to: directory) else { return }
        let file = directory.appendingPathComponent("lan.json")
        try XrayConfigBuilder.writeJSON(config, to: file)
        var environment = ProcessInfo.processInfo.environment
        environment["XRAY_LOCATION_ASSET"] = directory.path
        let result = try await ProcessRunner.run(executable: binary,
            arguments: ["run", "-test", "-config", file.path], timeout: 15, environment: environment)
        XCTAssertEqual(result.status, 0, String(decoding: result.output, as: UTF8.self))
    }

    func testSoftwareRouteProbeFollowsTheSelectedTargets() {
        let google = [AppProbeTarget.google]
        let both = [AppProbeTarget.google, AppProbeTarget.tiktok]
        XCTAssertTrue(SoftwareRouteProbe.passes([AppProbeTarget.google.id], targets: google))
        XCTAssertFalse(SoftwareRouteProbe.passes([AppProbeTarget.tiktok.id], targets: google))
        XCTAssertTrue(SoftwareRouteProbe.passes([AppProbeTarget.youtube.id], targets: [AppProbeTarget.youtube]))
        XCTAssertFalse(SoftwareRouteProbe.passes([AppProbeTarget.chatgpt.id], targets: both))
        let googleOnly = SoftwareRouteProbe.Rank(passedIDs: [AppProbeTarget.google.id], latencyMs: 800)
        let tiktokFaster = SoftwareRouteProbe.Rank(passedIDs: [AppProbeTarget.tiktok.id], latencyMs: 100)
        XCTAssertTrue(SoftwareRouteProbe.rank(googleOnly, before: tiktokFaster, order: both))
        XCTAssertFalse(SoftwareRouteProbe.rank(tiktokFaster, before: googleOnly, order: both))
        let googleSlower = SoftwareRouteProbe.Rank(passedIDs: [AppProbeTarget.google.id], latencyMs: 900)
        XCTAssertTrue(SoftwareRouteProbe.rank(googleOnly, before: googleSlower, order: both))
        let youtube = AppProbeTarget.application(path: "https://www.youtube.com/generate_204", name: "优兔", url: URL(string: "https://www.youtube.com/generate_204"))
        let googleURL = AppProbeTarget.application(path: "https://www.google.com/generate_204", name: "谷歌", url: URL(string: "https://www.google.com/generate_204"))
        XCTAssertEqual(SoftwareRouteProbe.targets(from: [youtube.id], available: [youtube, googleURL]), [youtube])
        XCTAssertEqual(SoftwareRouteProbe.targets(from: ["YouTube"], available: [youtube, googleURL]), [youtube])
        XCTAssertEqual(AppSettings.connectivityProbeLabel(for: AppSettings.presetTestURLs[0], customName: nil), "谷歌")
        XCTAssertEqual(AppSettings.connectivityProbeLabel(for: AppSettings.presetTestURLs[3], customName: nil), "谷歌静态资源")
        XCTAssertEqual(AppSettings.connectivityProbeLabel(for: AppSettings.presetTestURLs[6], customName: nil), "ChatGPT")
        XCTAssertEqual(AppSettings.connectivityProbeLabel(for: "https://github.com/generate_204", customName: "github"), "github")
        XCTAssertEqual(AppSettings.connectivityProbeLabel(for: "https://example.com/a", customName: "备用连通性检测节点"), "备用节点")
        let fastNoExit = SoftwareRouteProbe.Rank(
            passedIDs: [AppProbeTarget.google.id], latencyMs: 100, exit: nil
        )
        let slowerWithExit = SoftwareRouteProbe.Rank(
            passedIDs: [AppProbeTarget.google.id], latencyMs: 900,
            exit: SoftwareRouteExit(country: "JP", countryCode: "JP", city: "Tokyo", ip: "1.2.3.4")
        )
        XCTAssertTrue(SoftwareRouteProbe.rank(slowerWithExit, before: fastNoExit, order: [.google]))
        XCTAssertFalse(SoftwareRouteProbe.rank(fastNoExit, before: slowerWithExit, order: [.google]))
        XCTAssertEqual(AppProbeTarget.liveStream.probeURLs.first?.absoluteString,
                       "https://zh.myavlive.com/api/front/models?limit=1&offset=0&primaryTag=girls")
        XCTAssertEqual(AppProbeTarget.liveStream.probeHTTPHeaders["Accept"], "application/json")
        XCTAssertEqual(AppProbeTarget.liveStream.probeHTTPHeaders["Referer"], "https://zh.myavlive.com/")
        XCTAssertEqual(AppProbeTarget.liveStream.probeHTTPHeaders["Origin"], "https://zh.myavlive.com")
        XCTAssertTrue(AppProbeTarget.liveStream.probeHTTPHeaders["User-Agent"]?.contains("Chrome/131") == true)
        let japan = SoftwareRouteExit(country: "Japan", countryCode: "JP", city: nil, ip: nil)
        XCTAssertEqual(SoftwareRouteProbe.exitText(japan, showChinese: true), "日本")
        XCTAssertEqual(
            SoftwareRouteProbe.exitText(SoftwareRouteExit(country: "Atlantis", countryCode: nil, city: nil, ip: nil), showChinese: true),
            "Atlantis"
        )
        XCTAssertEqual(SoftwareRouteProbe.exitText(japan, showChinese: false), "Japan")
        XCTAssertEqual(
            SoftwareRouteProbe.exitText(SoftwareRouteExit(country: nil, countryCode: nil, city: nil, ip: "1.1.1.1"), showChinese: true),
            "1.1.1.1"
        )
        XCTAssertNil(SoftwareRouteProbe.exitText(SoftwareRouteExit(country: " ", countryCode: nil, city: nil, ip: nil), showChinese: false))
    }

    func testSoftwareRouteGroupsFollowTheCheckedSubscriptions() {
        let chosen = UUID()
        let other = UUID()
        let kept = ProxyNode(name: "kept", protocolType: .vless, server: "1.1.1.1", port: 443, subscriptionID: chosen)
        let skipped = ProxyNode(name: "other", protocolType: .vless, server: "1.1.1.1", port: 443, subscriptionID: other)
        let turnedOff = ProxyNode(name: "off", protocolType: .vless, server: "1.1.1.1", port: 443, subscriptionID: chosen, enabled: false)
        let leaving = ProxyNode(name: "gone", protocolType: .vless, server: "1.1.1.1", port: 443, subscriptionID: chosen, pendingRemoval: true)
        let manual = ProxyNode(name: "manual", protocolType: .vless, server: "1.1.1.1", port: 443)
        XCTAssertTrue(SoftwareRouteGroups.includes(kept, selection: nil))
        XCTAssertTrue(SoftwareRouteGroups.includes(kept, selection: [chosen.uuidString]))
        XCTAssertFalse(SoftwareRouteGroups.includes(skipped, selection: [chosen.uuidString]))
        XCTAssertFalse(SoftwareRouteGroups.includes(turnedOff, selection: nil))
        XCTAssertFalse(SoftwareRouteGroups.includes(leaving, selection: nil))
        XCTAssertEqual(SoftwareRouteGroups.id(for: manual), SoftwareRouteGroups.manual)
        XCTAssertFalse(SoftwareRouteGroups.includes(manual, selection: [chosen.uuidString]))
    }

    func testSoftwareRouteRanksRoundTripWithoutTheNode() throws {
        let id = UUID()
        let rank = SoftwareRouteProbe.Rank(
            passedIDs: ["Google"],
            latencyMs: 780,
            exit: SoftwareRouteExit(country: "United States", countryCode: "US", city: "San Francisco", ip: "1.2.3.4")
        )
        let data = try XCTUnwrap(SoftwareRoutePreferences.encodeRanks([
            id: rank,
            UUID(): SoftwareRouteProbe.Rank(passedIDs: [], latencyMs: nil)
        ]))
        let loaded = SoftwareRoutePreferences.decodeRanks(data)
        XCTAssertEqual(loaded, [id: rank])
    }

    func testSoftwareRouteRestoresItsOwnNodeWhileTheMainAppStaysDisconnected() {
        let kept = ProxyNode(name: "kept", protocolType: .vless, server: "1.1.1.1", port: 443)
        let off = ProxyNode(name: "off", protocolType: .vless, server: "1.1.1.1", port: 443, enabled: false)
        let leaving = ProxyNode(name: "gone", protocolType: .vless, server: "1.1.1.1", port: 443, pendingRemoval: true)
        let nodes = [kept, off, leaving]
        XCTAssertEqual(SoftwareRouteRestore.nodeID(saved: kept.id.uuidString, nodes: nodes), kept.id)
        XCTAssertNil(SoftwareRouteRestore.nodeID(saved: nil, nodes: nodes))
        XCTAssertNil(SoftwareRouteRestore.nodeID(saved: off.id.uuidString, nodes: nodes))
        XCTAssertNil(SoftwareRouteRestore.nodeID(saved: leaving.id.uuidString, nodes: nodes))
        XCTAssertNil(SoftwareRouteRestore.nodeID(saved: UUID().uuidString, nodes: nodes))
    }

    func testSoftwareRouteLatencyFailoverPreferencesDefault() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "HopWorld.softwareRoute.latencyFailover")
        defaults.removeObject(forKey: "HopWorld.softwareRoute.latencyFailoverSeconds")
        defaults.removeObject(forKey: "HopWorld.softwareRoute.latencyFailoverTop")
        let loaded = SoftwareRoutePreferences.loadLatencyFailover()
        XCTAssertTrue(loaded.enabled)
        XCTAssertEqual(loaded.maxSeconds, 10)
        XCTAssertEqual(loaded.topCount, 10)
        SoftwareRoutePreferences.saveLatencyFailover(enabled: false, maxSeconds: 15, topCount: 3)
        let saved = SoftwareRoutePreferences.loadLatencyFailover()
        XCTAssertFalse(saved.enabled)
        XCTAssertEqual(saved.maxSeconds, 15)
        XCTAssertEqual(saved.topCount, 3)
        defaults.removeObject(forKey: "HopWorld.softwareRoute.latencyFailover")
        defaults.removeObject(forKey: "HopWorld.softwareRoute.latencyFailoverSeconds")
        defaults.removeObject(forKey: "HopWorld.softwareRoute.latencyFailoverTop")
    }

    func testSoftwareRouteScheduleUsesItsOwnIntervals() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertFalse(SoftwareRouteSchedule.isDue(now: start, enabled: true, interval: 30 * 60, lastRun: nil))
        XCTAssertFalse(SoftwareRouteSchedule.isDue(now: start.addingTimeInterval(29 * 60), enabled: true, interval: 30 * 60, lastRun: start))
        XCTAssertTrue(SoftwareRouteSchedule.isDue(now: start.addingTimeInterval(30 * 60), enabled: true, interval: 30 * 60, lastRun: start))
        XCTAssertFalse(SoftwareRouteSchedule.isDue(now: start.addingTimeInterval(6 * 3600), enabled: false, interval: 6 * 3600, lastRun: start))
        XCTAssertTrue(SoftwareRouteSchedule.isDue(now: start.addingTimeInterval(6 * 3600), enabled: true, interval: 6 * 3600, lastRun: start))
    }

    func testOrphanSessionCoreMatchesLeftoverConfigsOnly() {
        XCTAssertTrue(LanForwardPorts.isOrphanSessionCore(command: "/tmp/xray run -config /var/folders/x/hopworld-singbox-ABC/xray.json"))
        XCTAssertTrue(LanForwardPorts.isOrphanSessionCore(command: "/tmp/sing-box run -c /tmp/hopworld-tun-ABC/config.json"))
        XCTAssertTrue(LanForwardPorts.isOrphanSessionCore(command: "/tmp/xray -config /tmp/HopWorld-runtime-ABC/xray.json"))
        XCTAssertFalse(LanForwardPorts.isOrphanSessionCore(command: "/Applications/HopWorld.app/Contents/MacOS/HopWorld"))
        XCTAssertFalse(LanForwardPorts.isOrphanSessionCore(command: "/usr/local/bin/xray run -config /tmp/other.json"))
        let parents: [Int32: Int32] = [10: 1, 20: 10, 30: 20, 40: 1]
        XCTAssertTrue(LanForwardPorts.belongsToProcessTree(pid: 10, root: 10, parents: parents))
        XCTAssertTrue(LanForwardPorts.belongsToProcessTree(pid: 30, root: 10, parents: parents))
        XCTAssertFalse(LanForwardPorts.belongsToProcessTree(pid: 40, root: 10, parents: parents))
    }

    func testLanForwardPortsStayOn17890() throws {
        XCTAssertThrowsError(try LanForwardPorts.reserve(avoiding: [LanForwardPorts.firstChoice]))
        XCTAssertTrue(LanForwardPorts.isStaleLanCore(command: "/usr/local/bin/xray run -config /tmp/lan-abc.json"))
        XCTAssertFalse(LanForwardPorts.isStaleLanCore(command: "/usr/local/bin/xray run -config /tmp/config-abc.json"))
        var held: LanForwardPorts.Hold
        do {
            held = try LanForwardPorts.reserve(avoiding: [XrayConfigBuilder.apiPort])
        } catch SoftwareRouterError.noFreePort {
            throw XCTSkip("17890 is already taken on this machine")
        }
        defer { held.release() }
        XCTAssertEqual(held.http, 17_890)
        XCTAssertEqual(held.socks, 17_891)
        XCTAssertThrowsError(try LanForwardPorts.reserve(avoiding: []))
    }
}
