import XCTest

final class ComponentReleaseTests: XCTestCase {
    func testOnlyStableNumericVersionsAndCompleteDigestsAreAccepted() throws {
        for tag in ["v../../tmp", "v1.14.4-rc1", "1.14", "v1.14.-4"] {
            XCTAssertThrowsError(try release(tag).version(for: .singBox))
        }
        XCTAssertEqual(try release("v1.14.4").version(for: .singBox), "1.14.4")
        XCTAssertEqual(try release("202610242205").version(for: .geoFiles), "202610242205")
        for tag in ["latest", "20261024", "../202610242205", "20261024220x"] {
            XCTAssertThrowsError(try release(tag).version(for: .geoFiles))
        }
        XCTAssertThrowsError(try release("v1.14.4", prerelease: true).version(for: .singBox))
        XCTAssertThrowsError(try release("202610242205", draft: true).version(for: .geoFiles))
        let asset = ComponentRelease.Asset(name: "geoip.dat", digest: "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertNoThrow(try asset.verify(Data("abc".utf8)))
        XCTAssertThrowsError(try asset.verify(Data("corrupt".utf8)))
        XCTAssertThrowsError(try asset.verify(Data()))
        XCTAssertThrowsError(try ComponentRelease.Asset(name: "geoip.dat", digest: nil).verify(Data("abc".utf8)))
    }

    func testUpdateSelectionNeverDowngradesAndRestrictsSingBoxToPinnedVersion() {
        XCTAssertEqual(UpdateComponent.singBox.installVersion(latest: "1.14.4", installed: "1.14.2"), "1.14.4")
        XCTAssertEqual(UpdateComponent.singBox.installVersion(latest: "1.15.0", installed: nil), "1.14.4")
        XCTAssertNil(UpdateComponent.singBox.installVersion(latest: "1.14.4", installed: "1.14.4"))
        XCTAssertNil(UpdateComponent.singBox.installVersion(latest: "1.14.4", installed: "1.15.0"))
        XCTAssertNil(UpdateComponent.singBox.installVersion(latest: "1.14.2", installed: nil))
        XCTAssertEqual(UpdateComponent.geoFiles.installVersion(latest: "202610252205", installed: "202610242205"), "202610252205")
        XCTAssertNil(UpdateComponent.geoFiles.installVersion(latest: "202610242205", installed: "202610252205"))
        XCTAssertNil(UpdateComponent.geoFiles.installVersion(latest: "202610242205", installed: "202610242205"))
        XCTAssertNil(UpdateComponent.geoFiles.installVersion(latest: nil, installed: nil))
    }

    func testRulesSwitchAsAPairAndFailedNativeValidationPreservesOldSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rules-update-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("download")
        let managed = root.appendingPathComponent("rules")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let binary = root.appendingPathComponent("xray")
        // This fixture reads the exact asset directory passed to the native validation command.
        let script = #"""
        #!/bin/sh
        test "$1" = run || exit 1
        test "$2" = -test || exit 1
        test "$(cat "$XRAY_LOCATION_ASSET/geoip.dat")" = good-ip || exit 2
        test "$(cat "$XRAY_LOCATION_ASSET/geosite.dat")" = good-site || exit 3
        """#
        try Data(script.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        func rules(_ ip: String, _ site: String) throws {
            try Data(ip.utf8).write(to: source.appendingPathComponent("geoip.dat"))
            try Data(site.utf8).write(to: source.appendingPathComponent("geosite.dat"))
        }
        try rules("good-ip", "good-site")
        try await GeoFilesInstaller.activate(from: source, version: "202610242205", binary: binary, root: managed)
        let first = try XCTUnwrap(GeoFilesInstaller.currentDirectory(in: managed))
        XCTAssertEqual(try String(contentsOf: first.appendingPathComponent("version.txt")), "202610242205")
        try await GeoFilesInstaller.activate(from: source, version: "202610252205", binary: binary, root: managed)
        let second = try XCTUnwrap(GeoFilesInstaller.currentDirectory(in: managed))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try String(contentsOf: first.appendingPathComponent("geoip.dat")), "good-ip")
        for (ip, site) in [("corrupt", "good-site"), ("good-ip", ""), ("good-ip", "corrupt")] {
            try rules(ip, site)
            do {
                try await GeoFilesInstaller.activate(from: source, version: "202610262205", binary: binary, root: managed)
                XCTFail("A failed pair must not activate")
            } catch { }
            XCTAssertEqual(GeoFilesInstaller.currentDirectory(in: managed), second)
        }
        let entries = try FileManager.default.contentsOfDirectory(atPath: managed.path)
        XCTAssertEqual(entries.count, 3, "Only the two immutable snapshots and current link should remain")
    }

    func testSingBoxRejectsWrongVersionAndIncompatibleConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("singbox-update-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("sing-box")
        func script(_ contents: String) throws {
            try Data(("#!/bin/sh\n" + contents).utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
        try script("echo 'sing-box version 1.14.2'\n")
        do {
            try await SingBoxInstaller.validateCompatibility(binary: binary)
            XCTFail("Wrong binary version must reject the candidate")
        } catch { }
        try script("if [ \"$1\" = version ]; then echo 'sing-box version 1.14.4'; exit 0; fi\nexit 1\n")
        do {
            try await SingBoxInstaller.validateCompatibility(binary: binary)
            XCTFail("A failed native config check must reject the candidate")
        } catch { }
    }

    func testRealApprovedSingBoxConfigurations() async throws {
        guard let path = ProcessInfo.processInfo.environment["HOPWORLD_TEST_APPROVED_SING_BOX"] else {
            throw XCTSkip("Set HOPWORLD_TEST_APPROVED_SING_BOX to validate the real approved core")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("approved-singbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("sing-box")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: binary)
        try await SingBoxInstaller.validateCompatibility(binary: binary)
    }

    func testRealPreparedArchiveUsesTheSelectedPinnedVersion() async throws {
        guard let expected = ProcessInfo.processInfo.environment["HOPWORLD_TEST_SELECTED_SING_BOX"] else {
            throw XCTSkip("Set HOPWORLD_TEST_SELECTED_SING_BOX to validate selected archive preparation")
        }
        XCTAssertEqual(SingBoxInstaller.selectedVersion, expected)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("selected-singbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = try await SingBoxInstaller.prepare(in: root)
        let result = try await ProcessRunner.run(executable: binary, arguments: ["version"], timeout: 5)
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(String(decoding: result.output, as: UTF8.self).contains("sing-box version " + expected))
        XCTAssertEqual(try SingBoxInstaller.digest(root.appendingPathComponent("release.tar.gz")),
                       SingBoxInstaller.expectedDigest(version: expected))
    }

    func testRealRulesAreAcceptedAndCorruptRulesPreserveThePreviousVersion() async throws {
        guard let path = ProcessInfo.processInfo.environment["HOPWORLD_TEST_RULES_DIRECTORY"] else {
            throw XCTSkip("Set HOPWORLD_TEST_RULES_DIRECTORY to validate official rule data")
        }
        let source = URL(fileURLWithPath: path)
        let binary = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("HopWorld/Resources/xray")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw XCTSkip("Local Xray unavailable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("real-rules-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try await GeoFilesInstaller.activate(from: source, version: "202610242205", binary: binary, root: root)
        let before = try XCTUnwrap(GeoFilesInstaller.currentDirectory(in: root))
        let corrupt = root.appendingPathComponent("corrupt")
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("corrupt-protobuf".utf8).write(to: corrupt.appendingPathComponent("geoip.dat"))
        try FileManager.default.copyItem(at: source.appendingPathComponent("geosite.dat"), to: corrupt.appendingPathComponent("geosite.dat"))
        do {
            try await GeoFilesInstaller.activate(from: corrupt, version: "202610252205", binary: binary, root: root)
            XCTFail("Real Xray must reject corrupted rule data")
        } catch { }
        XCTAssertEqual(GeoFilesInstaller.currentDirectory(in: root), before)
    }

    private func release(_ tag: String, draft: Bool = false, prerelease: Bool = false) -> ComponentRelease {
        ComponentRelease(tag_name: tag, draft: draft, prerelease: prerelease, assets: [])
    }
}

@MainActor
final class ComponentUpdatePreferenceTests: XCTestCase {
    func testAutomaticUpdateSwitchesPersistIndependentlyAndPreserveXrayDefault() throws {
        let suite = "component-update-preferences-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let xray = XrayUpdateManager(defaults: defaults)
        let singBox = ComponentUpdateManager(.singBox, defaults: defaults)
        let rules = ComponentUpdateManager(.geoFiles, defaults: defaults)
        XCTAssertTrue(xray.automaticUpdates)
        XCTAssertTrue(singBox.automaticUpdates)
        XCTAssertTrue(rules.automaticUpdates)
        singBox.automaticUpdates = false
        XCTAssertFalse(ComponentUpdateManager(.singBox, defaults: defaults).automaticUpdates)
        XCTAssertTrue(ComponentUpdateManager(.geoFiles, defaults: defaults).automaticUpdates)
        XCTAssertTrue(XrayUpdateManager(defaults: defaults).automaticUpdates)
        xray.automaticUpdates = false
        rules.automaticUpdates = false
        XCTAssertFalse(XrayUpdateManager(defaults: defaults).automaticUpdates)
        XCTAssertFalse(ComponentUpdateManager(.geoFiles, defaults: defaults).automaticUpdates)
    }
}
