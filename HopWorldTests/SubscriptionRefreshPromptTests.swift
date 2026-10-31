import XCTest

final class SubscriptionRefreshPromptTests: XCTestCase {
    private func node(_ name: String, server: String = "example.com") -> ProxyNode {
        var node = ProxyNode(name: name, protocolType: .vless, server: server, port: 443,
                             uuid: "11111111-1111-1111-1111-111111111111")
        node.nodeFingerprint = NodeFingerprint.make(from: node)
        return node
    }

    func testNotModifiedAndIdenticalContentDoNotRequestAnotherTest() {
        let baseline = [node("A")]
        // Both HTTP 304 and the unchanged-body path keep the original node collection.
        XCTAssertFalse(SubscriptionMerger.hasNodeChanges(before: baseline, after: baseline))
        XCTAssertFalse(SubscriptionMerger.hasNodeChanges(before: [], after: []))
    }

    func testMatchingMergeCountsDoNotMeanNodesActuallyChanged() {
        let baseline = [node("A")]
        for mode in [SubscriptionUpdateMode.overwrite, .merge, .smartMerge] {
            let plan = SubscriptionMerger.buildPlan(mode: mode, oldNodes: baseline,
                                                   newNodes: [node("A")], missingLimit: 3)
            XCTAssertGreaterThan(plan.updatedCount, 0)
            XCTAssertFalse(SubscriptionMerger.hasNodeChanges(before: baseline, after: plan.resultingNodes))
        }
    }

    func testNodeOrderDoesNotTriggerPrompt() {
        let baseline = [node("A", server: "a.example"), node("B", server: "b.example")]
        XCTAssertFalse(SubscriptionMerger.hasNodeChanges(before: baseline, after: Array(baseline.reversed())))
    }

    func testRuntimeObservationsDoNotTriggerPrompt() {
        let old = node("A")
        var observed = old
        observed.lastLatency = 120
        observed.lastTestStatus = .fast
        observed.lastTestDate = Date()
        observed.lastTestErrorMessage = "HTTPS 探测超时（2 秒）"
        observed.lastAvailableAt = Date()
        observed.unavailableSince = Date()
        observed.lastAppProbeDate = Date()
        observed.lastAppProbeOkCount = 2
        observed.lastAppProbeLatency = 80
        observed.lastAppProbePassedIDs = ["chatgpt"]
        observed.countryCode = "GB"
        observed.countryName = "英国"
        observed.pendingConfigUpdate = true
        observed.exitMetadata = .init(ip: "203.0.113.1", city: "London", networkOperator: "Example ISP",
                                     asn: "AS64500", networkType: .hosting, countryCode: "GB", localizedCity: "伦敦")
        XCTAssertFalse(SubscriptionMerger.hasNodeChanges(before: [old], after: [observed]))
    }

