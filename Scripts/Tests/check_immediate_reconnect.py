#!/usr/bin/env python3
"""Exercise production connection methods with isolated proxy/probe fixtures."""

from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
source_root = Path(sys.argv[1]) if len(sys.argv) > 1 else None
app_source = (source_root / "AppState.swift" if source_root else root / "HopWorld/App/AppState.swift").read_text()
manager_source = (source_root / "ConnectionManager.swift" if source_root else root / "HopWorld/Services/System/ConnectionManager.swift").read_text()


def method(source, declaration):
    start = source.index("    " + declaration)
    end = source.index("\n    }", start) + len("\n    }")
    return source[start:end]


fixture = r'''
import Foundation
import Darwin

enum ConnectionStatus { case disconnected, connecting, connected, disconnecting, error }
enum CaptureMode { case systemProxy, systemVPN }
enum ConnectOnLaunch: CaseIterable { case none, lastNode, fastest }
enum ConnectionError: Error { case cancelled }
struct ConnectionState {
    var status = ConnectionStatus.disconnected
    var autoSelectEnabled = true
    var currentNodeID: UUID?
    var lastError: String?
}
struct ProxyNode {
    let id = UUID()
    var countryCode: String? = "US"
    var countryName: String? = "United States"
    var pendingConfigUpdate = false
    var subscriptionID: UUID?
    var sourceName: String?
    var pendingRemoval = false
    var enabled = true
}
struct AppSettings {
    var nodeListCategoryRaw = "all"
    var autoAppProbeUsableNodes = true
    var maxFailoverAttempts = 3
    var connectionCaptureMode = CaptureMode.systemProxy
    var connectOnLaunch = ConnectOnLaunch.lastNode
    var blockedIDs: Set<UUID> = []
    func isTemporarilyBlocked(_ id: UUID) -> Bool { blockedIDs.contains(id) }
    func nodeDisplayTitle(_ node: ProxyNode) -> String { node.id.uuidString }
    mutating func normalizeApplicationProxyMode() {}
}
struct StartupConnectionIntent {
    var lastConnectedNodeID: UUID?
    var reconnectOnNextLaunch = false
    var stayDisconnectedUntilConnect = false
}
@MainActor final class Store {
    var intent = StartupConnectionIntent()
    var flushes = 0
    func saveStartupConnectionIntent(_ intent: StartupConnectionIntent) { self.intent = intent }
    func flush() async { flushes += 1 }
}
enum CountryResolver {
    static func effectiveCode(for node: ProxyNode) -> String? { node.countryCode }
}
enum Category { case network }
@MainActor final class Logger {
    func info(_ message: String, category: Category) {}
    func warning(_ message: String, category: Category) {}
    func flush() async {}
}
@MainActor final class TestManager {
    var isTesting = true
    var isProbingApps = true
    var resetCount = 0
    func resetAppProbes() { resetCount += 1; isProbingApps = false }
    func shutdown() async { isTesting = false; isProbingApps = false }
}
enum SubscriptionUpdateState { case idle, fetching }
struct Subscription { var id = UUID() }
@MainActor final class SubscriptionManager { var updateState = SubscriptionUpdateState.fetching }
@MainActor final class CleanupGate {
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
@MainActor final class ConnectionManager {
    var state = ConnectionState()
    var isBusy = false
    var activeSettings: AppSettings?
    var calls = 0
    var disconnects = 0
    var captureCleanupFailed = false
    var events: [String] = []
    var cleanupGate: CleanupGate?
    var idleTimerCancelled = false
    var failConnect = false
    let operations = ConnectionOperations()
    var connectGeneration: Int { operations.generation }
    var onUnexpectedDisconnect: ((UUID?, String, Bool) -> Void)?
    func setAutomaticRecoveryPending(_ value: Bool) {}
    func cancelErrorIdleRecovery() { idleTimerCancelled = true }
    func logConnectionReplacement(node: ProxyNode, settings: AppSettings, reason: String?) {}
    func connectBody(node: ProxyNode, settings: AppSettings, allNodes: [ProxyNode],
                     countryCode: String?, countryName: String?) async throws {
        calls += 1
        events.append("connect")
        if failConnect { state.status = .error; throw ConnectionError.cancelled }
        activeSettings = settings
        state.currentNodeID = node.id
        state.status = .connected
        isBusy = false
    }
    func failAndClearProxy(settings: AppSettings, message: String) async {
        events.append("cleanup-start")
        await cleanupGate?.wait()
        events.append("cleanup-finished")
        activeSettings = nil
        isBusy = false
        state.status = .error
    }
    func simulateCoreExit() { handleXrayCrash() }
    func simulateVPNDrop() async { await handleVPNDrop() }
    func disconnect(settings: AppSettings, reason: String) async {
        disconnects += 1
        state.status = .disconnected
        isBusy = false
    }
    func connectBestNode(in code: String, nodes: [ProxyNode], settings: AppSettings) async throws {
        try await connect(node: nodes[0], settings: settings)
    }
__MANAGER_METHODS__
}
@MainActor final class AppState {
    let connection = ConnectionManager()
    var nodes = [ProxyNode()]
    var settings = AppSettings()
    var isTerminating = false
    var librarySaveRetryTask: Task<Void, Never>?
    var applicationHealthTask: Task<Void, Never>?
    var applicationHealthSwitchTask: Task<Void, Never>?
    var cityLocalizationTasks: [UUID: Task<Void, Never>] = [:]
    let health = Store()
    func stopBackgroundActivity() {}
    var connectionRequestGeneration = 0
    var userStoppedConnection = false
    var recentNodeIDs: [UUID] = []
    var schedulerTimer: Timer?
    let logger = Logger()
    var excludedCountry = false
    var noRankedNodes = false
    var rankedNodes: [ProxyNode]?
    var eligibilitySwitchTask: Task<Void, Never>?
    var unexpectedReconnectTask: Task<Void, Never>?
    var recoveryAttemptedIDs: Set<UUID> = []
    var statusBanner: String?
    var disconnects: Int { connection.disconnects }
    let testManager = TestManager()
    let subscriptionManager = SubscriptionManager()
    var isLibraryReady = true
    var subscriptionRefreshInProgress = true
    var nodeTestRequests = 0
    var automaticProbeIDs: Set<UUID> = []
    var pendingAutomaticAppProbeNodeIDs: Set<UUID> = []
    var pendingManualAppProbeNodeIDs: Set<UUID> = []
    var automaticAppProbeTask: Task<Void, Never>?
    var automaticProbeGate: CleanupGate?
    var cancelledAutomaticProbes = 0
    let store = Store()
    var startupConnectionIntent = StartupConnectionIntent()
    var recoveryHealthySince: Date?
    var probesBeforeConnection = 0
    var probesAfterConnection = 0
    var guidance = 0
    func launch() async { await connectOnLaunchIfNeeded() }
    func preferredConnectNode() -> ProxyNode? { nodes.first }
    func automaticallyRankedNodes(_ nodes: [ProxyNode]) -> [ProxyNode] { noRankedNodes ? [] : (rankedNodes ?? nodes) }
    func isCountryExcludedFromAutoSelect(_ code: String?) -> Bool { excludedCountry }
    func presentNoConnectionCandidates() { guidance += 1 }
    func purgePendingRemovalNodes() {}
    func subscription(for id: UUID) -> UUID? { id }
    func updateSettings(_ mutate: (inout AppSettings) -> Void) { mutate(&settings) }
    func testNodes(_ targets: [ProxyNode], strictResults: Bool = false) async { nodeTestRequests += 1 }
    func queueAutomaticProbes(_ ids: Set<UUID>) { enqueueAutomaticAppProbes(onlyIDs: ids) }
    func ensureAppProbesForUsableNodes(onlyIDs: Set<UUID>? = nil, preferIDs: Set<UUID> = [],
                                       countryCode: String? = nil, limit: Int? = nil, silent: Bool = true,
                                       forceRetestIDs: Set<UUID> = []) async {
        probesBeforeConnection += 1
        automaticProbeIDs.formUnion(onlyIDs ?? [])
        await automaticProbeGate?.wait()
        if Task.isCancelled { cancelledAutomaticProbes += 1 }
    }
    func pushRecent(_ id: UUID) {}
    func persist() {}
    func probeCurrentAppsIfNeeded() async {
        if connection.state.status == .connected { probesAfterConnection += 1 }
    }
__APP_METHODS__
}
@main struct ImmediateReconnectCheck {
    @MainActor static var failures = 0
    @MainActor static var checks = 0
    @MainActor static func check(_ value: Bool, _ message: String) {
        checks += 1
        if !value { failures += 1; print("FAIL: " + message) }
    }
    @MainActor static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
        check(false, "fixture did not reach the expected suspension")
    }
    @MainActor static func main() async throws {
        for policy in ConnectOnLaunch.allCases {
            for reconnect in [false, true] {
                for manualStop in [false, true] {
                    for auto in [false, true] {
                        let first = AppState()
                        first.settings.connectOnLaunch = policy
                        first.connection.state.autoSelectEnabled = auto
                        first.userStoppedConnection = manualStop
                        first.noRankedNodes = policy == .lastNode
                        first.excludedCountry = true
                        let last = first.nodes[0]
                        let fastest = ProxyNode()
                        first.nodes.append(fastest)
                        first.rankedNodes = [fastest, last]
                        first.startupConnectionIntent = StartupConnectionIntent(lastConnectedNodeID: last.id,
                            reconnectOnNextLaunch: reconnect, stayDisconnectedUntilConnect: manualStop)
                        first.store.saveStartupConnectionIntent(first.startupConnectionIntent)
                        let expectedID: UUID? = policy == .none ? nil : (policy == .lastNode ? last.id : fastest.id)
                        let expectedCalls = policy == .none ? 0 : 1
                        let label = "\(policy), reconnect=\(reconnect), manualStop=\(manualStop), auto=\(auto)"
                        await first.launch()
                        check(first.connection.state.currentNodeID == expectedID && first.connection.calls == expectedCalls,
                              "startup setting overrides saved session flags: " + label)
                        check(first.connection.state.autoSelectEnabled == auto, "preserve dashboard auto-select toggle")
                        check(first.probesBeforeConnection == 0, "startup does not await batch probes")
                        if policy == .none {
                            check(first.userStoppedConnection, "no-auto-connect also blocks deferred automatic recovery")
                            check(first.startupConnectionIntent.lastConnectedNodeID == last.id, "no-auto-connect retains last-node history")
                        } else {
                            check(first.startupConnectionIntent.reconnectOnNextLaunch, "successful startup preserves connection history")
                            check(!first.userStoppedConnection, "configured startup connection resumes recovery")
                        }
                        await first.disconnectForTermination()
                        if let expectedID {
                            check(first.store.intent.reconnectOnNextLaunch && first.store.intent.lastConnectedNodeID == expectedID,
                                  "quit preserves the node actually selected by startup policy")
                        }
                        check(first.store.flushes == 1, "quit waits for connection records to reach disk")
                        let second = AppState()
                        second.nodes = first.nodes
                        second.settings.connectOnLaunch = policy
                        second.rankedNodes = first.rankedNodes
                        second.startupConnectionIntent = first.store.intent
                        await second.launch()
                        check(second.connection.calls == expectedCalls && second.connection.state.currentNodeID == expectedID,
                              "second relaunch also follows startup setting: " + label)
                    }
                }
            }
        }
        for policy in ConnectOnLaunch.allCases {
            let stopped = AppState()
            stopped.settings.connectOnLaunch = policy
            stopped.startupConnectionIntent.lastConnectedNodeID = stopped.nodes[0].id
            await stopped.disconnect()
            check(stopped.store.intent.stayDisconnectedUntilConnect, "manual stop remains recorded")
            let relaunched = AppState()
            relaunched.nodes = stopped.nodes
            relaunched.settings.connectOnLaunch = policy
            relaunched.startupConnectionIntent = stopped.store.intent
            await relaunched.launch()
            check(relaunched.connection.calls == (policy == .none ? 0 : 1),
                  "previous manual stop cannot disable configured startup policy: \(policy)")
            await relaunched.connect(to: relaunched.nodes[0])
            check(!relaunched.store.intent.stayDisconnectedUntilConnect && relaunched.store.intent.reconnectOnNextLaunch,
                  "successful manual connection enables later recovery")
        }
        let failedStartup = AppState()
        failedStartup.connection.failConnect = true
        failedStartup.startupConnectionIntent = StartupConnectionIntent(
            lastConnectedNodeID: failedStartup.nodes[0].id, reconnectOnNextLaunch: true)
        await failedStartup.launch()
        check(failedStartup.startupConnectionIntent.reconnectOnNextLaunch, "failed recovery remains retryable next launch")
        let quitting = AppState()
        quitting.connection.state.status = .connected
        quitting.connection.state.currentNodeID = quitting.nodes[0].id
        await quitting.disconnectForTermination()
        check(quitting.store.intent.reconnectOnNextLaunch && quitting.store.intent.lastConnectedNodeID == quitting.nodes[0].id,
              "quit repairs a previously cleared recovery flag before disconnecting")
        let terminating = AppState()
        terminating.isTerminating = true
        terminating.startupConnectionIntent = StartupConnectionIntent(
            lastConnectedNodeID: terminating.nodes[0].id, reconnectOnNextLaunch: true)
        await terminating.launch()
        check(terminating.connection.calls == 0 && terminating.connection.state.status == .disconnected,
              "late startup cannot connect during termination")
        let manuallyConnected = AppState()
        await manuallyConnected.connect(to: manuallyConnected.nodes[0])
        await manuallyConnected.launch()
        check(manuallyConnected.connection.calls == 1 && manuallyConnected.connection.state.status == .connected,
              "late startup cannot replace a connection the user already started")
        let manuallyStopping = AppState()
        manuallyStopping.connectionRequestGeneration = 1
        manuallyStopping.userStoppedConnection = true
        manuallyStopping.connection.state.status = .disconnecting
        await manuallyStopping.launch()
        check(manuallyStopping.connection.state.status == .disconnecting,
              "late startup cannot reset an in-progress manual disconnect")
        let staleState = AppState()
        staleState.settings.connectOnLaunch = .none
        staleState.connection.state.status = .connected
        staleState.userStoppedConnection = true
        staleState.startupConnectionIntent.stayDisconnectedUntilConnect = true
        await staleState.launch()
        check(staleState.connection.calls == 0 && staleState.connection.state.status == .disconnected,
              "saved manual stop cannot display a stale connected session")
        for invalid in 0..<4 {
            let missing = AppState()
            missing.settings.connectOnLaunch = .lastNode
            missing.startupConnectionIntent = StartupConnectionIntent(lastConnectedNodeID: missing.nodes[0].id,
                                                                     reconnectOnNextLaunch: true)
            switch invalid {
            case 0: missing.nodes = []
            case 1: missing.nodes[0].enabled = false
            case 2: missing.nodes[0].pendingRemoval = true
            default: missing.settings.blockedIDs.insert(missing.nodes[0].id)
            }
            await missing.launch()
            check(missing.connection.calls == 0,
                  "do not restore an unavailable last-node record: \(invalid)")
        }
        for status in [ConnectionStatus.error, .disconnected] {
            for busy in [false, true] {
                for auto in [false, true] {
                    let app = AppState()
                    app.connection.state.status = status
                    app.connection.state.autoSelectEnabled = auto
                    app.connection.isBusy = busy
                    app.userStoppedConnection = true // Includes TUN's paused recovery state.
                    await app.toggleConnection()
                    let label = "\(status), busy=\(busy), auto=\(auto)"
                    check(app.connection.calls == 1, "one click must connect: " + label)
                    check(app.disconnects == 0, "reconnect must not disconnect: " + label)
                    check(app.probesBeforeConnection == 0, "reconnect must not await batch probes: " + label)
                    check(app.connection.state.status == .connected, "reconnect completed: " + label)
                    if app.connection.calls == 1 {
                        await waitUntil { app.probesAfterConnection == 1 }
                        check(!app.userStoppedConnection, "manual connect resumes paused recovery")
                    }
                }
            }
        }
        for status in [ConnectionStatus.connected, .connecting, .disconnecting] {
            let app = AppState()
            app.connection.state.status = status
            await app.toggleConnection()
            check(app.disconnects == (status == .disconnecting ? 0 : 1), "preserve cancel/stop: \(status)")
            check(app.connection.calls == 0, "stop must not reconnect: \(status)")
        }
        for auto in [false, true] {
            let app = AppState()
            app.nodes = []
            app.connection.state.autoSelectEnabled = auto
            await app.toggleConnection()
            check(app.guidance == 1 && app.connection.calls == 0, "no-candidate guidance: auto=\(auto)")
        }
        let automatic = AppState()
        await automatic.connectWithAutoSelect()
        check(automatic.probesBeforeConnection == 0, "automatic connection must not await application probes")
        let explicit = AppState()
        await explicit.connect(to: explicit.nodes[0])
        check(explicit.probesBeforeConnection == 0, "node connection must not await application probes")
        let country = AppState()
        await country.connectCountry("US")
        check(country.connection.calls == 1 && country.probesBeforeConnection == 0,
              "country connection must not await node or application tests")
        let stopping = AppState()
        stopping.connection.state.status = .connected
        await stopping.disconnect()
        check(stopping.testManager.isProbingApps && stopping.testManager.resetCount == 0,
              "disconnect must leave the independent application probe running")
        let updating = AppState()
        updating.testManager.isTesting = false
        let subscriptionID = UUID()
        updating.nodes[0].subscriptionID = subscriptionID
        await updating.testSubscriptionNodes([subscriptionID])
        check(updating.nodeTestRequests == 1, "subscription download must not block node detection")
        let queued = AppState()
        let firstID = UUID(), secondID = UUID()
        let probeGate = CleanupGate()
        queued.automaticProbeGate = probeGate
        queued.queueAutomaticProbes([firstID])
        await waitUntil { probeGate.continuation != nil }
        queued.queueAutomaticProbes([secondID])
        await queued.disconnect()
        check(queued.automaticAppProbeTask != nil, "disconnect must not drop the automatic application queue")
        probeGate.release()
        queued.automaticProbeGate = nil
        await queued.automaticAppProbeTask?.value
        check(queued.automaticProbeIDs == [firstID, secondID], "automatic application requests are not lost")
        check(queued.cancelledAutomaticProbes == 0, "connection changes must not cancel automatic probes")
        check(queued.testManager.resetCount == 0, "automatic probes must not reset manual probe results")
        for vpn in [false, true] {
            let manager = ConnectionManager()
            let settings = AppSettings(connectionCaptureMode: vpn ? .systemVPN : .systemProxy)
            manager.activeSettings = settings
            manager.state.status = .connected
            manager.state.currentNodeID = UUID()
            manager.isBusy = true
            let gate = CleanupGate()
            manager.cleanupGate = gate
            var staleCallbacks = 0
            manager.onUnexpectedDisconnect = { _, _, _ in staleCallbacks += 1 }
            let cleanup: Task<Void, Never>?
            if vpn { cleanup = Task { await manager.simulateVPNDrop() } }
            else { cleanup = nil; manager.simulateCoreExit() }
            await waitUntil { gate.continuation != nil }
            let reconnect = Task { try await manager.connect(node: ProxyNode(), settings: settings) }
            await waitUntil { manager.connectGeneration == 2 }
            check(manager.state.status == .connecting, "show connecting while cleanup finishes: vpn=\(vpn)")
            check(manager.idleTimerCancelled, "cancel idle-to-disconnected timer on request")
            check(manager.calls == 0, "new core waits for old proxy cleanup")
            gate.release()
            try await reconnect.value
            await cleanup?.value
            for _ in 0..<10 { await Task.yield() }
            check(manager.events == ["cleanup-start", "cleanup-finished", "connect"], "cleanup/connect ordering")
            check(staleCallbacks == 0, "old cleanup cannot schedule recovery over manual reconnect: vpn=\(vpn)")
            check(manager.state.status == .connected && manager.calls == 1, "one queued reconnect completes")
        }
        for vpn in [false, true] {
            let manager = ConnectionManager()
            manager.activeSettings = AppSettings(connectionCaptureMode: vpn ? .systemVPN : .systemProxy)
            manager.state.status = .connected
            var callbacks = 0
            manager.onUnexpectedDisconnect = { _, _, _ in callbacks += 1 }
            if vpn { await manager.simulateVPNDrop() }
            else { manager.simulateCoreExit(); await waitUntil { callbacks == 1 } }
            check(callbacks == 1, "current failure still triggers ordinary recovery: vpn=\(vpn)")
        }
        print("Immediate reconnect: \(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
'''

