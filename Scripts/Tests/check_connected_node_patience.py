#!/usr/bin/env python3
"""Check the production connected-node recovery gate without network or user data."""

from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / "HopWorld/App/AppState.swift").read_text()
start = source.index("    private func currentNodeNeedsEligibilityRecovery(")
end = source.index("\n    }", start) + len("\n    }")
method = source[start:end]

fixture = r'''
import Foundation

enum Usability { case unavailable, timeoutProne, slow, usable, unknown }
struct Assessment { let state: Usability }
struct Quality {
    let state: Usability
    let measuredAt: Date
    func usability(settings: AppSettings, now: Date) -> Assessment {
        Assessment(state: (0...60).contains(now.timeIntervalSince(measuredAt)) ? state : .unknown)
    }
}
struct ProxyNode {
    let id = UUID()
    var enabled = true
    var pendingRemoval = false
    var countryCode: String? = "US"
    var speedPassesCandidateFilter = false
    var appProbePassesCandidateFilter = false
}
struct AppSettings {
    var blocked: Set<UUID> = []
    var excludedCountries: Set<String> = []
    func isTemporarilyBlocked(_ id: UUID) -> Bool { blocked.contains(id) }
    func allowsAutoSelectCountry(_ code: String?) -> Bool { !excludedCountries.contains(code ?? "XX") }
    func allowsAutoSelectNode(_ node: ProxyNode) -> Bool {
        node.speedPassesCandidateFilter && node.appProbePassesCandidateFilter
    }
}
enum CountryResolver {
    static func effectiveCode(for node: ProxyNode) -> String? { node.countryCode }
}
struct Connection { var nodeQuality: [UUID: Quality] = [:] }
@MainActor final class AppState {
    var settings = AppSettings()
    var connection = Connection()
__PRODUCTION_GATE__
    func needsRecovery(_ node: ProxyNode, now: Date) -> Bool {
        currentNodeNeedsEligibilityRecovery(node, now: now)
    }
}
@main struct Check {
    @MainActor static func main() {
        let app = AppState()
        let node = ProxyNode()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        precondition(!app.settings.allowsAutoSelectNode(node), "Fixture deliberately fails candidate ranking")
        for state in [Usability.slow, .timeoutProne, .usable, .unknown] {
            app.connection.nodeQuality[node.id] = Quality(state: state, measuredAt: now)
            precondition(!app.needsRecovery(node, now: now),
                         "A slow, occasionally timing-out, usable, or unconfirmed node must not be replaced for ranking alone")
        }
        app.connection.nodeQuality = [:]
        precondition(!app.needsRecovery(node, now: now), "Missing observations never establish unusability")
        app.connection.nodeQuality[node.id] = Quality(state: .unavailable, measuredAt: now)
        precondition(app.needsRecovery(node, now: now), "A current confirmed unavailable assessment may request recovery")
        precondition(!app.needsRecovery(node, now: now.addingTimeInterval(61)),
                     "The gate must request fresh classification rather than trusting expired failure data")

        app.connection.nodeQuality[node.id] = Quality(state: .usable, measuredAt: now)
        var disabled = node; disabled.enabled = false
        precondition(app.needsRecovery(disabled, now: now))
        var removed = node; removed.pendingRemoval = true
        precondition(app.needsRecovery(removed, now: now))
        app.settings.blocked.insert(node.id)
        precondition(app.needsRecovery(node, now: now))
        app.settings.blocked.removeAll()
        app.settings.excludedCountries.insert("US")
        precondition(app.needsRecovery(node, now: now))
        app.settings.excludedCountries.removeAll()
        precondition(!app.needsRecovery(node, now: now))
        print("PASS: slow/timeout-prone/usable/unknown nodes retained; only fresh unusability or explicit exclusions request recovery")
    }
}
'''.replace("__PRODUCTION_GATE__", method)

with tempfile.TemporaryDirectory(prefix="hopworld-node-patience-", dir="/tmp") as temporary:
    directory = Path(temporary)
    swift = directory / "ConnectedNodePatienceCheck.swift"
    swift.write_text(fixture)
    executable = directory / "check"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(swift), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
