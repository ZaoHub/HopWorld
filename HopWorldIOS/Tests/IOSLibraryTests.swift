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

        XCTAssertNil(library.selectedNode)
        let node = try XCTUnwrap(library.connectableNodes.first)
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

        library.select(node)
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
        XCTAssertNil(library.selectedNode)
        let notice = try XCTUnwrap(library.nodes.first { IOSSubscriptionNotice.matches($0) })
        library.select(notice)
        XCTAssertNil(library.selectedNode)
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

    func testBatchPromptAsksToConnectOnlyWhileDisconnected() {
        let subscription = UUID()
        var usable = ProxyNode(name: "快", protocolType: .vless, server: "a.example", port: 443)
        usable.lastTestStatus = .fast
        usable.lastLatency = 100
        usable.subscriptionID = subscription
        var failed = ProxyNode(name: "失败", protocolType: .vless, server: "b.example", port: 443)
        failed.lastTestStatus = .failed
        failed.subscriptionID = subscription

        let connect = IOSBatchPrompt.make(status: .disconnected, cancelled: false, tested: [usable, failed], subscriptionOrder: [subscription])
        XCTAssertEqual(connect, .connect(usable: 1, testedIDs: [usable.id, failed.id]))
        XCTAssertNil(IOSBatchPrompt.make(status: .connected, cancelled: false, tested: [usable], subscriptionOrder: [subscription]))
        XCTAssertNil(IOSBatchPrompt.make(status: .disconnected, cancelled: true, tested: [failed], subscriptionOrder: [subscription]))

        let other = UUID()
        XCTAssertEqual(
            IOSBatchPrompt.make(status: .invalid, cancelled: false, tested: [failed], subscriptionOrder: [other, subscription]),
            .noAvailable(subscriptionIDs: [subscription])
        )
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

    func testDomainServerIsResolvedBeforeSingBoxDial() throws {
        let previous = IOSSingBoxConfig.resolveServer
        defer { IOSSingBoxConfig.resolveServer = previous }
        IOSSingBoxConfig.resolveServer = { host in
            XCTAssertEqual(host, "proxy.example")
            return "9.9.9.9"
        }
        let node = ProxyNode(name: "n", protocolType: .trojan, server: "proxy.example", port: 443, password: "secret", transport: .tcp, security: .tls, sni: "tls.example")
        let json = try IOSSingBoxConfig.probeJSON(for: node)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let proxy = try XCTUnwrap((object["outbounds"] as? [[String: Any]])?.first { $0["tag"] as? String == "proxy" })
        XCTAssertEqual(proxy["server"] as? String, "9.9.9.9")
        XCTAssertEqual((proxy["tls"] as? [String: Any])?["server_name"] as? String, "tls.example")

        IOSSingBoxConfig.resolveServer = { _ in nil }
        let unchanged = try IOSSingBoxConfig.probeJSON(for: node)
        let unchangedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(unchanged.utf8)) as? [String: Any])
        let unchangedProxy = try XCTUnwrap((unchangedObject["outbounds"] as? [[String: Any]])?.first { $0["tag"] as? String == "proxy" })
        XCTAssertEqual(unchangedProxy["server"] as? String, "proxy.example")

        var bare = node
        bare.sni = nil
        IOSSingBoxConfig.resolveServer = { _ in "8.8.8.8" }
        let bareJSON = try IOSSingBoxConfig.probeJSON(for: bare)
        let bareObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(bareJSON.utf8)) as? [String: Any])
        let bareProxy = try XCTUnwrap((bareObject["outbounds"] as? [[String: Any]])?.first { $0["tag"] as? String == "proxy" })
        XCTAssertEqual(bareProxy["server"] as? String, "8.8.8.8")
        XCTAssertEqual((bareProxy["tls"] as? [String: Any])?["server_name"] as? String, "proxy.example")
    }

    func testProbeSessionSendsConnectToLocalProxy() async throws {
        let proxy = try LocalProxyCatcher()
        defer { proxy.close() }
        let session = IOSExitLookup.httpProxySession(port: proxy.port, timeout: 3)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://example.test/generate_204")!)
        request.timeoutInterval = 3
        _ = try? await IOSURL.load(request, session: session)
        let line = try await IOSLatencyProbe.within(4) { await proxy.firstLine() }
        XCTAssertTrue(line.contains("CONNECT example.test:443"), line)
    }

    func testProbeRequestStopsAtTimeout() async throws {
        let started = Date()
        do {
            _ = try await IOSLatencyProbe.within(0.15) {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return true
            }
            XCTFail("应在设置的时间内停止")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
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

    func testInstalledAppCatalogStaysWithinQueryLimit() throws {
        let catalog = IOSSettings.installedAppCatalog
        XCTAssertLessThanOrEqual(catalog.count, 50)
        XCTAssertEqual(Set(catalog.map(\.scheme)).count, catalog.count)
        XCTAssertEqual(Set(catalog.map(\.url)).count, catalog.count)
        let systemSchemes: Set<String> = ["sms", "tel", "mailto", "maps", "prefs", "App-prefs", "mobilenotes", "music", "facetime", "messages", "itms-apps"]
        XCTAssertTrue(catalog.allSatisfy { app in
            !systemSchemes.contains(app.scheme) && !app.scheme.contains(":") && app.scheme == app.scheme.lowercased()
        })
        for app in catalog {
            if let builtIn = IOSSettings.builtInTargets.first(where: { $0.url == app.url }) {
                XCTAssertEqual(builtIn.title, app.title)
            } else {
                XCTAssertNotNil(IOSSettings.customTarget(title: app.title, url: app.url, kind: "App"))
            }
        }
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/Info.plist")
        let plist = try XCTUnwrap(NSDictionary(contentsOf: plistURL))
        XCTAssertEqual(plist["LSApplicationQueriesSchemes"] as? [String], catalog.map(\.scheme))
        let appPresets = IOSSettings.builtInTargets.filter { $0.kind == "App" }
        XCTAssertEqual(appPresets.map(\.title), [
            "YouTube", "Telegram", "Instagram", "WhatsApp", "TikTok", "X", "Discord", "ChatGPT",
            "Claude", "GitHub", "Cloudflare"
        ])
        XCTAssertEqual(Set(IOSSettings.builtInTargets.map(\.url)).count, IOSSettings.builtInTargets.count)
        let cloudflare = IOSSettings.probeGroup(for: "https://www.cloudflare.com/cdn-cgi/trace")
        XCTAssertTrue(cloudflare.matchAny)
        XCTAssertFalse(IOSSettings.probesAppServer("https://www.cloudflare.com/cdn-cgi/trace"))
        XCTAssertTrue(IOSSettings.probesAppServer("https://api.github.com/"))
        let logos = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/Assets.xcassets/PlatformLogos")
        XCTAssertNil(IOSSettings.logoAsset(for: "https://www.gstatic.com/generate_204"))
        XCTAssertTrue(IOSSettings.showsLogo(for: "https://www.gstatic.com/generate_204"))
        XCTAssertNil(IOSSettings.logoAsset(for: "https://example.com/check"))
        for target in IOSSettings.builtInTargets where target.url != "https://www.gstatic.com/generate_204" {
            let name = try XCTUnwrap(IOSSettings.logoAsset(for: target.url))
            XCTAssertTrue(FileManager.default.fileExists(atPath: logos.appendingPathComponent("\(name).imageset/icon.png").path), name)
        }
        for app in catalog {
            let name = try XCTUnwrap(IOSSettings.logoAsset(for: app.url))
            XCTAssertEqual(name, "Logo" + app.scheme.replacingOccurrences(of: ".", with: ""))
            XCTAssertTrue(FileManager.default.fileExists(atPath: logos.appendingPathComponent("\(name).imageset/icon.png").path), name)
        }
    }

    func testInstalledAppsFollowTheDeviceOpener() {
        let wanted: Set<String> = ["weixin", "tg"]
        let found = IOSSettings.installedApps { wanted.contains($0) }
        XCTAssertEqual(found.map(\.scheme), IOSSettings.installedAppCatalog.map(\.scheme).filter { wanted.contains($0) })
        XCTAssertTrue(IOSSettings.installedApps { _ in false }.isEmpty)
    }

    func testAdoptInstalledAppSelectsWithoutDuplicating() throws {
        let youtube = try XCTUnwrap(IOSSettings.installedAppCatalog.first { $0.scheme == "youtube" })
        let selectedBuiltIn = IOSSettings.adoptInstalledApp(youtube, custom: [], selected: [])
        XCTAssertEqual(selectedBuiltIn.custom, [])
        XCTAssertEqual(selectedBuiltIn.selected, [youtube.url])
        let again = IOSSettings.adoptInstalledApp(youtube, custom: selectedBuiltIn.custom, selected: selectedBuiltIn.selected)
        XCTAssertEqual(again.custom, selectedBuiltIn.custom)
        XCTAssertEqual(again.selected, selectedBuiltIn.selected)

        let wechat = try XCTUnwrap(IOSSettings.installedAppCatalog.first { $0.scheme == "weixin" })
        let added = IOSSettings.adoptInstalledApp(wechat, custom: [], selected: [])
        XCTAssertEqual(added.custom, [IOSSettings.Target(title: "微信", url: wechat.url, kind: "App")])
        XCTAssertEqual(added.selected, [wechat.url])
        let addedAgain = IOSSettings.adoptInstalledApp(wechat, custom: added.custom, selected: added.selected)
        XCTAssertEqual(addedAgain.custom, added.custom)
        XCTAssertEqual(addedAgain.selected, added.selected)
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

    func testMultipleTestTargetsAndEmptySelection() throws {
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
        let tiktok = try XCTUnwrap(IOSSettings.builtInTargets.first { $0.title == "TikTok" && $0.kind == "App" })
        let group = IOSSettings.probeGroup(for: tiktok.url)
        XCTAssertTrue(group.matchAny)
        XCTAssertFalse(group.requests.contains { $0.url.contains("www.tiktok.com") })
        XCTAssertTrue(group.requests.allSatisfy { $0.url.contains("tiktokv.com") && $0.anyHTTPStatus })
        XCTAssertEqual(IOSSettings.retiredProbeURLs["https://www.tiktok.com/"], tiktok.url)
        defaults.set(#"["https://www.tiktok.com/"]"#, forKey: IOSSettings.selectedTargetsKey)
        XCTAssertEqual(IOSSettings.selectedTestURLs, ["https://www.tiktok.com/"])
        let chatgpt = IOSSettings.probeGroup(for: "https://chatgpt.com/generate_204")
        XCTAssertTrue(chatgpt.requests.allSatisfy { $0.anyHTTPStatus })
        XCTAssertFalse(IOSSettings.probesAppServer("https://chatgpt.com/generate_204"))
        let youtube = IOSSettings.probeGroup(for: "https://www.youtube.com/generate_204")
        XCTAssertFalse(youtube.matchAny)
        XCTAssertTrue(youtube.requests.contains { $0.url.contains("googlevideo.com") })
        XCTAssertTrue(IOSLatencyProbe.accepts(status: 404, anyHTTPStatus: true))
        XCTAssertFalse(IOSLatencyProbe.accepts(status: 404, anyHTTPStatus: false))
        XCTAssertTrue(IOSLatencyProbe.accepts(status: 204, anyHTTPStatus: false))
        let migrated = IOSSettings.migrateCustomTargets([
            IOSSettings.Target(title: "TikTok", url: "https://www.tiktok.com/", kind: "App"),
            IOSSettings.Target(title: "我的", url: "https://example.com/check", kind: "App")
        ])
        XCTAssertEqual(migrated.map(\.url), ["https://example.com/check"])
        XCTAssertEqual(IOSLatencyProbe.combined([.latency(100), .latency(400)]), .latency(400))
        XCTAssertEqual(IOSLatencyProbe.combined([.latency(100), .unavailable]), .unavailable)
        XCTAssertEqual(IOSLatencyProbe.combined([]), .failed("请先在设置中选择测试目标"))
    }

    func testUsePolicyCombinesAvailabilityExitAndCountry() {
        let saved = (
            IOSSettings.useAvailableOnly, IOSSettings.useExitIPOnly, IOSSettings.useCountryScope,
            IOSSettings.useExcludedCountries, IOSSettings.useIncludedCountries
        )
        defer {
            IOSSettings.useAvailableOnly = saved.0
            IOSSettings.useExitIPOnly = saved.1
            IOSSettings.useCountryScope = saved.2
            IOSSettings.useExcludedCountries = saved.3
            IOSSettings.useIncludedCountries = saved.4
        }
        IOSSettings.useAvailableOnly = false
        IOSSettings.useExitIPOnly = false
        IOSSettings.useCountryScope = .all
        var node = ProxyNode(name: "node", protocolType: .vless, server: "1.2.3.4", port: 443, transport: .tcp, security: .none)
        XCTAssertTrue(IOSSettings.allowsUse(node))
        IOSSettings.useAvailableOnly = true
        XCTAssertFalse(IOSSettings.allowsUse(node))
        node.lastTestStatus = .fast
        node.lastLatency = 100
        XCTAssertTrue(IOSSettings.allowsUse(node))
        IOSSettings.useExitIPOnly = true
        XCTAssertFalse(IOSSettings.allowsUse(node))
        node.exitMetadata = NodeExitMetadata(ip: "1.1.1.1", countryCode: "US")
        XCTAssertTrue(IOSSettings.allowsUse(node))
        IOSSettings.useCountryScope = .excluded
        IOSSettings.useExcludedCountries = ["US"]
        XCTAssertTrue(IOSSettings.outsideCountryScope(node))
        XCTAssertFalse(IOSSettings.allowsUse(node))
        IOSSettings.useCountryScope = .included
        IOSSettings.useIncludedCountries = ["JP"]
        XCTAssertFalse(IOSSettings.allowsUse(node))
        IOSSettings.useIncludedCountries = ["US"]
        XCTAssertTrue(IOSSettings.allowsUse(node))
    }

    func testConnectChoiceSkipsBlockedNodes() {
        let saved = (
            IOSSettings.useAvailableOnly, IOSSettings.useExitIPOnly, IOSSettings.useCountryScope,
            IOSSettings.useIncludedCountries
        )
        defer {
            IOSSettings.useAvailableOnly = saved.0
            IOSSettings.useExitIPOnly = saved.1
            IOSSettings.useCountryScope = saved.2
            IOSSettings.useIncludedCountries = saved.3
        }
        IOSSettings.useAvailableOnly = true
        IOSSettings.useExitIPOnly = true
        IOSSettings.useCountryScope = .included
        IOSSettings.useIncludedCountries = ["JP"]
        var slow = ProxyNode(name: "slow", protocolType: .vless, server: "1.1.1.1", port: 443, transport: .tcp, security: .none)
        slow.lastTestStatus = .slow
        slow.lastLatency = 800
        slow.exitMetadata = NodeExitMetadata(ip: "1.1.1.1", countryCode: "JP")
        var fast = ProxyNode(name: "fast", protocolType: .vless, server: "8.8.8.8", port: 443, transport: .tcp, security: .none)
        fast.lastTestStatus = .fast
        fast.lastLatency = 50
        fast.exitMetadata = NodeExitMetadata(ip: "8.8.8.8", countryCode: "JP")
        var blocked = ProxyNode(name: "blocked", protocolType: .vless, server: "9.9.9.9", port: 443, transport: .tcp, security: .none)
        blocked.lastTestStatus = .ultraFast
        blocked.lastLatency = 10
        blocked.exitMetadata = NodeExitMetadata(ip: "9.9.9.9", countryCode: "US")
        XCTAssertEqual(IOSSettings.blockMessage(blocked), "这个节点不在指定国家里，不能选择。")
        XCTAssertNil(IOSSettings.blockMessage(fast))
        let nodes = [blocked, slow, fast]
        XCTAssertEqual(IOSSettings.connectChoice(selected: nil, in: nodes)?.name, "fast")
        XCTAssertEqual(IOSSettings.connectChoice(selected: slow, in: nodes)?.name, "slow")
        XCTAssertEqual(IOSSettings.connectChoice(selected: blocked, in: nodes)?.name, "fast")
        slow.exitMetadata = nil
        XCTAssertEqual(IOSSettings.nextConnectChoice(after: slow.id, in: [blocked, slow, fast])?.name, "fast")
        fast.exitMetadata = nil
        XCTAssertNil(IOSSettings.nextConnectChoice(after: fast.id, in: [blocked, slow, fast]))
        let timeoutKey = IOSSettings.autoSelectTimeoutKey
        let savedTimeout = UserDefaults.standard.object(forKey: timeoutKey)
        defer {
            if let savedTimeout {
                UserDefaults.standard.set(savedTimeout, forKey: timeoutKey)
            } else {
                UserDefaults.standard.removeObject(forKey: timeoutKey)
            }
        }
        UserDefaults.standard.removeObject(forKey: timeoutKey)
        XCTAssertEqual(IOSSettings.autoSelectTimeoutSeconds, 15)
        IOSSettings.autoSelectTimeoutSeconds = 7
        XCTAssertEqual(IOSSettings.autoSelectTimeoutSeconds, 15)
        IOSSettings.autoSelectTimeoutSeconds = 30
        XCTAssertEqual(IOSSettings.autoSelectTimeoutSeconds, 30)
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

    func testExitLookupParsesCountryFromNodeResponse() async throws {
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
        let leaseweb = Data(#"{"ip":"23.19.230.245","isp":{"asn":"AS395954","org":"Leaseweb USA, Inc."},"location":{"country_code":"US","city":"Los Angeles"},"risk":{"is_mobile":false,"is_vpn":false,"is_tor":false,"is_proxy":false,"is_datacenter":true}}"#.utf8)
        XCTAssertEqual(IOSExitLookup.parse(leaseweb)?.kind, "机房托管")
        let kind = await IOSExitLookup.attribute(forIP: "23.19.230.245", loaders: [
            { _ in nil },
            { _ in leaseweb }
        ])
        XCTAssertEqual(kind, "机房托管")
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
        let fresh = try XCTUnwrap(library.nodes.first { $0.id == nodeID })
        XCTAssertEqual(fresh.resolvedTestStatus, .untested)
        XCTAssertTrue(IOSNodeScope.untested.matches(fresh))
        XCTAssertEqual(IOSNodeTally.make(library.nodes).line, "总 1 · 可用 0 · 不可用 0 · 失败 0 · 未测试 1")
        library.applyProbeResult(nodeID: nodeID, outcome: .latency(1500), announce: false)
        await library.refreshSubscription(subscriptionID)
        let node = try XCTUnwrap(library.nodes.first { $0.id == nodeID })
        XCTAssertEqual(node.lastLatency, 1500)
        XCTAssertTrue(node.resolvedTestStatus.isUsable)
        var tally = IOSNodeTally.make(library.nodes)
        XCTAssertEqual(tally, IOSNodeTally(total: 1, available: 1, unavailable: 0, failed: 0, untested: 0))
        XCTAssertFalse(IOSNodeScope.untested.matches(node))
        library.applyProbeResult(nodeID: nodeID, outcome: .failed("配置无法测"), announce: false)
        tally = IOSNodeTally.make(library.nodes)
        XCTAssertEqual(tally.failed, 1)
        XCTAssertEqual(tally.available, 0)
        XCTAssertEqual(tally.untested, 0)
        XCTAssertTrue(IOSNodeScope.failed.matches(try XCTUnwrap(library.nodes.first)))
        XCTAssertFalse(IOSNodeScope.available.matches(try XCTUnwrap(library.nodes.first)))
    }

    func testAppendAndDeleteShareLinksKeepsTheRest() throws {
        let directory = try makeDirectory()
        let library = IOSLibrary(directory: directory, watchTunnel: false)
        try library.importShareText("trojan://password@a.example:443#A\ntrojan://password@b.example:443#B")
        let id = try XCTUnwrap(library.subscriptions.first?.id)
        let keptID = try XCTUnwrap(library.connectableNodes.first { $0.server == "a.example" }?.id)
        library.select(try XCTUnwrap(library.connectableNodes.first { $0.server == "b.example" }))

        let added = try library.appendShareLinks("trojan://password@c.example:443#C", to: id)
        XCTAssertEqual(added.added, 1)
        XCTAssertEqual(added.nodeIDs, [library.connectableNodes.first { $0.server == "c.example" }?.id].compactMap { $0 })
        XCTAssertEqual(library.connectableNodes.first { $0.server == "a.example" }?.id, keptID)
        XCTAssertEqual(try library.appendShareLinks("trojan://password@b.example:443#B", to: id).added, 0)

        let drop = try XCTUnwrap(library.connectableNodes.first { $0.server == "b.example" })
        library.deleteSubscriptionNodes([drop.id], subscriptionID: id)
        XCTAssertNil(library.selectedNodeID)
        XCTAssertEqual(Set(library.connectableNodes.map(\.server)), ["a.example", "c.example"])
        let text = try XCTUnwrap(library.subscriptions.first?.shareLinksText)
        XCTAssertFalse(text.contains("b.example"))
        XCTAssertTrue(text.contains("a.example"))
        XCTAssertTrue(text.contains("c.example"))

        let reloaded = IOSLibrary(directory: directory, watchTunnel: false)
        XCTAssertEqual(Set(reloaded.connectableNodes.map(\.server)), ["a.example", "c.example"])
        XCTAssertThrowsError(try library.appendShareLinks("hello", to: id))
    }

    func testAppendShareLinksAddsNodeIntoRemoteSubscription() throws {
        let directory = try makeDirectory()
        let id = UUID()
        let subscription = Subscription(id: id, name: "远程", originalURL: "https://example.com/sub.txt", sourceKind: .remoteURL, nodeCount: 0)
        let file = IOSLibraryFile(subscriptions: [subscription], nodes: [], selectedNodeID: nil)
        try JSONEncoder().encode(file).write(to: directory.appendingPathComponent(IOSAppGroup.libraryFileName))
        let library = IOSLibrary(directory: directory, watchTunnel: false)
        let link = "trojan://password@added.example:443#Added"
        let added = try library.appendShareLinks(link, to: id)
        XCTAssertEqual(added.added, 1)
        let node = try XCTUnwrap(library.connectableNodes.first { $0.server == "added.example" })
        XCTAssertEqual(node.subscriptionID, id)
        XCTAssertEqual(added.nodeIDs, [node.id])
        XCTAssertEqual(try library.appendShareLinks(link, to: id).added, 0)
        XCTAssertEqual(library.connectableNodes.filter { $0.server == "added.example" }.count, 1)
        XCTAssertThrowsError(try library.appendShareLinks("hello", to: id))
        let again = IOSLibrary(directory: directory, watchTunnel: false)
        XCTAssertEqual(again.connectableNodes.first { $0.server == "added.example" }?.subscriptionID, id)
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

    func testUnsupportedClientFlagRetriesThenKeepsOtherHTTP400() async throws {
        ClientFlagFixture.reset()
        let session = ClientFlagFixture.session()
        let data = try await IOSSubscriptionClient.fetch("https://fixture.invalid/flag", session: session)
        XCTAssertEqual(String(data: data, encoding: .utf8), "subscription fixture")
        XCTAssertEqual(ClientFlagFixture.recorded(), Array(IOSSubscriptionClient.userAgents.prefix(2)))

        ClientFlagFixture.reset()
        do {
            _ = try await IOSSubscriptionClient.fetch("https://fixture.invalid/flag-none", session: session)
            XCTFail("名单用尽后应保留 HTTP 400")
        } catch let error as IOSSubscriptionError {
            XCTAssertEqual(error.localizedDescription, "HTTP 400")
        }
        XCTAssertEqual(ClientFlagFixture.recorded(), IOSSubscriptionClient.userAgents)

        ClientFlagFixture.reset()
        do {
            _ = try await IOSSubscriptionClient.fetch("https://fixture.invalid/bad", session: session)
            XCTFail("其他 HTTP 400 不能改写")
        } catch let error as IOSSubscriptionError {
            XCTAssertEqual(error.localizedDescription, "HTTP 400")
        }
        XCTAssertEqual(ClientFlagFixture.recorded(), [IOSSubscriptionClient.userAgents[0]])
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hopworld-ios-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class ClientFlagFixture: URLProtocol {
    private static let lock = NSLock()
    private static var agents: [String] = []

    static func reset() {
        lock.lock()
        agents = []
        lock.unlock()
    }

    static func recorded() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return agents
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ClientFlagFixture.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let agent = request.value(forHTTPHeaderField: "User-Agent") ?? ""
        Self.lock.lock()
        Self.agents.append(agent)
        Self.lock.unlock()
        let path = request.url?.path ?? ""
        let accepted = path == "/flag" && agent == "clash-meta/1.18.0"
        if accepted {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("subscription fixture".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let body = path == "/bad"
            ? Data("bad token".utf8)
            : Data("bad request: unsupported client flag: \(agent)".utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
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

private final class LocalProxyCatcher: @unchecked Sendable {
    let port: Int
    private let fd: Int32
    private let lock = NSLock()
    private var line: String?
    private var waiters: [CheckedContinuation<String, Never>] = []

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw URLError(.cannotConnectToHost) }
        self.fd = fd
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw URLError(.cannotConnectToHost)
        }
        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else {
            Darwin.close(fd)
            throw URLError(.cannotConnectToHost)
        }
        port = Int(UInt16(bigEndian: boundAddress.sin_port))
        Thread { [self] in
            var clientAddress = sockaddr_in()
            var clientLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &clientAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(fd, $0, &clientLength)
                }
            }
            guard client >= 0 else {
                finish("")
                return
            }
            var buffer = [UInt8](repeating: 0, count: 512)
            let count = read(client, &buffer, buffer.count)
            Darwin.close(client)
            finish(count > 0 ? String(decoding: buffer.prefix(count), as: UTF8.self) : "")
        }.start()
    }

    func close() { Darwin.close(fd) }

    func firstLine() async -> String {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let line {
                lock.unlock()
                continuation.resume(returning: line)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func finish(_ text: String) {
        lock.lock()
        line = text
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume(returning: text) }
    }
}
