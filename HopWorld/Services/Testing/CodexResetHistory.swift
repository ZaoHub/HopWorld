import Foundation

struct CodexResetObservation: Sendable {
    let timestamp: Date
    let accountID: String?
    let limitID: String
    let fiveHourResetsAt: Date?
    let fiveHourUsedPercent: Double?
    let weeklyResetsAt: Date?
    var weeklyUsedPercent: Double? = nil
}

struct CodexResetSummary: Sendable {
    let naturalResets: Int
    let unattributedChanges: Int
    let observationCount: Int
    let unknownAccountObservations: Int
    let firstObservationAt: Date?
    let lastObservationAt: Date?
}

enum CodexQuotaBoundaryKind: Sendable {
    case reportedReset, inferredStart, observedChange, unavailable
}

struct CodexQuotaBoundary: Sendable {
    let date: Date
    let kind: CodexQuotaBoundaryKind
    var observedBetween: DateInterval? = nil
}

struct CodexQuotaPeriod: Identifiable, Sendable {
    var id: Date { end.date }
    let accountID: String?
    var start: CodexQuotaBoundary
    var end: CodexQuotaBoundary
    let scheduledResetAt: Date?
    var interval: DateInterval { DateInterval(start: start.date, end: end.date) }
}

enum CodexResetHistory {
    // Reported deadlines can drift by over a minute between snapshots of the same window.
    static let tolerance: TimeInterval = 120

    /// Reconstruct observed quota periods instead of projecting today's deadline backwards.
    static func periods(_ observations: [CodexResetObservation], minutes: Int, now: Date,
                        latestResetsAt: Date? = nil) -> [CodexQuotaPeriod] {
        let duration = TimeInterval(minutes) * 60
        guard [300, 10080].contains(minutes), now.timeIntervalSince1970.isFinite else { return [] }
        func deadline(_ observation: CodexResetObservation) -> Date? {
            minutes == 300 ? observation.fiveHourResetsAt : observation.weeklyResetsAt
        }
        let valid = observations.filter {
            guard $0.limitID == "codex", $0.timestamp <= now,
                  $0.timestamp.timeIntervalSince1970.isFinite,
                  let reset = deadline($0), reset.timeIntervalSince1970.isFinite else { return false }
            let remaining = reset.timeIntervalSince($0.timestamp)
            return remaining >= -tolerance && remaining <= duration + tolerance
        }.sorted { $0.timestamp < $1.timestamp }
        // The displayed history belongs to the most recently observed account, never a merged quota.
        let account = valid.last?.accountID
        let samples = valid.filter { $0.accountID == account }
        var result: [CodexQuotaPeriod] = []
        var previousObservation: Date?
        let byTime = Dictionary(grouping: samples, by: \.timestamp)
        for timestamp in byTime.keys.sorted() {
            let deadlines = (byTime[timestamp] ?? []).compactMap(deadline)
            guard let first = deadlines.min(), let last = deadlines.max(),
                  last.timeIntervalSince(first) <= tolerance else { continue }
            if let current = result.last, let scheduled = current.scheduledResetAt {
                let difference = first.timeIntervalSince(scheduled)
                if abs(difference) <= tolerance {
                    previousObservation = timestamp
                    continue
                }
                // Late snapshots of an older window cannot reopen an already closed period.
                if difference < -tolerance { continue }
                let boundary: CodexQuotaBoundary
                if timestamp >= scheduled {
                    boundary = CodexQuotaBoundary(date: scheduled, kind: .reportedReset)
                    result[result.count - 1].end = boundary
                } else {
                    boundary = CodexQuotaBoundary(date: timestamp, kind: .observedChange,
                        observedBetween: DateInterval(start: previousObservation ?? current.start.date, end: timestamp))
                    result[result.count - 1].end = boundary
                }
                let nominalStart = first.addingTimeInterval(-duration)
                // Exclude idle gaps, but keep boundary usage when the difference is only deadline jitter.
                let start = nominalStart > boundary.date.addingTimeInterval(tolerance)
                    ? CodexQuotaBoundary(date: nominalStart, kind: .inferredStart) : boundary
                result.append(CodexQuotaPeriod(accountID: account, start: start,
                    end: CodexQuotaBoundary(date: first, kind: .reportedReset), scheduledResetAt: first))
            } else {
                result.append(CodexQuotaPeriod(accountID: account,
                    start: CodexQuotaBoundary(date: first.addingTimeInterval(-duration), kind: .inferredStart),
                    end: CodexQuotaBoundary(date: first, kind: .reportedReset), scheduledResetAt: first))
            }
            previousObservation = timestamp
        }
        if let latestResetsAt, latestResetsAt.timeIntervalSince1970.isFinite,
           latestResetsAt > now, latestResetsAt.timeIntervalSince(now) <= duration {
            if result.last.map({ latestResetsAt.timeIntervalSince($0.end.date) > tolerance }) ?? true {
                var start = latestResetsAt.addingTimeInterval(-duration)
                if let current = result.last, current.end.date > start {
                    // A live snapshot establishes a new window, but not the exact early-reset time.
                    let boundary = max(current.start.date, start)
                    result[result.count - 1].end = CodexQuotaBoundary(date: boundary, kind: .inferredStart)
                    start = boundary
                }
                result.append(CodexQuotaPeriod(accountID: nil,
                    start: CodexQuotaBoundary(date: start, kind: .inferredStart),
                    end: CodexQuotaBoundary(date: latestResetsAt, kind: .reportedReset), scheduledResetAt: latestResetsAt))
            }
        }
        if let last = result.last, last.end.date <= now {
            // After a known deadline, new usage starts a separate period even before a new deadline is read.
            result.append(CodexQuotaPeriod(accountID: last.accountID,
                start: CodexQuotaBoundary(date: last.end.date, kind: .reportedReset),
                end: CodexQuotaBoundary(date: now, kind: .unavailable), scheduledResetAt: nil))
        }
        if result.isEmpty {
            result.append(CodexQuotaPeriod(accountID: nil,
                start: CodexQuotaBoundary(date: now.addingTimeInterval(-duration), kind: .inferredStart),
                end: CodexQuotaBoundary(date: now, kind: .unavailable), scheduledResetAt: nil))
        }
        return result.filter { $0.end.date > $0.start.date }
    }

