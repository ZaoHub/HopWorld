import Foundation

/// Historical application evidence and fresh candidate probes serve different purposes.
enum ApplicationHealthFailoverPolicy {
    static let failureDuration: TimeInterval = 30
    static let cooldown: TimeInterval = 2
    static let exhaustedRetryDelay: TimeInterval = 30
    static let candidateLifetime: TimeInterval = 15 * 60

    static func canAttemptRecovery(now: Date = Date(), lastAttemptAt: Date? = nil) -> Bool {
        lastAttemptAt.map { now.timeIntervalSince($0) >= cooldown } ?? true
    }

    /// Keep the caller's order stable for a recovery pass, then continue after the failed node.
    static func orderedCandidates<ID: Hashable>(in orderedIDs: [ID], after currentID: ID?,
                                                excluding attempted: Set<ID> = []) -> [ID] {
        var seen = Set<ID>()
        let unique = orderedIDs.filter { seen.insert($0).inserted }
        let ordered: [ID]
        if let currentID, let index = unique.firstIndex(of: currentID) {
            ordered = Array(unique.dropFirst(index + 1)) + Array(unique.prefix(index))
        } else {
            ordered = unique
        }
        return ordered.filter { !attempted.contains($0) && $0 != currentID }
    }

    /// Passing this gate only permits a fresh independent probe, never a recovery claim.
    static func candidateCanBeProbed(_ candidate: AppHealthSnapshot, now: Date = Date()) -> Bool {
        guard !candidate.quarantined, candidate.failureSince == nil,
              candidate.status != .degraded, candidate.status != .unavailable,
              !isRecent(candidate.lastServiceFailureAt, within: 120, now: now),
              candidate.score.map({ $0 >= 60 }) ?? true else { return false }
        if let failure = candidate.lastFailureAt, isRecent(failure, within: 120, now: now) {
            return candidate.lastSuccessAt.map { $0 > failure } ?? false
        }
        return true
    }

    static func shouldSwitch(current: AppHealthSnapshot, candidate: AppHealthSnapshot,
                             now: Date = Date(), lastAttemptAt: Date? = nil) -> Bool {
        guard canAttemptRecovery(now: now, lastAttemptAt: lastAttemptAt),
              currentNeedsRecovery(current, now: now) else { return false }

        guard candidate.status == .healthy || candidate.status == .mild,
              let score = candidate.score, score >= 60,
              let success = candidate.lastSuccessAt,
              isRecent(success, within: candidateLifetime, now: now),
              isRecent(candidate.lastObservedAt, within: candidateLifetime, now: now),
              !isRecent(candidate.lastServiceFailureAt, within: 120, now: now),
              candidate.failureSince == nil,
              !candidate.quarantined else { return false }
        return candidate.lastFailureAt.map { $0 < success } ?? true
    }

    static func currentNeedsRecovery(_ current: AppHealthSnapshot, now: Date = Date()) -> Bool {
        guard current.status == .degraded || current.status == .unavailable,
              let failureSince = current.failureSince,
              now.timeIntervalSince(failureSince) >= failureDuration,
              current.recentFailureCount >= 3,
              isRecent(current.lastFailureAt, within: 20, now: now),
              !isRecent(current.lastServiceFailureAt, within: 120, now: now) else { return false }

        // Progress proves the app still works; reconnecting alone must not interrupt it.
        if let success = current.lastSuccessAt,
           success >= failureSince || isRecent(success, within: failureDuration, now: now) { return false }

        return true
    }

    /// Caller supplies one snapshot per distinct node in the same network environment.
    static func hasCommonFailure(snapshots: [AppHealthSnapshot], now: Date = Date()) -> Bool {
        var counts: [CodexHealthEvent.Kind: Int] = [:]
        for snapshot in snapshots {
            guard snapshot.failureSince != nil,
                  isRecent(snapshot.lastFailureAt, within: 5 * 60, now: now),
                  let kind = snapshot.lastFailureKind,
                  kind == .connectionFailure || kind == .requestFailure else { continue }
            counts[kind, default: 0] += 1
            if counts[kind, default: 0] >= 2 { return true }
        }
        return false
    }

    private static func isRecent(_ date: Date?, within interval: TimeInterval, now: Date) -> Bool {
        guard let date else { return false }
        return (0...interval).contains(now.timeIntervalSince(date))
    }
}

/// Active reference-path checks remain separate from application logs and scores.
struct CodexPathObservation: Sendable {
    private(set) var failureSince: Date?
    private(set) var lastCheckedAt: Date?
    private(set) var consecutiveFailures = 0
    private(set) var reachable: Bool?

    mutating func record(reachable: Bool, at date: Date = Date()) {
        guard lastCheckedAt.map({ date >= $0 }) ?? true else { return }
        lastCheckedAt = date
        self.reachable = reachable
        if reachable {
            failureSince = nil
            consecutiveFailures = 0
        } else {
            if failureSince == nil { failureSince = date }
            consecutiveFailures += 1
        }
    }

