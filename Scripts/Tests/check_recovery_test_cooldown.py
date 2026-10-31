#!/usr/bin/env python3
"""Exercise production recovery/test orchestration without network or user data."""
from check_app_probe_batches import app, declaration, fixture, run_checks

fixture = fixture[:fixture.index("@main struct Check")]
fixture = fixture.replace('var appProbeTimeoutSeconds = 1', '''var appProbeTimeoutSeconds = 1
    var autoFailover = true
    var scheduledTestEnabled = true
    var scheduledTestScope = 0
    var scheduledTestSubscriptionRaw = "all"
    var lastScheduledTestAt: Date?
    var codexSmartFailover = false
    var scheduledTestIntervalMinutes = 30''')
fixture = fixture.replace('var fingerprint = "initial"', '''var fingerprint = "initial"
    var countryCode: String?
    var countryName: String?''')
fixture = fixture.replace(
    'struct Connection { struct State { var status = Phase.idle }; var state = State() }',
    '''enum ConnectionError: Error { case cancelled }
enum ApplicationProxyError: Error { case fixture }
enum FixtureFailure: Error { case connection }
enum ApplicationHealthFailoverPolicy { static let exhaustedRetryDelay: TimeInterval = 30 }
struct RecoveryNetwork { var canRecover = true }
@MainActor final class Connection {
    struct State { var status = Phase.idle; var autoSelectEnabled = true; var currentNodeID: UUID? }
    var state = State()
    var isBusy = false
    var captureCleanupFailed = false
    var automaticRecoveryPending = false
    var attempts = 0
    func setAutomaticRecoveryPending(_ value: Bool) { automaticRecoveryPending = value }
    func connect(node: ProxyNode, settings: AppSettings, allNodes: [ProxyNode],
                 countryCode: String?, countryName: String?) async throws {
        attempts += 1
        throw FixtureFailure.connection
    }
}''')
fixture = fixture.replace('var beforeProbe: ((ProxyNode) async -> Void)?', '''var beforeProbe: ((ProxyNode) async -> Void)?
    var beforeNodeTest: (() -> Void)?
    var nodeTestRuns = 0''')
fixture = fixture.replace('sessionNodeIDs = Set(nodes.map(\\.id))', r'''sessionNodeIDs = Set(nodes.map(\.id))
        nodeTestRuns += 1
        beforeNodeTest?()''')