fixture = fixture.replace("__APP_METHODS__", "\n".join(method(app_source, signature) for signature in [
    "private func beginConnectionRequest()",
    "private func connectOnLaunchIfNeeded()",
    "private func restorableConnectedNode(",
    "private func markConnectedForNextLaunch(",
    "func disconnectForTermination()",
    "func toggleConnection()",
    "func connectWithAutoSelect(",
    "func connect(to node:",
    "func connectCountry(",
    "func disconnect(manual:",
    "func testSubscriptionNodes(",
    "private func enqueueAutomaticAppProbes(",
]))
fixture = fixture.replace("__MANAGER_METHODS__", "\n".join(method(manager_source, signature) for signature in [
    "func connect(",
    "private func handleVPNDrop()",
    "private func handleXrayCrash()",
]))
with tempfile.TemporaryDirectory(prefix="hopworld-reconnect-") as temporary:
    path = Path(temporary)
    source = path / "ImmediateReconnectCheck.swift"
    source.write_text(fixture)
    executable = path / "check"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library",
                    str(root / "HopWorld/Services/System/ConnectionOperations.swift"),
                    str(root / "HopWorld/Models/NodeListFilter.swift"),
                    str(source), "-o", str(executable)], check=True)
    sys.exit(subprocess.run([str(executable)]).returncode)
