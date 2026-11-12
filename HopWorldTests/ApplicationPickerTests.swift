import XCTest

final class ApplicationPickerTests: XCTestCase {
    private let app = ApplicationPickerEntry(url: URL(fileURLWithPath: "/Applications/Codex.app"),
                                             name: "Codex", bundleIdentifier: "com.example.codex")

    func testEmptyAndWhitespaceQueriesShowApplications() {
        XCTAssertTrue(app.matches(""))
        XCTAssertTrue(app.matches("  \n\t"))
    }

    func testSearchMatchesNameIdentifierAndPathCaseInsensitively() {
        XCTAssertTrue(app.matches("CODEX"))
        XCTAssertTrue(app.matches("example.codex"))
        XCTAssertTrue(app.matches("/Applications/"))
        XCTAssertTrue(app.matches(" codex   example "))
        XCTAssertFalse(app.matches("codex safari"))
        XCTAssertFalse(app.matches("Safari"))
    }

    func testLocalizedNameStillMatchesOriginalBundleName() {
        let app = ApplicationPickerEntry(url: URL(fileURLWithPath: "/Applications/HopWorld.app"),
                                         name: "跃界", bundleIdentifier: "com.hopworld.app")
        XCTAssertTrue(app.matches("跃界"))
        XCTAssertTrue(app.matches("HopWorld"))
        XCTAssertTrue(app.matches("跃界 hopworld"))
    }
}


final class AutomaticAppProbeSelectionTests: XCTestCase {
    func testAutomaticProbesDefaultOffAndRespectSavedChoice() throws {
        XCTAssertFalse(AppSettings().autoAppProbeUsableNodes)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        let store = PersistenceStore(directory: directory)
        try Data("{}".utf8).write(to: file)
        XCTAssertFalse(store.loadSettings().autoAppProbeUsableNodes)
        try Data("{\"autoAppProbeUsableNodes\":true}".utf8).write(to: file)
        XCTAssertTrue(store.loadSettings().autoAppProbeUsableNodes)
        try Data("{\"autoAppProbeUsableNodes\":false}".utf8).write(to: file)
        XCTAssertFalse(store.loadSettings().autoAppProbeUsableNodes)
    }

    func testAvailableProbeGroupsUseActiveNodesAndKeepOrphanSourcesSeparate() {
        let subscription = Subscription(name: "同名组", originalURL: "https://example.com")
        func node() -> ProxyNode {
            ProxyNode(name: "grouped", protocolType: .vless, server: "example.com", port: 443,
                      subscriptionID: subscription.id, lastTestStatus: .fast)
        }
        let grouped = node()
        var unavailable = node()
        unavailable.lastTestStatus = .unavailable
        var disabled = node()
        disabled.enabled = false
        var removed = node()
        removed.pendingRemoval = true
        var orphan = node()
        orphan.subscriptionID = UUID()
        orphan.sourceName = subscription.name
        var manual = node()
        manual.subscriptionID = nil
        let nodes = [grouped, unavailable, disabled, removed, orphan, manual]
        func available(_ source: NodeListFilter.Source) -> [UUID] {
            NodeListFilter.nodes(in: nodes, source: source, subscriptions: [subscription])
                .filter { $0.lastTestStatus.isUsable }.map(\.id)
        }
        XCTAssertEqual(available(.all), [grouped.id, orphan.id, manual.id])
        var disabledSubscription = subscription
        disabledSubscription.isEnabled = false
        XCTAssertEqual(
            NodeListFilter.nodes(in: nodes, source: .all, subscriptions: [disabledSubscription]).map(\.id),
            [orphan.id, manual.id]
        )
        XCTAssertEqual(available(.subscription(subscription.id)), [grouped.id])
        XCTAssertEqual(available(.namedSource(subscription.name)), [orphan.id])
        XCTAssertEqual(available(.manual), [manual.id])
        XCTAssertTrue(available(.subscription(UUID())).isEmpty)
    }

    private func application(_ name: String) throws -> ProxyApplication {
        let data = try JSONSerialization.data(withJSONObject: [
            "path": "/Applications/\(name).app", "name": name, "isBundle": true
        ])
        return try JSONDecoder().decode(ProxyApplication.self, from: data)
    }

    func testDefaultsRetainOriginalServices() {
        XCTAssertEqual(AppSettings().automaticAppProbeTargets, AppProbeTarget.allCases)
    }