fixture = fixture.replace('var isTerminating = false', '''var isTerminating = false
    var userStoppedConnection = false
    var automaticRecoveryNeedsUserAction = false
    var recoveryRunning = false
    var recoveryHealthySince: Date?
    var recoveryAttemptedIDs: Set<UUID> = []
    var recoveryNodeOrder: [UUID] = []
    var applicationRecoveryRetryAt: Date?
    var applicationHealthSwitchTask: Task<Void, Never>?
    var scheduledTestRunning = false
    var connectionRequestGeneration = 0
    var connectionCountryCode: String?
    var connectionScopedNodes: [ProxyNode] { nodes }
    var networkRecovery = RecoveryNetwork()
    func orderedRecoveryNodes(after id: UUID?) -> [ProxyNode] {
        nodes.filter { $0.enabled && !$0.pendingRemoval && !recoveryAttemptedIDs.contains($0.id) && $0.id != id }
    }
    func pushRecent(_ id: UUID) {}
    func markConnectedForNextLaunch(_ id: UUID) {}
    func recover() async { await recoverAutomatically(avoiding: nil) }
    func scheduled(now: Date = Date()) async { await runScheduledTestIfDue(now: now) }
    func nodesForScheduledOrScopedTest(scope: Int, subscriptionRaw: String) -> [ProxyNode] { nodes }
    func automaticallyRankedNodes(_ nodes: [ProxyNode]) -> [ProxyNode] { [] }
    func considerApplicationHealthSwitch() {}
    func connect(to node: ProxyNode, restrictToCountry: String? = nil) async {}
__RECOVERY__''')
fixture = fixture.replace('__RECOVERY__', '\n'.join(declaration(app, signature) for signature in [
    'private func recoverAutomatically(', 'private func runScheduledTestIfDue(',
]))
fixture += r'''
@main struct RecoveryChecks {
    @MainActor static var count = 0
    @MainActor static func check(_ condition: Bool, _ message: String) {
        count += 1
        precondition(condition, message)
    }
    @MainActor static func state() -> AppState {
        let app = AppState()
        app.settings.autoAppProbeUsableNodes = false
        app.nodes = [ProxyNode(), ProxyNode()]
        return app
    }
    @MainActor static func main() async throws {
        let repeated = state()
        repeated.settings.nodeListCategoryRaw = NodeListFilter.encode(scope: .country("SG"), source: .subscription(UUID()))
        var recoveryScopeObserved = false
        repeated.testManager.beforeNodeTest = {
            let filter = NodeListFilter.decode(repeated.settings.nodeListCategoryRaw)
            recoveryScopeObserved = filter.source == .all && filter.scope == .country("SG")
        }
        await repeated.recover()
        check(recoveryScopeObserved, "recovery full test synchronizes all source before starting while preserving country filtering")
        check(repeated.testManager.nodeTestRuns == 1, "an exhausted pass may request one initial full test")
        check(repeated.lastFullNodeTestAt != nil, "completed full recovery tests record their completion time")
        check(repeated.connection.automaticRecoveryPending && repeated.applicationRecoveryRetryAt != nil,
              "exhausted recovery still schedules ordinary connection retries")
        let initialAttempts = repeated.connection.attempts
        repeated.recoveryAttemptedIDs.removeAll()
        await repeated.recover()
        check(repeated.testManager.nodeTestRuns == 1, "a new recovery task must not restart a recent full test")
        check(repeated.connection.attempts > initialAttempts, "recent full tests do not block candidate reconnection")
        repeated.lastFullNodeTestAt = Date().addingTimeInterval(-31 * 60)
        repeated.recoveryAttemptedIDs.removeAll()
        await repeated.recover()
        check(repeated.testManager.nodeTestRuns == 2, "expired results permit one fresh full test")

        let manual = state()
        await manual.testNodes(manual.nodes)
        await manual.drain()
        await manual.recover()
        check(manual.testManager.nodeTestRuns == 1, "a completed manual full test also suppresses immediate recovery retesting")
        manual.settings.lastScheduledTestAt = Date().addingTimeInterval(-31 * 60)
        await manual.scheduled()
        check(manual.testManager.nodeTestRuns == 1, "an old scheduled timestamp does not trigger another full test immediately after a manual full test")
        manual.lastFullNodeTestAt = Date().addingTimeInterval(-31 * 60)
        manual.settings.lastScheduledTestAt = Date()
        await manual.scheduled()
        check(manual.testManager.nodeTestRuns == 1, "a newer persisted scheduled result also suppresses an overdue in-memory result")
        manual.settings.lastScheduledTestAt = Date().addingTimeInterval(-31 * 60)
        manual.settings.nodeListCategoryRaw = NodeListFilter.encode(scope: .available, source: .subscription(UUID()))
        var scheduledScopeObserved = false
        manual.testManager.beforeNodeTest = {
            let filter = NodeListFilter.decode(manual.settings.nodeListCategoryRaw)
            scheduledScopeObserved = filter.source == .all && filter.scope == .available
        }
        await manual.scheduled()
        check(manual.testManager.nodeTestRuns == 2, "the scheduled test runs again after both freshness timestamps expire")
        check(scheduledScopeObserved, "scheduled full test synchronizes all source before starting while preserving status filtering")
        check(manual.settings.lastScheduledTestAt != nil, "a completed scheduled test records its existing scheduled timestamp")

        let partial = state()
        await partial.testNodes([partial.nodes[0]], silent: true)
        check(partial.lastFullNodeTestAt == nil, "testing one group must not mark the whole library freshly tested")
        await partial.recover()
        check(partial.testManager.nodeTestRuns == 2, "partial tests leave other nodes eligible for a full recovery test")
        let partialSchedule = state()
        await partialSchedule.testNodes([partialSchedule.nodes[0]], silent: true)
        await partialSchedule.scheduled()
        check(partialSchedule.testManager.nodeTestRuns == 2, "a partial test does not defer the due full scheduled test")

        let paused = state()
        paused.testManager.finishPhase = .paused
        await paused.testNodes(paused.nodes, silent: true)
        check(paused.lastFullNodeTestAt == nil, "paused tests never establish a fresh full result")
        paused.testManager.finishPhase = .finished
        await paused.resumeTesting()
        check(paused.lastFullNodeTestAt != nil, "finishing a resumed full test establishes fresh full results")
        await paused.recover()
        check(paused.testManager.nodeTestRuns == 1, "finishing a resumed full test prevents an immediate recovery full retest")
        let resumedPartial = state()
        resumedPartial.testManager.finishPhase = .paused
        await resumedPartial.testNodes([resumedPartial.nodes[0]], silent: true)
        resumedPartial.testManager.finishPhase = .finished
        await resumedPartial.resumeTesting()
        check(resumedPartial.lastFullNodeTestAt == nil, "finishing a resumed partial test still leaves the rest of the library stale")
        let stopped = state()
        stopped.testManager.stopped = true
        await stopped.testNodes(stopped.nodes, silent: true)
        check(stopped.lastFullNodeTestAt == nil, "stopped tests never establish a fresh full result")

        let edited = state()
        let initialNodes = edited.nodes
        edited.testManager.beforeNodeTest = { edited.nodes.append(ProxyNode()) }
        await edited.testNodes(initialNodes, silent: true)
        check(edited.lastFullNodeTestAt == nil, "nodes added during a run prevent partial results being marked complete")

        let activeOnly = state()
        var disabled = ProxyNode(); disabled.enabled = false
        var removed = ProxyNode(); removed.pendingRemoval = true
        let activeNodes = activeOnly.nodes
        activeOnly.nodes += [disabled, removed]
        await activeOnly.testNodes(activeNodes, silent: true)
        check(activeOnly.lastFullNodeTestAt != nil, "disabled and retiring nodes do not prevent a full active-node result")

        let waiting = state()
        waiting.recoveryAttemptedIDs = Set(waiting.nodes.map(\.id))
        waiting.testManager.isTesting = true
        let existingTest = Task { @MainActor in
            try await Task.sleep(nanoseconds: 20_000_000)
            waiting.lastFullNodeTestAt = Date()
            waiting.testManager.isTesting = false
        }
        await waiting.recover()
        try await existingTest.value
        check(waiting.testManager.nodeTestRuns == 0, "recovery rechecks freshness after waiting for an existing full test")

        let minimum = state()
        minimum.settings.scheduledTestIntervalMinutes = 1
        minimum.lastFullNodeTestAt = Date().addingTimeInterval(-2 * 60)
        await minimum.recover()
        check(minimum.testManager.nodeTestRuns == 0, "malformed short intervals still enforce at least five minutes between full tests")
        minimum.lastFullNodeTestAt = Date().addingTimeInterval(-6 * 60)
        minimum.recoveryAttemptedIDs.removeAll()
        await minimum.recover()
        check(minimum.testManager.nodeTestRuns == 1, "the minimum cooldown expires after five minutes")
        print("Recovery full-test cooldown: \(count) checks, 0 failures")
    }
}
'''
run_checks(fixture)