    func testFailureReasonRoundTripsAndOlderNodeDataDecodesWithoutIt() throws {
        var failed = node("A")
        failed.lastTestStatus = .unavailable
        failed.lastTestErrorMessage = "HTTPS 探测超时（2 秒）\n完整诊断"
        let encoded = try JSONEncoder().encode(failed)
        XCTAssertEqual(try JSONDecoder().decode(ProxyNode.self, from: encoded).lastTestErrorMessage,
                       failed.lastTestErrorMessage)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "lastTestErrorMessage")
        let decoded = try JSONDecoder().decode(ProxyNode.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.lastTestStatus, .unavailable)
        XCTAssertNil(decoded.lastTestErrorMessage)
    }

    func testRefreshAcceptsAndPreservesConcurrentFailureDiagnostics() throws {
        let subscriptionID = UUID()
        var original = node("A")
        original.subscriptionID = subscriptionID
        var latest = original
        latest.lastTestStatus = .unavailable
        latest.lastTestDate = Date()
        latest.lastTestErrorMessage = "HTTPS/TLS 握手失败"
        let committed = try XCTUnwrap(SubscriptionMerger.commitRefresh(
            subscriptionID: subscriptionID, baseline: [original], proposed: [original], current: [latest]
        ))
        XCTAssertEqual(committed.first?.lastTestStatus, .unavailable)
        XCTAssertEqual(committed.first?.lastTestErrorMessage, latest.lastTestErrorMessage)
        XCTAssertFalse(SubscriptionMerger.hasNodeChanges(before: [original], after: [latest]))
    }

    func testMergePreservesFailureReasonUntilConnectionConfigurationChanges() {
        var old = node("A")
        old.lastTestStatus = .failed
        old.lastTestErrorMessage = "缺少 UUID"
        for mode in [SubscriptionUpdateMode.overwrite, .merge, .smartMerge] {
            let unchanged = SubscriptionMerger.buildPlan(mode: mode, oldNodes: [old], newNodes: [node("A")], missingLimit: 3)
            XCTAssertEqual(unchanged.resultingNodes.first?.lastTestErrorMessage, old.lastTestErrorMessage)
            var changed = node("A")
            changed.uuid = "22222222-2222-4222-8222-222222222222"
            changed.nodeFingerprint = NodeFingerprint.make(from: changed)
            let updated = SubscriptionMerger.buildPlan(mode: mode, oldNodes: [old], newNodes: [changed], missingLimit: 3)
            XCTAssertEqual(updated.resultingNodes.first?.lastTestStatus, .untested)
            XCTAssertNil(updated.resultingNodes.first?.lastTestErrorMessage)
        }
        old.lastTestStatus = .fast
        old.refreshLatencyTier()
        XCTAssertNil(old.lastTestErrorMessage)
    }

    func testAddedAndDeletedNodesTriggerPrompt() {
        let a = node("A", server: "a.example")
        let b = node("B", server: "b.example")
        XCTAssertTrue(SubscriptionMerger.hasNodeChanges(before: [a], after: [a, b]))
        XCTAssertTrue(SubscriptionMerger.hasNodeChanges(before: [a, b], after: [a]))
    }

    func testChangedConnectionConfigurationTriggersPrompt() {
        let old = node("A")
        var edited = old
        edited.port = 8443
        edited.nodeFingerprint = NodeFingerprint.make(from: edited)
        XCTAssertTrue(SubscriptionMerger.hasNodeChanges(before: [old], after: [edited]))
        var uncachedOld = old
        uncachedOld.nodeFingerprint = nil
        edited.nodeFingerprint = nil
        XCTAssertTrue(SubscriptionMerger.hasNodeChanges(before: [uncachedOld], after: [edited]))
    }

    func testRenamedNodeTriggersPromptEvenIfConnectionIsUnchanged() {
        let old = node("A")
        var renamed = old
        renamed.name = "A renamed"
        XCTAssertTrue(SubscriptionMerger.hasNodeChanges(before: [old], after: [renamed]))
    }

    func testPendingRemovalChangesTriggerPrompt() {
        let old = node("A")
        var removed = old
        removed.pendingRemoval = true
        XCTAssertTrue(SubscriptionMerger.hasNodeChanges(before: [old], after: [removed]))
        XCTAssertTrue(SubscriptionMerger.hasNodeChanges(before: [removed], after: [old]))
    }

    func testSmartMergeBelowMissingLimitDoesNotTriggerPrompt() {
        let a = node("A", server: "a.example")
        let b = node("B", server: "b.example")
        let plan = SubscriptionMerger.buildPlan(mode: .smartMerge, oldNodes: [a, b],
                                               newNodes: [node("A", server: "a.example")], missingLimit: 3)
        XCTAssertEqual(plan.resultingNodes.first(where: { $0.id == b.id })?.missingCount, 1)
        XCTAssertFalse(SubscriptionMerger.hasNodeChanges(before: [a, b], after: plan.resultingNodes))
    }

    func testSmartMergeRemovalAndDeferredFavoriteRemovalTriggerPrompt() {
        let a = node("A", server: "a.example")
        for favorite in [false, true] {
            var b = node("B", server: "b.example")
            b.missingCount = 2
            b.isFavorite = favorite
            let plan = SubscriptionMerger.buildPlan(mode: .smartMerge, oldNodes: [a, b],
                                                   newNodes: [node("A", server: "a.example")], missingLimit: 3)
            XCTAssertTrue(SubscriptionMerger.hasNodeChanges(before: [a, b], after: plan.resultingNodes))
        }
    }

    func testCachedFingerprintAvoidsTreatingCredentialStorageAsConfigurationChange() {
        let old = node("A")
        var stored = old
        stored.uuid = nil
        stored.password = nil
        stored.credentialKey = UUID().uuidString
        XCTAssertFalse(SubscriptionMerger.hasNodeChanges(before: [old], after: [stored]))
    }
}

private final class SubscriptionTransportFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        switch request.url!.path {
        case "/direct", "/http-error", "/origin-certificate-error":
            let status = request.url!.path == "/direct" ? 200 : (request.url!.path == "/origin-certificate-error" ? 526 : 403)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["ETag": "direct-tag"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("direct subscription payload".utf8))
            client?.urlProtocolDidFinishLoading(self)
        case "/certificate":
            client?.urlProtocol(self, didFailWithError: URLError(.serverCertificateUntrusted))
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.secureConnectionFailed))
        }
    }
    override func stopLoading() {}
}