    func needsRecovery(now: Date = Date()) -> Bool {
        guard reachable == false, consecutiveFailures >= 3,
              let failureSince, let lastCheckedAt,
              now.timeIntervalSince(failureSince) >= ApplicationHealthFailoverPolicy.failureDuration,
              (0...20).contains(now.timeIntervalSince(lastCheckedAt)) else { return false }
        return true
    }
}

struct CodexInviteCheckObservation: Sendable {
    private(set) var result: CodexInviteCheckResult?
    private(set) var lastCheckedAt: Date?
    private(set) var network = CodexPathObservation()
    private var lastApplicationResponseAt: Date?

    mutating func record(result: CodexInviteCheckResult, at date: Date = Date()) {
        guard lastCheckedAt.map({ date >= $0 }) ?? true else { return }
        self.result = result
        lastCheckedAt = date
        if let failed = result.recoveryFailure {
            network.record(reachable: !failed, at: date)
        } else {
            network = CodexPathObservation()
        }
    }

    // Invitation availability is a supporting signal, never a reason to interrupt a conversation.
    func needsRecovery(now: Date = Date()) -> Bool { false }

    mutating func observeApplicationResponse(at date: Date) {
        guard lastApplicationResponseAt.map({ date > $0 }) ?? true else { return }
        lastApplicationResponseAt = date
        guard let failureSince = network.failureSince, failureSince <= date else { return }
        let laterFailure = network.lastCheckedAt.flatMap { $0 > date ? $0 : nil }
        network = CodexPathObservation()
        if let laterFailure { network.record(reachable: false, at: laterFailure) }
    }
}

/// One reachable invitation check grants one observation interval per unresolved failure episode.
struct CodexRecoveryTiming {
    private(set) var scope: String?
    private(set) var failureSince: Date?
    private(set) var observationUntil: Date?
    private(set) var minimumFailureDuration: TimeInterval = ApplicationHealthFailoverPolicy.failureDuration

    var switchAt: Date? {
        guard let failureSince else { return nil }
        return max(failureSince.addingTimeInterval(minimumFailureDuration),
                   observationUntil?.addingTimeInterval(ApplicationHealthFailoverPolicy.failureDuration) ?? .distantPast)
    }

    mutating func synchronize(scope: String?, failureSince: Date?, inviteReachableAt: Date?, recoveredAt: Date? = nil,
                              minimumFailureDuration: TimeInterval = ApplicationHealthFailoverPolicy.failureDuration) {
        if self.scope != scope || failureSince == nil
            || self.failureSince.map({ first in recoveredAt.map { $0 >= first } ?? false }) == true {
            self = Self()
            self.scope = scope
        }
        guard scope != nil, let failureSince else { return }
        if self.failureSince == nil { self.failureSince = failureSince }
        if minimumFailureDuration.isFinite {
            self.minimumFailureDuration = max(self.minimumFailureDuration, min(99, minimumFailureDuration))
        }
        if observationUntil == nil, let inviteReachableAt, inviteReachableAt >= failureSince {
            observationUntil = inviteReachableAt.addingTimeInterval(ApplicationHealthFailoverPolicy.failureDuration)
        }
    }
}

/// An app recovery trigger, independent of public-node attribution and scoring.
struct CodexRecoveryTracker {
    private struct Failure {
        let date: Date
        let origin: CodexHealthEvent.RecoveryOrigin
        let workspaceFeature: CodexHealthEvent.WorkspaceFeature?
    }

    private(set) var scope: String?
    private var scopeSince = Date.distantFuture
    private var failures: [Failure] = []
    private var unresolvedBridgeSince: Date?
    private var unresolvedRequestSince: Date?
    private var unresolvedSettingsSince: Date?
    private var latestEventAt: Date?
    private(set) var latestProgressAt: Date?
    private(set) var lastTransportReadyAt: Date?
    private(set) var lastFailureAt: Date?
    private(set) var lastServiceFailureAt: Date?

    var failureSince: Date? { [unresolvedBridgeSince, unresolvedRequestSince, unresolvedSettingsSince].compactMap { $0 }.min() }
    var bridgeRecoveryDeadline: Date? {
        unresolvedBridgeSince?.addingTimeInterval(ApplicationHealthFailoverPolicy.failureDuration)
    }
    var failureCount: Int { observationCount(in: activeEpisode) }
    var hasRequestFailureInEpisode: Bool { activeEpisode.contains { $0.origin == .responseStream || $0.workspaceFeature == .settings } }

    mutating func setScope(_ newScope: String?, since: Date = Date()) {
        guard newScope != scope else { return }
        self = Self()
        scope = newScope
        scopeSince = since
    }

