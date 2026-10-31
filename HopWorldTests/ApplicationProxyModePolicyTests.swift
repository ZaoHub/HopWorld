import XCTest

final class ApplicationProxyModePolicyTests: XCTestCase {
    func testSettingsPreserveCountryFiltersAfterScheduledTestAndUpgrade() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = AppSettings()
        settings.autoSelectExcludedCountryCodes = ["CN", "HK"]
        settings.autoSelectMinimumSpeed = .fairlyFast
        settings.lastScheduledTestAt = Date(timeIntervalSince1970: 1_790_000_000)
        for strategy in [JSONEncoder.DateEncodingStrategy.iso8601, .deferredToDate] {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = strategy
            let data = try encoder.encode(settings)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            object.removeValue(forKey: "autoSelectUnhealthySeconds")
            try JSONSerialization.data(withJSONObject: object).write(to: directory.appendingPathComponent("settings.json"))
            let loaded = PersistenceStore(directory: directory).loadSettings()
            XCTAssertEqual(loaded.autoSelectExcludedCountryCodes, settings.autoSelectExcludedCountryCodes)
            XCTAssertEqual(loaded.autoSelectMinimumSpeed, .fairlyFast)
            XCTAssertEqual(loaded.lastScheduledTestAt, settings.lastScheduledTestAt)
            XCTAssertEqual(loaded.autoSelectUnhealthySeconds, 30)
        }
    }

    func testApplicationProxyIsOfferedOnlyInRulesMode() {
        for mode in RoutingMode.allCases {
            var settings = AppSettings()
            settings.routingMode = mode
            XCTAssertEqual(settings.supportsApplicationProxy, mode == .rules)
        }
    }

    func testLeavingRulesChoosesFullCaptureOrSystemProxyAndKeepsWhitelist() throws {
        for mode in [RoutingMode.global, .direct] {
            var settings = AppSettings()
            settings.routingMode = .rules
            settings.connectionCaptureMode = .applications
            settings.proxyApplications = [try ProxyApplication(url: URL(fileURLWithPath: "/usr/bin/curl"))]
            let saved = settings.proxyApplications
            settings.selectRoutingMode(mode)
            XCTAssertEqual(settings.connectionCaptureMode, mode == .global ? .globalTun : .systemProxy)
            XCTAssertEqual(settings.routingMode, mode)
            XCTAssertEqual(settings.proxyApplications, saved)
            settings.selectRoutingMode(.rules)
            XCTAssertEqual(settings.connectionCaptureMode, .applications,
                           "返回规则模式且名单非空时恢复应用白名单，避免仍显示名单却走系统代理")
            XCTAssertEqual(settings.proxyApplications, saved)
        }
    }

    func testReturningToRulesWithoutWhitelistStaysOnSystemProxy() {
        var settings = AppSettings()
        settings.routingMode = .global
        settings.connectionCaptureMode = .globalTun
        settings.selectRoutingMode(.rules)
        XCTAssertEqual(settings.connectionCaptureMode, .systemProxy)
        XCTAssertTrue(settings.proxyApplications.isEmpty)
    }

    func testExplicitSystemProxyInRulesSurvivesNormalization() throws {
        var settings = AppSettings()
        settings.routingMode = .rules
        settings.connectionCaptureMode = .systemProxy
        settings.proxyApplications = [try ProxyApplication(url: URL(fileURLWithPath: "/usr/bin/curl"))]
        settings.normalizeApplicationProxyMode()
        XCTAssertEqual(settings.connectionCaptureMode, .systemProxy,
                       "规则模式下主动恢复系统代理后，normalize 不得擅自改回应用白名单")
    }

    func testNormalizationDoesNotChangeValidRulesCapture() {
        var settings = AppSettings()
        settings.routingMode = .rules
        settings.connectionCaptureMode = .applications
        settings.normalizeApplicationProxyMode()
        XCTAssertEqual(settings.connectionCaptureMode, .applications)
    }

    func testLoadingLegacyCaptureSelectsGlobalTunOrSystemProxy() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistenceStore(directory: directory)
        for mode in [RoutingMode.global, .direct] {
            var settings = AppSettings()
            settings.routingMode = mode
            settings.connectionCaptureMode = .applications
            settings.proxyApplications = [try ProxyApplication(url: URL(fileURLWithPath: "/usr/bin/curl"))]
            try JSONEncoder().encode(settings).write(to: directory.appendingPathComponent("settings.json"))
            let loaded = store.loadSettings()
            XCTAssertEqual(loaded.routingMode, mode)
            XCTAssertEqual(loaded.connectionCaptureMode, mode == .global ? .globalTun : .systemProxy)
            XCTAssertEqual(loaded.proxyApplications, settings.proxyApplications)
        }
    }
    func testEveryCaptureModeNormalizesToFullTunInGlobalMode() {
        for capture in ConnectionCaptureMode.allCases {
            var settings = AppSettings()
            settings.connectionCaptureMode = capture
            settings.selectRoutingMode(.global)
            XCTAssertEqual(settings.connectionCaptureMode, .globalTun)
            XCTAssertTrue(settings.proxyApplications.isEmpty)
            settings.normalizeApplicationProxyMode()
            XCTAssertEqual(settings.connectionCaptureMode, .globalTun)
            for next in [RoutingMode.rules, .direct] {
                settings.selectRoutingMode(.global)
                settings.selectRoutingMode(next)
                XCTAssertEqual(settings.connectionCaptureMode, .systemProxy)
            }
        }
    }

    func testLoadingLegacyGlobalSystemProxyMigratesToTun() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = AppSettings()
        settings.routingMode = .global
        settings.connectionCaptureMode = .systemProxy
        try JSONEncoder().encode(settings).write(to: directory.appendingPathComponent("settings.json"))
        let store = PersistenceStore(directory: directory)
        let loaded = store.loadSettings()
        XCTAssertEqual(loaded.connectionCaptureMode, .globalTun)
        store.saveSettings(loaded)
        XCTAssertEqual(store.loadSettings().connectionCaptureMode, .globalTun)
    }

}
