import XCTest

final class RoutingRulesTests: XCTestCase {
    func testNormalizeDomainsAndIPRanges() throws {
        let parsed = try RoutingRules().entries(" Example.COM \nfull:api.example.com\ndomain:test.com\n1.2.3.4\n10.0.0.0/8\n2001:db8::/32\n# comment\n")
        XCTAssertEqual(parsed.domains, ["domain:example.com", "full:api.example.com", "domain:test.com"])
        XCTAssertEqual(parsed.ips, ["1.2.3.4", "10.0.0.0/8", "2001:db8::/32"])
    }

    func testRejectMalformedRules() {
        for value in ["https://example.com", "example.com:443", "*.example.com", "1.2.3.4/33", "::1/129", "1.2.3.999", "geosite:cn", "bad..com", "-bad.com", "1.2.3.4/", "1.2.3.4/8/9", "1.2.3.4/+24"] {
            XCTAssertThrowsError(try RoutingRules().entries(value), value)
        }
    }

    func testCustomRulesPrecedeBuiltinsAndFallbackRemainsUnmatched() throws {
        var settings = RoutingRules()
        settings.blocked = "ads.example.com"
        settings.proxy = "example.com\n1.2.3.0/24"
        settings.direct = "internal.example.com"
        let config = try settings.xrayRouting()
        XCTAssertEqual(config["domainStrategy"] as? String, "IPOnDemand")
        let rules = try XCTUnwrap(config["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.prefix(5).compactMap { $0["outboundTag"] as? String }, ["api", "blocked", "proxy", "proxy", "direct"])
        XCTAssertTrue(rules.contains { ($0["domain"] as? [String]) == ["geosite:cn"] })
        XCTAssertTrue(rules.contains { ($0["ip"] as? [String]) == ["geoip:cn"] })
        XCTAssertFalse(rules.contains { $0["network"] != nil })
        settings.bypassChina = false
        let disabled = try JSONSerialization.data(withJSONObject: settings.xrayRouting())
        XCTAssertFalse(String(decoding: disabled, as: UTF8.self).contains(":cn"))
    }

    func testRoundTrip() throws {
        var settings = AppSettings()
        settings.routingRules.proxy = "example.com"
        settings.routingRules.bypassChina = false
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testRealXrayAcceptsRoutingWithBundledData() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let resources = try XCTUnwrap(Bundle(for: Self.self).resourceURL)
        let binary = root.appendingPathComponent("HopWorld/Resources/xray")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw XCTSkip("本地未提供 Xray") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = RoutingRules()
        settings.proxy = "full:example.com\n2001:db8::/32"
        settings.blocked = "ads.example.com"
        let config: [String: Any] = [
            "routing": try settings.xrayRouting(),
            "outbounds": [["tag": "proxy", "protocol": "freedom"], ["tag": "direct", "protocol": "freedom"], ["tag": "blocked", "protocol": "blackhole"], ["tag": "api", "protocol": "freedom"]],
            "dns": ["servers": [["address": "223.5.5.5", "domains": ["geosite:cn"], "skipFallback": true] as [String: Any], "1.1.1.1"]]
        ]
        let file = directory.appendingPathComponent("config.json")
        try JSONSerialization.data(withJSONObject: config).write(to: file)
        let process = Process()
        process.executableURL = binary
        process.arguments = ["run", "-test", "-config", file.path]
        var environment = ProcessInfo.processInfo.environment
        // Child processes may not inherit removable-volume access. Keep the
        // integration fixture self-contained while validating the bundled bytes.
        for name in ["geoip.dat", "geosite.dat"] {
            try FileManager.default.copyItem(at: resources.appendingPathComponent(name),
                                             to: directory.appendingPathComponent(name))
        }
        environment["XRAY_LOCATION_ASSET"] = directory.path
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: output, as: UTF8.self))
    }
}

final class DateTemplateTests: XCTestCase {
    func testNodeFreeTemplateDetection() {
        let url = "https://node.nodefree.me/2026/08/20260818.txt"
        let detection = SubscriptionDateTemplateDetector.detect(from: url)
        XCTAssertTrue(detection.detected)
        XCTAssertEqual(detection.template, "https://node.nodefree.me/{yyyy}/{MM}/{yyyyMMdd}.txt")
    }

