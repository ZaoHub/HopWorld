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
        XCTAssertTrue(settings.automaticAppProbeTargets.allSatisfy { $0.probeURLs.isEmpty })
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
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.effectiveAppProbeSource, .custom)
    }
}
