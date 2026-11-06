#!/usr/bin/env python3
"""Run production latency-to-app queue methods with isolated, deterministic probes."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
app = (root / "HopWorld/App/AppState.swift").read_text()
probes = (root / "HopWorld/Services/Testing/AppProbe.swift").read_text()


def declaration(source, signature, indent="    "):
    start = source.index(indent + signature)
    end = source.index("\n" + indent + "}", start) + len("\n" + indent + "}")
    return source[start:end]


fixture = r'''
import Foundation
import Darwin

enum Status { case untested, testing, fast, unavailable; var isUsable: Bool { self == .fast } }
enum Phase { case idle, running, paused, finished }
struct ProxyNode {
    let id = UUID()
    var name = "fixture"
    var enabled = true
    var pendingRemoval = false
    var isFavorite = false
    var subscriptionID: UUID?
    var sourceName: String?
    var lastTestStatus = Status.fast
    var lastTestErrorMessage: String?
    var lastTestDate: Date?
    var lastLatency: Int? = 10
    var lastAppProbeDate: Date?
    var lastAppProbePassedIDs: Set<String>?
    var lastAppProbeOkCount: Int?
    var lastAppProbeLatency: Int?
    var lastAvailableAt: Date?
    var unavailableSince: Date?
    var fingerprint = "initial"
}
enum NodeFingerprint { static func make(from node: ProxyNode) -> String { node.fingerprint } }
enum CountryResolver { static func effectiveCode(for node: ProxyNode) -> String { "US" } }
struct AppSettings {
    var autoAppProbeUsableNodes = true
    var automaticAppProbeTargets = ["app"]
    var appProbeTimeoutSeconds = 1
    var nodeListCategoryRaw = "all"
    func nodeDisplayTitle(_ node: ProxyNode) -> String { node.name }
}
enum Category { case test, network }
@MainActor final class Logger {
    var messages: [String] = []
    func info(_ message: String, category: Category) { messages.append(message) }
    func warning(_ message: String, category: Category) { messages.append(message) }
}
struct Connection { struct State { var status = Phase.idle }; var state = State() }
extension Phase { static var connected: Phase { .finished } }
struct NodeTestResult { var success = true }
@MainActor final class TestManager {
    var isTesting = false
    var phase = Phase.idle
    var remainingNodeIDs: [UUID] = []
    var sessionNodeIDs: Set<UUID> = []
    var canResume: Bool { phase == .paused }
    var stopped = false
    var finishPhase = Phase.finished
    var calls: [UUID] = []
    var onStart: (() async -> Void)?
    var failStartup = false
    var beforeProbe: ((ProxyNode) async -> Void)?
    func consumeUserStop() -> Bool { stopped }
    func startTest(nodes: [ProxyNode], settings: AppSettings, silent: Bool,
                   updateNode: (UUID, NodeTestResult) -> Void) async -> Bool {
        phase = .running
        isTesting = true
        sessionNodeIDs = Set(nodes.map(\.id))
        await onStart?()
        for node in nodes { updateNode(node.id, NodeTestResult()) }
        phase = finishPhase
        isTesting = false
        return true
    }
    func resumeTest(nodesByID: (UUID) -> ProxyNode?, settings: AppSettings,
                    updateNode: (UUID, NodeTestResult) -> Void) async {
        for id in sessionNodeIDs { updateNode(id, NodeTestResult()) }
        phase = finishPhase
    }
    func measureAppProbe(for node: ProxyNode, timeout: TimeInterval, targets: [String]) async
        -> (okCount: Int, bestLatencyMs: Int?, passedIDs: Set<String>)? {
        calls.append(node.id)
        await beforeProbe?(node)
        if Task.isCancelled || failStartup { return nil }
        return (1, 5, ["app"])
    }
}
__PROGRESS__
@MainActor final class AppState {
    var settings = AppSettings()
    var nodes: [ProxyNode] = []
    var subscriptions: [Subscription] = []
    var connection = Connection()
    var isTerminating = false
    var statusBanner: String?
    var pendingSilentTestNodeIDs: Set<UUID> = []
    var testSessionIncludesAppProbes = false
    var lastFullNodeTestAt: Date?
    var pendingAutomaticAppProbeNodeIDs: Set<UUID> = []
    var pendingManualAppProbeNodeIDs: Set<UUID> = []
    var automaticAppProbeTask: Task<Void, Never>?
    var autoSelectResultsGeneration = 0
    var sawProgress = false
    var appProbeBatch = AppProbeBatchProgress() {
        didSet { if appProbeBatch.isRunning && appProbeBatch.total > 0 { sawProgress = true } }
    }
    let testManager = TestManager()
    func updateSettings(_ mutate: (inout AppSettings) -> Void) { mutate(&settings) }
    let logger = Logger()
    func persist() {}
    func flushTestResults() {}
    func checkConnectedNodeEligibility() {}
    func enqueueTestResult(id: UUID, result: NodeTestResult, strictResults: Bool = false, fingerprint: String? = nil) {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
        nodes[index].lastTestStatus = result.success ? .fast : .unavailable
        nodes[index].lastTestDate = Date()
    }
    func queue(_ ids: Set<UUID>) { enqueueAutomaticAppProbes(onlyIDs: ids) }
    func drain() async {
        while let task = automaticAppProbeTask { await task.value }
    }
__METHODS__
}
@MainActor final class ScopedTestHarness {
    let appState: AppState
    let testScope: NodeListFilter.Source
    init(appState: AppState, scope: NodeListFilter.Source) {
        self.appState = appState
        testScope = scope
    }
    func run() async { await startScopedTest() }
__SCOPED_METHODS__
}
@main struct Check {
    @MainActor static var count = 0
    @MainActor static func check(_ value: Bool, _ message: String) {
        count += 1
        if !value { fatalError("FAIL: " + message) }
    }
    @MainActor static func main() async {
        let app = AppState()
        app.nodes = [ProxyNode(), ProxyNode()]
        await app.testNodes(app.nodes)
        await app.drain()
        check(Set(app.testManager.calls) == Set(app.nodes.map(\.id)), "latency completion automatically probes all usable nodes")
        check(app.nodes.allSatisfy { $0.lastAppProbePassedIDs == ["app"] }, "automatic results are persisted per node")
        check(app.sawProgress && app.appProbeBatch.completed == 2 && !app.appProbeBatch.isRunning, "automatic progress is visible and completes")
        check(app.logger.messages.contains { $0.contains("测试完成") }, "completion reaches unified logs")

        let probingApp = AppState()
        let groupID = UUID()
        var groupedNode = ProxyNode(); groupedNode.subscriptionID = groupID
        probingApp.nodes = [groupedNode]
        var probingGroup: UUID?
        probingApp.testManager.beforeProbe = { _ in probingGroup = probingApp.appProbeBatch.currentSubscriptionID }
        probingApp.queue([groupedNode.id])
        await probingApp.drain()
        check(probingGroup == groupID, "the probing node's subscription is published while its probe runs")
        check(probingApp.appProbeBatch.currentSubscriptionID == nil, "the probing subscription clears when the batch ends")

        await app.testNodes(app.nodes)
        await app.drain()
        check(app.testManager.calls.count == 4, "a new latency run refreshes old application results")

        let optedOut = AppState()
        optedOut.settings.autoAppProbeUsableNodes = false
        optedOut.nodes = [ProxyNode()]
        await optedOut.testNodes(optedOut.nodes, silent: true)
        await optedOut.drain()
        check(optedOut.testManager.calls.isEmpty, "latency completion respects the automatic application switch")
        check(!optedOut.sawProgress, "automatic application progress must not start with the switch off")
        await optedOut.testNodes(optedOut.nodes)
        await optedOut.drain()
        check(optedOut.testManager.calls.isEmpty, "manual node test also respects the automatic application switch")
        check(!optedOut.settings.autoAppProbeUsableNodes, "manual test preserves the saved automatic switch")
        check(!optedOut.sawProgress, "manual latency completion must not start application progress with the switch off")

        let scoped = AppState()
        let selectedGroup = Subscription(name: "selected", originalURL: "https://fixture.invalid/selected")
        let otherGroup = Subscription(name: "other", originalURL: "https://fixture.invalid/other")
        scoped.subscriptions = [selectedGroup, otherGroup]
        var selected = ProxyNode(); selected.subscriptionID = selectedGroup.id
        selected.lastAppProbeDate = Date(); selected.lastAppProbePassedIDs = ["cached"]
        var untested = ProxyNode(); untested.subscriptionID = selectedGroup.id; untested.lastTestStatus = .untested
        var disabledInGroup = ProxyNode(); disabledInGroup.subscriptionID = selectedGroup.id; disabledInGroup.enabled = false
        var removedInGroup = ProxyNode(); removedInGroup.subscriptionID = selectedGroup.id; removedInGroup.pendingRemoval = true
        var other = ProxyNode(); other.subscriptionID = otherGroup.id
        other.lastAppProbeDate = Date(); other.lastAppProbePassedIDs = ["other-cached"]
        scoped.nodes = [selected, untested, other, disabledInGroup, removedInGroup]
        let groupView = ScopedTestHarness(appState: scoped, scope: .subscription(selectedGroup.id))
        await groupView.run()
        await scoped.drain()
        check(Set(scoped.testManager.calls) == [selected.id, untested.id], "Test Center current-group button chains app probes for exactly its active usable nodes")
        check(scoped.nodes[0].lastAppProbePassedIDs == ["app"], "current-group test refreshes cached application results")
        check(scoped.nodes[2].lastAppProbePassedIDs == ["other-cached"], "current-group test leaves other groups' app results unchanged")
        check(scoped.sawProgress && scoped.appProbeBatch.completed == 2, "current-group app probe progress starts and completes")

        let automaticAll = AppState()
        automaticAll.subscriptions = [selectedGroup, otherGroup]
        automaticAll.nodes = [selected, untested, other, disabledInGroup, removedInGroup]
        automaticAll.settings.nodeListCategoryRaw = NodeListFilter.encode(scope: .country("JP"), source: .subscription(selectedGroup.id))
        automaticAll.testManager.onStart = {
            let filter = NodeListFilter.decode(automaticAll.settings.nodeListCategoryRaw)
            check(filter.source == .all && filter.scope == .country("JP"), "background full-library test selects all before probing and preserves the country filter")
        }
        await automaticAll.testNodes([selected, untested, other], silent: true)
        await automaticAll.drain()

        let oneSource = AppState()
        oneSource.nodes = [selected, untested, disabledInGroup, removedInGroup]
        oneSource.settings.nodeListCategoryRaw = NodeListFilter.encode(scope: .unavailable, source: .subscription(selectedGroup.id))
        oneSource.testManager.onStart = {
            let filter = NodeListFilter.decode(oneSource.settings.nodeListCategoryRaw)
            check(filter.source == .all && filter.scope == .unavailable, "background full active-library test selects all even when every active node has one source")
        }
        await oneSource.testNodes([selected, untested], silent: true)
        await oneSource.drain()

        let partialSource = AppState()
        partialSource.nodes = [selected, other]
        let originalSelection = NodeListFilter.encode(scope: .available, source: .subscription(selectedGroup.id))
        partialSource.settings.nodeListCategoryRaw = originalSelection
        partialSource.testManager.onStart = {
            check(partialSource.settings.nodeListCategoryRaw == originalSelection, "single-source partial background test preserves the current picker")
        }
        await partialSource.testNodes([other], silent: true)
        await partialSource.drain()
        partialSource.testManager.onStart = {
            check(partialSource.settings.nodeListCategoryRaw == originalSelection, "ordinary manual full test does not override the explicit picker")
        }
        await partialSource.testNodes(partialSource.nodes)
        await partialSource.drain()

        let mixedSource = AppState()
        let manualNode = ProxyNode()
        mixedSource.nodes = [selected, other, manualNode]
        mixedSource.settings.nodeListCategoryRaw = originalSelection
        mixedSource.testManager.onStart = {
            check(NodeListFilter.decode(mixedSource.settings.nodeListCategoryRaw).source == .all, "partial background batch spanning a subscription and manual source selects all before probing")
        }
        await mixedSource.testNodes([selected, manualNode], silent: true)
        await mixedSource.drain()

        let queuedScope = AppState()
        let thirdID = UUID()
        var thirdSource = ProxyNode(); thirdSource.subscriptionID = thirdID
        queuedScope.nodes = [selected, other, thirdSource]
        queuedScope.settings.nodeListCategoryRaw = originalSelection
        var observedStarts: [NodeListFilter.Source] = []
        queuedScope.testManager.onStart = {
            let filter = NodeListFilter.decode(queuedScope.settings.nodeListCategoryRaw)
            observedStarts.append(filter.source)
            if observedStarts.count == 1 {
                await queuedScope.testNodes([other, thirdSource], silent: true)
                check(queuedScope.settings.nodeListCategoryRaw == originalSelection, "queued background request does not change the active run's picker")
                await queuedScope.testNodes([other, thirdSource])
                check(queuedScope.settings.nodeListCategoryRaw == originalSelection, "busy rejected manual request does not change the active run's picker")
            } else {
                check(filter.source == .all && filter.scope == .available, "drained multi-subscription batch selects all at its actual start and preserves status filtering")
            }
        }
        await queuedScope.testNodes([selected])
        await queuedScope.drain()
        check(observedStarts == [.subscription(selectedGroup.id), .all], "queued batch changes source only when the next run starts")

        let paused = AppState()
        paused.settings.autoAppProbeUsableNodes = false
        paused.nodes = [ProxyNode()]
        paused.testManager.finishPhase = .paused
        await paused.testNodes(paused.nodes)
        await paused.drain()
        check(paused.testManager.calls.isEmpty, "paused latency test must not trigger app probes")
        paused.testManager.finishPhase = .finished
        await paused.resumeTesting()
        await paused.drain()
        check(paused.testManager.calls.isEmpty, "resumed latency completion respects the automatic application switch")
        paused.settings.autoAppProbeUsableNodes = true
        paused.testManager.phase = .paused
        paused.testManager.sessionNodeIDs = Set(paused.nodes.map(\.id))
        await paused.resumeTesting()
        await paused.drain()
        check(paused.testManager.calls == paused.nodes.map(\.id), "resumed latency completion triggers app probes when the switch is on")
        let stopped = AppState()
        stopped.nodes = [ProxyNode()]
        stopped.testManager.stopped = true
        await stopped.testNodes(stopped.nodes)
        await stopped.drain()
        check(stopped.testManager.calls.isEmpty, "stopped latency run must not trigger app probes")

        let manual = AppState()
        manual.settings.autoAppProbeUsableNodes = false
        let group = Subscription(name: "fixture", originalURL: "https://fixture.invalid")
        manual.subscriptions = [group]
        var grouped = ProxyNode()
        grouped.subscriptionID = group.id
        grouped.lastAppProbeDate = Date()
        grouped.lastAppProbePassedIDs = ["old"]
        var disabled = ProxyNode(); disabled.enabled = false
        var removed = ProxyNode(); removed.pendingRemoval = true
        var unavailable = ProxyNode(); unavailable.lastTestStatus = .unavailable
        manual.nodes = [grouped, ProxyNode(), disabled, removed, unavailable]
        manual.queue(Set(manual.nodes.map(\.id)))
        await manual.drain()
        check(manual.testManager.calls.isEmpty, "saved opt-out prevents automatic tests")
        manual.testUsableNodeApps(in: .subscription(group.id))
        await manual.drain()
        check(manual.testManager.calls == [grouped.id], "manual group tests include cached nodes with automatic tests off")
        manual.testUsableNodeApps(in: .all)
        await manual.drain()
        check(manual.testManager.calls.count == 3, "all excludes disabled, removed, and unavailable nodes")
        check(manual.nodes[0].lastAppProbePassedIDs == ["app"], "manual retest refreshes old results")

        let failed = AppState()
        failed.nodes = [ProxyNode()]
        failed.testManager.failStartup = true
        failed.queue([failed.nodes[0].id])
        await failed.drain()
        check(failed.nodes[0].lastAppProbeDate == nil && failed.appProbeBatch.failed == 1, "startup failure is not cached as unreachable")
        failed.testManager.failStartup = false
        failed.queue([failed.nodes[0].id])
        await failed.drain()
        check(failed.testManager.calls.count == 2 && failed.nodes[0].lastAppProbeDate != nil, "failed startup remains eligible for retry")

        for change in ["cancel", "fingerprint", "date", "targets"] {
            let stale = AppState()
            stale.nodes = [ProxyNode()]
            stale.testManager.beforeProbe = { _ in
                switch change {
                case "cancel": stale.stopAppProbeBatch()
                case "fingerprint": stale.nodes[0].fingerprint = "replacement"
                case "date": stale.nodes[0].lastTestDate = Date()
                default: stale.settings.automaticAppProbeTargets = ["new-target"]
                }
            }
            stale.queue([stale.nodes[0].id])
            await stale.drain()
            check(stale.nodes[0].lastAppProbeDate == nil, "discard stale results after " + change)
            check(!stale.appProbeBatch.isRunning, "progress leaves running state after " + change)
        }

        let queued = AppState()
        queued.nodes = [ProxyNode(), ProxyNode()]
        queued.testManager.beforeProbe = { node in
            if node.id == queued.nodes[0].id { queued.queue([queued.nodes[1].id]) }
        }
        queued.queue([queued.nodes[0].id])
        await queued.drain()
        check(queued.testManager.calls == queued.nodes.map(\.id), "requests arriving during a batch are not lost")
        print("Application probe batches: \(count) checks, 0 failures")
    }
}
'''
fixture = fixture.replace("__PROGRESS__", declaration(probes, "struct AppProbeBatchProgress", ""))
fixture = fixture.replace("__METHODS__", "\n".join(declaration(app, signature) for signature in [
    "func testNodes(", "private func enqueueAutomaticAppProbes(",
    "private func drainPendingSilentNodeTests()",
    "func usableNodesForAppProbe(", "func testUsableNodeApps(", "func stopAppProbeBatch()",
    "func ensureAppProbesForUsableNodes(", "private func applyAppProbeSummary(",
    "private func clearStuckTestingStatuses(", "private func resetNodesForRetest(", "func resumeTesting()",
]))
test_center = (root / "HopWorld/Views/Testing/TestCenterView.swift").read_text()
fixture = fixture.replace("__SCOPED_METHODS__", "\n".join(declaration(test_center, signature) for signature in [
    "private var scopedTargets:", "private func startScopedTest()",
]))
def run_checks(source_text):
    with tempfile.TemporaryDirectory(prefix="hopworld-app-probes-") as temporary:
        source = Path(temporary) / "Check.swift"
        source.write_text(source_text)
        binary = Path(temporary) / "check"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library",
                        str(root / "HopWorld/Models/Subscription.swift"),
                        str(root / "HopWorld/Models/NodeListFilter.swift"), str(source), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    run_checks(fixture)
