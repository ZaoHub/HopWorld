import Foundation

struct SubscriptionMergePlan: Sendable {
    var resultingNodes: [ProxyNode]
    var addedCount: Int
    var updatedCount: Int
    var removedCount: Int
    var duplicateCount: Int
}

enum SubscriptionMerger {
    /// Fields that may change during an in-flight refresh (tests, probes) without
    /// rejecting the downloaded merge.
    private struct RefreshBaseline: Equatable {
        var node: ProxyNode
    }

    private static func refreshBaseline(_ node: ProxyNode) -> RefreshBaseline {
        var copy = node
        copy.lastLatency = nil
        copy.lastAvailableAt = nil
        copy.unavailableSince = nil
        copy.lastTestDate = nil
        copy.lastTestStatus = .untested
        copy.lastAppProbeOkCount = nil
        copy.lastAppProbeLatency = nil
        copy.lastAppProbeDate = nil
        copy.pendingConfigUpdate = false
        return RefreshBaseline(node: copy)
    }

    /// Commit only the downloaded subscription. Concurrent edits to its nodes
    /// reject the stale proposal; edits and additions in other subscriptions survive.
    static func commitRefresh(subscriptionID: UUID, baseline: [ProxyNode],
                              proposed: [ProxyNode], current: [ProxyNode]) -> [ProxyNode]? {
        let currentSource = current.filter { $0.subscriptionID == subscriptionID }
        guard refreshBaselinesEqual(baseline, currentSource) else { return nil }
        let currentByID = Dictionary(uniqueKeysWithValues: currentSource.map { ($0.id, $0) })
        let committed = proposed.filter { $0.subscriptionID == subscriptionID }.map { node in
            var copy = node
            if let latest = currentByID[node.id]?.lastAvailableAt,
               latest > (copy.lastAvailableAt ?? .distantPast) {
                copy.lastAvailableAt = latest
                copy.unavailableSince = nil
            }
            return copy
        }
        return current.filter { $0.subscriptionID != subscriptionID } + committed
    }

    private static func refreshBaselinesEqual(_ lhs: [ProxyNode], _ rhs: [ProxyNode]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        let map = Dictionary(uniqueKeysWithValues: lhs.map { ($0.id, refreshBaseline($0)) })
        for node in rhs {
            guard let expected = map[node.id], expected == refreshBaseline(node) else { return false }
        }
        return true
    }

    static func buildPlan(
        mode: SubscriptionUpdateMode,
        oldNodes: [ProxyNode],
        newNodes: [ProxyNode],
        missingLimit: Int,
        preserveNodeIDs: Set<UUID> = []
    ) -> SubscriptionMergePlan {
        let dedupedNew = deduplicate(newNodes)
        let duplicateCount = max(0, newNodes.count - dedupedNew.count)

        switch mode {
        case .overwrite:
            return overwrite(
                oldNodes: oldNodes,
                newNodes: dedupedNew,
                duplicateCount: duplicateCount,
                preserveNodeIDs: preserveNodeIDs
            )
        case .merge:
            return merge(
                oldNodes: oldNodes,
                newNodes: dedupedNew,
                duplicateCount: duplicateCount,
                preserveNodeIDs: preserveNodeIDs
            )
        case .smartMerge:
            return smartMerge(
                oldNodes: oldNodes,
                newNodes: dedupedNew,
                duplicateCount: duplicateCount,
                missingLimit: missingLimit,
                preserveNodeIDs: preserveNodeIDs
            )
        }
    }

    static func deduplicate(_ nodes: [ProxyNode]) -> [ProxyNode] {
        var seen: Set<String> = []
        var result: [ProxyNode] = []
        for var node in nodes {
            let fp = node.nodeFingerprint ?? NodeFingerprint.make(from: node)
            node.nodeFingerprint = fp
            if seen.contains(fp) { continue }
            seen.insert(fp)
            result.append(node)
        }
        return result
    }

    private static func fingerprint(of node: ProxyNode) -> String {
        node.nodeFingerprint ?? NodeFingerprint.make(from: node)
    }

