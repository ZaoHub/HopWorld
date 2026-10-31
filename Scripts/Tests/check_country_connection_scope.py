#!/usr/bin/env python3
"""Run production country connection and recovery paths without changing network state."""

from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
source_root = Path(sys.argv[1]) if len(sys.argv) > 1 else None
app_source = (source_root / "AppState.swift" if source_root else root / "HopWorld/App/AppState.swift").read_text()
manager_source = (source_root / "ConnectionManager.swift" if source_root else root / "HopWorld/Services/System/ConnectionManager.swift").read_text()
policy_source = (root / "HopWorld/Models/ApplicationHealthFailover.swift").read_text()


def method(source, declaration):
    start = source.index("    " + declaration)
    end = source.index("\n    }", start) + len("\n    }")
    return source[start:end]


fixture = r'''
import Foundation

enum ConnectionStatus { case disconnected, connecting, connected, disconnecting, error }
enum CaptureMode { case systemProxy, globalTun }
enum FailoverPoolMode { case limited, allAvailable }
enum FavoritePreference { case all, preferFavorites, favoritesOnly }
enum NodeTestStatus {
    case available, unavailable
    var isUsable: Bool { self == .available }
}
enum ConnectionError: Error { case cancelled, noCandidates, connectFailed }
struct ApplicationProxyError: Error {}
struct FixtureLabel { var displayName = "fixture" }
struct ProxyNode {
    let id = UUID()
    var name: String
    var countryCode: String?
    var countryName: String?
    var priority: Int
    var enabled = true
    var pendingRemoval = false
    var pendingConfigUpdate = false
    var isFavorite = false
    var lastTestStatus = NodeTestStatus.available
    var protocolType = FixtureLabel()
    var transport = FixtureLabel()
    var security = FixtureLabel()
    var server = "127.0.0.1"
    var port = 1
    static func autoSelectLessThan(_ lhs: Self, _ rhs: Self, considerAppProbe: Bool,
                                   appOrder: [String], preferFavorites: Bool) -> Bool {
        lhs.priority < rhs.priority
    }
}
struct CountryGroup { var code: String; var name: String; var flag: String; var nodes: [ProxyNode] }
struct AppTarget { var id: String }
struct AppSettings {
    var autoFailover = true
    var connectionCaptureMode = CaptureMode.systemProxy
    var favoritePreference = FavoritePreference.all
    var failoverPoolMode = FailoverPoolMode.limited
    var maxFailoverAttempts = 5
    var autoAppProbeUsableNodes = false
    var automaticAppProbeTargets: [AppTarget] = []
    var codexSmartFailover = false
    var scheduledTestIntervalMinutes = 30
    func allowsAutoSelectNode(_ node: ProxyNode) -> Bool { node.lastTestStatus.isUsable }
    func nodeDisplayTitle(_ node: ProxyNode) -> String { node.name }
    mutating func normalizeApplicationProxyMode() {}
}
struct ConnectionState {
    var status = ConnectionStatus.disconnected
    var autoSelectEnabled = true
    var currentNodeID: UUID?
    var currentCountryCode: String?
    var currentCountryName: String?
    var lastError: String?
    var protocolType = FixtureLabel()
}
enum Category { case network }
@MainActor final class Logger {
    func info(_ message: String, category: Category = .network) {}
    func debug(_ message: String, category: Category = .network) {}
    func warning(_ message: String, category: Category = .network) {}
}
enum ApplicationHealthFailoverPolicy {
    static let exhaustedRetryDelay: TimeInterval = 30
__POLICY__
}
@MainActor final class ConnectionManager {
    var state = ConnectionState()
    var activeSettings: AppSettings?
    var isBusy = false
    var failoverStatus: String?
    var captureCleanupFailed = false
    var automaticRecoveryPending = false
    var isNodeTemporarilyBlocked: ((UUID) -> Bool)?
    var rankAutomaticCandidates: (([ProxyNode]) -> [ProxyNode])?
    var onNodeConnectionFailed: ((UUID) -> Void)?
    let operations = ConnectionOperations()
    let logger = Logger()
    var connectGeneration: Int { operations.generation }
    var attemptedIDs: [UUID] = []
    var failingIDs: Set<UUID> = []
    func setAutomaticRecoveryPending(_ value: Bool) { automaticRecoveryPending = value }
    func cancelErrorIdleRecovery() {}
    func logConnectionReplacement(node: ProxyNode, settings: AppSettings, reason: String?) {}
    func teardownProxy(settings: AppSettings, restoreSystemProxy: Bool) async {}
    func clearSessionToDisconnected() { state.status = .disconnected }
    func failAndClearProxy(settings: AppSettings, message: String) async {
        state.status = .error; state.lastError = message
    }
    func connectOnce(node: ProxyNode, settings: AppSettings, countryCode: String?,
                     countryName: String?, verify: Bool, manageBusyFlag: Bool = true) async throws {
        attemptedIDs.append(node.id)
        state.currentNodeID = node.id
        if failingIDs.contains(node.id) { throw ConnectionError.connectFailed }
        state.currentCountryCode = countryCode ?? node.countryCode
        state.status = .connected
    }
    func disconnect(settings: AppSettings, reason: String) async { state.status = .disconnected }
__MANAGER__
}
struct StartupConnectionIntent {
    var reconnectOnNextLaunch = true
    var stayDisconnectedUntilConnect = false
}
struct RecoveryNetwork { var canRecover = true }
enum TestPhase { case finished, paused }
@MainActor final class TestManager { var isTesting = false; var phase = TestPhase.finished }
@MainActor final class Store { func saveStartupConnectionIntent(_ intent: StartupConnectionIntent) {} }
@MainActor final class AppState {
    var nodes: [ProxyNode] = []
    var settings = AppSettings()
    let connection = ConnectionManager()
    let logger = Logger()
    let store = Store()
    let testManager = TestManager()
    var startupConnectionIntent = StartupConnectionIntent()
    var networkRecovery = RecoveryNetwork()
    var connectionCountryCode: String?
    var connectionRequestGeneration = 0
    var recoveryNodeOrder: [UUID] = []
    var recoveryAttemptedIDs: Set<UUID> = []
    var recoveryHealthySince: Date?
    var recoveryRunning = false
    var automaticRecoveryNeedsUserAction = false
    var userStoppedConnection = false
    var isTerminating = false
    var statusBanner: String?
    var applicationRecoveryRetryAt: Date?
    var lastFullNodeTestAt: Date? = Date()
    var applicationHealthSwitchTask: Task<Void, Never>?
    var eligibilitySwitchTask: Task<Void, Never>?
    var unexpectedReconnectTask: Task<Void, Never>?
    var refreshes = 0
    func automaticallyRankedNodes(_ targets: [ProxyNode], preservingNodeID: UUID? = nil) -> [ProxyNode] {
        targets.filter { $0.enabled && !$0.pendingRemoval && settings.allowsAutoSelectNode($0) }
            .sorted { $0.priority < $1.priority }
    }
    func testNodes(_ targets: [ProxyNode], silent: Bool, strictResults: Bool) async { refreshes += 1 }
    func pushRecent(_ id: UUID) {}
    func markConnectedForNextLaunch(_ id: UUID) {}
    func persist() {}
    func probeCurrentAppsIfNeeded() async {}
    func purgePendingRemovalNodes() {}
    func presentNoConnectionCandidates() {}
    func begin(country: String? = nil) { _ = beginConnectionRequest(countryCode: country) }
    var scopedIDs: [UUID] { connectionScopedNodes.map(\.id) }
    func recoveryIDs(after id: UUID?) -> [UUID] { orderedRecoveryNodes(after: id).map(\.id) }
    func recover(after id: UUID?) async { await recoverAutomatically(avoiding: id) }
__APP__
}
@main struct CountryConnectionCheck {
    @MainActor static var checks = 0
    @MainActor static func check(_ condition: Bool, _ message: String) {
        checks += 1
        precondition(condition, message)
    }
    static func nodes(inferred: Bool = false) -> [ProxyNode] {
        let us = (0..<20).map { ProxyNode(name: "🇺🇸 美国 \($0)", countryCode: inferred ? nil : "US", priority: $0) }
        let japan = ProxyNode(name: "🇯🇵 日本", countryCode: inferred ? nil : "JP", priority: -1)
        return [japan] + us
    }
    @MainActor static func main() async throws {
        for inferred in [false, true] {
            let library = nodes(inferred: inferred)
            let us = library.filter { CountryResolver.effectiveCode(for: $0) == "US" }
            for autoSelect in [false, true] {
                for autoFailover in [false, true] {
                    let manager = ConnectionManager()
                    var settings = AppSettings()
                    settings.autoFailover = autoFailover
                    manager.state.autoSelectEnabled = autoSelect
                    manager.failingIDs = [us[0].id]
                    var succeeded = false
                    do {
                        try await manager.connectBestNode(in: "us", nodes: library, settings: settings)
                        succeeded = true
                    } catch ConnectionError.connectFailed {}
                    let enabled = autoSelect && autoFailover
                    check(succeeded == enabled, "only both enabled switches allow replacing a failed preferred node")
                    check(manager.attemptedIDs == (enabled ? [us[0].id, us[1].id] : [us[0].id]),
                          "country entry respects all four switch combinations, inferred=\(inferred)")
                }
            }
            for limit in [3, 20] {
                let manager = ConnectionManager()
                var settings = AppSettings()
                settings.maxFailoverAttempts = limit
                settings.failoverPoolMode = limit == 20 ? .allAvailable : .limited
                manager.failingIDs = Set(us.map(\.id))
                do {
                    try await manager.connectBestNode(in: "US", nodes: library, settings: settings)
                    preconditionFailure("all selected-country candidates should fail")
                } catch ConnectionError.connectFailed {}
                check(manager.attemptedIDs == Array(us.prefix(limit)).map(\.id),
                      "exhausted US candidates cannot fall through to working Japan, inferred=\(inferred)")
            }
            let successful = ConnectionManager()
            try await successful.connectBestNode(in: "US", nodes: library, settings: AppSettings())
            check(successful.attemptedIDs == [us[0].id], "first success stops the candidate chain")
            var ineligible = library
            for index in ineligible.indices where CountryResolver.effectiveCode(for: ineligible[index]) == "US" {
                ineligible[index].lastTestStatus = .unavailable
            }
            let empty = ConnectionManager()
            do {
                try await empty.connectBestNode(in: "US", nodes: ineligible, settings: AppSettings())
                preconditionFailure("an empty selected-country pool must report no candidates")
            } catch ConnectionError.noCandidates {}
            check(empty.attemptedIDs.isEmpty, "working foreign nodes cannot replace an ineligible country pool")

            let app = AppState()
            app.nodes = library
            app.begin(country: "us")
            check(app.connectionCountryCode == "US" && Set(app.scopedIDs) == Set(us.map(\.id)),
                  "request scope normalizes case and uses inferred country metadata")
            check(app.recoveryIDs(after: us[0].id) == Array(us.dropFirst()).map(\.id),
                  "background recovery preserves the selected country")
            app.recoveryAttemptedIDs = Set(us.map(\.id))
            check(app.recoveryIDs(after: us[0].id).isEmpty, "US recovery exhaustion never picks Japan")
            app.recoveryNodeOrder.removeAll()
            check(app.recoveryIDs(after: us[0].id).isEmpty, "rebuilding recovery order also preserves scope")
            let added = ProxyNode(name: "🇺🇸 新美国", priority: 21)
            app.nodes.append(added)
            check(app.recoveryIDs(after: us[0].id) == [added.id], "new same-country nodes enter recovery without outside nodes")
            app.begin()
            check(app.connectionCountryCode == nil && app.scopedIDs.count == app.nodes.count,
                  "a new general request clears the previous country scope")

            app.nodes = library
            await app.connectCountry("US")
            check(app.connectionCountryCode == "US" && app.connection.state.currentNodeID == us[0].id,
                  "real country request establishes scope")
            await app.connect(to: us[1], restrictToCountry: app.connectionCountryCode)
            check(app.connectionCountryCode == "US", "internal explicit reconnection retains country scope")
            await app.connectWithAutoSelect(restrictToCountry: app.connectionCountryCode)
            check(app.connectionCountryCode == "US" && app.connection.state.currentNodeID == us[0].id,
                  "internal automatic reconnection cannot choose a higher-ranked foreign node")
            await app.connect(to: library[0])
            check(app.connectionCountryCode == nil && app.connection.state.currentNodeID == library[0].id,
                  "a manual node choice starts a new unrestricted request")
            await app.connectCountry("US")
            await app.connectWithAutoSelect()
            check(app.connectionCountryCode == nil && app.connection.state.currentNodeID == library[0].id,
                  "a general automatic request clears country scope")
            await app.connectCountry("JP")
            check(app.connectionCountryCode == "JP" && app.scopedIDs == [library[0].id],
                  "choosing another country replaces the previous scope")
            await app.connectCountry("US")
            await app.disconnect(manual: false)
            check(app.connectionCountryCode == "US", "automatic cleanup retains the pending request scope")
            await app.disconnect()
            check(app.connectionCountryCode == nil, "manual stop clears scope even when already disconnected")

            let failing = AppState()
            failing.nodes = library
            failing.begin(country: "US")
            failing.connection.failingIDs = Set(us.map(\.id))
            await failing.recover(after: us[0].id)
            check(failing.connection.attemptedIDs == Array(us.dropFirst()).map(\.id),
                  "production background recovery exhausts only selected-country nodes")
            check(failing.applicationRecoveryRetryAt != nil && failing.connection.automaticRecoveryPending,
                  "country exhaustion schedules a later retry rather than switching country")
            check(failing.refreshes == 0, "fresh full results suppress redundant retesting")
            for disabledSetting in [false, true] {
                let disabled = AppState()
                disabled.nodes = library
                disabled.begin(country: "US")
                disabled.settings.autoFailover = !disabledSetting
                disabled.connection.state.autoSelectEnabled = disabledSetting
                await disabled.recover(after: us[0].id)
                check(disabled.connection.attemptedIDs.isEmpty,
                      "background recovery stops when either automatic switch is disabled")
            }
        }
        print("Country connection scope: \(checks) checks, 0 failures")
    }
}
'''

fixture = fixture.replace("__POLICY__", method(policy_source, "static func orderedCandidates<"))
fixture = fixture.replace("__MANAGER__", "\n".join(method(manager_source, declaration) for declaration in [
    "func connect(", "private func connectBody(", "func connectBestNode(",
    "private func connectWithFailover(", "private func buildFailoverChain(", "private func selectCandidates(",
]))
fixture = fixture.replace("__APP__", "\n".join(method(app_source, declaration) for declaration in [
    "private var connectionScopedNodes:", "private func beginConnectionRequest(",
    "private func orderedRecoveryNodes(", "private func recoverAutomatically(",
    "func connectCountry(", "func connect(to node:", "func connectWithAutoSelect(", "func disconnect(manual:",
]))

with tempfile.TemporaryDirectory(prefix="hopworld-country-scope-check-") as directory:
    directory = Path(directory)
    swift = directory / "Check.swift"
    swift.write_text(fixture)
    binary = directory / "Check"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library",
        str(root / "HopWorld/Services/Country/CountryResolver.swift"),
        str(root / "HopWorld/Services/System/ConnectionOperations.swift"),
        str(swift), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True)
