#!/usr/bin/env python3
"""Exercise production connection validation without contacting public endpoints."""

from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]


def method(path, declaration):
    source = path.read_text()
    start = source.index("    " + declaration)
    end = source.index("\n    }", start) + len("\n    }")
    return source[start:end]


fixture = r'''
import Foundation

struct AppSettings {
    var testURL: String
    var favoritePreference = FavoritePreference.preferFavorites
    var failoverPoolMode = FailoverPoolMode.limited
    var maxFailoverAttempts = 3
    var automaticAppProbeTargets: [ProbeTarget] = []
    var autoAppProbeUsableNodes = false
    var codexSmartFailover = false
    func allowsAutoSelectNode(_ node: ProxyNode) -> Bool { node.enabled }
__VALIDATE_URL__
}
__PATIENCE_POLICY__
enum FavoritePreference { case favoritesOnly, preferFavorites, all }
enum FailoverPoolMode { case limited, allAvailable }
struct ProbeTarget { var id: String }
struct TestStatus { var isUsable = true }
struct ProxyNode {
    var id = UUID()
    var countryCode: String? = "US"
    var enabled = true
    var pendingRemoval = false
    var lastTestStatus = TestStatus()
    var isFavorite = true
    static func autoSelectLessThan(_ lhs: Self, _ rhs: Self, considerAppProbe: Bool,
                                  appOrder: [String], preferFavorites: Bool) -> Bool { false }
}
enum CountryResolver {
    static func effectiveCode(for node: ProxyNode) -> String? { node.countryCode }
}
enum ApplicationHealthFailoverPolicy {
__ORDERED_CANDIDATES__
}
struct ConnectionState {
    var latency: Int?
    mutating func recordLatency(_ value: Int) { latency = value }
}
@MainActor enum ProxyHTTPTester {
    struct HTTPSOutcome { let latency: Int? }
    static var urls: [URL] = []
    static var timeouts: [TimeInterval] = []
    static var results: [Int?] = [42]
    static var onMeasure: ((Int) -> Void)?

    static func reset(_ values: [Int?]) {
        urls = []; timeouts = []; results = values; onMeasure = nil
    }

    static func diagnoseHTTPS(url: URL, httpProxyHost: String, httpProxyPort: Int,
                              timeout: TimeInterval) async -> HTTPSOutcome {
        precondition(httpProxyHost == "127.0.0.1" && httpProxyPort == 12345)
        precondition(timeout >= 1 && timeout <= 99)
        urls.append(url)
        timeouts.append(timeout)
        precondition(!results.isEmpty, "A verification pass must never make unbounded retries")
        let latency = results.removeFirst()
        onMeasure?(urls.count)
        return HTTPSOutcome(latency: latency)
    }
}
@MainActor final class ConnectionManager {
    var connectGeneration = 1
    var state = ConnectionState()
    var failoverStatus: String?
    var rankAutomaticCandidates: (([ProxyNode]) -> [ProxyNode])?
__VERIFY_CONNECTIVITY__
__FAILOVER_CHAIN__

    func candidates(_ nodes: [ProxyNode], settings: AppSettings) -> [ProxyNode] {
        buildFailoverChain(preferred: nodes[0], nodes: nodes, settings: settings, restrictToCountry: nil)
    }

    func check(_ url: String, timeout: TimeInterval = 15, generation: Int = 1) async -> Int? {
        await verifyConnectivity(settings: AppSettings(testURL: url), probePort: 12345,
                                 timeout: timeout, generation: generation)
    }
}
@main struct Check {
    @MainActor static func main() async {
        let manager = ConnectionManager()
        let configured = "https://probe.example.test/ready?scope=mine"
        let success = await manager.check(configured)
        precondition(success == 42 && manager.state.latency == 42)
        precondition(ProxyHTTPTester.urls.map(\.absoluteString) == [configured])

        precondition(ProxyHTTPTester.timeouts == [15])

        ProxyHTTPTester.reset([nil, 73])
        manager.failoverStatus = "正在尝试候选 1"
        ProxyHTTPTester.onMeasure = { call in
            if call == 2 { precondition(manager.failoverStatus?.contains("复验当前节点") == true) }
        }
        let delayed = await manager.check(configured)
        precondition(delayed == 73 && manager.state.latency == 73)
        precondition(manager.failoverStatus == "正在尝试候选 1", "The temporary confirmation message must restore the caller's progress")
        precondition(ProxyHTTPTester.urls.map(\.absoluteString) == [configured, configured])
        precondition(ProxyHTTPTester.timeouts[0] == 15 && ProxyHTTPTester.timeouts[1] > 15
                     && ProxyHTTPTester.timeouts[1] <= 30,
                     "Confirmation gets only the remaining fixed budget on this same node")

        ProxyHTTPTester.reset([nil, nil])
        let failure = await manager.check(configured)
        precondition(failure == nil && manager.state.latency == 73)
        precondition(ProxyHTTPTester.urls.map(\.absoluteString) == [configured, configured],
                     "A failed configured address must not trigger built-in fallback endpoints")

        ProxyHTTPTester.reset([nil, 99])
        let generous = await manager.check(configured, timeout: 99)
        precondition(generous == 99 && ProxyHTTPTester.timeouts.count == 2)
        precondition(ProxyHTTPTester.timeouts[0] == 99 && ProxyHTTPTester.timeouts[1] <= 99,
                     "Even an immediate first failure never restarts a new 99-second total budget")

        ProxyHTTPTester.reset([])
        for invalid in ["file:///tmp/probe", "https://user:password@example.test/"] {
            let result = await manager.check(invalid)
            precondition(result == nil && ProxyHTTPTester.urls.isEmpty)
        }
        let stale = await manager.check(configured, generation: 0)
        precondition(stale == nil && ProxyHTTPTester.urls.isEmpty)

        ProxyHTTPTester.reset([7])
        let httpURL = "http://private.example.test/ping"
        let http = await manager.check(httpURL)
        precondition(http == 7 && ProxyHTTPTester.urls.map(\.absoluteString) == [httpURL])

        ProxyHTTPTester.reset([nil, 8])
        ProxyHTTPTester.onMeasure = { _ in manager.connectGeneration += 1 }
        let superseded = await manager.check(configured)
        precondition(superseded == nil && manager.state.latency == 7)
        precondition(ProxyHTTPTester.urls.count == 1, "A superseded first failure must not retry")

        manager.connectGeneration = 1
        ProxyHTTPTester.reset([nil, 8])
        var cancelledTask: Task<Int?, Never>!
        ProxyHTTPTester.onMeasure = { _ in cancelledTask.cancel() }
        cancelledTask = Task { await manager.check(configured) }
        let cancelled = await cancelledTask.value
        precondition(cancelled == nil && manager.state.latency == 7)
        precondition(ProxyHTTPTester.urls.count == 1, "Cancellation after the first failure must prevent confirmation")

        ProxyHTTPTester.reset([nil, 8])
        ProxyHTTPTester.onMeasure = { call in
            if call == 2 { manager.connectGeneration += 1; manager.failoverStatus = "新连接的进度" }
        }
        let replacedDuringRetry = await manager.check(configured)
        precondition(replacedDuringRetry == nil && manager.state.latency == 7,
                     "An old confirmation result must not update a replacement connection")
        precondition(ProxyHTTPTester.urls.count == 2)
        precondition(manager.failoverStatus == "新连接的进度", "Old verification must not overwrite a replacement session's progress")

        let nodes = (0..<15).map { _ in ProxyNode() }
        var settings = AppSettings(testURL: configured)
        for preference in [FavoritePreference.preferFavorites, .favoritesOnly, .all] {
            settings.favoritePreference = preference
            for limit in [1, 3, 10] {
                settings.maxFailoverAttempts = limit
                let candidates = manager.candidates(nodes, settings: settings)
                precondition(candidates.count == limit && candidates.first?.id == nodes[0].id,
                             "Favorite order must respect the configured attempt limit")
            }
            settings.failoverPoolMode = .allAvailable
            precondition(manager.candidates(nodes, settings: settings).count == nodes.count)
            settings.failoverPoolMode = .limited
        }
        print("PASS: same configured address; bounded extended confirmation; maximum 99 seconds; HTTP preserved; stale/cancelled results rejected")
        print("PASS: limited failover respects attempt counts for every favorite preference; all-available mode preserved")
    }
}
'''
fixture = fixture.replace("__PATIENCE_POLICY__", (root / "HopWorld/Models/ConnectionPatience.swift").read_text())
fixture = fixture.replace("__VALIDATE_URL__", method(
    root / "HopWorld/Models/ConnectionState.swift", "static func validatedTestURL("))
