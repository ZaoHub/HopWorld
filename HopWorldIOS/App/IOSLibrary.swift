import Foundation
import NetworkExtension

struct IOSLibraryFile: Codable {
    var subscriptions: [Subscription] = []
    var nodes: [ProxyNode] = []
    var selectedNodeID: UUID?
}

enum IOSSubscriptionNotice {
    static func matches(_ node: ProxyNode) -> Bool {
        guard node.subscriptionID != nil else { return false }
        let name = node.name.lowercased()
        return name.contains("2024之前的软件无法使用")
            || name.contains("用不了下载本站最新软件")
            || name.contains("官网续费")
            || name.range(of: #"exp:\d{8}"#, options: .regularExpression) != nil
            || name.range(of: #"rst:\d+d/\d+(?:\.\d+)?\s*(?:gb|mb|tb)"#, options: .regularExpression) != nil
    }
}

enum IOSSubscriptionMerge {
    static func uniqueNodes(_ nodes: [ProxyNode], selectedID: UUID? = nil) -> [ProxyNode] {
        var seen: Set<String> = []
        let ordered = nodes.filter { $0.id == selectedID } + nodes.filter { $0.id != selectedID }
        return ordered.filter { node in
            let fingerprint = node.nodeFingerprint ?? NodeFingerprint.make(from: node)
            let key = "\(node.subscriptionID?.uuidString ?? "manual")|\(fingerprint)"
            return seen.insert(key).inserted
        }
    }

    static func prepare(_ incoming: [ProxyNode], subscription: Subscription) -> [ProxyNode] {
        incoming.map { node in
            var copy = node
            copy.subscriptionID = subscription.id
            copy.sourceName = subscription.name
            CountryResolver.applyNameHeuristics(to: &copy)
            copy.nodeFingerprint = NodeFingerprint.make(from: copy)
            return copy
        }
    }

    static func merge(old: [ProxyNode], incoming: [ProxyNode], subscription: Subscription,
                      selectedID: UUID?, preserveSelected: Bool) -> [ProxyNode] {
        let prepared = prepare(incoming, subscription: subscription)
        let oldNodes = uniqueNodes(old.filter { !IOSSubscriptionNotice.matches($0) }, selectedID: selectedID)
        let newNodes = prepared.filter { !IOSSubscriptionNotice.matches($0) }
        let preserve: Set<UUID> = preserveSelected ? Set([selectedID].compactMap { $0 }) : []
        let plan = SubscriptionMerger.buildPlan(mode: subscription.updateMode, oldNodes: oldNodes,
            newNodes: newNodes, missingLimit: max(1, subscription.smartMergeMissingLimit), preserveNodeIDs: preserve)
        let notices = IOSNodeIdentity.keepingResults(existing: old.filter { IOSSubscriptionNotice.matches($0) },
            proposed: prepared.filter { IOSSubscriptionNotice.matches($0) }, subscriptionID: subscription.id, sourceName: subscription.name)
        return plan.resultingNodes + notices
    }
}

@MainActor
final class IOSLibrary: ObservableObject {
    @Published private(set) var subscriptions: [Subscription] = []
    @Published private(set) var nodes: [ProxyNode] = []
    @Published private(set) var selectedNodeID: UUID?
    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var exitQuery: IOSExitQuery = .idle
    @Published var lastError: String?
    @Published private(set) var isBusy = false
    @Published private(set) var refreshingSubscriptionID: UUID?
    @Published private(set) var batchDone = 0
    @Published private(set) var batchTotal = 0

    let tunnel: any IOSTunnelControlling
    private let directory: URL
    private var statusTask: Task<Void, Never>?
    private var exitTask: Task<Void, Never>?
    private var probeTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var exitNodeID: UUID?
    private var exitGeneration = 0
    private var batchTask: Task<Void, Never>?
    private var nodeSwitchTask: Task<Void, Never>?
    private var connectionStarting = false

    init(directory: URL? = nil, watchTunnel: Bool = true, tunnel: (any IOSTunnelControlling)? = nil) {
        self.tunnel = tunnel ?? IOSTunnelController()
        self.directory = directory ?? IOSAppGroup.libraryDirectory()
        load()
        self.tunnel.onStatus = { [weak self] status in
            self?.apply(status)
        }
        guard watchTunnel else { return }
        statusTask = Task { [weak self] in
            await self?.tunnel.reload()
            if let status = self?.tunnel.status {
                self?.apply(status)
            }
        }
    }

    deinit {
        statusTask?.cancel()
    }

    var connectableNodes: [ProxyNode] {
        IOSSubscriptionMerge.uniqueNodes(nodes.filter { !IOSSubscriptionNotice.matches($0) && !$0.pendingRemoval }, selectedID: selectedNodeID)
    }

    var selectedNode: ProxyNode? {
        guard let selectedNodeID else { return nil }
        return nodes.first { $0.id == selectedNodeID && !IOSSubscriptionNotice.matches($0) }
    }

    var countries: [CountryGroup] {
        CountryResolver.group(connectableNodes)
    }

    func nodes(in code: String) -> [ProxyNode] {
        IOSNodeSort.byLatency(countries.first { $0.code == code }?.nodes ?? [])
    }

    func select(_ node: ProxyNode) {
        guard !IOSSubscriptionNotice.matches(node) else { return }
        let changed = selectedNodeID != node.id
        selectedNodeID = node.id
        clearNotice()
        save()
        guard changed else { return }
        probeTask?.cancel()
        exitTask?.cancel()
        exitTask = nil
        exitGeneration += 1
        exitNodeID = nil
        exitQuery = .idle
        if connectionStarting || nodeSwitchTask != nil || status == .connected || status == .connecting || status == .reasserting {
            nodeSwitchTask?.cancel()
            nodeSwitchTask = Task { [weak self] in
                guard let self else { return }
                do {
                    while self.connectionStarting {
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                    try Task.checkCancellation()
                    self.tunnel.stop()
                    let deadline = Date().addingTimeInterval(15)
                    while self.tunnel.status != .disconnected && self.tunnel.status != .invalid {
                        guard Date() < deadline else {
                            self.showNotice("切换节点失败：等待旧连接断开超时")
                            self.nodeSwitchTask = nil
                            return
                        }
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                    try Task.checkCancellation()
                    await self.connect()
                    if !Task.isCancelled { self.nodeSwitchTask = nil }
                } catch { }
            }
        } else {
            Task { await refreshSelectedExit() }
        }
    }

    @discardableResult
    func importShareText(_ text: String, name: String = "", mode: SubscriptionUpdateMode = .smartMerge, missingLimit: Int = 3) throws -> UUID {
        let result = try parsed(text: text, data: Data(text.utf8))
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? "分享节点 \(result.validNodes.count)" : trimmed
        let subscription = Subscription(
            name: title,
            originalURL: "share://links",
            sourceKind: .shareLinks,
            shareLinksText: text,
            autoUpdate: false,
            updateInterval: .manual,
            updateMode: mode,
            smartMergeMissingLimit: min(10, max(1, missingLimit)),
            nodeCount: result.validNodes.count,
            statusMessage: skipMessage(result)
        )
        insert(subscription, with: result)
        return subscription.id
    }

    @discardableResult
    func importSubscription(urlString: String, name: String = "", mode: SubscriptionUpdateMode = .smartMerge, missingLimit: Int = 3) async throws -> UUID {
        isBusy = true
        defer { isBusy = false }
        let data = try await IOSSubscriptionClient.fetch(urlString)
        let text = String(data: data, encoding: .utf8) ?? ""
        let result = try parsed(text: text, data: data)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? (URL(string: urlString)?.host ?? "订阅") : trimmed
        let subscription = Subscription(
            name: title,
            originalURL: urlString,
            sourceKind: .remoteURL,
            autoUpdate: false,
            updateInterval: .manual,
            updateMode: mode,
            smartMergeMissingLimit: min(10, max(1, missingLimit)),
            nodeCount: result.validNodes.count,
            statusMessage: skipMessage(result)
        )
        insert(subscription, with: result)
        return subscription.id
    }

    func refreshSubscription(_ id: UUID) async {
        guard refreshingSubscriptionID == nil, let subscription = subscriptions.first(where: { $0.id == id }) else { return }
        refreshingSubscriptionID = id
        isBusy = true
        defer {
            refreshingSubscriptionID = nil
            isBusy = false
        }
        do {
            let text: String
            let data: Data
            switch subscription.sourceKind {
            case .remoteURL:
                data = try await IOSSubscriptionClient.fetch(subscription.originalURL)
                text = String(data: data, encoding: .utf8) ?? ""
            case .shareLinks:
                text = subscription.shareLinksText ?? ""
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    showNotice("这个订阅组没有可更新的内容")
                    return
                }
                data = Data(text.utf8)
            }
            let result = try parsed(text: text, data: data)
            guard let index = subscriptions.firstIndex(where: { $0.id == id }) else { return }
            let current = subscriptions[index]
            guard current.hasSameFetchSource(as: subscription) else { return }
            let existing = nodes.filter { $0.subscriptionID == id }
            let prepared = IOSSubscriptionMerge.prepare(result.validNodes, subscription: current)
            let incomingNodes = prepared.filter { !IOSSubscriptionNotice.matches($0) }
            let previousNodes = IOSSubscriptionMerge.uniqueNodes(existing.filter { !IOSSubscriptionNotice.matches($0) })
            if current.updateMode == .overwrite, !previousNodes.isEmpty,
               Double(incomingNodes.count) < Double(previousNodes.count) * 0.1 {
                showNotice("订阅节点数量异常下降，已保留原有节点")
                return
            }
            guard !incomingNodes.isEmpty else {
                showNotice("订阅没有可用节点，已保留原有节点")
                return
            }
            let merged = IOSSubscriptionMerge.merge(old: existing, incoming: result.validNodes, subscription: current,
                selectedID: selectedNodeID, preserveSelected: status == .connected || status == .connecting || status == .reasserting)
            nodes.removeAll { $0.subscriptionID == id }
            nodes.append(contentsOf: merged)
            if let selectedNodeID, !nodes.contains(where: { $0.id == selectedNodeID && !IOSSubscriptionNotice.matches($0) }) {
                self.selectedNodeID = nil
            }
            subscriptions[index].nodeCount = merged.filter { !IOSSubscriptionNotice.matches($0) && !$0.pendingRemoval }.count
            subscriptions[index].lastSuccessAt = Date()
            subscriptions[index].statusMessage = skipMessage(result)
            save()
            showNotice("已更新 \(subscriptions[index].name)：\(IOSNodeTally.make(merged.filter { !IOSSubscriptionNotice.matches($0) && !$0.pendingRemoval }).line)")
        } catch {
            showNotice(error.localizedDescription)
        }
    }

    func setUpdatePolicy(_ id: UUID, mode: SubscriptionUpdateMode? = nil, missingLimit: Int? = nil) {
        guard let index = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        if let mode { subscriptions[index].updateMode = mode }
        if let missingLimit { subscriptions[index].smartMergeMissingLimit = min(10, max(1, missingLimit)) }
        save()
    }

    func deleteSubscription(_ id: UUID) {
        if nodes.contains(where: { $0.subscriptionID == id && $0.id == selectedNodeID }) {
            tunnel.stop()
            selectedNodeID = nil
        }
        subscriptions.removeAll { $0.id == id }
        nodes.removeAll { $0.subscriptionID == id }
        save()
    }

    func connect() async {
        guard let node = selectedNode else {
            showNotice("先选择一个节点")
            return
        }
        isBusy = true
        connectionStarting = true
        defer { isBusy = false; connectionStarting = false }
        do {
            let config = try IOSSingBoxConfig.json(for: node)
            try IOSAppGroup.writeConfig(config, directory: directory)
            exitTask?.cancel()
            exitTask = nil
            exitQuery = .idle
            try await tunnel.start(config: config, server: node.server, name: node.displayTitle)
            apply(tunnel.status)
            clearNotice()
        } catch {
            showNotice(error.localizedDescription)
        }
    }

    func disconnect() {
        nodeSwitchTask?.cancel()
        nodeSwitchTask = nil
        exitTask?.cancel()
        exitTask = nil
        exitQuery = .idle
        tunnel.stop()
    }

    func refreshSelectedExit() async {
        guard status != .connected, let node = selectedNode else { return }
        if exitNodeID == node.id, exitQuery != .idle { return }
        probeTask?.cancel()
        exitGeneration += 1
        let generation = exitGeneration
        let nodeID = node.id
        exitNodeID = nodeID
        exitQuery = .looking
        clearNotice()
        probeTask = Task { [weak self] in
            let (result, failure) = await IOSExitProbe.measure(node)
            guard let self, !Task.isCancelled, self.exitGeneration == generation, self.selectedNode?.id == nodeID, self.exitNodeID == nodeID, self.status != .connected else { return }
            if let result {
                self.exitQuery = .found(result)
            } else {
                self.exitQuery = .failed
                self.showNotice(failure ?? "穿过节点后没有拿到出口国家")
            }
        }
        await probeTask?.value
    }

    func exitPresentation(for node: ProxyNode) -> (country: String, ip: String, kind: String) {
        switch exitQuery {
        case .looking:
            return ("查询中", "查询中", "查询中")
        case .found(let exit):
            let label = IOSExitCountry.label(code: exit.countryCode, name: exit.countryName, fallback: node)
            return ("\(FlagResolver.flag(for: exit.countryCode)) \(label)", exit.ip, exit.kind ?? "未知")
        case .failed:
            return ("未查到", "未查到", "未查到")
        case .idle:
            let code = CountryResolver.effectiveCode(for: node)
            return ("\(FlagResolver.flag(for: code)) \(IOSExitCountry.label(for: node))", "—", "—")
        }
    }

    private func apply(_ status: NEVPNStatus) {
        self.status = status
        guard status == .connected else {
            exitTask?.cancel()
            exitTask = nil
            // A disconnected status also arrives when the home page reloads the tunnel. Keep the probe result.
            return
        }
        guard exitTask == nil else { return }
        exitQuery = .looking
        exitTask = Task { [weak self] in
            let result = await IOSExitLookup.fetch()
            guard let self, self.status == .connected else { return }
            if let result {
                self.exitQuery = .found(result)
            } else {
                self.exitQuery = .failed
                self.showNotice("穿过节点后没有拿到出口国家")
            }
        }
    }

    /// Latency exit lookup uses a separate local proxy from node selection.
    private func refreshLatencyExit() async {
        guard status != .connected, let node = selectedNode, exitCountryMissing else { return }
        probeTask?.cancel()
        exitGeneration += 1
        let generation = exitGeneration
        let nodeID = node.id
        exitNodeID = nodeID
        exitQuery = .looking
        clearNotice()
        probeTask = Task { [weak self] in
            let (result, failure) = await IOSExitProbe.measureLatency(node)
            guard let self, !Task.isCancelled, self.exitGeneration == generation, self.selectedNode?.id == nodeID, self.status != .connected else { return }
            if let result {
                self.exitQuery = .found(result)
            } else {
                self.exitQuery = .failed
                self.showNotice(failure ?? "测延迟时没有拿到出口国家")
            }
        }
        await probeTask?.value
    }

    private var exitCountryMissing: Bool {
        switch exitQuery {
        case .failed, .idle: return true
        case .found(let exit): return exit.countryCode == nil
        case .looking: return false
        }
    }

    func measureSelected() async {
        guard !IOSSettings.selectedTestURLs.isEmpty else {
            showNotice("请先在设置中选择测试目标")
            return
        }
        guard let id = selectedNode?.id, let index = nodes.firstIndex(where: { $0.id == id }) else { return }
        let node = nodes[index]
        nodes[index].lastTestStatus = .testing
        let outcome = await IOSLatencyProbe.measure(node: node, throughTunnel: status == .connected)
        await refreshLatencyExit()
        applyProbeResult(nodeID: id, outcome: outcome, announce: true)
    }

    func startBatch(_ ids: [UUID]) {
        let urls = IOSSettings.selectedTestURLs
        guard !urls.isEmpty else {
            showNotice("请先在设置中选择测试目标")
            return
        }
        let allowed = Set(connectableNodes.map(\.id))
        let ids = ids.filter { allowed.contains($0) }
        guard batchTask == nil, !ids.isEmpty else { return }
        batchDone = 0
        batchTotal = ids.count
        batchTask = Task { [weak self] in
            await self?.runBatch(ids, urls: urls)
        }
    }

    func stopBatch() {
        batchTask?.cancel()
    }

    func applyProbeResult(nodeID: UUID, outcome: IOSProbeOutcome, announce: Bool) {
        guard let index = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        nodes[index].lastTestDate = Date()
        switch outcome {
        case .latency(let milliseconds):
            nodes[index].lastLatency = milliseconds
            nodes[index].lastTestStatus = NodeTestStatus.from(latencyMs: milliseconds)
            nodes[index].lastTestErrorMessage = nil
        case .unavailable:
            nodes[index].lastLatency = nil
            nodes[index].lastTestStatus = .unavailable
            nodes[index].lastTestErrorMessage = "经节点的探测没有返回"
            if announce, lastError == nil { showNotice("经节点的探测没有返回") }
        case .failed(let message):
            nodes[index].lastLatency = nil
            nodes[index].lastTestStatus = .failed
            nodes[index].lastTestErrorMessage = message
            if announce, lastError == nil { showNotice(message) }
        }
        save()
    }

    private func runBatch(_ ids: [UUID], urls: [String]) async {
        defer {
            batchTask = nil
            batchDone = 0
            batchTotal = 0
        }
        for id in ids {
            if Task.isCancelled { break }
            guard let node = nodes.first(where: { $0.id == id }) else { continue }
            if let index = nodes.firstIndex(where: { $0.id == id }) {
                nodes[index].lastTestStatus = .testing
            }
            let outcome = await IOSLatencyProbe.measure(node: node, throughTunnel: false, batch: true, urls: urls)
            if Task.isCancelled {
                if let index = nodes.firstIndex(where: { $0.id == id }) { nodes[index].lastTestStatus = node.lastTestStatus }
                break
            }
            applyProbeResult(nodeID: id, outcome: outcome, announce: false)
            batchDone += 1
            if Task.isCancelled { break }
        }
        let tally = IOSNodeTally.make(nodes.filter { ids.contains($0.id) })
        showNotice("测试完成：\(tally.line)")
    }

    private func parsed(text: String, data: Data) throws -> ParseResult {
        let result = try SubscriptionContentParser.parse(text: text, rawData: data)
        guard !result.validNodes.isEmpty else { throw ParserError.noValidNodes }
        return result
    }

    private func insert(_ subscription: Subscription, with result: ParseResult) {
        var stored = subscription
        stored.lastSuccessAt = Date()
        let prepared = IOSSubscriptionMerge.prepare(result.validNodes, subscription: stored)
        let imported = IOSSubscriptionMerge.uniqueNodes(prepared.filter { !IOSSubscriptionNotice.matches($0) })
            + prepared.filter { IOSSubscriptionNotice.matches($0) }
        stored.nodeCount = imported.filter { !IOSSubscriptionNotice.matches($0) }.count
        subscriptions.insert(stored, at: 0)
        nodes.append(contentsOf: imported)
        if selectedNodeID == nil {
            selectedNodeID = imported.first { !IOSSubscriptionNotice.matches($0) }?.id
        }
        clearNotice()
        save()
    }

    private func skipMessage(_ result: ParseResult) -> String? {
        result.invalidCount > 0 ? "跳过 \(result.invalidCount) 条无效链接" : nil
    }

    private func showNotice(_ message: String) {
        lastError = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.lastError = nil
        }
    }

    private func clearNotice() {
        noticeTask?.cancel()
        lastError = nil
    }

    private func load() {
        let url = directory.appendingPathComponent(IOSAppGroup.libraryFileName)
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(IOSLibraryFile.self, from: data) else { return }
        subscriptions = file.subscriptions
        nodes = file.nodes
        selectedNodeID = file.selectedNodeID
        if selectedNodeID != nil && selectedNode == nil { selectedNodeID = nil }
    }

    private func save() {
        let file = IOSLibraryFile(subscriptions: subscriptions, nodes: nodes, selectedNodeID: selectedNodeID)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(IOSAppGroup.libraryFileName), options: .atomic)
    }
}
