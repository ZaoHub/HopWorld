import XCTest

final class AIConnectionQualityTests: XCTestCase {
    private func application(_ path: String, name: String = "Claude", isBundle: Bool = true) throws -> ProxyApplication {
        let data = try JSONSerialization.data(withJSONObject: ["path": path, "name": name, "isBundle": isBundle])
        return try JSONDecoder().decode(ProxyApplication.self, from: data)
    }

    func testClaudeScoreRequiresSavedClaudeApplicationRuleAndStopsAfterRemoval() throws {
        var quality = AIConnectionQuality()
        for _ in 0..<10 { quality.record(latencyMs: 100) }
        var settings = AppSettings()
        settings.appProbeSource = .defaults
        XCTAssertTrue(settings.allAppProbeTargets.contains(.claude))
        XCTAssertNil(quality.score(for: .claude, settings: settings))

        let claude = try application("/Applications/Claude.app")
        settings.installedAppProbes = [InstalledAppProbe(application: claude, endpoint: "https://claude.ai/")]
        settings.proxyApplications = [try application("/Applications/NotClaude.app")]
        XCTAssertNil(quality.score(for: .claude, settings: settings), "测试目标或应用显示名不能代替代理规则")

        settings.proxyApplications.append(claude)
        XCTAssertEqual(quality.score(for: .claude, settings: settings), AINodeScore(points: 50, coverage: 50))
        settings.proxyApplications.removeAll { $0.id == claude.id }
        XCTAssertNil(quality.score(for: .claude, settings: settings))
        XCTAssertEqual(quality.score(for: .codex, settings: settings), AINodeScore(points: 50, coverage: 50))
        settings.selectRoutingMode(.global)
        XCTAssertNil(quality.score(for: .claude, settings: settings), "全局隐式覆盖所有应用不自动启用 Claude 评分")
    }