    mutating func observe(_ event: CodexHealthEvent, now: Date = Date()) {
        if scope != nil, event.date >= scopeSince, event.date <= now,
           now.timeIntervalSince(event.date) <= 120, event.recoveryOrigin == .businessResponse,
           event.kind == .responseProgress || event.kind == .responseCompleted,
           let since = unresolvedSettingsSince, event.date >= since {
            unresolvedSettingsSince = nil
            failures.removeAll { $0.workspaceFeature == .settings }
        }
        guard scope != nil, event.date >= scopeSince, event.date <= now,
              event.workspaceFeature != .inviteEligibility,
              now.timeIntervalSince(event.date) <= 120,
              latestEventAt.map({ event.date >= $0 }) ?? true,
              let origin = event.recoveryOrigin,
              origin == .appServerBridge || origin == .responseStream || origin == .businessResponse
                || (origin == .request && event.workspaceFeature == .settings) else { return }
        latestEventAt = event.date
        failures.removeAll { event.date.timeIntervalSince($0.date) > 120 }
        switch event.kind {
        case .connectionFailure, .requestFailure, .reconnecting, .waitingForNetwork, .workspaceFailure:
            guard event.drivesRecovery, event.scope != "local", event.scope != "unconfirmed-route",
                  origin == .appServerBridge || origin == .responseStream || (origin == .request && event.workspaceFeature == .settings),
                  latestProgressAt.map({ event.date > $0 }) ?? true,
                  lastServiceFailureAt.map({ event.date > $0 }) ?? true else { return }
            // One reconnect burst is one observation, even when multiple canonical events repeat it.
            guard failures.last(where: { $0.origin == origin && $0.workspaceFeature == event.workspaceFeature }).map({ event.date.timeIntervalSince($0.date) >= 2 }) ?? true else { return }
            failures.append(Failure(date: event.date, origin: origin, workspaceFeature: event.workspaceFeature))
            if failures.count > 64 { failures.removeFirst(failures.count - 64) }
            lastFailureAt = event.date
            if event.workspaceFeature == .settings {
                if unresolvedSettingsSince == nil { unresolvedSettingsSince = event.date }
            } else if origin == .appServerBridge, unresolvedBridgeSince == nil {
                // Reconnect backoff emits no logs; silence must not restart an unresolved connection's clock.
                unresolvedBridgeSince = event.date
            }
            if event.workspaceFeature == nil, origin == .responseStream, unresolvedRequestSince == nil {
                unresolvedRequestSince = event.date
            }
        case .connectionReady:
            guard origin == .appServerBridge, event.scope != "local", event.scope != "unconfirmed-route" else { return }
            lastTransportReadyAt = event.date
            unresolvedBridgeSince = nil
            failures.removeAll { $0.origin == .appServerBridge && $0.workspaceFeature == nil }
        case .responseProgress, .responseCompleted:
            guard origin == .businessResponse else { return }
            latestProgressAt = event.date
            unresolvedBridgeSince = nil
            unresolvedRequestSince = nil
            unresolvedSettingsSince = nil
            failures.removeAll()
        case .authenticationFailure, .rateLimited, .serviceFailure:
            lastServiceFailureAt = event.date
            if event.workspaceFeature == .settings {
                unresolvedSettingsSince = nil
                failures.removeAll { $0.workspaceFeature == .settings }
            } else if origin == .appServerBridge {
                unresolvedBridgeSince = nil
                failures.removeAll { $0.origin == .appServerBridge && $0.workspaceFeature == nil }
            } else if origin == .responseStream {
                unresolvedRequestSince = nil
                failures.removeAll { $0.origin == .responseStream }
            }
        case .requestStopped:
            guard origin == .responseStream else { return }
            unresolvedRequestSince = nil
            failures.removeAll { $0.origin == .responseStream }
        case .workspaceRecovered:
            guard event.workspaceFeature == .settings else { return }
            unresolvedSettingsSince = nil
            failures.removeAll { $0.workspaceFeature == .settings }
        }
    }

    func shouldRecover(now: Date = Date(), lastAttemptAt: Date? = nil) -> Bool {
        guard ApplicationHealthFailoverPolicy.canAttemptRecovery(now: now, lastAttemptAt: lastAttemptAt) else { return false }
        guard let since = failureSince else { return false }
        return now.timeIntervalSince(since) >= ApplicationHealthFailoverPolicy.failureDuration
    }

    /// A fresh app log signal confirms recovery at its own layer, never public request success.
    func hasRecovered(since: Date, allowTransportReady: Bool, now: Date = Date()) -> Bool {
        guard failureSince == nil else { return false }
        func isUninterrupted(_ date: Date) -> Bool {
            date >= since && (0...120).contains(now.timeIntervalSince(date))
                && (lastFailureAt.map { $0 < date } ?? true)
                && (lastServiceFailureAt.map { $0 < date } ?? true)
        }
        if let progress = latestProgressAt, isUninterrupted(progress) { return true }
        guard allowTransportReady, !hasRequestFailureInEpisode,
              let ready = lastTransportReadyAt, isUninterrupted(ready),
              now.timeIntervalSince(ready) >= 10 else { return false }
        return true
    }

    private var activeEpisode: [Failure] {
        guard !failures.isEmpty else { return [] }
        if failureSince != nil { return failures }
        var start = failures.count - 1
        while start > 0, failures[start].date.timeIntervalSince(failures[start - 1].date) <= 20 {
            start -= 1
        }
        return Array(failures[start...])
    }

    private func observationCount(in episode: [Failure]) -> Int {
        var count = 0
        var previous: Date?
        for failure in episode where previous.map({ failure.date.timeIntervalSince($0) >= 2 }) ?? true {
            count += 1
            previous = failure.date
        }
        return count
    }
}
