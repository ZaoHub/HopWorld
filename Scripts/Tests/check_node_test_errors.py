#!/usr/bin/env python3
"""Check persisted test diagnostics with production models, merge and result application."""
import subprocess
import tempfile
from pathlib import Path

from check_app_probe_batches import declaration, root

app = (root / "HopWorld/App/AppState.swift").read_text()
connection = (root / "HopWorld/Models/ConnectionState.swift").read_text()
crypto = (root / "HopWorld/Utilities/CryptoUtil.swift").read_text()
fixture = "import Foundation\nimport CryptoKit\n"
fixture += "\n".join(declaration(connection, signature, "") for signature in [
    "enum TestStage:", "struct NodeTestResult:", "struct NodeExitMetadata:", "enum ExitIPType:",
])
fixture += "\n" + "\n".join(declaration(crypto, signature, "") for signature in [
    "enum CryptoUtil", "enum NodeFingerprint",
])
fixture += r'''
struct AppSettings {
    var autoAppProbeUsableNodes = false
    func shouldResolveChineseCity(for node: ProxyNode) -> Bool { false }
}
enum Status { case disconnected, connected }
struct Connection { struct State { var status = Status.disconnected; var currentNodeID: UUID? }; var state = State() }
enum CountryResolver {
    static func applyExitIP(to node: inout ProxyNode, countryCode: String, countryName: String?) {
        node.countryCode = countryCode; node.countryName = countryName
    }
}
@MainActor final class AppState {
    var nodes: [ProxyNode] = []
    var settings = AppSettings()
    var connection = Connection()
    func persist() {}
    func persistAppProbeSummary(nodeID: UUID) {}
    func localizeCity(nodeID: UUID, metadata: NodeExitMetadata, eligible: Bool) {}
    func apply(_ result: NodeTestResult, strict: Bool = false) {
        applyTestResult(to: &nodes, index: 0, result: result, strictResults: strict)
    }
    func reset() { resetNodesForRetest(ids: Set(nodes.map { $0.id })) }
    func clearStuck() { clearStuckTestingStatuses(except: []) }
    func syncApps() { syncNodeStatusFromAppProbe(nodeID: nodes[0].id) }
__METHODS__
}
@main struct Check {
    @MainActor static var count = 0
    @MainActor static func check(_ value: Bool, _ message: String) {
        count += 1
        precondition(value, message)
    }
    static func node() -> ProxyNode {
        ProxyNode(name: "fixture", protocolType: .vless, server: "example.com", port: 443,
                  uuid: "11111111-1111-4111-8111-111111111111")
    }
    @MainActor static func main() throws {
        let state = AppState()
        state.nodes = [node()]
        let reason = "HTTPS 探测超时（2 秒）\n" + String(repeating: "完整诊断", count: 100)
        state.apply(NodeTestResult(nodeID: state.nodes[0].id, configValid: true,
                                   failureStage: .http, errorMessage: " \n" + reason + "\n "))
        check(state.nodes[0].lastTestStatus == .unavailable && state.nodes[0].lastTestErrorMessage == reason,
              "unavailable result stores the complete reason with only surrounding whitespace trimmed")
        state.apply(NodeTestResult(nodeID: state.nodes[0].id, failureStage: .config, errorMessage: "缺少 UUID"))
        check(state.nodes[0].lastTestStatus == .failed && state.nodes[0].lastTestErrorMessage == "缺少 UUID",
              "configuration failure stores its reason separately from unavailable results")
        for empty in [nil, "", " \n ", "TCP_PASS"] as [String?] {
            state.apply(NodeTestResult(nodeID: state.nodes[0].id, configValid: true, failureStage: .http, errorMessage: empty))
            check(state.nodes[0].lastTestErrorMessage == nil, "empty or internal markers never become display reasons")
        }
        state.nodes[0].lastTestErrorMessage = reason
        state.apply(NodeTestResult(nodeID: state.nodes[0].id, configValid: true, proxyLatency: 120,
                                   success: true, errorMessage: "stale diagnostic"))
        check(state.nodes[0].lastTestStatus.isUsable && state.nodes[0].lastTestErrorMessage == nil,
              "success clears a previous error even if the result carries stale diagnostic text")
        state.connection.state.status = .connected
        state.connection.state.currentNodeID = state.nodes[0].id
        state.nodes[0].lastTestErrorMessage = reason
        let failure = NodeTestResult(nodeID: state.nodes[0].id, configValid: true,
                                     failureStage: .http, errorMessage: reason)
        state.apply(failure)
        check(state.nodes[0].lastTestStatus.isUsable && state.nodes[0].lastTestErrorMessage == nil,
              "protected usable connection does not retain an unavailable error")
        state.apply(failure, strict: true)
        check(state.nodes[0].lastTestStatus == .unavailable && state.nodes[0].lastTestErrorMessage == reason,
              "strict result replaces the protected status and records its actual failure")
        state.reset()
        check(state.nodes[0].lastTestStatus == .testing && state.nodes[0].lastTestErrorMessage == nil,
              "starting a new test removes the previous failure reason")
        state.nodes[0].lastTestErrorMessage = reason
        state.clearStuck()
        check(state.nodes[0].lastTestStatus == .untested && state.nodes[0].lastTestErrorMessage == nil,
              "clearing interrupted testing removes stale failure reasons")
        state.nodes[0].lastTestStatus = .fast
        state.nodes[0].lastTestErrorMessage = reason
        state.reset()
        check(state.nodes[0].lastTestStatus == .fast && state.nodes[0].lastTestErrorMessage == nil,
              "retesting a protected usable connection clears the reason even when retaining its tier")
        state.nodes[0].lastTestStatus = .unavailable
        state.nodes[0].lastTestErrorMessage = reason
        state.nodes[0].lastAppProbeOkCount = 3
        state.nodes[0].lastAppProbeLatency = 120
        state.syncApps()
        check(state.nodes[0].lastTestStatus.isUsable && state.nodes[0].lastTestErrorMessage == nil,
              "successful application probes clear failure details when correcting node status")

        var original = node()
        original.subscriptionID = UUID()
        original.lastTestStatus = .unavailable
        original.lastTestErrorMessage = reason
        let data = try JSONEncoder().encode(original)
        check(try JSONDecoder().decode(ProxyNode.self, from: data).lastTestErrorMessage == reason,
              "node error reason survives persistence")
        var legacy = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        legacy.removeValue(forKey: "lastTestErrorMessage")
        let older = try JSONDecoder().decode(ProxyNode.self, from: JSONSerialization.data(withJSONObject: legacy))
        check(older.lastTestErrorMessage == nil && older.lastTestStatus == .unavailable, "older libraries decode without a diagnostic field")
        var latest = original
        latest.lastTestStatus = .failed
        latest.lastTestErrorMessage = "最新诊断"
        let committed = SubscriptionMerger.commitRefresh(subscriptionID: original.subscriptionID!,
                                                        baseline: [original], proposed: [original], current: [latest])
        check(committed?.first?.lastTestErrorMessage == "最新诊断", "refresh ignores concurrent diagnostic changes in its baseline and preserves the latest value")
        check(!SubscriptionMerger.hasNodeChanges(before: [original], after: [latest]), "diagnostics alone do not request another subscription test")
        for mode in [SubscriptionUpdateMode.overwrite, .merge, .smartMerge] {
            let same = SubscriptionMerger.buildPlan(mode: mode, oldNodes: [original], newNodes: [original], missingLimit: 3)
            check(same.resultingNodes[0].lastTestErrorMessage == reason, "unchanged configuration preserves failure details")
            var incoming = original
            incoming.uuid = "22222222-2222-4222-8222-222222222222"
            let changed = SubscriptionMerger.buildPlan(mode: mode, oldNodes: [original], newNodes: [incoming], missingLimit: 3)
            check(changed.resultingNodes[0].lastTestStatus == .untested && changed.resultingNodes[0].lastTestErrorMessage == nil,
                  "connection changes invalidate failure details along with other measurements")
        }
        print("Node test diagnostics: \(count) checks, 0 failures")
    }
}
'''
fixture = fixture.replace('__METHODS__', '\n'.join(declaration(app, signature) for signature in [
    'private func applyTestResult(to', 'private func resetNodesForRetest(',
    'private func clearStuckTestingStatuses(', 'private func syncNodeStatusFromAppProbe(',
]))
with tempfile.TemporaryDirectory(prefix='hopworld-test-errors-') as directory:
    source = Path(directory) / 'Check.swift'
    source.write_text(fixture)
    binary = Path(directory) / 'check'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library',
                    str(root / 'HopWorld/Models/ProxyNode.swift'),
                    str(root / 'HopWorld/Models/Subscription.swift'),
                    str(root / 'HopWorld/Utilities/LatencyFormat.swift'),
                    str(root / 'HopWorld/Services/Subscription/SubscriptionMerger.swift'),
                    str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