    func testClaudeRulesRecognizeBundleHelpersCLIAndRenamedBundle() throws {
        XCTAssertTrue(try application("/Applications/Claude.app/Contents/MacOS/Claude", isBundle: false).isClaude)
        XCTAssertTrue(try application("/usr/local/bin/claude", isBundle: false).isClaude)
        XCTAssertFalse(try application("/Applications/Claude.app.backup").isClaude)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = directory.appendingPathComponent("Renamed.app")
        let contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleName": "Claude", "CFBundleIdentifier": "test.claude.fixture", "CFBundlePackageType": "APPL"
        ], format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        XCTAssertTrue(try application(bundle.path, name: "Renamed").isClaude)
    }

    func testClaudeStreamingCompletionIsOnlyScoredWhenMeasured() {
        var quality = AIConnectionQuality()
        for _ in 0..<10 { quality.record(latencyMs: 100) }
        XCTAssertEqual(quality.score(for: .codex, settings: AppSettings()), AINodeScore(points: 50, coverage: 50))
        let withStreamEvidence = AINodeScore.calculate(longConnectionSurvival: 0.8,
            jitterMs: 0, successRate: 1, latencyMs: 100)
        XCTAssertEqual(withStreamEvidence, AINodeScore(points: 78, coverage: 85))
    }

    func testUnknownEvidenceNeverBecomesFullScore() {
        let missing = AINodeScore.calculate(jitterMs: nil, successRate: nil, latencyMs: nil)
        XCTAssertEqual(missing, AINodeScore(points: 0, coverage: 0))
        let basic = AINodeScore.calculate(jitterMs: 0, successRate: 1, latencyMs: 100)
        XCTAssertEqual(basic, AINodeScore(points: 50, coverage: 50))
        let full = AINodeScore.calculate(longConnectionSurvival: 1, packetLoss: 0,
                                            jitterMs: 0, successRate: 1, latencyMs: 100)
        XCTAssertEqual(full, AINodeScore(points: 100, coverage: 100))
        let poor = AINodeScore.calculate(longConnectionSurvival: 0, packetLoss: 0.1,
                                            jitterMs: 1000, successRate: 0, latencyMs: 5000)
        XCTAssertEqual(poor, AINodeScore(points: 0, coverage: 100))
        let invalid = AINodeScore.calculate(jitterMs: .nan, successRate: -.infinity, latencyMs: -1)
        XCTAssertEqual(invalid.coverage, 0)
        XCTAssertEqual(AINodeScore.calculate(longConnectionSurvival: 2, packetLoss: 2,
                                                jitterMs: nil, successRate: 2, latencyMs: nil).coverage, 0)
    }

    func testFailuresAreCountedButNotInventedAsPacketLossOrJitter() {
        var quality = AIConnectionQuality()
        quality.record(latencyMs: 100)
        quality.record(latencyMs: 140)
        quality.record(latencyMs: nil)
        quality.record(latencyMs: 900)
        XCTAssertEqual(quality.successRate, 0.75)
        XCTAssertEqual(quality.jitterMs, 40)
        XCTAssertEqual(quality.p95LatencyMs, 900)
        XCTAssertNil(quality.score(for: .codex, settings: AppSettings()))
        for _ in 0..<6 { quality.record(latencyMs: 100) }
        XCTAssertEqual(quality.score(for: .codex, settings: AppSettings())?.coverage, 50)
        for _ in 0..<120 { quality.record(latencyMs: nil) }
        XCTAssertEqual(quality.samples.count, 120)
        XCTAssertEqual(quality.successRate, 0)
        XCTAssertNil(quality.jitterMs)
        XCTAssertNil(quality.p95LatencyMs)
        XCTAssertEqual(quality.score(for: .codex, settings: AppSettings()), AINodeScore(points: 0, coverage: 20))
    }

    func testMissingExitObservationsDoNotCountAsChanges() {
        var quality = AIConnectionQuality()
        XCTAssertFalse(quality.recordExit(identifier: nil))
        XCTAssertFalse(quality.recordExit(identifier: "ip#first"))
        XCTAssertFalse(quality.recordExit(identifier: nil))
        XCTAssertFalse(quality.recordExit(identifier: "ip#first"))
        XCTAssertTrue(quality.recordExit(identifier: "ip#second"))
        XCTAssertEqual(quality.exitChanges, 1)
        XCTAssertEqual(quality.exitObservations, 3)
    }

    func testReferenceScoreUsesOnlyFreshSamplesAndExpiresSpecializedResults() {
        var quality = AIConnectionQuality()
        var settings = AppSettings()
        settings.testResultTTLMinutes = 1
        let now = Date(timeIntervalSince1970: 1_000)
        for _ in 0..<10 { quality.record(latencyMs: nil, at: now.addingTimeInterval(-61)) }
        quality.webSocket = .init(verified: true, survived: true, observedSeconds: 360,
                                 requestedSeconds: 360, detail: "fixture", measuredAt: now.addingTimeInterval(-61))
        quality.datagrams = .init(verified: true, sent: 30, received: 30,
                                 detail: "fixture", measuredAt: now.addingTimeInterval(-61))
        XCTAssertNil(quality.score(for: .codex, settings: settings, now: now))
        for age in 0..<10 { quality.record(latencyMs: 100, at: now.addingTimeInterval(Double(-age))) }
        let fresh = quality.freshObservations(settings: settings, now: now)
        XCTAssertEqual(quality.samples.count, 20, "Expired observations remain available as run history")
        XCTAssertEqual(fresh.samples.count, 10)
        XCTAssertEqual(fresh.lastSampleAt, now)
        XCTAssertNil(fresh.webSocket)
        XCTAssertNil(fresh.datagrams)
        XCTAssertEqual(quality.score(for: .codex, settings: settings, now: now), AINodeScore(points: 50, coverage: 50))
        XCTAssertNil(quality.score(for: .codex, settings: settings, now: now.addingTimeInterval(61)))
    }

    func testReferenceFreshnessIncludesTTLBoundaryAndRejectsFutureSamples() {
        var quality = AIConnectionQuality()
        var settings = AppSettings()
        settings.testResultTTLMinutes = 1
        let now = Date(timeIntervalSince1970: 1_000)
        quality.record(latencyMs: 800, at: now.addingTimeInterval(-61))
        quality.record(latencyMs: 120, at: now.addingTimeInterval(-60))
        quality.record(latencyMs: nil, at: now)
        quality.record(latencyMs: 1, at: now.addingTimeInterval(1))
        let fresh = quality.freshObservations(settings: settings, now: now)
        XCTAssertEqual(fresh.samples.count, 2)
        XCTAssertEqual(fresh.successRate, 0.5)
        XCTAssertEqual(fresh.p95LatencyMs, 120)
        XCTAssertNil(fresh.jitterMs, "A failed request cannot supply a fabricated latency")
        XCTAssertNil(fresh.score(for: .codex, settings: settings, now: now))
    }

    func testSpecializedMeasurementsScoreBeforeHTTPSHasTenSamples() {
        let now = Date(timeIntervalSince1970: 1_000)
        var quality = AIConnectionQuality()
        let settings = AppSettings()
        quality.webSocket = .init(verified: true, survived: true, observedSeconds: 360,
                                 requestedSeconds: 360, detail: "fixture", measuredAt: now)
        XCTAssertEqual(quality.score(for: .codex, settings: settings, now: now), AINodeScore(points: 35, coverage: 35))
        quality.datagrams = .init(verified: true, sent: 30, received: 29, detail: "fixture", measuredAt: now)
        for _ in 0..<9 { quality.record(latencyMs: 100, at: now) }
        XCTAssertEqual(quality.score(for: .codex, settings: settings, now: now), AINodeScore(points: 40, coverage: 50))
        let partial = quality.scoringComponents(for: .codex, settings: settings, now: now)
        XCTAssertEqual(partial.map(\.id), ["stream", "packetLoss", "jitter", "successRate", "latency"])
        XCTAssertEqual(partial.map(\.weight), [35, 15, 15, 20, 15])
        XCTAssertEqual(partial.map(\.points), [35, 5, nil, nil, nil])
        quality.record(latencyMs: 100, at: now)
        XCTAssertEqual(quality.score(for: .codex, settings: settings, now: now), AINodeScore(points: 90, coverage: 100))
    }

    func testUDPOnlyScoreAndComponentCoverageExpireTogether() {
        let now = Date(timeIntervalSince1970: 1_000)
        var settings = AppSettings()
        settings.testResultTTLMinutes = 1
        var quality = AIConnectionQuality()
        quality.datagrams = .init(verified: true, sent: 30, received: 30, detail: "fixture", measuredAt: now)
        XCTAssertEqual(quality.score(for: .codex, settings: settings, now: now), AINodeScore(points: 15, coverage: 15))
        XCTAssertEqual(quality.scoringComponents(for: .codex, settings: settings, now: now).compactMap(\.points), [15])
        let later = now.addingTimeInterval(61)
        XCTAssertNil(quality.score(for: .codex, settings: settings, now: later))
        XCTAssertTrue(quality.scoringComponents(for: .codex, settings: settings, now: later).allSatisfy { $0.points == nil })
        quality.datagrams = .init(verified: false, sent: 30, received: 30, detail: "fixture", measuredAt: later)
        XCTAssertNil(quality.score(for: .codex, settings: settings, now: later), "Unverified probes must not supply measured coverage")
    }

    func testScoreRoundsAfterSummingContributionsRatherThanSummingDisplayedRoundedPoints() {
        let now = Date(timeIntervalSince1970: 1_000)
        var quality = AIConnectionQuality()
        for index in 0..<10 { quality.record(latencyMs: index.isMultiple(of: 2) ? 1560 : 1832, at: now) }
        let components = quality.scoringComponents(for: .codex, settings: AppSettings(), now: now)
        XCTAssertEqual(components.compactMap(\.points).reduce(0, +), 22)
        XCTAssertEqual(quality.score(for: .codex, settings: AppSettings(), now: now), AINodeScore(points: 23, coverage: 50))
        XCTAssertEqual(quality.score(for: .codex, settings: AppSettings(), now: now),
                       AINodeScore.calculate(jitterMs: 272, successRate: 1, latencyMs: 1832))
    }

    func testQuickChecksOnlyCoverShortMeasurementEvidence() {
        let now = Date(timeIntervalSince1970: 1_000)
        var quality = AIConnectionQuality()
        let settings = AppSettings()
        for _ in 0..<10 { quality.record(latencyMs: 100, at: now) }
        quality.webSocket = .init(verified: true, survived: true, observedSeconds: 10,
                                 requestedSeconds: 10, detail: "quick", measuredAt: now)
        XCTAssertEqual(quality.score(for: .codex, settings: settings, now: now), AINodeScore(points: 60, coverage: 60))
        quality.datagrams = .init(verified: true, sent: 10, received: 10, detail: "quick", measuredAt: now)
        XCTAssertEqual(quality.score(for: .codex, settings: settings, now: now), AINodeScore(points: 65, coverage: 65))
        let components = quality.scoringComponents(for: .codex, settings: settings, now: now)
        XCTAssertEqual(components.map(\.weight), [10, 5, 15, 20, 15])
        XCTAssertEqual(components.first?.title, "WebSocket 快速连接检查")
        quality.datagrams = .init(verified: true, sent: 30, received: 30, detail: "automatic quick", measuredAt: now)
        XCTAssertEqual(quality.score(for: .codex, settings: settings, now: now), AINodeScore(points: 75, coverage: 75),
                       "The automatic ten-second check must not claim six-minute stability coverage")
        quality.webSocket = .init(verified: true, survived: true, observedSeconds: 360,
                                 requestedSeconds: 360, detail: "deep", measuredAt: now)
        quality.datagrams = .init(verified: true, sent: 30, received: 30, detail: "deep", measuredAt: now)
        XCTAssertEqual(quality.score(for: .codex, settings: settings, now: now), AINodeScore(points: 100, coverage: 100))
        XCTAssertEqual(quality.scoringComponents(for: .codex, settings: settings, now: now).first?.title,
                       "WebSocket 长连接存活率")
    }

    func testVerifiedQuickFailureOnlyUsesTheShortObservationCoverage() {
        let now = Date(timeIntervalSince1970: 1_000)
        var quality = AIConnectionQuality()
        let settings = AppSettings()
        for _ in 0..<10 { quality.record(latencyMs: 100, at: now) }
        quality.webSocket = .init(verified: true, survived: false, observedSeconds: 0.2,
                                 requestedSeconds: 10, detail: "interrupted", measuredAt: now)
        XCTAssertEqual(quality.score(for: .codex, settings: settings, now: now), AINodeScore(points: 50, coverage: 60))
        quality.datagrams = .init(verified: true, sent: 10, received: 9, detail: "quick loss", measuredAt: now)
        XCTAssertEqual(quality.score(for: .codex, settings: settings, now: now), AINodeScore(points: 50, coverage: 65))
        quality.webSocket = .init(verified: false, survived: false, observedSeconds: 0,
                                 requestedSeconds: 10, detail: "unverified", measuredAt: now)
        quality.datagrams = .init(verified: false, sent: 0, received: 0, detail: "unverified", measuredAt: now)
        let components = quality.scoringComponents(for: .codex, settings: settings, now: now)
        XCTAssertEqual(components.map(\.weight), [35, 15, 15, 20, 15])
        XCTAssertNil(components[0].points)
        XCTAssertNil(components[1].points)
        XCTAssertEqual(quality.score(for: .codex, settings: settings, now: now), AINodeScore(points: 50, coverage: 50))
    }

    func testShortChecksExpireAndIncompleteSuccessCannotSupplyLongObservationPoints() {
        let now = Date(timeIntervalSince1970: 1_000)
        var quality = AIConnectionQuality()
        var settings = AppSettings()
        settings.testResultTTLMinutes = 1
        quality.webSocket = .init(verified: true, survived: true, observedSeconds: 10,
                                 requestedSeconds: 360, detail: "incomplete", measuredAt: now)
        XCTAssertNil(quality.webSocket?.survivalRate)
        XCTAssertNil(quality.score(for: .codex, settings: settings, now: now))
        quality.webSocket = .init(verified: true, survived: true, observedSeconds: 10,
                                 requestedSeconds: 10, detail: "quick", measuredAt: now)
        quality.datagrams = .init(verified: true, sent: 10, received: 10, detail: "quick", measuredAt: now)
        XCTAssertEqual(quality.score(for: .codex, settings: settings, now: now), AINodeScore(points: 15, coverage: 15))
        XCTAssertNil(quality.score(for: .codex, settings: settings, now: now.addingTimeInterval(61)))
        let invalid = DatagramLossResult(verified: true, sent: 10, received: 11, detail: "invalid", measuredAt: now)
        XCTAssertNil(invalid.lossRate)
        XCTAssertEqual(invalid.scoringWeight, 15)
    }

    func testAutomaticRefreshOnlyRequestsMissingOrExpiredMeasurements() {
        let now = Date(timeIntervalSince1970: 1_000)
        var settings = AppSettings()
        settings.testResultTTLMinutes = 1
        var quality = AIConnectionQuality()
        var needs = quality.refreshNeeds(settings: settings, now: now)
        XCTAssertTrue(needs.webSocket)
        XCTAssertTrue(needs.datagrams)
        quality.webSocket = .init(verified: true, survived: true, observedSeconds: 360,
                                 requestedSeconds: 360, detail: "deep", measuredAt: now)
        needs = quality.refreshNeeds(settings: settings, now: now)
        XCTAssertFalse(needs.webSocket, "Fresh deep results must not be replaced by an automatic short test")
        XCTAssertTrue(needs.datagrams)
        quality.datagrams = .init(verified: true, sent: 30, received: 29, detail: "measured loss", measuredAt: now)
        needs = quality.refreshNeeds(settings: settings, now: now.addingTimeInterval(60))
        XCTAssertFalse(needs.webSocket)
        XCTAssertFalse(needs.datagrams, "A measured loss rate is valid until its configured TTL")
        needs = quality.refreshNeeds(settings: settings, now: now.addingTimeInterval(61))
        XCTAssertTrue(needs.webSocket)
        XCTAssertTrue(needs.datagrams)
    }

    func testAutomaticRefreshBacksOffUnverifiedAndInterruptedMeasurementsForOneMinute() {
        let now = Date(timeIntervalSince1970: 1_000)
        let settings = AppSettings()
        var quality = AIConnectionQuality()
        quality.webSocket = .init(verified: false, survived: false, observedSeconds: 0,
                                 requestedSeconds: 10, detail: "unverified", measuredAt: now)
        quality.datagrams = .init(verified: false, sent: 0, received: 0, detail: "unverified", measuredAt: now)
        var needs = quality.refreshNeeds(settings: settings, now: now.addingTimeInterval(59))
        XCTAssertFalse(needs.webSocket)
        XCTAssertFalse(needs.datagrams)
        needs = quality.refreshNeeds(settings: settings, now: now.addingTimeInterval(60))
        XCTAssertTrue(needs.webSocket)
        XCTAssertTrue(needs.datagrams)
        quality.webSocket = .init(verified: true, survived: false, observedSeconds: 2,
                                 requestedSeconds: 10, detail: "interrupted", measuredAt: now)
        quality.datagrams = .init(verified: true, sent: 30, received: 0, detail: "verified loss", measuredAt: now)
        needs = quality.refreshNeeds(settings: settings, now: now.addingTimeInterval(60))
        XCTAssertTrue(needs.webSocket)
        XCTAssertFalse(needs.datagrams)
        quality.webSocket = .init(verified: true, survived: true, observedSeconds: 10,
                                 requestedSeconds: 10, detail: "quick recovered", measuredAt: now.addingTimeInterval(60))
        XCTAssertFalse(quality.refreshNeeds(settings: settings, now: now.addingTimeInterval(120)).webSocket)
    }

    func testRedactionPreservesDiagnosticCodesAndCorrelatesAddresses() {
        let raw = "session=abc123 HTTPS timeout=3s HTTP=429 code=56 203.0.113.7:443 [2001:db8::1]:443 tcp:2001:db8::2 /Users/alice/log"
        let redacted = LogRedactor.redact(raw)
        XCTAssertFalse(redacted.contains("203.0.113.7"))
        XCTAssertFalse(redacted.contains("2001:db8::1"))
        XCTAssertFalse(redacted.contains("2001:db8::2"))
        XCTAssertFalse(redacted.contains("alice"))
        XCTAssertTrue(redacted.contains(LogRedactor.addressIdentifier("203.0.113.7")))
        XCTAssertTrue(redacted.contains("HTTP=429 code=56"))
        XCTAssertTrue(redacted.contains("timeout=3s"))
        XCTAssertEqual(LogRedactor.redact(redacted), redacted)
    }

    func testSecretsDoNotSurviveLogRedaction() {
        let raw = """
        https://user:credential@example.com/private/path?access_token=access-secret
        vmess://base64-secret
        hy2://hy-secret@host.example:443
        Authorization: Bearer bearer-secret
        Cookie: session=cookie-secret
        {"password":"json-secret", "access_token": "json-token"}
        api_key=key-secret sk-api-secret
        11111111-1111-4111-8111-111111111111
        """
        let redacted = LogRedactor.redact(raw)
        for secret in ["credential", "private/path", "access-secret", "base64-secret", "hy-secret",
                       "bearer-secret", "cookie-secret", "json-secret", "json-token", "key-secret", "sk-api-secret",
                       "11111111-1111-4111-8111-111111111111"] {
            XCTAssertFalse(redacted.contains(secret), secret)
        }
        let structured = LogRedactor.redact(#"{"password":"prefix\"escaped-secret", "cookie":"session=json-cookie"}"#)
        XCTAssertFalse(structured.contains("escaped-secret"))
        XCTAssertFalse(structured.contains("json-cookie"))
    }

    @MainActor
    func testHistoricalAndExplicitlyExportedLogsAreRedactedAndPrivate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("logs.json")
        let entry = LogEntry(level: .warning, category: .network, message: "password=old-secret 203.0.113.8")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([entry]).write(to: file)
        let logger = AppLogger(logFileURL: file)
        XCTAssertFalse(logger.entries[0].message.contains("old-secret"))
        XCTAssertFalse(logger.exportText([entry]).contains("203.0.113.8"))
        await logger.flush()
        let saved = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(saved.contains("old-secret"))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testDualStackDNSLongConnectionPolicyAndTLSForwardingAcrossModes() throws {
        let node = ProxyNode(name: "fixture", protocolType: .vless, server: "node.example", port: 443,
                             uuid: "11111111-1111-4111-8111-111111111111", security: .tls)
        for mode in RoutingMode.allCases {
            let config = try XrayConfigBuilder.build(node: node,
                ports: .init(socksHost: "127.0.0.1", socksPort: 10808, httpHost: "127.0.0.1", httpPort: 10809),
                routingMode: mode)
            let dns = try XCTUnwrap(config["dns"] as? [String: Any])
            XCTAssertEqual(dns["queryStrategy"] as? String, "UseIP")
            XCTAssertEqual(dns["tag"] as? String, "dns-remote")
            let rules = try XCTUnwrap((config["routing"] as? [String: Any])?["rules"] as? [[String: Any]])
            let remote = try XCTUnwrap(rules.first { ($0["inboundTag"] as? [String]) == ["dns-remote"] })
            XCTAssertEqual(remote["outboundTag"] as? String, mode == .direct ? "direct" : "proxy")
            let policy = try XCTUnwrap((config["policy"] as? [String: Any])?["levels"] as? [String: [String: Int]])
            XCTAssertEqual(policy["0"]?["connIdle"], 3600)
            let inbounds = try XCTUnwrap(config["inbounds"] as? [[String: Any]])
            for inbound in inbounds where inbound["tag"] as? String != "api" {
                let sniffing = try XCTUnwrap(inbound["sniffing"] as? [String: Any])
                XCTAssertEqual(sniffing["routeOnly"] as? Bool, true)
                XCTAssertNil(inbound["streamSettings"], "Local inbounds must not terminate app TLS")
            }
            let outbound = try XCTUnwrap((config["outbounds"] as? [[String: Any]])?.first)
            let socket = try XCTUnwrap((outbound["streamSettings"] as? [String: Any])?["sockopt"] as? [String: Any])
            XCTAssertEqual(socket["domainStrategy"] as? String, "UseIPv4v6")
            XCTAssertEqual(socket["tcpKeepAliveIdle"] as? Int, 30)
        }
    }
}