final class SubscriptionFetcherTests: XCTestCase {
    @MainActor
    func testOriginCertificateFailureKeepsNodesAndRecordsHTTPStatus() async {
        let successfulAt = Date(timeIntervalSince1970: 1_700_000_000)
        let subscription = Subscription(name: "manifest fixture", originalURL: "https://fixture.invalid/origin-certificate-error",
                                        lastSuccessAt: successfulAt, updateFailureCount: 47,
                                        etag: "last-good-tag", contentHash: "last-good-hash", nodeCount: 1)
        let node = ProxyNode(name: "last good node", protocolType: .http, server: "127.0.0.1", port: 1,
                             subscriptionID: subscription.id)
        let manager = SubscriptionManager(fetcher: fetcher())
        let (updated, nodes, log) = await manager.update(subscription, existingNodes: [node])
        XCTAssertFalse(log.success)
        XCTAssertEqual(updated.lastHTTPStatus, 526)
        XCTAssertEqual(log.httpStatus, 526)
        XCTAssertTrue(updated.lastError?.contains("订阅源站证书校验失败") == true)
        XCTAssertEqual(updated.updateFailureCount, 48)
        XCTAssertNotNil(updated.nextRetryAt)
        XCTAssertEqual(updated.lastSuccessAt, successfulAt)
        XCTAssertEqual(updated.etag, "last-good-tag")
        XCTAssertEqual(updated.contentHash, "last-good-hash")
        XCTAssertEqual(nodes, [node])
        XCTAssertEqual(updated.nodeCount, 1)
        XCTAssertEqual(manager.updateState, .idle)
    }

    func testClashPlainScalarContinuationDoesNotRejectSubscription() throws {
        let yaml = """
        proxies:
        - type: vmess
          name: wrapped
            node name
          server: example.com
          port: 443
          uuid: 11111111-1111-4111-8111-111111111111
          network: ws
          ws-opts:
            headers:
              Host: example.com
              User-Agent: Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.36
                Chrome/70.0.3538.110 Safari/537.36
            path: /proxy
        - {type: socks5, name: second, server: example.org, port: 1080}
        """
        let result = try SubscriptionContentParser.parse(data: Data(yaml.utf8))
        XCTAssertEqual(result.validNodes.count, 2)
        XCTAssertEqual(result.validNodes[0].name, "wrapped node name")
        XCTAssertEqual(result.validNodes[0].host, "example.com")
        XCTAssertEqual(result.validNodes[0].path, "/proxy")
        XCTAssertEqual(result.validNodes[1].name, "second")
        XCTAssertThrowsError(try ClashYAMLParser.parse(yaml.replacingOccurrences(of: "node name", with: "server: invalid.example")))
    }

