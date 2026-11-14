import XCTest
import NetworkExtension
@testable import HopWorldIOS

@MainActor
final class IOSLibraryTests: XCTestCase {
    private let realityLink = "vless://b831381d-6324-4d53-ad4f-8cda48b30811@1.2.3.4:443?encryption=none&security=reality&sni=www.microsoft.com&fp=chrome&pbk=QAbDKrO6KPZ3vYXDFZCOUNzFEFJ2QG0dcSxrDTZCxAU&sid=abcd&type=tcp&flow=xtls-rprx-vision#%E9%A6%99%E6%B8%AF"

    func testImportGroupsHongKongAndBuildsTunnelConfig() throws {
        let directory = try makeDirectory()
        let library = IOSLibrary(directory: directory, watchTunnel: false)
        try library.importShareText(realityLink)

        let node = try XCTUnwrap(library.selectedNode)
        XCTAssertEqual(CountryResolver.effectiveCode(for: node), "HK")
        XCTAssertEqual(library.countries.map(\.code), ["HK"])

        let json = try IOSSingBoxConfig.json(for: node)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let outbounds = try XCTUnwrap(object["outbounds"] as? [[String: Any]])
        let proxy = try XCTUnwrap(outbounds.first { $0["tag"] as? String == "proxy" })
        XCTAssertEqual(proxy["server"] as? String, "1.2.3.4")
        XCTAssertEqual(proxy["uuid"] as? String, "b831381d-6324-4d53-ad4f-8cda48b30811")
        XCTAssertEqual(proxy["flow"] as? String, "xtls-rprx-vision")
        let tls = try XCTUnwrap(proxy["tls"] as? [String: Any])
        let reality = try XCTUnwrap(tls["reality"] as? [String: Any])
        XCTAssertEqual(reality["public_key"] as? String, "QAbDKrO6KPZ3vYXDFZCOUNzFEFJ2QG0dcSxrDTZCxAU")
        let safari = safariRealityNode()
        let safariJSON = try IOSSingBoxConfig.json(for: safari)
        let safariObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(safariJSON.utf8)) as? [String: Any])
        let safariProxy = try XCTUnwrap((safariObject["outbounds"] as? [[String: Any]])?.first { $0["tag"] as? String == "proxy" })
        let safariTLS = try XCTUnwrap(safariProxy["tls"] as? [String: Any])
        let safariUTLS = try XCTUnwrap(safariTLS["utls"] as? [String: Any])
        XCTAssertEqual(safariUTLS["fingerprint"] as? String, "chrome")
        XCTAssertNil(object["endpoints"])
        XCTAssertFalse(json.contains("process_name"))
        XCTAssertFalse(json.contains("include_package"))
        XCTAssertFalse(json.contains("per-app"))

        let reloaded = IOSLibrary(directory: directory, watchTunnel: false)
        XCTAssertEqual(reloaded.nodes.count, 1)
        XCTAssertEqual(reloaded.selectedNodeID, node.id)
    }

    func testSelectingNodeWhileConnectedRestartsTunnelWithNewNode() async throws {
        let tunnel = FakeSwitchTunnel()
        let library = IOSLibrary(directory: try makeDirectory(), watchTunnel: false, tunnel: tunnel)
        try library.importShareText("trojan://password@first.example:443#First\ntrojan://password@second.example:443#Second")
        tunnel.setStatus(.connected)
        let second = try XCTUnwrap(library.connectableNodes.first { $0.server == "second.example" })
        library.select(second)
        for _ in 0..<100 where tunnel.startedServers.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(library.selectedNodeID, second.id)
        XCTAssertEqual(tunnel.stopCount, 1)
        XCTAssertEqual(tunnel.startedServers, ["second.example"])
    }

    func testSubscriptionNoticesAreVisibleButCannotBeSelected() throws {
        let directory = try makeDirectory()
        let library = IOSLibrary(directory: directory, watchTunnel: false)
        let names = ["✅官网续费vgvg.vg关vpn访问✅", "🎉rst:16d/99.24 GB/返佣:60%🎉", "⚠️exp:20271106没网卸旧装新⚠️", "【2024之前的软件无法使用】", "【用不了下载本站最新软件】", "美国-美西极速-rl(主力)gemini"]
        let links = names.map { name in
            "trojan://password@example.com:443#" + name.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)!
        }.joined(separator: "\n")
        try library.importShareText(links)
        XCTAssertEqual(library.nodes.filter { IOSSubscriptionNotice.matches($0) }.count, 5)
        XCTAssertEqual(library.connectableNodes.map(\.name), [names[5]])
        XCTAssertEqual(library.selectedNode?.name, names[5])
        let notice = try XCTUnwrap(library.nodes.first { IOSSubscriptionNotice.matches($0) })
        library.select(notice)
        XCTAssertEqual(library.selectedNode?.name, names[5])
        XCTAssertEqual(library.countries.flatMap(\.nodes).count, 1)

        let file = IOSLibraryFile(subscriptions: library.subscriptions, nodes: library.nodes, selectedNodeID: notice.id)
        try JSONEncoder().encode(file).write(to: directory.appendingPathComponent(IOSAppGroup.libraryFileName))
        let restored = IOSLibrary(directory: directory, watchTunnel: false)
        XCTAssertNil(restored.selectedNode)
        XCTAssertNil(restored.selectedNodeID)
        XCTAssertEqual(restored.nodes.count, 6)
    }

    func testSubscriptionMergeModesReuseMacRulesAndKeepNoticesSeparate() throws {
        var subscription = Subscription(name: "测试", originalURL: "https://example.com")
        func node(_ name: String, _ host: String) -> ProxyNode {
            ProxyNode(name: name, protocolType: .vless, server: host, port: 443, uuid: "11111111-1111-1111-1111-111111111111")
        }
        let a = node("节点 A", "a.example.com")
        let b = node("节点 B", "b.example.com")
        let notice = node("✅官网续费✅", "a.example.com")
        let old = IOSSubscriptionMerge.prepare([notice, a, b], subscription: subscription)
        let selected = old[1].id
        let duplicate = node("节点 A 别名", "a.example.com")
        let imported = IOSSubscriptionMerge.uniqueNodes(IOSSubscriptionMerge.prepare([a, duplicate], subscription: subscription))
        XCTAssertEqual(imported.count, 1)

        subscription.updateMode = .overwrite
        let overwritten = IOSSubscriptionMerge.merge(old: old, incoming: [notice, a, duplicate], subscription: subscription, selectedID: selected, preserveSelected: false)
        XCTAssertEqual(overwritten.filter { !IOSSubscriptionNotice.matches($0) }.map(\.name), ["节点 A"])
        XCTAssertEqual(overwritten.first { !IOSSubscriptionNotice.matches($0) }?.id, selected)
        XCTAssertEqual(overwritten.filter { IOSSubscriptionNotice.matches($0) }.count, 1)

        subscription.updateMode = .merge
        let merged = IOSSubscriptionMerge.merge(old: old, incoming: [a], subscription: subscription, selectedID: selected, preserveSelected: false)
        XCTAssertEqual(Set(merged.map(\.name)), Set(["节点 A", "节点 B"]))

        subscription.updateMode = .smartMerge
        subscription.smartMergeMissingLimit = 2
        let first = IOSSubscriptionMerge.merge(old: old, incoming: [a], subscription: subscription, selectedID: selected, preserveSelected: false)
        XCTAssertTrue(first.contains { $0.name == "节点 B" && $0.missingCount == 1 })
        let second = IOSSubscriptionMerge.merge(old: first, incoming: [a], subscription: subscription, selectedID: selected, preserveSelected: false)
        XCTAssertFalse(second.contains { $0.name == "节点 B" })
        let protected = IOSSubscriptionMerge.merge(old: old, incoming: [b], subscription: subscription, selectedID: selected, preserveSelected: true)
        XCTAssertTrue(protected.contains { $0.id == selected })
    }

    func testNodesSortByMeasuredLatencyBeforeUntestedAndFailures() {
        func node(_ name: String, status: NodeTestStatus, latency: Int?) -> ProxyNode {
            var result = ProxyNode(name: name, protocolType: .vless, server: "example.com", port: 443)
            result.lastTestStatus = status
            result.lastLatency = latency
            return result
        }
        let nodes = [node("不可用", status: .unavailable, latency: nil),
                     node("慢", status: .fast, latency: 800),
                     node("未测试", status: .untested, latency: nil),
                     node("快", status: .ultraFast, latency: 100),
                     node("失败", status: .failed, latency: nil),
                     node("测试中", status: .testing, latency: nil),
                     node("TCP", status: .unavailable, latency: 50)]
        XCTAssertEqual(IOSNodeSort.byLatency(nodes).map(\.name), ["快", "慢", "测试中", "未测试", "失败", "TCP", "不可用"])
    }

    func testSingleAndBatchTimeoutSettings() {
        let defaults = UserDefaults.standard
        let keys = ["ios.testTimeout", "ios.batchTestTimeout"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        keys.forEach { defaults.removeObject(forKey: $0) }
        XCTAssertEqual(IOSSettings.timeoutSeconds, 8)
        XCTAssertEqual(IOSSettings.batchTimeoutSeconds, 2)
        IOSSettings.timeoutSeconds = 12
        IOSSettings.batchTimeoutSeconds = 4
        XCTAssertEqual(IOSSettings.timeoutSeconds, 12)
        XCTAssertEqual(IOSSettings.batchTimeoutSeconds, 4)
        IOSSettings.timeoutSeconds = 99
        IOSSettings.batchTimeoutSeconds = 0
        XCTAssertEqual(IOSSettings.timeoutSeconds, 30)
        XCTAssertEqual(IOSSettings.batchTimeoutSeconds, 1)
    }

    func testCustomTestTargetValidationAndPersistence() throws {
        let defaults = UserDefaults.standard
        let key = IOSSettings.customTargetsKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        XCTAssertNil(IOSSettings.customTarget(title: "", url: "https://example.com", kind: "网页"))
        XCTAssertNil(IOSSettings.customTarget(title: "测试", url: "file:///tmp/test", kind: "网页"))
        XCTAssertNil(IOSSettings.customTarget(title: "测试", url: "https://user:pass@example.com", kind: "网页"))
        let target = try XCTUnwrap(IOSSettings.customTarget(title: " 我的目标 ", url: " https://example.com/check ", kind: "App"))
        IOSSettings.customTargets = [target]
        XCTAssertEqual(IOSSettings.customTargets, [target])
        XCTAssertEqual(IOSSettings.title(for: target.url), "我的目标")
        XCTAssertTrue(IOSSettings.targets.contains(target))
    }

    func testMultipleTestTargetsAndEmptySelection() {
        let defaults = UserDefaults.standard
        let keys = [IOSSettings.selectedTargetsKey, "ios.testURL"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.removeObject(forKey: IOSSettings.selectedTargetsKey)
        let first = IOSSettings.builtInTargets[0].url
        let second = IOSSettings.builtInTargets[1].url
        defaults.set(second, forKey: "ios.testURL")
        XCTAssertEqual(IOSSettings.selectedTestURLs, [second])
        let encoded = IOSSettings.encodedTestURLs([first, second, first])
        XCTAssertEqual(IOSSettings.selectedTestURLs(from: encoded), [first, second])
        XCTAssertEqual(IOSSettings.selectedTestURLs(from: IOSSettings.encodedTestURLs([])), [])
        IOSSettings.selectedTestURLs = [first, second, first]
        XCTAssertEqual(IOSSettings.selectedTestURLs, [first, second])
        IOSSettings.selectedTestURLs = []
        XCTAssertEqual(IOSSettings.selectedTestURLs, [])
        XCTAssertEqual(IOSLatencyProbe.combined([.latency(100), .latency(400)]), .latency(400))
        XCTAssertEqual(IOSLatencyProbe.combined([.latency(100), .unavailable]), .unavailable)
        XCTAssertEqual(IOSLatencyProbe.combined([]), .failed("请先在设置中选择测试目标"))
    }

    func testExitCountryPrefersChineseThenEnglish() {
        let named = ProxyNode(name: "爱尔兰 Dublin-rl", protocolType: .vless, server: "1.2.3.4", port: 443, transport: .tcp, security: .none)
        XCTAssertEqual(IOSExitCountry.label(for: named), "爱尔兰")

        var stored = ProxyNode(name: "node", protocolType: .vless, server: "1.2.3.4", port: 443, transport: .tcp, security: .none)
        stored.countryCode = "IE"
        stored.countryName = "Ireland"
        XCTAssertEqual(IOSExitCountry.label(for: stored), "爱尔兰")

        var english = ProxyNode(name: "node", protocolType: .vless, server: "1.2.3.4", port: 443, transport: .tcp, security: .none)
        english.countryName = "Atlantis"
        XCTAssertEqual(IOSExitCountry.label(for: english), "Atlantis")

        let unknown = ProxyNode(name: "HopWorld", protocolType: .vless, server: "1.2.3.4", port: 443, transport: .tcp, security: .none)
        XCTAssertEqual(IOSExitCountry.label(for: unknown), "未知")
        XCTAssertEqual(IOSExitCountry.label(code: "IE", name: "Ireland", fallback: unknown), "爱尔兰")
    }

    func testExitLookupParsesCountryFromNodeResponse() throws {
        let ipSB = Data(#"{"ip":"8.8.8.8","country_code":"US","country":"United States"}"#.utf8)
        let parsed = try XCTUnwrap(IOSExitLookup.parse(ipSB))
        XCTAssertEqual(parsed.countryCode, "US")
        XCTAssertEqual(parsed.ip, "8.8.8.8")
        let numericASN = try XCTUnwrap(IOSExitLookup.parse(Data(#"{"ip":"8.8.8.8","asn":15169}"#.utf8)))
        XCTAssertEqual(numericASN.asn, "AS15169")

        let ipquery = Data(#"{"ip":"1.1.1.1","location":{"country_code":"jp","country":"Japan","city":"Tokyo"},"isp":{"org":"Example ISP","asn":"AS123"},"risk":{"is_tor":false,"is_vpn":false,"is_proxy":false,"is_datacenter":true,"is_mobile":false}}"#.utf8)
        let query = try XCTUnwrap(IOSExitLookup.parse(ipquery))
        XCTAssertEqual(query.countryCode, "JP")
        XCTAssertEqual(query.kind, "机房托管")
        XCTAssertEqual(query.city, "Tokyo")
        XCTAssertEqual(query.networkOperator, "Example ISP")
        XCTAssertEqual(query.asn, "AS123")
    }

    func testEachShareImportIsItsOwnGroup() throws {
        let directory = try makeDirectory()
        let library = IOSLibrary(directory: directory, watchTunnel: false)
        let firstID = try library.importShareText(realityLink, name: "甲")
        let secondID = try library.importShareText(realityLink, name: "乙")
        XCTAssertNotEqual(firstID, secondID)
        XCTAssertEqual(library.connectableNodes.filter { $0.subscriptionID == secondID }.count, 1)
        XCTAssertEqual(library.subscriptions.map(\.name), ["乙", "甲"])
        XCTAssertEqual(library.nodes.count, 2)
        XCTAssertEqual(Set(library.nodes.compactMap(\.subscriptionID)), Set(library.subscriptions.map(\.id)))
    }

    func testMasqueStaysImportedButCannotConnect() throws {
        let directory = try makeDirectory()
        let library = IOSLibrary(directory: directory, watchTunnel: false)
        try library.importShareText("masque://1.2.3.4:443?sni=example.com#test")
        let node = try XCTUnwrap(library.nodes.first)
        XCTAssertEqual(node.protocolType, .masque)
        XCTAssertThrowsError(try IOSSingBoxConfig.json(for: node))
    }

    func testWireGuardUsesEndpointNotPerAppRules() throws {
        let node = ProxyNode(
            name: "wg",
            protocolType: .wireguard,
            server: "1.2.3.4",
            port: 51820,
            wireGuardOptions: WireGuardOptions(
                privateKey: "YWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWE=",
                addresses: ["10.0.0.2/32"],
                peerPublicKey: "YWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWE="
            ),
            transport: .tcp,
            security: .none
        )
        let object = try IOSSingBoxConfig.document(for: node)
        let endpoints = try XCTUnwrap(object["endpoints"] as? [[String: Any]])
        XCTAssertEqual(endpoints.first?["type"] as? String, "wireguard")
        XCTAssertEqual(endpoints.first?["tag"] as? String, "proxy")
        let route = try XCTUnwrap(object["route"] as? [String: Any])
        XCTAssertEqual(route["final"] as? String, "proxy")
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        XCTAssertTrue(rules.contains { $0["ip_is_private"] as? Bool == true })
        XCTAssertFalse(rules.contains { $0["process_name"] != nil })
        let inbounds = try XCTUnwrap(object["inbounds"] as? [[String: Any]])
        let socks = try XCTUnwrap(inbounds.first { $0["type"] as? String == "mixed" })
        XCTAssertEqual(socks["listen"] as? String, "127.0.0.1")
        XCTAssertEqual(socks["listen_port"] as? Int, IOSSingBoxConfig.socksPort)
        let probe = try JSONSerialization.jsonObject(with: Data(IOSSingBoxConfig.probeJSON(for: node).utf8)) as? [String: Any]
        let probeInbounds = try XCTUnwrap(probe?["inbounds"] as? [[String: Any]])
        XCTAssertEqual(probeInbounds.count, 1)
        XCTAssertEqual(probeInbounds.first?["type"] as? String, "http")
        XCTAssertEqual(probeInbounds.first?["listen_port"] as? Int, IOSSingBoxConfig.httpPort)
        let latency = try JSONSerialization.jsonObject(with: Data(IOSSingBoxConfig.latencyJSON(for: node).utf8)) as? [String: Any]
        let latencyInbounds = try XCTUnwrap(latency?["inbounds"] as? [[String: Any]])
        XCTAssertEqual(latencyInbounds.count, 1)
        XCTAssertEqual(latencyInbounds.first?["type"] as? String, "mixed")
        XCTAssertEqual(latencyInbounds.first?["listen_port"] as? Int, IOSSingBoxConfig.socksPort)
    }

    func testRefreshKeepsLatencyAndCountsStatuses() async throws {
        let directory = try makeDirectory()
        let library = IOSLibrary(directory: directory, watchTunnel: false)
        try library.importShareText(realityLink)
        let nodeID = try XCTUnwrap(library.nodes.first?.id)
        let subscriptionID = try XCTUnwrap(library.subscriptions.first?.id)
        library.applyProbeResult(nodeID: nodeID, outcome: .latency(1500), announce: false)
        await library.refreshSubscription(subscriptionID)
        let node = try XCTUnwrap(library.nodes.first { $0.id == nodeID })
        XCTAssertEqual(node.lastLatency, 1500)
        XCTAssertTrue(node.resolvedTestStatus.isUsable)
        var tally = IOSNodeTally.make(library.nodes)
        XCTAssertEqual(tally, IOSNodeTally(total: 1, available: 1, unavailable: 0, failed: 0))
        library.applyProbeResult(nodeID: nodeID, outcome: .failed("配置无法测"), announce: false)
        tally = IOSNodeTally.make(library.nodes)
        XCTAssertEqual(tally.failed, 1)
        XCTAssertEqual(tally.available, 0)
        XCTAssertTrue(IOSNodeScope.failed.matches(try XCTUnwrap(library.nodes.first)))
        XCTAssertFalse(IOSNodeScope.available.matches(try XCTUnwrap(library.nodes.first)))
    }

    private func safariRealityNode() -> ProxyNode {
        var node = ProxyNode(
            name: "乌克兰-rl",
            protocolType: .vless,
            server: "1.2.3.4",
            port: 443,
            uuid: "b831381d-6324-4d53-ad4f-8cda48b30811",
            flow: "xtls-rprx-vision",
            transport: .tcp,
            security: .reality,
            sni: "music.apple.com",
            publicKey: "QAbDKrO6KPZ3vYXDFZCOUNzFEFJ2QG0dcSxrDTZCxAU",
            shortID: "abcd",
            fingerprint: "safari"
        )
        return node
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hopworld-ios-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

@MainActor
private final class FakeSwitchTunnel: IOSTunnelControlling {
    var status: NEVPNStatus = .disconnected
    var onStatus: ((NEVPNStatus) -> Void)?
    var startedServers: [String] = []
    var stopCount = 0
    func setStatus(_ value: NEVPNStatus) { status = value; onStatus?(value) }
    func reload() async { }
    func start(config: String, server: String, name: String) async throws {
        startedServers.append(server)
        setStatus(.connecting)
    }
    func stop() { stopCount += 1; setStatus(.disconnected) }
}