extension AIConnectionQualityTests {
    func testNodeUsabilitySeparatesNormalSlowAndOccasionalTimeouts() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let settings = AppSettings()
        var usable = AIConnectionQuality()
        for _ in 0..<6 { usable.record(latencyMs: 200, timeoutSeconds: 3, at: now) }
        XCTAssertEqual(usable.usability(settings: settings, now: now).state, .usable)
        var timingOut = usable
        for _ in 0..<2 { timingOut.record(latencyMs: nil, timedOut: true, timeoutSeconds: 3, at: now) }
        XCTAssertEqual(timingOut.usability(settings: settings, now: now).state, .timeoutProne)
        XCTAssertTrue(timingOut.usability(settings: settings, now: now).detail.contains("节点仍能使用"))
        var slow = AIConnectionQuality()
        for latency in [2_000, 2_500, 3_000] { slow.record(latencyMs: latency, at: now) }
        XCTAssertEqual(slow.usability(settings: settings, now: now).state, .slow)
        var outlier = AIConnectionQuality()
        for latency in [100, 120, 9_000] { outlier.record(latencyMs: latency, at: now) }
        XCTAssertEqual(outlier.usability(settings: settings, now: now).state, .usable,
                       "One slow response does not establish a typically slow node")
    }

    func testShortOrUnclassifiedFailuresCannotProveNodeUnusable() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let settings = AppSettings()
        var short = AIConnectionQuality()
        for _ in 0..<10 { short.record(latencyMs: nil, timedOut: true, timeoutSeconds: 3, at: now) }
        XCTAssertEqual(short.usability(settings: settings, now: now).state, .unknown)
        var unclassified = AIConnectionQuality()
        for _ in 0..<10 { unclassified.record(latencyMs: nil, at: now) }
        XCTAssertEqual(unclassified.usability(settings: settings, now: now).state, .unknown)
        var insufficient = AIConnectionQuality()
        insufficient.record(latencyMs: 100, at: now)
        XCTAssertEqual(insufficient.usability(settings: settings, now: now).state, .unknown)
    }

    func testThreeConsecutiveGenerousConfirmationsCanProveNodeUnusableAndResponseEndsThatState() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var settings = AppSettings()
        settings.connectTimeoutSeconds = 15
        var quality = AIConnectionQuality()
        quality.record(latencyMs: 100, timeoutSeconds: 3, at: now)
        for offset in [1.0, 2] {
            quality.record(latencyMs: nil, timedOut: true, timeoutSeconds: 30, at: now.addingTimeInterval(offset))
        }
        XCTAssertNotEqual(quality.usability(settings: settings, now: now.addingTimeInterval(2)).state, .unavailable)
        quality.record(latencyMs: nil, timedOut: true, timeoutSeconds: 30, at: now.addingTimeInterval(3))
        XCTAssertEqual(quality.usability(settings: settings, now: now.addingTimeInterval(3)).state, .unavailable)
        quality.record(latencyMs: 300, timeoutSeconds: 30, at: now.addingTimeInterval(4))
        XCTAssertEqual(quality.usability(settings: settings, now: now.addingTimeInterval(4)).state, .timeoutProne)
        settings.connectTimeoutSeconds = 99
        XCTAssertNotEqual(quality.usability(settings: settings, now: now.addingTimeInterval(3)).state, .unavailable,
                          "Configured longer waiting must be honored before declaring failure")
    }

    func testUsabilityUsesFreshRecentSamplesAndValidTimeoutMetadata() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var settings = AppSettings()
        settings.testResultTTLMinutes = 1
        var expired = AIConnectionQuality()
        for _ in 0..<3 { expired.record(latencyMs: nil, timedOut: true, timeoutSeconds: 99, at: now.addingTimeInterval(-61)) }
        XCTAssertEqual(expired.usability(settings: settings, now: now).state, .unknown)
        var recovered = AIConnectionQuality()
        for _ in 0..<10 { recovered.record(latencyMs: nil, timedOut: true, timeoutSeconds: 3, at: now.addingTimeInterval(-10)) }
        for _ in 0..<20 { recovered.record(latencyMs: 100, timeoutSeconds: 3, at: now) }
        XCTAssertEqual(recovered.usability(settings: settings, now: now).state, .usable)
        var invalid = AIConnectionQuality()
        for _ in 0..<3 { invalid.record(latencyMs: nil, timedOut: true, timeoutSeconds: .nan, at: now) }
        XCTAssertEqual(invalid.usability(settings: settings, now: now).state, .unknown)
        var contradictory = AIConnectionQuality()
        for _ in 0..<3 { contradictory.record(latencyMs: 100, timedOut: true, at: now) }
        XCTAssertEqual(contradictory.usability(settings: settings, now: now).state, .usable)
        XCTAssertFalse(contradictory.samples.contains(where: \.timedOut))
    }
}