fixture = fixture.replace("__VERIFY_CONNECTIVITY__", method(
    root / "HopWorld/Services/System/ConnectionManager.swift", "private func verifyConnectivity("))
fixture = fixture.replace("__FAILOVER_CHAIN__", method(
    root / "HopWorld/Services/System/ConnectionManager.swift", "private func buildFailoverChain("))
fixture = fixture.replace("__ORDERED_CANDIDATES__", method(
    root / "HopWorld/Models/ApplicationHealthFailover.swift", "static func orderedCandidates<"))
manager = (root / "HopWorld/Services/System/ConnectionManager.swift").read_text()
assert manager.count("verify: false") >= 2, (
    "User connect and failover connect must not gate on the configured probe URL")
assert "verify: true" not in manager, (
    "No connect path should still require probe verification before takeover")
assert "let requiresProbe = settings.routingMode != .direct" in manager, (
    "Network revalidation must skip probe reachability in direct routing")

with tempfile.TemporaryDirectory(prefix="hopworld-test-url-", dir="/tmp") as temporary:
    directory = Path(temporary)
    source = directory / "ConnectionTestURLCheck.swift"
    source.write_text(fixture)
    executable = directory / "check"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(source), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
print("PASS: connect skips probe gates; direct routing still skips revalidation probes")