    func testClashGitHubTemplateDetection() {
        let url = "https://clashgithub.com/wp-content/uploads/rss/20260818.txt"
        let detection = SubscriptionDateTemplateDetector.detect(from: url)
        XCTAssertTrue(detection.detected)
        XCTAssertEqual(detection.template, "https://clashgithub.com/wp-content/uploads/rss/{yyyyMMdd}.txt")
    }

    func testResolveAcrossMonth() {
        let template = SubscriptionDateTemplate(template: "https://node.nodefree.me/{yyyy}/{MM}/{yyyyMMdd}.txt")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        let resolved = template.resolve(date: date, timeZone: calendar.timeZone)
        XCTAssertEqual(resolved, "https://node.nodefree.me/2026/09/20260901.txt")
    }

    func testResolveAcrossYear() {
        let template = SubscriptionDateTemplate(template: "https://example.com/{yyyy}/{MM}/{yyyyMMdd}.txt")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let date = calendar.date(from: DateComponents(year: 2027, month: 1, day: 1))!
        let resolved = template.resolve(date: date, timeZone: calendar.timeZone)
        XCTAssertEqual(resolved, "https://example.com/2027/01/20270101.txt")
    }
}

final class MergeTests: XCTestCase {
    private func node(_ name: String, server: String, port: Int = 443) -> ProxyNode {
        var n = ProxyNode(
            name: name,
            protocolType: .vless,
            server: server,
            port: port,
            uuid: "11111111-1111-1111-1111-111111111111"
        )
        n.nodeFingerprint = NodeFingerprint.make(from: n)
        return n
    }

    func testOverwrite() {
        let a = node("A", server: "a.com")
        let b = node("B", server: "b.com")
        let c = node("C", server: "c.com")
        let d = node("D", server: "d.com")
        let plan = SubscriptionMerger.buildPlan(
            mode: .overwrite,
            oldNodes: [a, b, c],
            newNodes: [b, c, d],
            missingLimit: 3
        )
        XCTAssertEqual(Set(plan.resultingNodes.map(\.server)), Set(["b.com", "c.com", "d.com"]))
    }

    func testMerge() {
        let a = node("A", server: "a.com")
        let b = node("B", server: "b.com")
        let c = node("C", server: "c.com")
        let d = node("D", server: "d.com")
        let plan = SubscriptionMerger.buildPlan(
            mode: .merge,
            oldNodes: [a, b, c],
            newNodes: [b, c, d],
            missingLimit: 3
        )
        XCTAssertEqual(Set(plan.resultingNodes.map(\.server)), Set(["a.com", "b.com", "c.com", "d.com"]))
    }

    func testSmartMergeUpdatesExisting() {
        var old = node("B", server: "b.com")
        old.isFavorite = true
        var incoming = node("B-new", server: "b.com")
        incoming.nodeFingerprint = NodeFingerprint.make(from: incoming)
        let plan = SubscriptionMerger.buildPlan(
            mode: .smartMerge,
            oldNodes: [old],
            newNodes: [incoming],
            missingLimit: 3
        )
        XCTAssertEqual(plan.resultingNodes.count, 1)
        XCTAssertEqual(plan.resultingNodes[0].name, "B-new")
        XCTAssertTrue(plan.resultingNodes[0].isFavorite)
        XCTAssertEqual(plan.resultingNodes[0].id, old.id)
    }

    func testSmartMergeMatchesIdentityWhenPasswordChanges() {
        var old = node("JP-01", server: "1.2.3.4")
        old.isFavorite = true
        old.note = "office"
        var incoming = node("JP-01", server: "1.2.3.4")
        incoming.uuid = "22222222-2222-2222-2222-222222222222"
        incoming.nodeFingerprint = NodeFingerprint.make(from: incoming)
        let plan = SubscriptionMerger.buildPlan(
            mode: .smartMerge,
            oldNodes: [old],
            newNodes: [incoming],
            missingLimit: 3
        )
        XCTAssertEqual(plan.resultingNodes.count, 1)
        XCTAssertEqual(plan.resultingNodes[0].id, old.id)
        XCTAssertTrue(plan.resultingNodes[0].isFavorite)
        XCTAssertEqual(plan.resultingNodes[0].note, "office")
        XCTAssertEqual(plan.resultingNodes[0].uuid, incoming.uuid)
    }
}

