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
            XCTAssertEqual(settings.connectionCaptureMode, .systemProxy, "返回规则模式不自动启用 TUN 或请求授权")
            XCTAssertEqual(settings.proxyApplications, saved)
        }
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
