#!/usr/bin/env python3
"""Exercise production import/refresh orchestration with deterministic downloads and probes."""
from check_app_probe_batches import app, declaration, fixture, root, run_checks

fixture = fixture[:fixture.index("@main struct Check")]
fixture = fixture.replace('case untested, testing, fast, unavailable',
                          'case untested, testing, ultraFast, fast, fairlyFast, fairlySlow, slow, ultraSlow, failed, unavailable')
fixture = fixture.replace('var fingerprint = "initial"', '''var fingerprint = "initial"
    var nodeFingerprint: String?
    var pendingConfigUpdate = false''')
fixture = fixture.replace('case test, network', 'case test, network, subscription')
fixture = fixture.replace('var appProbeTimeoutSeconds = 1', '''var appProbeTimeoutSeconds = 1
    var defaultUpdateMode = SubscriptionUpdateMode.smartMerge''')
fixture = fixture.replace('var status = Phase.idle', 'var status = Phase.idle; var currentNodeID: UUID?')
fixture = fixture.replace('var calls: [UUID] = []', '''var calls: [UUID] = []
    var runs: [[UUID]] = []''')
fixture = fixture.replace('sessionNodeIDs = Set(nodes.map(\\.id))', r'''sessionNodeIDs = Set(nodes.map(\.id))
        runs.append(nodes.map(\.id))''')