final class ParserTests: XCTestCase {
    func testVLESSParse() throws {
        let link = "vless://11111111-1111-1111-1111-111111111111@example.com:443?encryption=none&security=reality&sni=www.example.com&fp=chrome&pbk=abc&sid=abcd&type=tcp#Japan-01"
        let node = try VLESSParser.parse(link)
        XCTAssertEqual(node.protocolType, .vless)
        XCTAssertEqual(node.server, "example.com")
        XCTAssertEqual(node.port, 443)
        XCTAssertEqual(node.security, .reality)
        XCTAssertEqual(node.name, "Japan-01")
    }

    func testTrojanParse() throws {
        let link = "trojan://password@example.com:443?security=tls&sni=example.com#HK"
        let node = try TrojanParser.parse(link)
        XCTAssertEqual(node.protocolType, .trojan)
        XCTAssertEqual(node.password, "password")
        XCTAssertEqual(node.name, "HK")
    }

    func testTrojanParseFinalMask() throws {
        let fm = #"{"tcp":[{"type":"fragment","settings":{"packets":"tlshello","lengths":["5","94","1"],"delays":["0"],"maxSplit":"0"}}]}"#
        let encoded = fm.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? fm
        let link = "trojan://password@104.21.70.21:443?security=tls&sni=id1.nathaya.web.id&fp=unsafe&fm=\(encoded)&type=ws&host=id1.nathaya.web.id&path=%2Ftrojan#T"
        let node = try TrojanParser.parse(link)
        XCTAssertNotNil(node.finalMaskJSON)
        XCTAssertEqual(node.fingerprint, "unsafe")
        XCTAssertEqual(node.transport, .ws)
        let object = FinalMaskCodec.jsonObject(from: node) as? [String: Any]
        let tcp = object?["tcp"] as? [[String: Any]]
        let settings = tcp?.first?["settings"] as? [String: Any]
        XCTAssertEqual(settings?["lengths"] as? [String], ["5", "94", "1"])
        XCTAssertEqual(settings?["delays"] as? [String], ["0"])
    }
}

final class XrayTrafficStatisticsTests: XCTestCase {
    func testCountsApplicationAndSystemTrafficWithoutProbesOrAPI() throws {
        let data = Data(#"{"stat":[{"name":"inbound>>>application-in>>>traffic>>>uplink","value":"1234"},{"name":"inbound>>>application-in>>>traffic>>>downlink","value":5678},{"name":"inbound>>>socks-in>>>traffic>>>uplink","value":10},{"name":"inbound>>>http-in>>>traffic>>>downlink","value":20},{"name":"inbound>>>probe-in>>>traffic>>>downlink","value":9999},{"name":"inbound>>>api>>>traffic>>>uplink","value":9999},{"name":"outbound>>>proxy>>>traffic>>>downlink","value":5698}]}"#.utf8)
        let snapshot = try XCTUnwrap(XrayStatsClient.parse(data))
        XCTAssertEqual(snapshot.uploadBytes, 1244)
        XCTAssertEqual(snapshot.downloadBytes, 5698)
    }
}

final class AutoSelectAppReachabilityTests: XCTestCase {
    func testFailedProbeExcludesFavoriteUntilSuccessfulProbe() {
        let settings = AppSettings()
        var node = ProxyNode(name: "US test", protocolType: .vless, server: "example.com", port: 443)
        node.isFavorite = true
        node.lastLatency = 100
        node.lastTestStatus = .fast
        XCTAssertTrue(settings.allowsAutoSelectNode(node), "Untested nodes must remain available for probing")
        node.lastAppProbeDate = Date()
        node.lastAppProbeOkCount = 0
        XCTAssertFalse(settings.allowsAutoSelectNode(node), "Favorite must not override failed reachability")
        node.lastAppProbeOkCount = 2
        node.lastAppProbeLatency = 100
        XCTAssertTrue(settings.allowsAutoSelectNode(node))
        node.lastTestStatus = .unavailable
        XCTAssertFalse(settings.allowsAutoSelectNode(node), "Old app success must not override a failed connection")
    }
}