    private static func identityKey(of node: ProxyNode) -> String {
        NodeFingerprint.identityKey(from: node)
    }

    private struct MergeMaps {
        var byFingerprint: [String: ProxyNode] = [:]
        var identityToFingerprint: [String: String] = [:]
    }

    private static func seedMaps(from oldNodes: [ProxyNode]) -> MergeMaps {
        var maps = MergeMaps()
        for node in oldNodes {
            let fp = fingerprint(of: node)
            var copy = node
            copy.nodeFingerprint = fp
            maps.byFingerprint[fp] = copy
            maps.identityToFingerprint[identityKey(of: copy)] = fp
        }
        return maps
    }

    private static func resolveOld(
        for incoming: ProxyNode,
        maps: inout MergeMaps
    ) -> (fp: String, old: ProxyNode)? {
        let fp = fingerprint(of: incoming)
        if let old = maps.byFingerprint[fp] {
            return (fp, old)
        }
        let identity = identityKey(of: incoming)
        if let previousFP = maps.identityToFingerprint[identity],
           let old = maps.byFingerprint[previousFP] {
            return (fp, old)
        }
        return nil
    }

    private static func store(_ node: ProxyNode, maps: inout MergeMaps) {
        let fp = fingerprint(of: node)
        var copy = node
        copy.nodeFingerprint = fp
        maps.byFingerprint[fp] = copy
        maps.identityToFingerprint[identityKey(of: copy)] = fp
    }

    private static func overwrite(
        oldNodes: [ProxyNode],
        newNodes: [ProxyNode],
        duplicateCount: Int,
        preserveNodeIDs: Set<UUID>
    ) -> SubscriptionMergePlan {
        var maps = seedMaps(from: oldNodes)

        var added = 0
        var updated = 0

        for incoming in newNodes {
            if let (_, old) = resolveOld(for: incoming, maps: &maps) {
                var merged = preserveUserMetadata(from: old, onto: incoming)
                merged.pendingRemoval = false
                merged.missingCount = 0
                if fingerprint(of: old) != fingerprint(of: incoming) {
                    maps.byFingerprint.removeValue(forKey: fingerprint(of: old))
                }
                store(merged, maps: &maps)
                updated += 1
            } else {
                var copy = incoming
                copy.missingCount = 0
                copy.pendingRemoval = false
                store(copy, maps: &maps)
                added += 1
            }
        }

        let mergedFingerprints = Set(newNodes.map(fingerprint(of:)))
        for (fp, old) in maps.byFingerprint where !mergedFingerprints.contains(fp) {
            if preserveNodeIDs.contains(old.id) {
                var copy = old
                copy.pendingRemoval = true
                maps.byFingerprint[fp] = copy
            } else {
                maps.byFingerprint.removeValue(forKey: fp)
            }
        }

        let resulting = Array(maps.byFingerprint.values)
        let removed = max(0, oldNodes.count - updated - (resulting.count - added))
        return SubscriptionMergePlan(
            resultingNodes: resulting,
            addedCount: added,
            updatedCount: updated,
            removedCount: removed,
            duplicateCount: duplicateCount
        )
    }

    private static func merge(
        oldNodes: [ProxyNode],
        newNodes: [ProxyNode],
        duplicateCount: Int,
        preserveNodeIDs: Set<UUID>
    ) -> SubscriptionMergePlan {
        var maps = seedMaps(from: oldNodes)

        var added = 0
        var updated = 0

        for incoming in newNodes {
            if let (_, old) = resolveOld(for: incoming, maps: &maps) {
                var merged = preserveUserMetadata(from: old, onto: incoming)
                merged.pendingRemoval = false
                if fingerprint(of: old) != fingerprint(of: incoming) {
                    maps.byFingerprint.removeValue(forKey: fingerprint(of: old))
                }
                store(merged, maps: &maps)
                updated += 1
            } else {
                store(incoming, maps: &maps)
                added += 1
            }
        }

        _ = preserveNodeIDs
        return SubscriptionMergePlan(
            resultingNodes: Array(maps.byFingerprint.values),
            addedCount: added,
            updatedCount: updated,
            removedCount: 0,
            duplicateCount: duplicateCount
        )
    }

