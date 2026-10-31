import XCTest
import Darwin

final class ApplicationProxyTests: XCTestCase {
    func testSettingsMigrationKeepsExistingValuesAndPersistsWhitelist() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = AppSettings()
        settings.httpPort = 11809
        settings.routingMode = .direct
        var oldJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        oldJSON.removeValue(forKey: "proxyApplications")
        let file = directory.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: oldJSON).write(to: file)
        let store = PersistenceStore(directory: directory)
        XCTAssertEqual(store.loadSettings().httpPort, 11809)
        XCTAssertEqual(store.loadSettings().routingMode, .direct)
        XCTAssertTrue(store.loadSettings().proxyApplications.isEmpty)
        settings.connectionCaptureMode = .applications
        settings.routingMode = .rules
        settings.proxyApplications = [try ProxyApplication(url: URL(fileURLWithPath: "/usr/bin/curl"))]
        try JSONEncoder().encode(settings).write(to: file)
        XCTAssertEqual(store.loadSettings().connectionCaptureMode, .applications)
        XCTAssertEqual(store.loadSettings().proxyApplications, settings.proxyApplications)
    }

    private func fixtureDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tun-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }

    private func controlFiles(_ directory: URL) throws -> (URL, URL) {
        let lease = directory.appendingPathComponent("lease")
        let status = directory.appendingPathComponent("status")
        for file in [lease, status] {
            XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data("pulse".utf8), attributes: [.posixPermissions: 0o600]))
        }
        return (lease, status)
    }

    func testExactExecutableAndBundleRegexDoNotMatchOtherApps() throws {
        let app = try JSONDecoder().decode(ProxyApplication.self, from: Data(
            #"{"path":"/Applications/Code[x]+.app","name":"fixture","isBundle":true}"#.utf8))
        let regex = try NSRegularExpression(pattern: app.pathRegex)
        func matches(_ path: String) -> Bool { regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil }
        XCTAssertTrue(matches("/Applications/Code[x]+.app/Contents/MacOS/Codex"))
        XCTAssertTrue(matches("/Applications/Code[x]+.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"))
        XCTAssertFalse(matches("/Applications/Code[x]+.app.evil/Contents/MacOS/Codex"))
        XCTAssertFalse(matches("/Applications/Other.app/Contents/MacOS/Codex"))
        XCTAssertFalse(matches("/usr/bin/curl"))
        let executable = try ProxyApplication(url: URL(fileURLWithPath: "/usr/bin/curl"))
        XCTAssertFalse(executable.isBundle)
        XCTAssertTrue(executable.pathRegex.hasSuffix("$"))
        XCTAssertThrowsError(try ProxyApplication(url: URL(fileURLWithPath: "/Applications")))
    }

    func testApplicationWhitelistKeepsSharedDNSDirectEvenWhenNodeIsUnavailable() throws {
        let app = try ProxyApplication(url: URL(fileURLWithPath: "/usr/bin/curl"))
        let config = try ApplicationProxyConfig.build(applications: [app], socksPort: 12001, password: "fixture", bypassExecutables: ["/fixture/xray"])
        let route = try XCTUnwrap(config["route"] as? [String: Any])
        XCTAssertEqual(route["final"] as? String, "direct")
        XCTAssertEqual(route["auto_detect_interface"] as? Bool, true)
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.first?["process_path"] as? [String], ["/fixture/xray"])
        XCTAssertEqual(rules.first?["outbound"] as? String, "direct")
        XCTAssertEqual(rules.last?["process_path_regex"] as? [String], [app.pathRegex])
        XCTAssertEqual(rules.last?["outbound"] as? String, "selected-apps")
        XCTAssertNil(config["dns"])
        XCTAssertNil(route["default_domain_resolver"])
        XCTAssertEqual(rules[1]["port"] as? [Int], [53])
        XCTAssertEqual(rules[1]["action"] as? String, "route")
        XCTAssertEqual(rules[1]["outbound"] as? String, "direct")
        XCTAssertEqual(rules[2]["ip_is_private"] as? Bool, true)
        let tun = try XCTUnwrap((config["inbounds"] as? [[String: Any]])?.first)
        XCTAssertEqual(tun["dns_mode"] as? String, "disabled")
        XCTAssertEqual((tun["address"] as? [String])?.count, 2)
        XCTAssertNil(tun["platform"])
        XCTAssertThrowsError(try ApplicationProxyConfig.build(applications: [], socksPort: 12001, password: "fixture", bypassExecutables: []))
    }


    func testGlobalTunIgnoresWhitelistAndCapturesUnknownProcessesWithDNS() throws {
        let stale = try JSONDecoder().decode(ProxyApplication.self, from: Data(
            #"{"path":"/missing/Cursor.app","name":"Cursor","isBundle":true}"#.utf8))
        for apps in [[], [stale]] {
            let config = try ApplicationProxyConfig.build(applications: apps, socksPort: 12001,
                password: "fixture", bypassExecutables: ["/fixture/xray"], captureAll: true,
                bootstrapDomains: ["node.example"])
            let route = try XCTUnwrap(config["route"] as? [String: Any])
            XCTAssertEqual(route["final"] as? String, "selected-apps")
            let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
            XCTAssertEqual(rules.first?["process_path"] as? [String], ["/fixture/xray"])
            XCTAssertEqual(rules.first?["outbound"] as? String, "direct")
            XCTAssertFalse(rules.contains { $0["process_path_regex"] != nil || $0["ip_is_private"] != nil })
            XCTAssertEqual(rules.last?["action"] as? String, "hijack-dns")
            let tun = try XCTUnwrap((config["inbounds"] as? [[String: Any]])?.first)
            XCTAssertEqual(tun["dns_mode"] as? String, "hijack")
            XCTAssertEqual(tun["auto_route"] as? Bool, true)
            XCTAssertEqual((tun["address"] as? [String])?.count, 2)
            let dns = try XCTUnwrap(config["dns"] as? [String: Any])
            XCTAssertEqual(dns["final"] as? String, "remote-dns")
            XCTAssertEqual((dns["rules"] as? [[String: Any]])?.first?["domain"] as? [String], ["node.example"])
            let servers = try XCTUnwrap(dns["servers"] as? [[String: Any]])
            XCTAssertEqual(servers.first?["detour"] as? String, "selected-apps")
        }
    }

    func testRealSingBoxAcceptsGeneratedConfigurationWithoutStartingTUN() async throws {
        guard let path = ProcessInfo.processInfo.environment["HOPWORLD_TEST_SING_BOX"] else {
            throw XCTSkip("设置 HOPWORLD_TEST_SING_BOX 可运行真实核心配置校验")
        }
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for captureAll in [false, true] {
            let config = try ApplicationProxyConfig.build(applications: [ProxyApplication(url: URL(fileURLWithPath: "/usr/bin/curl"))],
                socksPort: 12001, password: "fixture", bypassExecutables: ["/fixture/xray"],
                captureAll: captureAll, bootstrapDomains: ["node.example"])
            let file = directory.appendingPathComponent("config.json")
            try XrayConfigBuilder.writeJSON(config, to: file)
            let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: path), arguments: ["check", "-c", file.path], timeout: 5)
            XCTAssertEqual(result.status, 0, String(decoding: result.output, as: UTF8.self))
            XCTAssertFalse(result.timedOut)
        }
    }

    @MainActor
    func testTunCoreReusesVerifiedExecutableAndRebuildsAfterTampering() async throws {
        guard SingBoxInstaller.installedVersion != nil else { throw XCTSkip("本地缺少已验证的 sing-box 安装包") }
        let manager = ApplicationProxyManager()
        let first = try await manager.prepareCore()
        let expected = try SingBoxInstaller.digest(first)
        let firstID = try FileManager.default.attributesOfItem(atPath: first.path)[.systemFileNumber] as? NSNumber
        let started = ProcessInfo.processInfo.systemUptime
        let second = try await manager.prepareCore()
        XCTAssertEqual(second, first)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: second.path)[.systemFileNumber] as? NSNumber, firstID)
        print("TUN 已验证核心复用耗时：\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) ms")
        try Data("tampered".utf8).write(to: first)
        let rebuilt = try await manager.prepareCore()
        XCTAssertNotEqual(rebuilt, first)
        XCTAssertEqual(try SingBoxInstaller.digest(rebuilt), expected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    }

    func testRealGlobalDNSAndOutboundsStartWithoutPrivilegedCapture() async throws {
        guard let path = ProcessInfo.processInfo.environment["HOPWORLD_TEST_SING_BOX"] else {
            throw XCTSkip("设置 HOPWORLD_TEST_SING_BOX 可运行真实核心启动校验")
        }
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = try ApplicationProxyConfig.build(applications: [], socksPort: 12001,
            password: "fixture", bypassExecutables: ["/fixture/xray"], captureAll: true,
            bootstrapDomains: ["node.example"])
        // Initialize the real DNS/outbound services, without creating a TUN,
        // changing host routes/DNS, or opening any listening socket.
        config.removeValue(forKey: "inbounds")
        let file = directory.appendingPathComponent("config.json")
        try XrayConfigBuilder.writeJSON(config, to: file)
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: path),
            arguments: ["run", "-c", file.path], timeout: 2)
        let output = String(decoding: result.output, as: UTF8.self)
        XCTAssertTrue(output.contains("sing-box started"), output)
        XCTAssertTrue(result.timedOut, "Healthy core must remain alive until test teardown: " + output)
    }

    func testXrayApplicationInboundForcesProxyAndUsesPrivateCredentials() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = try CoreValidationFixture.copyXray(to: directory)
        let node = ProxyNode(name: "fixture", protocolType: .vless, server: "127.0.0.1", port: 443,
                             uuid: "11111111-1111-4111-8111-111111111111")
        for mode in RoutingMode.allCases {
            let config = try XrayConfigBuilder.build(node: node,
                ports: .init(socksHost: "127.0.0.1", socksPort: 10808, httpHost: "127.0.0.1", httpPort: 10809),
                routingMode: mode, applicationProxy: (12001, "fixture-only-password"))
            let inbounds = try XCTUnwrap(config["inbounds"] as? [[String: Any]])
            let app = try XCTUnwrap(inbounds.first { $0["tag"] as? String == "application-in" })
            XCTAssertEqual(app["listen"] as? String, "127.0.0.1")
            XCTAssertEqual((app["settings"] as? [String: Any])?["auth"] as? String, "password")
            let rule = ((config["routing"] as? [String: Any])?["rules"] as? [[String: Any]])?.first
            XCTAssertEqual(rule?["outboundTag"] as? String, "proxy")
            let file = directory.appendingPathComponent("config.json")
            try XrayConfigBuilder.writeJSON(config, to: file)
            if let binary {
                let valid = try await XrayValidator.validateConfigFile(at: file, xrayURL: binary)
                XCTAssertTrue(valid)
            }
        }
    }

    func testLeaseUsesMonotonicTimeAndRequiresChangingHeartbeat() {
        var lease = TunLeaseWatchdog(lastChange: 0, timeout: 10)
        XCTAssertTrue(lease.isAlive(value: Data([1]), now: 0))
        XCTAssertTrue(lease.isAlive(value: Data([1]), now: 9))
        XCTAssertFalse(lease.isAlive(value: Data([1]), now: 10))
        XCTAssertTrue(lease.isAlive(value: Data([2]), now: 10))
        XCTAssertFalse(lease.isAlive(value: nil, now: 11))
    }

    func testPrivilegedControlRejectsSymlinksHardlinksAndWorldWritableFiles() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (lease, _) = try controlFiles(directory)
        let symbolic = directory.appendingPathComponent("symbolic")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: lease)
        XCTAssertThrowsError(try TunControlFile(path: symbolic.path, uid: getuid(), writable: true))
        let hard = directory.appendingPathComponent("hard")
        try FileManager.default.linkItem(at: lease, to: hard)
        XCTAssertThrowsError(try TunControlFile(path: lease.path, uid: getuid(), writable: true))
        try FileManager.default.removeItem(at: hard)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: lease.path)
        XCTAssertThrowsError(try TunControlFile(path: lease.path, uid: getuid(), writable: true))
    }

    func testSupervisorStopsOwnedChildWhenHeartbeatStops() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (leaseURL, statusURL) = try controlFiles(directory)
        let lease = try TunControlFile(path: leaseURL.path, uid: getuid(), writable: false)
        let status = try TunControlFile(path: statusURL.path, uid: getuid(), writable: true)
        let start = ProcessInfo.processInfo.systemUptime
        try await Task.detached {
            try TunSupervisor().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
                                    lease: lease, status: status, leaseTimeout: 0.2)
        }.value
        let result = try JSONDecoder().decode(TunSessionStatus.self, from: Data(contentsOf: statusURL))
        XCTAssertEqual(result.state, "stopped")
        XCTAssertEqual(result.stopReason, .leaseExpired)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 4)
    }

    func testSupervisorReportsCoreFailureAndStartupTimeout() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (leaseURL, statusURL) = try controlFiles(directory)
        let lease = try TunControlFile(path: leaseURL.path, uid: getuid(), writable: false)
        let status = try TunControlFile(path: statusURL.path, uid: getuid(), writable: true)
        try await Task.detached {
            try TunSupervisor().run(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [], lease: lease, status: status)
        }.value
        var result = try JSONDecoder().decode(TunSessionStatus.self, from: Data(contentsOf: statusURL))
        XCTAssertEqual(result.state, "failed")
        try await Task.detached {
            try TunSupervisor().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
                                    lease: lease, status: status, startupTimeout: 0.1)
        }.value
        result = try JSONDecoder().decode(TunSessionStatus.self, from: Data(contentsOf: statusURL))
        XCTAssertEqual(result.state, "failed")
        XCTAssertTrue(result.message.contains("超时"))
    }

    func testStaleLeaseCannotStartCoreAfterDelayedAuthorization() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (leaseURL, statusURL) = try controlFiles(directory)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: leaseURL.path)
        let lease = try TunControlFile(path: leaseURL.path, uid: getuid(), writable: false)
        let status = try TunControlFile(path: statusURL.path, uid: getuid(), writable: true)
        // Invalid executable proves it is never launched.
        try await Task.detached {
            try TunSupervisor().run(executable: URL(fileURLWithPath: "/does-not-exist"), arguments: [], lease: lease, status: status)
        }.value
        let result = try JSONDecoder().decode(TunSessionStatus.self, from: Data(contentsOf: statusURL))
        XCTAssertEqual(result.state, "stopped")
        XCTAssertEqual(result.stopReason, .leaseExpired)
    }

    func testSupervisorSignalStopDoesNotLaunchPendingCore() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (leaseURL, statusURL) = try controlFiles(directory)
        let lease = try TunControlFile(path: leaseURL.path, uid: getuid(), writable: false)
        let status = try TunControlFile(path: statusURL.path, uid: getuid(), writable: true)
        for signal in [SIGTERM, SIGINT] {
            let supervisor = TunSupervisor()
            supervisor.requestStop(signal: signal)
            let result = try await Task.detached {
                try supervisor.run(executable: URL(fileURLWithPath: "/does-not-exist"), arguments: [],
                                   lease: lease, status: status)
            }.value

            XCTAssertEqual(result.state, "stopped")
            XCTAssertEqual(result.stopReason, .systemSignal)
            XCTAssertEqual(result.signal, signal)
            XCTAssertTrue(result.message.contains(signal == SIGTERM ? "SIGTERM" : "SIGINT"))
        }
    }

    func testSupervisorKeepsFirstSignalAndItsSender() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (leaseURL, statusURL) = try controlFiles(directory)
        let lease = try TunControlFile(path: leaseURL.path, uid: getuid(), writable: false)
        let status = try TunControlFile(path: statusURL.path, uid: getuid(), writable: true)
        let supervisor = TunSupervisor()
        supervisor.requestStop(signal: SIGTERM, senderPID: 12345, senderUID: 501, senderName: "first-sender")
        supervisor.requestStop(signal: SIGINT, senderPID: 54321, senderUID: 0, senderName: "later-sender")

        let result = try await Task.detached {
            try supervisor.run(executable: URL(fileURLWithPath: "/does-not-exist"), arguments: [],
                               lease: lease, status: status)
        }.value
        let published = try JSONDecoder().decode(TunSessionStatus.self, from: Data(contentsOf: statusURL))
        for value in [result, published] {
            XCTAssertEqual(value.state, "stopped")
            XCTAssertEqual(value.stopReason, .systemSignal)
            XCTAssertEqual(value.signal, SIGTERM)
            XCTAssertEqual(value.signalSenderPID, 12345)
            XCTAssertEqual(value.signalSenderUID, 501)
            XCTAssertEqual(value.signalSenderName, "first-sender")
            XCTAssertTrue(value.message.contains("first-sender"))
            XCTAssertTrue(value.message.contains("12345"))
            XCTAssertFalse(value.message.contains("later-sender"))
            XCTAssertFalse(value.allowsAutomaticRecovery)
        }
    }

    func testSupervisorExplicitStopIsNotOverwrittenByLaterSignal() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (leaseURL, statusURL) = try controlFiles(directory)
        let lease = try TunControlFile(path: leaseURL.path, uid: getuid(), writable: false)
        let status = try TunControlFile(path: statusURL.path, uid: getuid(), writable: true)
        let supervisor = TunSupervisor()
        supervisor.requestStop()
        supervisor.requestStop(signal: SIGTERM, senderPID: 12345, senderUID: 501, senderName: "later-sender")

        let result = try await Task.detached {
            try supervisor.run(executable: URL(fileURLWithPath: "/does-not-exist"), arguments: [],
                               lease: lease, status: status)
        }.value
        XCTAssertEqual(result.state, "stopped")
        XCTAssertEqual(result.stopReason, .requested)
        XCTAssertNil(result.signal)
        XCTAssertNil(result.signalSenderPID)
        XCTAssertNil(result.signalSenderUID)
        XCTAssertNil(result.signalSenderName)
        XCTAssertFalse(result.message.contains("later-sender"))
        XCTAssertFalse(result.allowsAutomaticRecovery)
    }

    func testSupervisorUnlinkStopsImmediatelyAndStatusWriteStaysOnOpenedFile() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (leaseURL, statusURL) = try controlFiles(directory)
        let lease = try TunControlFile(path: leaseURL.path, uid: getuid(), writable: false)
        let status = try TunControlFile(path: statusURL.path, uid: getuid(), writable: true)
        let task = Task.detached {
            try TunSupervisor().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], lease: lease, status: status)
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        try FileManager.default.removeItem(at: leaseURL)
        try await task.value
        let result = try JSONDecoder().decode(TunSessionStatus.self, from: Data(contentsOf: statusURL))
        XCTAssertEqual(result.state, "stopped")
        let victim = directory.appendingPathComponent("untouched")
        try Data("unchanged".utf8).write(to: victim)
        try FileManager.default.removeItem(at: statusURL)
        try FileManager.default.createSymbolicLink(at: statusURL, withDestinationURL: victim)
        status.publish(.init(state: "stopped", message: "fixture"))
        XCTAssertEqual(try String(contentsOf: victim), "unchanged")
    }

    func testRuntimeDirectoryAcceptsBothMacOSPathSpellings() {
        for path in ["/private/var/run/hopworld-tun.fixture", "/var/run/hopworld-tun.fixture"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            XCTAssertTrue(TunRuntimeDirectory.hasExpectedLocation(directory), path)
            XCTAssertTrue(TunRuntimeDirectory.hasExpectedLocation(directory.resolvingSymlinksInPath()), path)
        }
        for path in ["/tmp/hopworld-tun.fixture", "/private/var/run/hopworld-tun.",
                     "/private/var/run/hopworld-tun.fixture/nested", "/private/var/run/hopworld-tun-evil"] {
            XCTAssertFalse(TunRuntimeDirectory.hasExpectedLocation(URL(fileURLWithPath: path)), path)
        }
    }

    func testRuntimeDirectoryStillRequiresRootPrivateDirectory() {
        XCTAssertTrue(TunRuntimeDirectory.hasSafeOwnership(owner: 0, mode: mode_t(S_IFDIR | 0o700)))
        XCTAssertFalse(TunRuntimeDirectory.hasSafeOwnership(owner: 501, mode: mode_t(S_IFDIR | 0o700)))
        XCTAssertFalse(TunRuntimeDirectory.hasSafeOwnership(owner: 0, mode: mode_t(S_IFDIR | 0o750)))
        XCTAssertFalse(TunRuntimeDirectory.hasSafeOwnership(owner: 0, mode: mode_t(S_IFREG | 0o700)))
        XCTAssertFalse(TunRuntimeDirectory.hasSafeOwnership(owner: 0, mode: mode_t(S_IFLNK | 0o700)))
    }

    func testLaunchReportsEarlySupervisorExitWithoutWaitingForTunTimeout() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Use the system shell directly so first-execution policy scanning of
        // a freshly created executable does not consume the startup deadline.
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("supervisor").path,
                                                   withDestinationPath: "/bin/sh")
        let executable = directory.appendingPathComponent("fixture.sh")
        try Data("#!/bin/sh\necho fixture-startup-error >&2\nexit 42\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let command = (["set -eu", "runtime=" + TunAuthorizationCommand.shellQuote(directory.path)] +
            TunAuthorizationCommand.launchCommands(lease: executable,
                status: directory.appendingPathComponent("status"), uid: getuid())).joined(separator: "\n")
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", command], timeout: 4)
        XCTAssertEqual(result.status, 1)
        XCTAssertFalse(result.timedOut)
        let output = String(decoding: result.output, as: UTF8.self)
        XCTAssertTrue(output.contains("42"), output)
        XCTAssertTrue(output.contains("fixture-startup-error"), output)
    }

    func testBackgroundLaunchSurvivesParentExitAndHangupWithoutTerminal() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Use the system shell directly so first-execution policy scanning of
        // a freshly created executable does not consume the startup deadline.
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("supervisor").path,
                                                   withDestinationPath: "/bin/sh")
        let executable = directory.appendingPathComponent("fixture.sh")
        let pidFile = directory.appendingPathComponent("pid")
        let completed = directory.appendingPathComponent("completed")
        let fixture = "#!/bin/sh\necho $$ > " + TunAuthorizationCommand.shellQuote(pidFile.path) +
            "\n/bin/sleep 3\necho done > " + TunAuthorizationCommand.shellQuote(completed.path) + "\n"
        try Data(fixture.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let command = (["set -eu", "runtime=" + TunAuthorizationCommand.shellQuote(directory.path)] +
            TunAuthorizationCommand.launchCommands(lease: executable,
                status: directory.appendingPathComponent("status"), uid: getuid())).joined(separator: "\n")
        // ProcessRunner uses pipes, with no PTY. The launching shell must exit
        // while its child stays alive and has no inherited output pipe open.
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", command], timeout: 4)
        XCTAssertEqual(result.status, 0, String(decoding: result.output, as: UTF8.self))
        XCTAssertFalse(result.timedOut)
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines)))
        guard pid > 1 else { return XCTFail("Invalid fixture PID") }
        XCTAssertEqual(kill(pid, SIGHUP), 0)
        for _ in 0..<30 {
            if FileManager.default.fileExists(atPath: completed.path) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(try String(contentsOf: completed).trimmingCharacters(in: .whitespacesAndNewlines), "done")
    }

    func testSupervisorPublishesReadyBeforeQuietChildExits() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (leaseURL, statusURL) = try controlFiles(directory)
        let lease = try TunControlFile(path: leaseURL.path, uid: getuid(), writable: false)
        let status = try TunControlFile(path: statusURL.path, uid: getuid(), writable: true)
        let supervisor = TunSupervisor()
        let task = Task.detached {
            try supervisor.run(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo 'sing-box started'; exec /bin/sleep 5"],
                lease: lease, status: status, startupTimeout: 2)
        }
        var running = false
        for _ in 0..<15 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if let data = try? Data(contentsOf: statusURL),
               let value = try? JSONDecoder().decode(TunSessionStatus.self, from: data), value.state == "running" {
                running = true
                break
            }
        }
        supervisor.requestStop()
        let result = try await task.value
        XCTAssertTrue(running, "Must see readiness without waiting for EOF or a full output buffer")
        XCTAssertEqual(result.state, "stopped")
        XCTAssertEqual(result.stopReason, .requested)
        XCTAssertNil(result.signal)
    }

    func testShellQuotingRoundTripDoesNotExecuteInjectedText() async throws {
        let value = "space ' \" ; $(echo INJECTED) `id`\n中文"
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf %s " + TunAuthorizationCommand.shellQuote(value)], timeout: 3)
        XCTAssertEqual(String(decoding: result.output, as: UTF8.self), value)
        let script = TunAuthorizationCommand.appleScript("echo \"value\"\nexit 0")
        XCTAssertTrue(script.contains("with administrator privileges"))
        XCTAssertTrue(script.contains("\\n"))
    }

    func testHelperLaunchScriptDoesNotEmbedASession() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let supervisor = directory.appendingPathComponent("HopWorldTunSupervisor")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: supervisor)
        let script = try TunAuthorizationCommand.makeHelper(supervisor: supervisor, uid: getuid())
        XCTAssertTrue(script.contains("--serve \(getuid())"))
        XCTAssertTrue(script.contains(TunHelperChannel.socketPath))
        XCTAssertTrue(script.contains("with administrator privileges"))
        XCTAssertFalse(script.contains("config.json"))
        let framed = try TunHelperChannel.frame(TunHelperRequest(op: "ping"))
        let payload = try TunHelperChannel.payload(from: framed)
        XCTAssertEqual(try JSONDecoder().decode(TunHelperRequest.self, from: payload).op, "ping")
    }

    func testAuthorizationWaitUsesHelperBeforeScriptExits() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = "/tmp/hw-auth-\(getpid()).sock"
        unlink(socket)
        defer { unlink(socket) }
        let server = TunHelperServer()
        let finished = expectation(description: "helper exit")
        Thread {
            _ = server.serve(owner: getuid(), socketPath: socket, idleTimeout: 5)
            finished.fulfill()
        }.start()
        let start = ProcessInfo.processInfo.systemUptime
        let client = try await TunHelperAuthorizationWait.wait(timeout: 3, connect: {
            try TunHelperClient.connect(socket, timeout: 0.3)
        }, authorization: { nil })
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
        XCTAssertTrue(client.ping())
        client.quitAndClose()
        await fulfillment(of: [finished], timeout: 3)
    }

    func testAuthorizationWaitReportsDeniedScriptImmediately() async throws {
        let result = ProcessRunResult(status: 1, output: Data("不允许".utf8), timedOut: false, cancelled: false)
        let start = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await TunHelperAuthorizationWait.wait(timeout: 10, connect: {
                throw CocoaError(.fileReadNoPermission)
            }, authorization: { .success(result) })
            XCTFail("拒绝授权应立即失败")
        } catch let error as ApplicationProxyError {
            XCTAssertTrue(error.localizedDescription.contains("不允许"))
            XCTAssertTrue(error.localizedDescription.contains("退出码 1"))
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
    }

    func testStageRejectsMismatchedDigest() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = directory.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let files = try sessionFiles(directory)
        var request = try startRequest(files)
        request.binaryDigest = String(repeating: "ab", count: 32)
        XCTAssertThrowsError(try TunHelperServer.stage(request, owner: getuid(), runtime: runtime))
        request = try startRequest(files)
        request.binary = directory.path + "/../" + directory.lastPathComponent + "/" + files.binary.lastPathComponent
        XCTAssertThrowsError(try TunHelperServer.stage(request, owner: getuid(), runtime: runtime))
    }

    func testResidentHelperServesSecondStartWithoutAnotherLaunch() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = "/tmp/hw-tun-\(getpid()).sock"
        unlink(socket)
        defer { unlink(socket) }
        let server = TunHelperServer()
        let finished = expectation(description: "helper exit")
        Thread {
            _ = server.serve(owner: getuid(), socketPath: socket, idleTimeout: 8) {
                let runtime = directory.appendingPathComponent("run-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                return runtime
            }
            finished.fulfill()
        }.start()
        let client = try TunHelperClient.connect(socket, timeout: 3)
        XCTAssertTrue(client.ping())
        let rejected = try sessionFiles(directory.appendingPathComponent("bad"))
        var bad = try startRequest(rejected)
        bad.binaryDigest = String(repeating: "cd", count: 32)
        let refusal = try client.request(bad, timeout: 3)
        XCTAssertFalse(refusal.ok)
        XCTAssertTrue(client.ping())
        let executed = directory.appendingPathComponent("executed-cores")
        for name in ["one", "two", "updated"] {
            let files = try sessionFiles(directory.appendingPathComponent(name), recordExecutableAt: executed)
            if name == "updated" {
                let handle = try FileHandle(forWritingTo: files.binary)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data("# updated core\n".utf8))
                try handle.close()
            }
            let lease = try FileHandle(forUpdating: files.lease)
            let pulse = Task {
                while !Task.isCancelled {
                    var value = DispatchTime.now().uptimeNanoseconds
                    _ = withUnsafeBytes(of: &value) { pwrite(lease.fileDescriptor, $0.baseAddress, $0.count, 0) }
                    do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                }
            }
            let response = try client.request(try startRequest(files), timeout: 5)
            XCTAssertTrue(response.ok, response.message)
            var running = false
            for _ in 0..<40 {
                if let data = try? Data(contentsOf: files.status),
                   let state = try? JSONDecoder().decode(TunSessionStatus.self, from: data), state.state == "running" {
                    running = true
                    break
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            XCTAssertTrue(running, name)
            pulse.cancel()
            try? FileManager.default.removeItem(at: files.lease)
            try? lease.close()
            var stopped = false
            for _ in 0..<40 {
                if let data = try? Data(contentsOf: files.status),
                   let state = try? JSONDecoder().decode(TunSessionStatus.self, from: data),
                   state.state == "stopped" || state.state == "failed" {
                    stopped = true
                    break
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            XCTAssertTrue(stopped, name)
            let stop = try client.request(TunHelperRequest(op: "stop"), timeout: 3)
            XCTAssertTrue(stop.ok, stop.message)
            let paths = try String(contentsOf: executed).split(separator: "\n").map(String.init)
            XCTAssertEqual(paths.count, name == "one" ? 1 : name == "two" ? 2 : 3)
            XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: paths.last!).deletingLastPathComponent()
                .appendingPathComponent("config.json").path), "会话结束不能保留含密码的配置")
            let originalDigest = try SingBoxInstaller.digest(files.binary)
            try Data("tampered".utf8).write(to: files.binary)
            var tampered = try startRequest(files)
            tampered.binaryDigest = originalDigest
            XCTAssertFalse(try client.request(tampered, timeout: 3).ok, "复用已验证核心也必须检查每次请求的源文件")
        }
        let paths = try String(contentsOf: executed).split(separator: "\n").map(String.init)
        XCTAssertEqual(paths[0], paths[1], "重复连接必须使用同一个已验证可执行文件")
        XCTAssertNotEqual(paths[1], paths[2], "核心变化必须建立新的验证副本")
        client.quitAndClose()
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertTrue(paths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
    }

    func testResidentHelperShutdownDuringPreparationRejectsStart() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = "/tmp/hw-stop-start-\(getpid()).sock"
        unlink(socket)
        defer { unlink(socket) }
        let files = try sessionFiles(directory.appendingPathComponent("session"))
        let originalStatus = try Data(contentsOf: files.status)
        let server = TunHelperServer()
        let finished = expectation(description: "stopped helper exit")
        Thread {
            _ = server.serve(owner: getuid(), socketPath: socket, idleTimeout: 8) {
                let runtime = directory.appendingPathComponent("run")
                try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                server.requestStop()
                return runtime
            }
            finished.fulfill()
        }.start()
        let client = try TunHelperClient.connect(socket, timeout: 3)
        defer { client.close() }
        let response = try client.request(try startRequest(files), timeout: 3)

        XCTAssertFalse(response.ok, "整体停止后不能接受待启动会话")
        XCTAssertTrue(response.message.contains("正在停止"), response.message)
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(try Data(contentsOf: files.status), originalStatus, "未启动核心，不应发布运行状态")
    }

    @MainActor
    func testSlowTunStopKeepsAuthorizedHelperReusable() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = "/tmp/hw-slow-stop-\(getpid()).sock"
        unlink(socket)
        defer { unlink(socket) }
        let server = TunHelperServer()
        let finished = expectation(description: "helper exit")
        Thread {
            _ = server.serve(owner: getuid(), socketPath: socket, idleTimeout: 8) {
                let runtime = directory.appendingPathComponent("run-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                return runtime
            }
            finished.fulfill()
        }.start()
        let client = try TunHelperClient.connect(socket, timeout: 3)
        defer { client.quitAndClose() }
        let files = try sessionFiles(directory.appendingPathComponent("slow"), ignoresTermination: true)
        let response = try client.request(try startRequest(files), timeout: 5)
        XCTAssertTrue(response.ok, response.message)
        var running = false
        for _ in 0..<40 {
            if let data = try? Data(contentsOf: files.status),
               let state = try? JSONDecoder().decode(TunSessionStatus.self, from: data), state.state == "running" {
                running = true
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(running)

        let manager = ApplicationProxyManager(helper: client, activeSession: files.lease.deletingLastPathComponent())
        let started = ProcessInfo.processInfo.systemUptime
        let stopped = await manager.stop()

        XCTAssertTrue(stopped)
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - started, 2.5)
        XCTAssertTrue(client.ping(), "慢停止不能把已授权辅助服务误判失效，否则下次连接会重复授权")
        client.quitAndClose()
        await fulfillment(of: [finished], timeout: 3)
    }

    private struct SessionFiles {
        let binary: URL
        let config: URL
        let lease: URL
        let status: URL
    }

    private func sessionFiles(_ directory: URL, ignoresTermination: Bool = false, recordExecutableAt: URL? = nil) throws -> SessionFiles {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let binary = directory.appendingPathComponent("core.sh")
        let trap = ignoresTermination ? "trap '' TERM\n" : ""
        let record = recordExecutableAt.map { "printf '%s\\n' \"$0\" >> \(TunAuthorizationCommand.shellQuote($0.path))\n" } ?? ""
        try Data("#!/bin/sh\n\(trap)\(record)echo 'sing-box started'\nexec /bin/sleep 30\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let config = directory.appendingPathComponent("config.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: config.path, contents: Data("{}\n".utf8), attributes: [.posixPermissions: 0o600]))
        let lease = directory.appendingPathComponent("lease")
        let status = directory.appendingPathComponent("status.json")
        for file in [lease, status] {
            XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data("pulse".utf8), attributes: [.posixPermissions: 0o600]))
        }
        return SessionFiles(binary: binary, config: config, lease: lease, status: status)
    }

    private func startRequest(_ files: SessionFiles) throws -> TunHelperRequest {
        TunHelperRequest(op: "start", binary: files.binary.path, config: files.config.path, lease: files.lease.path,
                         status: files.status.path, binaryDigest: try SingBoxInstaller.digest(files.binary),
                         configDigest: try SingBoxInstaller.digest(files.config))
    }
}
