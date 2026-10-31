#!/usr/bin/env python3
"""Exercise aligned quota observations and token intervals in production Swift."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
fixture = r'''
import Foundation

@main struct Checks {
    static let base = Date(timeIntervalSince1970: 1_700_000_000)
    static func date(_ seconds: Double) -> Date { base.addingTimeInterval(seconds) }
    static func observation(_ t: Double, _ used: Double, reset: Double = 18000,
                            account: String = "a", weekly: Double? = nil) -> CodexResetObservation {
        CodexResetObservation(timestamp: date(t), accountID: account, limitID: "codex",
            fiveHourResetsAt: date(reset), fiveHourUsedPercent: used,
            weeklyResetsAt: date(604800), weeklyUsedPercent: weekly)
    }
    static func event(_ t: Double, _ input: Int64, _ cached: Int64, _ output: Int64,
                      account: String = "a", model: String = "gpt-6.1-sol") -> CodexTokenEvent {
        CodexTokenEvent(timestamp: date(t), inputTokens: input, outputTokens: output, cachedInputTokens: cached,
            model: model, reasoningEffort: "ultra", accountID: account)
    }
    static func rows(_ observations: [CodexResetObservation], events: [CodexTokenEvent] = [],
                     minutes: Int = 300, account: String? = "a", modelID: String? = nil) -> [CodexQuotaComparison] {
        let snapshot = CodexTokenHistorySnapshot(events: events, scannedFiles: 1, unreadableFiles: 0,
            skippedRecords: 0, resetObservations: observations)
        return snapshot.quotaComparisons(in: DateInterval(start: date(0), end: date(3600)),
            bucketDuration: 1800, minutes: minutes, accountID: account, modelID: modelID)
    }
    static func main() {
        let events = [event(0, 500, 0, 500), event(600, 10, 4, 1), event(1800, 20, 8, 2),
                      event(2400, 30, 12, 3), event(3600, 999, 0, 999), event(600, 999, 0, 999, account: "b")]
        let samples = [observation(0, 10), observation(600, 14, reset: 18005), observation(600, 14),
                       observation(1800, 20), observation(2400, 21), observation(3599, 24),
                       observation(600, 99, account: "b")]
        let aligned = rows(samples.reversed(), events: events)
        precondition(aligned.count == 2 && aligned[0].status == .observed && aligned[1].status == .observed)
        precondition(aligned[0].decline == 10 && aligned[1].decline == 4)
        precondition(aligned[0].uncachedInputTokens == 18 && aligned[0].cachedInputTokens == 12)
        precondition(aligned[0].outputTokens == 3 && aligned[1].outputTokens == 3)
        precondition(aligned[1].uncachedInputTokens == 18 && aligned[1].cachedInputTokens == 12)
        precondition(aligned[0].observationCount == 3)
        precondition(aligned[0].sampledInterval == DateInterval(start: date(0), end: date(1800)))
        precondition(aligned[1].sampledInterval == DateInterval(start: date(1800), end: date(3599)))
        let jitter = rows([observation(0, 10), observation(600, 14, reset: 18075),
                           observation(600, 14), observation(1200, 17, reset: 18090)])
        precondition(jitter[0].status == .observed && jitter[0].decline == 7,
            "Minor deadline jitter must not turn the same quota window into a conflict or reset")
        precondition(rows([observation(600, 20)])[0].status == .insufficient)
        precondition(rows(samples, account: nil)[0].status == .unknownAccount)
        let conflict = rows([observation(0, 10), observation(600, 14), observation(600, 15)])
        precondition(conflict[0].status == .conflicting && conflict[0].decline == nil)
        let reversed = rows([observation(0, 10), observation(600, 8), observation(1200, 14)])
        precondition(reversed[0].status == .conflicting && reversed[0].decline == nil)
        let recoveredSamples = [observation(0, 0), observation(100, 9), observation(108, 7),
            observation(135, 11), observation(141, 10), observation(300, 17), observation(308, 16),
            observation(600, 19)]
        let recovered = rows(recoveredSamples, events: events)[0]
        precondition(recovered.status == .observed && recovered.decline == 19 && recovered.transientRollbackCount == 3)
        precondition(recovered.observationCount == 8 && recovered.fromPercent == 0 && recovered.toPercent == 19)
        precondition(recovered.sampledInterval == DateInterval(start: date(0), end: date(600)))
        precondition(recovered.uncachedInputTokens == 6 && recovered.cachedInputTokens == 4 && recovered.outputTokens == 1,
            "Recovered reads must preserve the original Token interval, boundary exclusion and account filter")
        let recoveredModel = rows(recoveredSamples, events: events, modelID: events[0].modelID)[0]
        precondition(recoveredModel.decline == 19 && recoveredModel.uncachedInputTokens == 6)
        let recoveredMixed = rows(recoveredSamples,
            events: [events[1], event(200, 20, 0, 2, model: "gpt-6-astra")], modelID: events[0].modelID)[0]
        precondition(recoveredMixed.status == .mixedModels && recoveredMixed.decline == nil)
        for unresolved in [[observation(0, 0), observation(100, 20), observation(600, 19)],
                           [observation(0, 10), observation(100, 9), observation(600, 14)],
                           [observation(0, 10), observation(600, 9)]] {
            precondition(rows(unresolved)[0].status == .conflicting && rows(unresolved)[0].decline == nil)
        }
        let recoveredReset = rows([observation(0, 0), observation(100, 9), observation(108, 7),
            observation(600, 19, reset: 18600)])[0]
        precondition(recoveredReset.status == .resetChanged && recoveredReset.decline == nil)
        let weeklyRecovered = rows([observation(0, 10, weekly: 0), observation(100, 20, weekly: 9),
            observation(108, 30, weekly: 7), observation(600, 40, weekly: 19)], minutes: 10080)[0]
        precondition(weeklyRecovered.status == .observed && weeklyRecovered.decline == 19 && weeklyRecovered.transientRollbackCount == 1)
        let reset = rows([observation(0, 80), observation(600, 5, reset: 18600)])
        precondition(reset[0].status == .resetChanged && reset[0].decline == nil)
        let saturated = rows([observation(0, 80), observation(600, 100)])
        precondition(saturated[0].status == .capped && saturated[0].decline == nil)
        precondition(rows([observation(0, 5), observation(600, 5)])[0].decline == 0)

        let selectedID = events[0].modelID
        let pure = rows([observation(0, 10), observation(600, 14)], events: events, modelID: selectedID)
        precondition(pure[0].decline == 4 && pure[0].uncachedInputTokens == 6)
        let mixed = rows([observation(0, 10), observation(600, 14)],
            events: [event(100, 10, 0, 1), event(200, 20, 0, 2, model: "gpt-6-astra")], modelID: selectedID)
        precondition(mixed[0].status == .mixedModels && mixed[0].decline == nil)
        precondition(mixed[0].uncachedInputTokens == 10)
        let otherModel = CodexTokenModelUsage(model: "gpt-6-luna", reasoningEffort: "low").id
        precondition(rows(samples, events: events, modelID: otherModel)[0].status == .noSelectedModel)
        let weekly = rows([observation(0, 10, weekly: 1), observation(600, 90, weekly: 4)], minutes: 10080)
        precondition(weekly[0].decline == 3, "Week mode must not display five-hour usage as weekly usage")
        let weeklySnapshot = CodexTokenHistorySnapshot(events: [
            event(0, 500, 0, 500), event(600, 10, 4, 1), event(18000, 20, 8, 2),
            event(24000, 30, 12, 3), event(604800, 999, 0, 999), event(600, 999, 0, 999, account: "b")
        ], scannedFiles: 1, unreadableFiles: 0, skippedRecords: 0, resetObservations: [
            observation(0, 10, weekly: 1), observation(18000, 90, weekly: 4),
            observation(35999, 5, reset: 53999, weekly: 8), observation(600, 99, account: "b", weekly: 99)
        ])
        let weeklyRows = weeklySnapshot.quotaComparisons(in: DateInterval(start: date(0), end: date(604800)),
            bucketDuration: 18000, minutes: 10080, accountID: "a")
        precondition(weeklyRows.count == 34 && weeklyRows[0].start == date(0))
        precondition(weeklyRows[0].end == date(18000) && weeklyRows[1].start == date(18000))
        precondition(weeklyRows.last?.end == date(604800) && weeklyRows.last?.start == date(594000))
        precondition(weeklyRows[0].decline == 3 && weeklyRows[1].decline == 4,
            "Five-hour rows in week mode compare weekly quota, even when the five-hour quota resets")
        precondition(weeklyRows[0].uncachedInputTokens == 18 && weeklyRows[0].cachedInputTokens == 12)
        precondition(weeklyRows[0].outputTokens == 3 && weeklyRows[1].outputTokens == 3)
        precondition(weeklyRows[1].uncachedInputTokens == 18 && weeklyRows[1].cachedInputTokens == 12,
            "The boundary observation can anchor adjacent deltas without counting its tokens twice")
        precondition(weeklyRows.dropFirst(2).allSatisfy { $0.status == .insufficient })
        let stale = rows([observation(0, 10), observation(600, 20, reset: 100)])
        precondition(stale[0].status == .insufficient && stale[0].decline == nil)
        let snapshot = CodexTokenHistorySnapshot(events: [], scannedFiles: 0, unreadableFiles: 0, skippedRecords: 0)
        precondition(snapshot.quotaComparisons(in: DateInterval(start: date(0), end: date(3600)),
            bucketDuration: 0, minutes: 300, accountID: "a").isEmpty)
        print("Codex quota comparison: aligned intervals, resets, conflicts, models, accounts and week mode passed")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="hopworld-quota-comparison-") as temporary:
    directory = Path(temporary)
    source = directory / "Checks.swift"
    source.write_text(fixture)
    binary = directory / "checks"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library",
        str(root / "HopWorld/Services/Testing/CodexResetHistory.swift"),
        str(root / "HopWorld/Services/Testing/CodexTokenHistory.swift"),
        str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