    /// Counts observed window changes; snapshots contain no complete manual-redemption history.
    static func summarize(_ observations: [CodexResetObservation], in interval: DateInterval) -> CodexResetSummary {
        func isInside(_ date: Date) -> Bool { date >= interval.start && date < interval.end }
        let relevant = observations.filter {
            $0.limitID == "codex" && $0.timestamp.timeIntervalSince1970.isFinite &&
            $0.fiveHourResetsAt?.timeIntervalSince1970.isFinite == true
        }
        let unknownAccounts = relevant.filter { ($0.accountID?.isEmpty != false) && isInside($0.timestamp) }.count
        let known = relevant.filter { $0.accountID?.isEmpty == false }
        let accounts = Dictionary(grouping: known, by: { $0.accountID! })
        var natural: [(account: String, resetAt: Date)] = []
        var unattributed = 0
        var sampledDates: Set<Date> = []

        for (accountID, samples) in accounts {
            let byTime = Dictionary(grouping: samples, by: \.timestamp)
            var previous: CodexResetObservation?
            for timestamp in byTime.keys.sorted() {
                guard let simultaneous = byTime[timestamp],
                      let earliest = simultaneous.compactMap(\.fiveHourResetsAt).min(),
                      let latest = simultaneous.compactMap(\.fiveHourResetsAt).max() else { continue }
                if isInside(timestamp) { sampledDates.insert(timestamp) }
                // Conflicting simultaneous snapshots cannot establish which quota window came first.
                guard latest.timeIntervalSince(earliest) <= tolerance else {
                    if isInside(timestamp) { unattributed += 1 }
                    previous = nil
                    continue
                }
                let weeklyDates = simultaneous.compactMap(\.weeklyResetsAt).filter { $0.timeIntervalSince1970.isFinite }
                if let firstWeek = weeklyDates.min(), let lastWeek = weeklyDates.max(),
                   lastWeek.timeIntervalSince(firstWeek) > tolerance {
                    if isInside(timestamp) { unattributed += 1 }
                    previous = nil
                    continue
                }
                let current = CodexResetObservation(timestamp: timestamp, accountID: accountID, limitID: "codex",
                    fiveHourResetsAt: latest, fiveHourUsedPercent: nil, weeklyResetsAt: weeklyDates.max())
                guard latest >= timestamp.addingTimeInterval(-tolerance) else {
                    // An already stale snapshot must not move the baseline back to an older window.
                    continue
                }
                guard let prior = previous, let priorReset = prior.fiveHourResetsAt else {
                    previous = current
                    continue
                }
                let delta = latest.timeIntervalSince(priorReset)
                if abs(delta) <= tolerance {
                    previous = CodexResetObservation(timestamp: timestamp, accountID: accountID, limitID: "codex",
                        fiveHourResetsAt: max(latest, priorReset), fiveHourUsedPercent: nil,
                        weeklyResetsAt: current.weeklyResetsAt ?? prior.weeklyResetsAt)
                    continue
                }

                let earlyWeeklyChange: Bool
                if let oldWeek = prior.weeklyResetsAt, let newWeek = current.weeklyResetsAt {
                    earlyWeeklyChange = abs(newWeek.timeIntervalSince(oldWeek)) > tolerance && timestamp < oldWeek
                } else { earlyWeeklyChange = false }
                if delta > tolerance && timestamp >= priorReset && !earlyWeeklyChange {
                    // A long unobserved gap confirms only this one change, never all elapsed 5-hour slots.
                    if isInside(priorReset), !natural.contains(where: {
                        $0.account == accountID && abs($0.resetAt.timeIntervalSince(priorReset)) <= tolerance
                    }) {
                        natural.append((accountID, priorReset))
                    }
                    previous = current
                } else {
                    if isInside(timestamp) { unattributed += 1 }
                    // A backwards jump can be a delayed snapshot; break the chain to avoid counting it twice.
                    previous = delta < -tolerance ? nil : current
                }
            }
        }
        return CodexResetSummary(naturalResets: natural.count, unattributedChanges: unattributed,
            observationCount: sampledDates.count, unknownAccountObservations: unknownAccounts,
            firstObservationAt: sampledDates.min(), lastObservationAt: sampledDates.max())
    }
}