fixture = fixture.replace('var isTerminating = false', '''var isTerminating = false
    var libraryAvailable = true
    var isLibraryReady: Bool { libraryAvailable }
    var subscriptionTestPromptIDs: Set<UUID> = []
    var subscriptionTestPromptSelectsAll = false
    var pendingSubscriptionTestPromptIDs: Set<UUID> = []
    var isRefreshingAllSubscriptions = false
    var subscriptionRefreshInProgress = false
    private var pendingSubscriptionRefresh: [PendingSubscriptionRefresh] = []
    var updateLogs: [SubscriptionUpdateLog] = []
    var importText = ""
    var showImportLinks = false
    var pinnedNodeIDs: [UUID] = []
    var recentNodeIDs: [UUID] = []
    var viewingNodeID: UUID?
    let subscriptionManager = SubscriptionManager()
    func warnUnsavedIfLibraryLocked() {}
    func focusNodeList(source: NodeListFilter.Source, nodeID: UUID?, openDetail: Bool) {}
    func revealNode(_ id: UUID) {}
    func subscription(for id: UUID) -> Subscription? { subscriptions.first { $0.id == id } }
    func markPendingConfigUpdates(subscriptionID: UUID, previousDigests: [UUID: String]) {}
    func refreshShareLinkParams(_ node: inout ProxyNode, from incoming: ProxyNode) -> Bool { false }
    func settle(expectedRuns: Int) async {
        for _ in 0..<1000 {
            if testManager.runs.count >= expectedRuns { break }
            try! await Task.sleep(nanoseconds: 1_000_000)
        }
        await drain()
    }
__IMPORT_METHODS__''')
fixture = fixture.replace('__IMPORT_METHODS__', '\n'.join(declaration(app, signature) for signature in [
    'private struct PendingSubscriptionRefresh', 'func addShareLinkSubscription(',
    'func mergeShareLinksText(', 'func applyShareLinkPaste(', 'func refreshSubscription(',
    'private func performSubscriptionRefresh(', 'private func presentSubscriptionTestPromptIfNeeded(',
    'func refreshAllSubscriptions()', 'func testSubscriptionNodes(',
    'func importLinksFromText(into', 'private func scheduleImportedNodeTests(',
    'private func resolveImportTarget(', 'private func appendShareLinks(',
    'func currentSubscriptionShareLinks(', 'func clearSubscriptionCleanupHistory(', 'func deleteNodes(',
    'func removeDuplicateNodes(', 'private func duplicateKeepScore(',
]))
fixture += r'''
struct ParsedLinks {
    var validNodes: [ProxyNode]
    var invalidCount: Int
    var skippedLinksSummary: String {
        invalidCount > 0 ? "；跳过 \(invalidCount) 条无效或暂不支持的链接" : ""
    }
}
@MainActor enum NodeLinkParser {
    static var fixtures: [String: ProxyNode] = [:]
    static var invalidCount = 0
    static func extractShareLinks(from text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { fixtures[$0] != nil }
    }
    static func parseLines(_ text: String) -> ParsedLinks {
        ParsedLinks(validNodes: extractShareLinks(from: text).compactMap { fixtures[$0] }, invalidCount: invalidCount)
    }
}
@MainActor final class SubscriptionManager {
    var updateState = SubscriptionUpdateState.idle
    var success = true
    var failureMessage = "fixture failure"
    var proposedNodes: [ProxyNode]?
    var beforeUpdate: (() async -> Void)?
    var updates = 0
    func computeNextUpdateAt(for sub: Subscription) -> Date? { nil }
__IMPORT_SHARE_LINKS__
    func update(_ sub: Subscription, existingNodes: [ProxyNode], preserveNodeIDs: Set<UUID>) async
        -> (Subscription, [ProxyNode], SubscriptionUpdateLog) {
        updates += 1
        await beforeUpdate?()
        let nodes = sub.isShareLinksBundle
            ? importShareLinks(sub.shareLinksText ?? "", sourceName: sub.name, subscriptionID: sub.id)
            : proposedNodes ?? existingNodes
        var updated = sub
        updated.nodeCount = nodes.filter { $0.subscriptionID == sub.id }.count
        updated.statusMessage = success ? "已导入 \(updated.nodeCount) 个分享节点" + NodeLinkParser.parseLines(sub.shareLinksText ?? "").skippedLinksSummary : failureMessage
        if !success { updated.lastError = failureMessage }
        return (updated, success ? nodes : existingNodes, SubscriptionUpdateLog(subscriptionID: sub.id,
            requestedURL: sub.originalURL, httpStatus: proposedNodes == nil ? 304 : 200, success: success))
    }
}
enum SubscriptionMerger {
__DEDUPLICATE__
    static func hasNodeChanges(before: [ProxyNode], after: [ProxyNode]) -> Bool {
        before.map { "\($0.id):\($0.name):\($0.fingerprint):\($0.pendingRemoval)" }.sorted()
            != after.map { "\($0.id):\($0.name):\($0.fingerprint):\($0.pendingRemoval)" }.sorted()
    }
    static func commitRefresh(subscriptionID: UUID, baseline: [ProxyNode], proposed: [ProxyNode],
                              current: [ProxyNode], preserveNodeIDs: Set<UUID>) -> [ProxyNode]? { proposed }
}
enum KeychainStore { static func storeNodeCredentials(_ node: inout ProxyNode) {} }
extension CountryResolver { static func applyNameHeuristics(to node: inout ProxyNode) {} }
@main struct ImportChecks {
    @MainActor static var count = 0
    @MainActor static func check(_ value: Bool, _ message: String) {
        count += 1
        if !value { fatalError("FAIL: " + message) }
    }
    @MainActor static func node(_ name: String, sub: Subscription? = nil) -> ProxyNode {
        var result = ProxyNode()
        result.name = name
        result.fingerprint = name
        result.subscriptionID = sub?.id
        return result
    }
    @MainActor static func main() async {
        let first = node("first"), second = node("second")
        let firstAlias = node("first"), secondAlias = node("second")
        NodeLinkParser.fixtures = ["first": first, "second": second,
                                   "first-alias": firstAlias, "second-alias": secondAlias]

        let imported = AppState()
        imported.importText = "first"
        imported.importLinksFromText(into: .manual)
        await imported.settle(expectedRuns: 1)
        check(imported.testManager.runs == [[first.id]], "new share link starts latency test")
        check(imported.testManager.calls == [first.id], "new link continues into application probes")
        imported.importText = "first"
        imported.importLinksFromText(into: .manual)
        try! await Task.sleep(nanoseconds: 10_000_000)
        check(imported.nodes.count == 1 && imported.testManager.runs.count == 1, "duplicate link neither adds nor retests a node")
        check(imported.testManager.calls.count == 1, "duplicate link does not repeat application probes")
        imported.importText = "first\nsecond\nsecond-alias"
        imported.importLinksFromText(into: .manual)
        await imported.settle(expectedRuns: 2)
        check(imported.nodes.count == 2 && imported.testManager.runs.last! == [second.id], "mixed append filters existing and within-batch duplicates")
        check(imported.testManager.calls == [first.id, second.id], "mixed append probes only the new node")

        NodeLinkParser.invalidCount = 7
        let partial = AppState()
        partial.importText = "first"
        partial.importLinksFromText(into: .manual)
        check(partial.statusBanner?.contains("跳过 7 条") == true, "partial import reports skipped links")
        await partial.settle(expectedRuns: 1)
        partial.importText = "first"
        partial.importLinksFromText(into: .manual)
        check(partial.statusBanner?.contains("跳过 7 条") == true, "duplicate import still reports skipped links")
        let partialGroup = AppState()
        partialGroup.addShareLinkSubscription(name: "partial", shareText: "first")
        check(partialGroup.statusBanner?.contains("跳过 7 条") == true, "new share group reports skipped links")
        check(partialGroup.subscriptions.first?.statusMessage?.contains("跳过 7 条") == true, "share group retains skipped count")
        await partialGroup.settle(expectedRuns: 1)
        NodeLinkParser.invalidCount = 0

        let group = AppState()
        group.addShareLinkSubscription(name: "shared", shareText: "first\nfirst-alias")
        await group.settle(expectedRuns: 1)
        check(group.nodes.count == 1, "new share group filters equivalent nodes with different link text")
        check(group.testManager.calls == [first.id], "creating a share-link group triggers both stages")
        await group.applyShareLinkPaste(subscriptionID: group.subscriptions[0].id, pastedText: "first\nsecond")
        await group.settle(expectedRuns: 2)
        check(group.testManager.runs.last! == [second.id], "pasting into share group tests only new nodes")
        check(group.testManager.calls.count == 2, "share group paste only probes the new node")
        group.nodes[0].lastTestStatus = .untested
        await group.applyShareLinkPaste(subscriptionID: group.subscriptions[0].id, pastedText: "first\nsecond")
        try! await Task.sleep(nanoseconds: 10_000_000)
        check(group.testManager.runs.count == 2 && group.testManager.calls.count == 2, "duplicate group paste does not test existing nodes, including untested ones")

        NodeLinkParser.fixtures["removed"] = node("removed")
        for mode in SubscriptionUpdateMode.allCases {
            let cleaned = AppState()
            var share = Subscription(name: "cleaned", originalURL: "share://links", sourceKind: .shareLinks,
                                     shareLinksText: "first\nremoved", updateMode: mode)
            let history = SubscriptionCleanupRecord(cleanedAt: Date(), automatic: true, removedCount: 1)
            share.cleanupHistory = [history]
            cleaned.subscriptions = [share]
            cleaned.nodes = cleaned.subscriptionManager.importShareLinks("first\nremoved", subscriptionID: share.id)
            cleaned.deleteNodes(Set(cleaned.nodes.filter { $0.name == "removed" }.map(\.id)))
            check(cleaned.subscriptions[0].shareLinksText == "first", "deletion removes stored links before a refresh")
            await cleaned.applyShareLinkPaste(subscriptionID: share.id, pastedText: "second")
            let expected: Set<String> = mode == .overwrite ? ["second"] : ["first", "second"]
            check(Set(cleaned.nodes.map(\.name)) == expected, "append after cleanup honors \(mode) without dropping new links")
            await cleaned.settle(expectedRuns: 1)
            check(cleaned.testManager.runs == [[second.id]], "append after cleanup only tests the new node")
            check(cleaned.subscriptions[0].cleanupHistory == [history], "append preserves cleanup history")
            await cleaned.refreshSubscription(share.id)
            check(Set(cleaned.nodes.map(\.name)) == expected, "later refresh keeps appended links and never restores deleted nodes")
        }

        let clearing = AppState()
        var clearingSub = Subscription(name: "clearing", originalURL: "share://links", sourceKind: .shareLinks,
                                       shareLinksText: "first")
        let lastHistory = SubscriptionCleanupRecord(cleanedAt: Date(), automatic: false, removedCount: 1)
        clearingSub.cleanupHistory = [lastHistory]
        clearing.subscriptions = [clearingSub]
        clearing.nodes = clearing.subscriptionManager.importShareLinks("first", subscriptionID: clearingSub.id)
        clearing.subscriptionManager.beforeUpdate = {
            clearing.subscriptionManager.beforeUpdate = nil
            clearing.clearSubscriptionCleanupHistory(clearingSub.id, recordIDs: [lastHistory.id])
        }
        await clearing.applyShareLinkPaste(subscriptionID: clearingSub.id, pastedText: "second")
        check(Set(clearing.nodes.map(\.name)) == ["first", "second"], "clearing the last history record during refresh never drops pending links")
        check(clearing.subscriptions[0].cleanupHistory?.isEmpty == true, "history removal survives refresh commit")
        check(NodeLinkParser.extractShareLinks(from: clearing.subscriptions[0].shareLinksText ?? "").contains("second"), "history editing preserves the pasted source")
        await clearing.settle(expectedRuns: 1)

        let failed = AppState()
        failed.subscriptions = [clearingSub]
        failed.nodes = failed.subscriptionManager.importShareLinks("first", subscriptionID: clearingSub.id)
        failed.subscriptionManager.success = false
        await failed.applyShareLinkPaste(subscriptionID: clearingSub.id, pastedText: "second")
        check(failed.statusBanner == "fixture failure", "failed append must not overwrite the real error with old node-count success")

        let invalidPaste = AppState()
        invalidPaste.subscriptions = [clearingSub]
        invalidPaste.nodes = invalidPaste.subscriptionManager.importShareLinks("first", subscriptionID: clearingSub.id)
        await invalidPaste.applyShareLinkPaste(subscriptionID: clearingSub.id, pastedText: "invalid text")
        check(invalidPaste.subscriptions[0].shareLinksText == "first" && invalidPaste.subscriptionManager.updates == 0,
              "invalid nonempty paste never changes the saved source or refreshes the group")
        check(invalidPaste.statusBanner?.contains("未解析到有效节点") == true, "invalid paste reports an error")

        let queuedAppend = AppState()
        let background = Subscription(name: "background", originalURL: "https://fixture.invalid")
        queuedAppend.subscriptions = [background, clearingSub]
        queuedAppend.nodes = queuedAppend.subscriptionManager.importShareLinks("first", subscriptionID: clearingSub.id)
        queuedAppend.subscriptionManager.beforeUpdate = {
            queuedAppend.subscriptionManager.beforeUpdate = nil
            await queuedAppend.applyShareLinkPaste(subscriptionID: clearingSub.id, pastedText: "second")
            check(queuedAppend.statusBanner == "正在处理分享链接…", "queued paste never reports success before its refresh runs")
            check(queuedAppend.nodes.map(\.name) == ["first"], "queued paste leaves existing nodes until commit")
        }
        await queuedAppend.refreshSubscription(background.id)
        check(Set(queuedAppend.nodes.map(\.name)) == ["first", "second"], "queued append drains and commits after the active refresh")
        check(queuedAppend.statusBanner?.contains("已导入 2 个分享节点") == true, "queued append reports success after commit")
        await queuedAppend.settle(expectedRuns: 1)

        let sub = Subscription(name: "remote", originalURL: "https://fixture.invalid")
        let remote = AppState()
        remote.subscriptions = [sub]
        remote.nodes = [node("existing", sub: sub)]
        remote.nodes[0].lastTestDate = Date()
        await remote.refreshSubscription(sub.id)
        try! await Task.sleep(nanoseconds: 10_000_000)
        check(remote.testManager.runs.isEmpty && remote.testManager.calls.isEmpty, "manual unchanged/304 refresh never tests nodes automatically")
        check(remote.subscriptionTestPromptIDs.isEmpty, "unchanged manual update does not prompt user to test")
        remote.settings.autoAppProbeUsableNodes = false
        await remote.testSubscriptionNodes([sub.id])
        await remote.settle(expectedRuns: 1)
        check(remote.testManager.runs == [remote.nodes.map(\.id)], "explicit manual test checks subscription nodes")
        check(remote.testManager.calls.isEmpty, "explicit manual latency test respects the automatic app probe switch")
        check(!remote.settings.autoAppProbeUsableNodes, "manual testing preserves the automatic app probe switch")
        remote.subscriptionTestPromptIDs.removeAll()
        await remote.refreshSubscription(sub.id, automatic: true)
        try! await Task.sleep(nanoseconds: 10_000_000)
        check(remote.testManager.runs.count == 1, "scheduled unchanged refresh avoids full retest")
        check(remote.subscriptionTestPromptIDs.isEmpty, "scheduled update does not show manual-test prompt")
        remote.nodes[0].lastTestStatus = .untested
        await remote.refreshSubscription(sub.id, automatic: true)
        await remote.settle(expectedRuns: 2)
        check(remote.testManager.runs.count == 2, "scheduled refresh retries untested existing nodes")
        var newNode = node("new", sub: sub)
        var changed = remote.nodes[0]; changed.fingerprint = "changed"
        newNode.lastTestDate = nil
        remote.subscriptionManager.proposedNodes = [changed, newNode]
        await remote.refreshSubscription(sub.id, automatic: true)
        await remote.settle(expectedRuns: 3)
        check(Set(remote.testManager.runs.last!) == [changed.id, newNode.id], "scheduled refresh tests added and changed nodes")
        remote.subscriptions[0].testAfterUpdate = false
        remote.subscriptionManager.proposedNodes = [changed, newNode, node("manual-opt-out", sub: sub)]
        await remote.refreshSubscription(sub.id)
        try! await Task.sleep(nanoseconds: 10_000_000)
        check(remote.testManager.runs.count == 3, "refresh respects per-subscription test opt-out")
        check(remote.subscriptionTestPromptIDs == [sub.id], "manual update prompts even with update testing off")
        remote.subscriptions[0].testAfterUpdate = true
        remote.subscriptionTestPromptIDs.removeAll()
        remote.subscriptionManager.success = false
        await remote.refreshSubscription(sub.id)
        try! await Task.sleep(nanoseconds: 10_000_000)
        check(remote.testManager.runs.count == 3, "failed download never schedules tests")
        check(remote.subscriptionTestPromptIDs.isEmpty, "failed update does not prompt for a successful update")

        let changedManually = AppState()
        changedManually.subscriptions = [sub]
        changedManually.subscriptionManager.proposedNodes = [node("new-manually", sub: sub)]
        await changedManually.refreshSubscription(sub.id)
        try! await Task.sleep(nanoseconds: 10_000_000)
        check(changedManually.testManager.runs.isEmpty && changedManually.subscriptionTestPromptIDs == [sub.id], "manual update with new nodes only prompts, even with update testing on")

        let scoped = AppState()
        scoped.subscriptions = [sub]
        let active = node("active", sub: sub)
        var disabled = node("disabled", sub: sub); disabled.enabled = false
        var removed = node("removed", sub: sub); removed.pendingRemoval = true
        let unrelated = node("unrelated")
        scoped.nodes = [active, disabled, removed, unrelated]
        await scoped.refreshSubscription(sub.id)
        await scoped.testSubscriptionNodes([sub.id])
        await scoped.settle(expectedRuns: 1)
        check(scoped.testManager.runs == [[active.id]], "manual refresh excludes disabled, removed, and other subscriptions")

        let nextSub = Subscription(name: "next", originalURL: "https://fixture.invalid/next")
        let unselectedSub = Subscription(name: "unselected", originalURL: "https://fixture.invalid/unselected")
        let globalDeduplication = AppState()
        globalDeduplication.subscriptions = [sub, nextSub]
        let remoteDuplicate = node("cross-subscription", sub: sub)
        var survivingRemote = node("cross-subscription", sub: nextSub); survivingRemote.isFavorite = true
        let manualDuplicate = node("cross-subscription")
        let replacedRemote = node("manual-survivor", sub: sub)
        var survivingManual = node("manual-survivor"); survivingManual.isFavorite = true
        let manualOnly = node("manual-only")
        globalDeduplication.nodes = [survivingRemote, manualDuplicate, replacedRemote, survivingManual, manualOnly]
        globalDeduplication.subscriptionManager.proposedNodes = globalDeduplication.nodes + [remoteDuplicate]
        await globalDeduplication.refreshAllSubscriptions()
        check(Set(globalDeduplication.nodes.map(\.id)) == [survivingRemote.id, survivingManual.id, manualOnly.id], "all-update invokes the real global helper across subscriptions and manually imported nodes")
        check(globalDeduplication.statusBanner == "已自动删除 3 个重复节点（全部节点去重）", "all-update reports the global removal count")
        check(globalDeduplication.subscriptions.first { $0.id == sub.id }?.nodeCount == 0, "global removal updates the emptied subscription node count")
        check(globalDeduplication.subscriptionTestPromptIDs == [nextSub.id] && globalDeduplication.subscriptionTestPromptSelectsAll, "test prompt replaces the emptied changed group with the surviving testable subscription")
        await globalDeduplication.testSubscriptionNodes(globalDeduplication.subscriptionTestPromptIDs,
                                                        selectAllSubscriptions: globalDeduplication.subscriptionTestPromptSelectsAll)
        await globalDeduplication.drain()
        check(globalDeduplication.testManager.runs == [[survivingRemote.id]], "subscription test prompt tests its surviving subscription without expanding to manual nodes")

        let connectedKeeper = AppState()
        connectedKeeper.subscriptions = [sub, nextSub]
        var current = node("connected-duplicate", sub: sub)
        current.enabled = false; current.lastTestStatus = .unavailable; current.lastLatency = nil
        var favoriteCopy = node("connected-duplicate", sub: nextSub)
        favoriteCopy.isFavorite = true; favoriteCopy.lastTestStatus = .ultraFast; favoriteCopy.lastLatency = 1
        connectedKeeper.nodes = [favoriteCopy, current]
        connectedKeeper.connection.state.currentNodeID = current.id
        check(connectedKeeper.removeDuplicateNodes() == 1 && connectedKeeper.nodes.map(\.id) == [current.id], "current connection wins even over an enabled faster favorite copy")
        check(connectedKeeper.nodes[0].isFavorite && connectedKeeper.connection.state.currentNodeID == current.id, "current survivor inherits favorite status and keeps connection attribution")

        let enabledKeeper = AppState()
        var disabledFavorite = node("enabled-duplicate"); disabledFavorite.enabled = false; disabledFavorite.isFavorite = true
        let enabledCopy = node("enabled-duplicate")
        enabledKeeper.nodes = [disabledFavorite, enabledCopy]
        check(enabledKeeper.removeDuplicateNodes() == 1 && enabledKeeper.nodes[0].id == enabledCopy.id && enabledKeeper.nodes[0].isFavorite, "enabled copy wins over disabled favorite and inherits its favorite status")

        let stableKeeper = AppState()
        let firstEqual = node("equal-score"), secondEqual = node("equal-score")
        stableKeeper.nodes = [firstEqual, secondEqual]
        check(stableKeeper.removeDuplicateNodes() == 1 && stableKeeper.nodes[0].id == firstEqual.id, "equal scores keep the first node in the original order")
        stableKeeper.statusBanner = "HTTP 526 fixture error"
        check(stableKeeper.removeDuplicateNodes(reportEmptyResult: false) == 0 && stableKeeper.statusBanner == "HTTP 526 fixture error", "quiet no-op deduplication preserves an existing HTTP error")
        check(stableKeeper.removeDuplicateNodes() == 0 && stableKeeper.statusBanner == "没有发现重复节点", "explicit no-op deduplication retains its normal feedback")

        let qualityKeeper = AppState()
        var slowerCopy = node("quality-duplicate"); slowerCopy.lastTestStatus = .slow; slowerCopy.lastLatency = 5_000
        let fasterCopy = node("quality-duplicate")
        qualityKeeper.nodes = [slowerCopy, fasterCopy]
        check(qualityKeeper.removeDuplicateNodes() == 1 && qualityKeeper.nodes[0].id == fasterCopy.id, "enabled non-current copies still prefer the better measured result")
        let cachedKeeper = AppState()
        var cachedFirst = node("cached-first"); cachedFirst.nodeFingerprint = "cached-connection"
        var cachedSecond = node("cached-second"); cachedSecond.nodeFingerprint = "cached-connection"
        cachedKeeper.nodes = [cachedFirst, cachedSecond]
        check(cachedKeeper.removeDuplicateNodes() == 1 && cachedKeeper.nodes[0].id == cachedFirst.id, "deduplication uses stored connection fingerprints instead of recomputing incomplete stored credentials")

        let scopedDeduplication = AppState()
        var deferredCopy = node("equal-score"); deferredCopy.pendingRemoval = true
        let outsideCopy = node("equal-score")
        scopedDeduplication.nodes = [firstEqual, secondEqual, deferredCopy, outsideCopy]
        check(scopedDeduplication.removeDuplicateNodes(among: [firstEqual.id, secondEqual.id, deferredCopy.id]) == 1, "scoped helper removes only eligible duplicates inside its requested IDs")
        check(Set(scopedDeduplication.nodes.map(\.id)) == [firstEqual.id, deferredCopy.id, outsideCopy.id], "pending-removal and unselected nodes remain outside deduplication")

        for automatic in [false, true] {
            let singleRefresh = AppState()
            singleRefresh.subscriptions = [sub, nextSub]
            singleRefresh.nodes = [remoteDuplicate, manualDuplicate]
            await singleRefresh.refreshSubscription(sub.id, automatic: automatic)
            await singleRefresh.drain()
            check(Set(singleRefresh.nodes.map(\.id)) == [remoteDuplicate.id, manualDuplicate.id], "single-group manual or scheduled refresh never deduplicates the whole library")
        }
        let failedAllUpdate = AppState()
        failedAllUpdate.subscriptions = [sub]
        failedAllUpdate.nodes = [node("unique", sub: sub)]
        failedAllUpdate.subscriptionManager.success = false
        failedAllUpdate.subscriptionManager.failureMessage = "更新失败，订阅源站证书校验失败（HTTP 526）"
        await failedAllUpdate.refreshAllSubscriptions()
        check(failedAllUpdate.statusBanner == failedAllUpdate.subscriptionManager.failureMessage, "all-update with zero duplicates preserves the actual HTTP 526 download failure banner")

        let lockedDeduplication = AppState()
        lockedDeduplication.subscriptions = [sub]
        lockedDeduplication.nodes = [remoteDuplicate, manualDuplicate]
        lockedDeduplication.subscriptionManager.beforeUpdate = { lockedDeduplication.libraryAvailable = false }
        await lockedDeduplication.refreshAllSubscriptions()
        check(lockedDeduplication.nodes.count == 2, "library becoming unavailable during all-update skips global deletion")
        let cancelledDeduplication = AppState()
        cancelledDeduplication.subscriptions = [sub]
        cancelledDeduplication.nodes = [remoteDuplicate, manualDuplicate]
        let cancelledUpdate = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await cancelledDeduplication.refreshAllSubscriptions()
        }
        await cancelledUpdate.value
        check(cancelledDeduplication.nodes.count == 2, "cancelled all-update skips global deletion")
        let terminatingDeduplication = AppState()
        terminatingDeduplication.subscriptions = [sub]
        terminatingDeduplication.nodes = [remoteDuplicate, manualDuplicate]
        terminatingDeduplication.subscriptionManager.beforeUpdate = { terminatingDeduplication.isTerminating = true }
        await terminatingDeduplication.refreshAllSubscriptions()
        check(terminatingDeduplication.nodes.count == 2, "termination during all-update skips global deletion")

        let allUpdated = AppState()
        allUpdated.subscriptions = [sub, nextSub]
        let next = node("next", sub: nextSub)
        let duplicate = node("active", sub: sub)
        allUpdated.nodes = [active, duplicate, next]
        allUpdated.settings.nodeListCategoryRaw = NodeListFilter.encode(scope: .available, source: .subscription(nextSub.id))
        allUpdated.subscriptionManager.proposedNodes = [active, next]
        await allUpdated.refreshAllSubscriptions()
        check(allUpdated.subscriptionTestPromptIDs == [sub.id], "all-update deduplication prompts only for the one changed subscription")
        check(allUpdated.subscriptionTestPromptSelectsAll, "all-update prompt preserves its all-subscriptions entry point even with one changed group")
        let promptIDs = allUpdated.subscriptionTestPromptIDs
        let selectAllSubscriptions = allUpdated.subscriptionTestPromptSelectsAll
        allUpdated.subscriptionTestPromptIDs.removeAll()
        await allUpdated.testSubscriptionNodes(promptIDs, selectAllSubscriptions: selectAllSubscriptions)
        await allUpdated.drain()
        check(NodeListFilter.decode(allUpdated.settings.nodeListCategoryRaw).source == .all, "manual test from all-update resets the shared picker after the alert dismisses")
        check(NodeListFilter.decode(allUpdated.settings.nodeListCategoryRaw).scope == .available, "all-update test preserves the node status filter")
        check(allUpdated.testManager.runs == [[active.id]], "selecting all in the picker does not expand the changed subscriptions being tested")
        await allUpdated.refreshAllSubscriptions()
        check(allUpdated.subscriptionTestPromptIDs.isEmpty, "unchanged all-update does not publish another test prompt")
        let nextAdded = node("next-added", sub: nextSub)
        allUpdated.subscriptionManager.proposedNodes = [active, next, nextAdded]
        await allUpdated.refreshSubscription(nextSub.id)
        check(allUpdated.subscriptionTestPromptIDs == [nextSub.id] && !allUpdated.subscriptionTestPromptSelectsAll, "a later single-group prompt clears the previous all-update selection intent")
        await allUpdated.testSubscriptionNodes(allUpdated.subscriptionTestPromptIDs,
                                               selectAllSubscriptions: allUpdated.subscriptionTestPromptSelectsAll)
        await allUpdated.drain()
        check(NodeListFilter.decode(allUpdated.settings.nodeListCategoryRaw).source == .subscription(nextSub.id), "ordinary single-group prompts still select that subscription")

        let onlyRemaining = AppState()
        onlyRemaining.subscriptions = [sub, nextSub]
        onlyRemaining.nodes = [active, duplicate]
        onlyRemaining.subscriptionManager.proposedNodes = [active]
        await onlyRemaining.refreshAllSubscriptions()
        check(onlyRemaining.subscriptionTestPromptIDs == [sub.id] && onlyRemaining.subscriptionTestPromptSelectsAll, "all-update keeps all selection when deduplication leaves only one group with testable nodes")
        await onlyRemaining.testSubscriptionNodes(onlyRemaining.subscriptionTestPromptIDs,
                                                  selectAllSubscriptions: onlyRemaining.subscriptionTestPromptSelectsAll)
        await onlyRemaining.drain()
        check(onlyRemaining.testManager.runs == [[active.id]] && NodeListFilter.decode(onlyRemaining.settings.nodeListCategoryRaw).source == .all, "the sole remaining testable group still synchronizes the picker to all")
        onlyRemaining.subscriptionManager.proposedNodes = [active, nextAdded]
        await onlyRemaining.refreshSubscription(nextSub.id)
        check(onlyRemaining.subscriptionTestPromptIDs == [sub.id, nextSub.id] && onlyRemaining.subscriptionTestPromptSelectsAll, "merging a new group into an unconsumed all-update prompt preserves its all selection intent")

        let batch = AppState()
        batch.settings.autoAppProbeUsableNodes = false
        batch.subscriptions = [sub, nextSub, unselectedSub]
        let unselected = node("unselected", sub: unselectedSub)
        batch.nodes = [active, disabled, removed, next, unselected, unrelated]
        batch.settings.nodeListCategoryRaw = NodeListFilter.encode(scope: .available, source: .subscription(unselectedSub.id))
        await batch.testSubscriptionNodes([sub.id])
        await batch.drain()
        check(NodeListFilter.decode(batch.settings.nodeListCategoryRaw).source == .subscription(sub.id), "single-group test replaces the previous subscription selection")
        check(NodeListFilter.decode(batch.settings.nodeListCategoryRaw).scope == .available, "changing subscription preserves the node status filter")
        await batch.testSubscriptionNodes([nextSub.id])
        await batch.drain()
        check(NodeListFilter.decode(batch.settings.nodeListCategoryRaw).source == .subscription(nextSub.id), "testing another group updates the shared Test Center picker")
        check(batch.testManager.runs == [[active.id], [next.id]], "successive single-group tests each use the selected subscription")
        batch.testManager.calls.removeAll()
        await batch.testSubscriptionNodes([sub.id, nextSub.id, UUID()])
        await batch.drain()
        check(batch.testManager.runs.count == 3 && batch.testManager.runs.last! == [active.id, next.id], "updated subscriptions run together in one session, excluding deleted, disabled, removed and unrelated nodes")
        check(NodeListFilter.decode(batch.settings.nodeListCategoryRaw).source == .all, "multi-group test clears the previous single-group filter")
        check(batch.testManager.calls.isEmpty, "the combined manual latency test respects the automatic app probe switch")
        batch.testManager.isTesting = true
        await batch.testSubscriptionNodes([sub.id])
        check(batch.testManager.runs.count == 3 && NodeListFilter.decode(batch.settings.nodeListCategoryRaw).source == .all, "a rejected busy request neither starts another run nor changes the picker")
        batch.testManager.isTesting = false
        for ids: Set<UUID> in [[], [UUID()]] {
            await batch.testSubscriptionNodes(ids)
        }
        batch.nodes = [disabled, removed]
        await batch.testSubscriptionNodes([sub.id])
        check(batch.testManager.runs.count == 3 && NodeListFilter.decode(batch.settings.nodeListCategoryRaw).source == .all, "empty or deleted groups do not start a run or change the picker")

        let optedOut = AppState()
        optedOut.settings.autoAppProbeUsableNodes = false
        optedOut.importText = "first"
        optedOut.importLinksFromText(into: .manual)
        await optedOut.settle(expectedRuns: 1)
        check(optedOut.testManager.runs.count == 1 && optedOut.testManager.calls.isEmpty, "import preserves the application opt-out while testing latency")

        let queued = AppState()
        queued.nodes = [first, second]
        queued.testManager.onStart = {
            queued.testManager.onStart = nil
            await queued.testNodes([second], silent: true)
        }
        await queued.testNodes([first])
        await queued.drain()
        check(queued.testManager.runs == [[first.id], [second.id]], "import requested during a running test drains afterwards")
        check(Set(queued.testManager.calls) == [first.id, second.id], "queued test continues to application probes")

        let edited = AppState()
        edited.nodes = [first, second]
        edited.testManager.onStart = {
            edited.testManager.onStart = nil
            await edited.testNodes([second], silent: true)
            edited.nodes[1].enabled = false
        }
        await edited.testNodes([first])
        await edited.drain()
        check(edited.testManager.runs == [[first.id]], "queued imports resolve current enabled state before starting")

        let paused = AppState()
        paused.nodes = [first, second]
        paused.testManager.finishPhase = .paused
        paused.testManager.onStart = {
            paused.testManager.onStart = nil
            await paused.testNodes([second], silent: true)
        }
        await paused.testNodes([first])
        check(paused.testManager.runs.count == 1, "paused test keeps import queued")
        paused.testManager.finishPhase = .finished
        await paused.resumeTesting()
        await paused.drain()
        check(paused.testManager.runs == [[first.id], [second.id]], "resuming a test also drains queued imports")

        let refreshed = AppState()
        refreshed.subscriptions = [sub]
        refreshed.nodes = [node("same", sub: sub)]
        refreshed.subscriptionManager.beforeUpdate = {
            refreshed.subscriptionManager.beforeUpdate = nil
            await refreshed.refreshSubscription(sub.id, automatic: true)
            await refreshed.refreshSubscription(sub.id)
        }
        await refreshed.refreshSubscription(sub.id, automatic: true)
        for _ in 0..<1000 {
            if refreshed.subscriptionManager.updates == 2 { break }
            try! await Task.sleep(nanoseconds: 1_000_000)
        }
        try! await Task.sleep(nanoseconds: 10_000_000)
        check(refreshed.subscriptionManager.updates == 2, "duplicate refresh requests coalesce")
        check(refreshed.testManager.runs.isEmpty && refreshed.subscriptionTestPromptIDs.isEmpty, "queued unchanged manual refresh neither prompts nor retests nodes")
        print("Import/refresh automatic tests: \(count) checks, 0 failures")
    }
}
'''
fixture = fixture.replace('__IMPORT_SHARE_LINKS__', declaration(
    (root / 'HopWorld/Services/Subscription/SubscriptionManager.swift').read_text(), 'func importShareLinks('))
fixture = fixture.replace('__DEDUPLICATE__', declaration(
    (root / 'HopWorld/Services/Subscription/SubscriptionMerger.swift').read_text(), 'static func deduplicate('))
run_checks(fixture)