    private func fetcher() -> SubscriptionFetcher {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SubscriptionTransportFixture.self]
        return SubscriptionFetcher(session: URLSession(configuration: config))
    }

    func testDirectSuccessAndServerErrorsDoNotUseTemporaryProxy() async throws {
        let fetcher = fetcher()
        let node = ProxyNode(name: "unreachable", protocolType: .http, server: "127.0.0.1", port: 1)
        let response = try await fetcher.fetch(urlString: "https://fixture.invalid/direct", fallbackNodes: [node])
        XCTAssertEqual(response.etag, "direct-tag")
        XCTAssertFalse(response.usedTemporaryProxy)
        do {
            _ = try await fetcher.fetch(urlString: "https://fixture.invalid/http-error", fallbackNodes: [node])
            XCTFail("HTTP errors must be preserved")
        } catch SubscriptionFetcherError.httpError(let status) { XCTAssertEqual(status, 403) }
        do {
            _ = try await fetcher.fetch(urlString: "https://fixture.invalid/certificate", fallbackNodes: [node])
            XCTFail("Certificate validation must remain enabled")
        } catch let error as URLError { XCTAssertEqual(error.code, .serverCertificateUntrusted) }
        do {
            _ = try await fetcher.fetch(urlString: "https://fixture.invalid/sub")
            XCTFail("No nodes must preserve the direct error")
        } catch let error as URLError { XCTAssertEqual(error.code, .secureConnectionFailed) }
    }

    func testTemporaryProxyCandidatesRespectDisabledAndRemovedNodes() {
        var nodes = (0..<6).map { ProxyNode(name: "\($0)", protocolType: .http, server: "127.0.0.1", port: 8080) }
        nodes[0].enabled = false
        nodes[1].pendingRemoval = true
        nodes[4].lastTestStatus = .fast
        nodes[4].lastLatency = 500
        nodes[5].lastTestStatus = .fast
        nodes[5].lastLatency = 800
        XCTAssertEqual(SubscriptionFetcher.temporaryProxyCandidates(nodes).map(\.name), ["4", "5", "2"])
        XCTAssertFalse(SubscriptionFetcher.shouldTryTemporaryProxy(URLError(.cancelled)))
        XCTAssertFalse(SubscriptionFetcher.shouldTryTemporaryProxy(URLError(.appTransportSecurityRequiresSecureConnection)))
    }

    func testTLSFailureDownloadsThroughIsolatedCoreAndCleansUp() async throws {
        guard await XrayProcessManager.resolveBinaryURLForTesting() != nil else { throw XCTSkip("Xray unavailable") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("subscription-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("proxy.py")
        let portFile = directory.appendingPathComponent("port")
        try #"""
import socketserver, sys, time
class Proxy(socketserver.StreamRequestHandler):
    def headers(self):
        lines = []
        while True:
            line = self.rfile.readline()
            if line in (b'\r\n', b'\n', b''): return b''.join(lines)
            lines.append(line)
    def handle(self):
        if not self.rfile.readline().startswith(b'CONNECT '): return
        self.headers()
        self.wfile.write(b'HTTP/1.1 200 Connection established\r\n\r\n')
        self.wfile.flush()
        path = self.rfile.readline().split()[1]
        headers = self.headers().lower()
        if path == b'/slow': time.sleep(10)
        if path == b'/redirect':
            response = b'HTTP/1.1 302 Found\r\nLocation: http://fixture.invalid/sub\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
        elif b'if-none-match: fixture-tag' in headers and b'if-modified-since: fixture-date' in headers:
            response = b'HTTP/1.1 304 Not Modified\r\nConnection: close\r\n\r\n'
        else:
            body = b'subscription fixture\n' * 5000
            response = b'HTTP/1.1 200 OK\r\nETag: fixture-tag\r\nLast-Modified: fixture-date\r\nConnection: close\r\nContent-Length: ' + str(len(body)).encode() + b'\r\n\r\n' + body
        self.wfile.write(response)
class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
with Server(('127.0.0.1', 0), Proxy) as server:
    with open(sys.argv[1], 'w') as f: f.write(str(server.server_address[1]))
    server.serve_forever()
"""#.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, portFile.path]
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: portFile.path) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let port = try XCTUnwrap(Int(String(contentsOf: portFile, encoding: .utf8)))
        let node = ProxyNode(name: "local fixture", protocolType: .http, server: "127.0.0.1", port: port)
        let before = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/sbin/scutil"), arguments: ["--proxy"], timeout: 3)
        let fetcher = fetcher()
        let deadNode = ProxyNode(name: "dead fixture", protocolType: .http, server: "127.0.0.1", port: 1)
        let response = try await fetcher.fetch(urlString: "http://fixture.invalid/redirect", fallbackNodes: [deadNode, node])
        XCTAssertTrue(response.usedTemporaryProxy)
        XCTAssertEqual(response.data.count, 105_000)
        XCTAssertEqual(response.etag, "fixture-tag")
        XCTAssertEqual(response.lastModified, "fixture-date")
        let cached = try await fetcher.fetch(urlString: "http://fixture.invalid/sub", etag: response.etag,
                                             lastModified: response.lastModified, fallbackNodes: [node])
        XCTAssertEqual(cached.statusCode, 304)
        XCTAssertTrue(cached.notModified)
        XCTAssertTrue(cached.data.isEmpty)
        XCTAssertEqual(cached.etag, response.etag)
        do {
            _ = try await fetcher.fetch(urlString: "http://fixture.invalid/sub", fallbackNodes: [deadNode])
            XCTFail("Failed fallback must report failure")
        } catch SubscriptionFetcherError.automaticRouteFailed { }
        let cancelled = Task {
            try await fetcher.fetch(urlString: "http://fixture.invalid/slow", fallbackNodes: [node])
        }
        try await Task.sleep(nanoseconds: 800_000_000)
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Cancellation must propagate")
        } catch is CancellationError { }
        let after = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/sbin/scutil"), arguments: ["--proxy"], timeout: 3)
        XCTAssertEqual(before.output, after.output)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
        XCTAssertFalse(remaining.contains { $0.hasPrefix("HopWorld-subscription-") })
    }
}