    func testRuleApplicationsTakePriorityAndCustomTargetsDeduplicate() throws {
        var settings = AppSettings()
        let github = try application("GitHub")
        settings.proxyApplications = [github]
        XCTAssertEqual(settings.automaticAppProbeTargets.map(\.displayName), ["GitHub"])
        settings.installedAppProbes = [InstalledAppProbe(application: github, endpoint: "https://example.com")]
        XCTAssertEqual(settings.automaticAppProbeTargets.count, 1)
        XCTAssertEqual(settings.automaticAppProbeTargets.first?.probeURL.host, "example.com")
    }

    func testCustomApplicationAndInvalidEndpoint() throws {
        var settings = AppSettings()
        let custom = try application("Custom")
        settings.appProbeSource = .custom
        settings.installedAppProbes = [InstalledAppProbe(application: custom, endpoint: "https://example.com")]
        XCTAssertEqual(settings.automaticAppProbeTargets.map(\.displayName), ["Custom"])
        settings.proxyApplications = [custom]
        settings.installedAppProbes[0].endpoint = "file:///tmp/test"
        XCTAssertTrue(settings.automaticAppProbeTargets.isEmpty)
        XCTAssertEqual(settings.allAppProbeTargets.count, 1, "未配置目标应保留供用户编辑")
    }

    func testBlankRuleOverridePreservesRecognizedServiceEndpoint() throws {
        var settings = AppSettings()
        let chatgpt = try application("ChatGPT")
        settings.appProbeSource = .rules
        settings.proxyApplications = [chatgpt]
        for endpoint in ["", "   ", "file:///tmp/test"] {
            settings.installedAppProbes = [InstalledAppProbe(application: chatgpt, endpoint: endpoint)]
            XCTAssertEqual(settings.automaticAppProbeTargets.count, 1)
            XCTAssertEqual(settings.automaticAppProbeTargets.first?.probeURLs, [AppProbeTarget.chatgpt.probeURL])
        }
        settings.appProbeDisabledTargetIDs = [chatgpt.id]
        XCTAssertTrue(settings.automaticAppProbeTargets.isEmpty)
    }

    func testUnknownRuleApplicationRequiresConfiguredEndpoint() throws {
        var settings = AppSettings()
        let unknown = try application("Unknown")
        settings.appProbeSource = .rules
        settings.proxyApplications = [unknown]
        settings.installedAppProbes = [InstalledAppProbe(application: unknown, endpoint: "")]
        XCTAssertTrue(settings.automaticAppProbeTargets.isEmpty)
        XCTAssertEqual(settings.allAppProbeTargets.map(\.id), [unknown.id])
        settings.installedAppProbes[0].endpoint = "https://example.com/"
        XCTAssertEqual(settings.automaticAppProbeTargets.first?.probeURL.host, "example.com")
    }

    func testUnconfiguredApplicationIsUntestedInsteadOfUnreachable() async {
        let target = AppProbeTarget.application(path: "/fixture/unknown", name: "Unknown", url: nil)
        let result = await AppProbeRunner.probeOne(target: target, proxyHost: "127.0.0.1",
                                                 httpPort: 1, socksPort: nil, timeout: 1)
        XCTAssertEqual(result.status, .untested)
        XCTAssertNil(result.testedAt)
        XCTAssertNil(result.latencyMs)
    }
}


extension AutomaticAppProbeSelectionTests {
    func testSourceDefaultsToRulesButRespectsManualOverride() throws {
        var settings = AppSettings()
        XCTAssertEqual(settings.effectiveAppProbeSource, .defaults)
        settings.proxyApplications = [try application("GitHub")]
        XCTAssertEqual(settings.effectiveAppProbeSource, .rules)
        settings.appProbeSource = .defaults
        XCTAssertEqual(settings.automaticAppProbeTargets, AppProbeTarget.allCases)
        settings.appProbeSource = .custom
        XCTAssertTrue(settings.automaticAppProbeTargets.isEmpty)
        XCTAssertTrue(settings.customAppProbeListIsEmpty)
        XCTAssertEqual(AppSettings.emptyCustomAppProbeNote, "自定义应用为空，不测试应用。")
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.effectiveAppProbeSource, .custom)
    }
}