    private static func smartMerge(
        oldNodes: [ProxyNode],
        newNodes: [ProxyNode],
        duplicateCount: Int,
        missingLimit: Int,
        preserveNodeIDs: Set<UUID>
    ) -> SubscriptionMergePlan {
        var maps = seedMaps(from: oldNodes)

        let newFingerprints = Set(newNodes.map(fingerprint(of:)))
        var added = 0
        var updated = 0
        var removed = 0

        for incoming in newNodes {
            if let (_, old) = resolveOld(for: incoming, maps: &maps) {
                var merged = preserveUserMetadata(from: old, onto: incoming)
                merged.missingCount = 0
                merged.pendingRemoval = false
                if fingerprint(of: old) != fingerprint(of: incoming) {
                    maps.byFingerprint.removeValue(forKey: fingerprint(of: old))
                }
                store(merged, maps: &maps)
                updated += 1
            } else {
                var copy = incoming
                copy.missingCount = 0
                store(copy, maps: &maps)
                added += 1
            }
        }

        for (fp, old) in maps.byFingerprint where !newFingerprints.contains(fp) {
            var copy = old
            copy.missingCount += 1
            if copy.missingCount >= missingLimit {
                copy.pendingRemoval = true
                removed += 1
                if copy.isFavorite || preserveNodeIDs.contains(copy.id) {
                    maps.byFingerprint[fp] = copy
                } else {
                    maps.byFingerprint.removeValue(forKey: fp)
                    maps.identityToFingerprint.removeValue(forKey: identityKey(of: copy))
                }
            } else {
                maps.byFingerprint[fp] = copy
            }
        }

        return SubscriptionMergePlan(
            resultingNodes: Array(maps.byFingerprint.values),
            addedCount: added,
            updatedCount: updated,
            removedCount: removed,
            duplicateCount: duplicateCount
        )
    }

    private static func preserveUserMetadata(from old: ProxyNode, onto incoming: ProxyNode) -> ProxyNode {
        ProxyNode(
            id: old.id,
            name: incoming.name,
            protocolType: incoming.protocolType,
            server: incoming.server,
            port: incoming.port,
            credentialKey: old.credentialKey ?? incoming.credentialKey,
            uuid: incoming.uuid ?? old.uuid,
            password: incoming.password ?? old.password,
            method: incoming.method ?? old.method,
            alterId: incoming.alterId ?? old.alterId,
            flow: incoming.flow ?? old.flow,
            encryption: incoming.encryption ?? old.encryption,
            transport: incoming.transport,
            security: incoming.security,
            sni: incoming.sni,
            host: incoming.host,
            path: incoming.path,
            serviceName: incoming.serviceName,
            publicKey: incoming.publicKey ?? old.publicKey,
            shortID: incoming.shortID ?? old.shortID,
            fingerprint: incoming.fingerprint,
            spiderX: incoming.spiderX,
            alpn: incoming.alpn,
            finalMaskJSON: incoming.finalMaskJSON ?? old.finalMaskJSON,
            countryCode: incoming.countryCode ?? old.countryCode,
            countryName: incoming.countryName ?? old.countryName,
            city: incoming.city ?? old.city,
            subscriptionID: incoming.subscriptionID ?? old.subscriptionID,
            sourceName: incoming.sourceName ?? old.sourceName,
            nodeFingerprint: fingerprint(of: incoming),
            lastLatency: old.lastLatency,
            lastAvailableAt: old.lastAvailableAt,
            unavailableSince: old.unavailableSince,
            lastTestDate: old.lastTestDate,
            lastTestStatus: old.lastTestStatus,
            lastAppProbeOkCount: old.lastAppProbeOkCount,
            lastAppProbeLatency: old.lastAppProbeLatency,
            lastAppProbeDate: old.lastAppProbeDate,
            enabled: old.enabled,
            isFavorite: old.isFavorite,
            missingCount: 0,
            pendingRemoval: false,
            pendingConfigUpdate: old.pendingConfigUpdate,
            note: old.note
        )
    }
}