final class AppProbePriorityTests: XCTestCase {
    func testEarlierApplicationWinsEvenWithHigherLatencyAndFewerPasses() {
        var codex = ProxyNode(name: "Codex node", protocolType: .vless, server: "example.com", port: 443)
        codex.lastLatency = 900
        codex.lastAppProbePassedIDs = ["codex"]
        var google = ProxyNode(name: "Google node", protocolType: .vless, server: "example.com", port: 443)
        google.lastLatency = 10
        google.lastAppProbePassedIDs = ["google", "github", "cursor"]
        let order = ["codex", "google", "github", "cursor"]
        XCTAssertTrue(ProxyNode.autoSelectLessThan(codex, google, considerAppProbe: true, appOrder: order))
        XCTAssertFalse(ProxyNode.autoSelectLessThan(google, codex, considerAppProbe: true, appOrder: order))
        XCTAssertTrue(ProxyNode.autoSelectLessThan(google, codex, considerAppProbe: false, appOrder: order))
        XCTAssertTrue(ProxyNode.autoSelectLessThan(google, codex, considerAppProbe: true, appOrder: ["google", "codex"]))
        google.lastAppProbePassedIDs = codex.lastAppProbePassedIDs
        XCTAssertTrue(ProxyNode.autoSelectLessThan(google, codex, considerAppProbe: true, appOrder: order))
    }

    func testSavedApplicationOrderSurvivesReload() throws {
        var settings = AppSettings()
        settings.appProbeSource = .defaults
        settings.appProbeOrder[AppProbeSource.defaults.rawValue] = ["GitHub", "Google"]
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(Array(restored.automaticAppProbeTargets.prefix(2)), [.github, .google])
        XCTAssertEqual(Set(restored.automaticAppProbeTargets), Set(AppProbeTarget.allCases))
    }
}


final class SettingsDraftCommitTests: XCTestCase {
    func testCommitPreservesBackgroundUpdatesAndUneditedFields() {
        let baseline = AppSettings()
        var draft = baseline
        draft.scheduledTestIntervalMinutes = 60
        draft.autoSelectCountryScope = .specified
        draft.autoSelectIncludedCountryCodes = ["US"]
        var current = baseline
        current.lastScheduledTestAt = Date(timeIntervalSince1970: 1234)
        current.testConcurrency = 8
        current.nodeListCategoryRaw = "available@@all"
        let saved = current.applyingSettingsEdits(from: draft, comparedTo: baseline)
        XCTAssertEqual(saved.scheduledTestIntervalMinutes, 60)
        XCTAssertEqual(saved.autoSelectIncludedCountryCodes, ["US"])
        XCTAssertEqual(saved.lastScheduledTestAt, current.lastScheduledTestAt)
        XCTAssertEqual(saved.testConcurrency, 8)
        XCTAssertEqual(saved.nodeListCategoryRaw, current.nodeListCategoryRaw)
        XCTAssertEqual(baseline.scheduledTestIntervalMinutes, 30)
    }

    func testUnchangedDraftDoesNotOverwriteConcurrentChanges() {
        let baseline = AppSettings()
        var current = baseline
        current.autoFailover = !baseline.autoFailover
        XCTAssertEqual(current.applyingSettingsEdits(from: baseline, comparedTo: baseline), current)
    }
}


extension SettingsDraftCommitTests {
    func testApplicationAndPortDraftsOnlyCommitEditedFields() {
        let baseline = AppSettings()
        var draft = baseline
        draft.appProbeSource = .custom
        draft.appProbeOrder = ["custom": ["codex", "google"]]
        draft.httpPort = 13000
        var current = baseline
        current.appProbeTimeoutSeconds = 12
        current.socksPort = 14000
        current.lastScheduledTestAt = Date(timeIntervalSince1970: 5678)
        let saved = current.applyingSettingsEdits(from: draft, comparedTo: baseline)
        XCTAssertEqual(saved.appProbeSource, .custom)
        XCTAssertEqual(saved.appProbeOrder, draft.appProbeOrder)
        XCTAssertEqual(saved.httpPort, 13000)
        XCTAssertEqual(saved.socksPort, 14000)
        XCTAssertEqual(saved.appProbeTimeoutSeconds, 12)
        XCTAssertEqual(saved.lastScheduledTestAt, current.lastScheduledTestAt)
        draft = baseline
        XCTAssertEqual(baseline.applyingSettingsEdits(from: draft, comparedTo: baseline), baseline)
    }
}
