#!/usr/bin/env python3
"""Verify conservative, read-only attribution of observed Codex quota windows."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
fixture = r'''
import Foundation

@main struct Checks {
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    static func date(_ seconds: Double) -> Date { epoch.addingTimeInterval(seconds) }
    static func observation(_ timestamp: Double, _ reset: Double, account: String? = "account-a",
                            limit: String = "codex", week: Double? = 604_800) -> CodexResetObservation {
        CodexResetObservation(timestamp: date(timestamp), accountID: account, limitID: limit,
            fiveHourResetsAt: date(reset), fiveHourUsedPercent: 20,
            weeklyResetsAt: week.map(date))
    }
    static func summary(_ rows: [CodexResetObservation], start: Double = 0, end: Double = 604_800) -> CodexResetSummary {
        CodexResetHistory.summarize(rows, in: DateInterval(start: date(start), end: date(end)))
    }
    static func main() {
        let jitter = [observation(0, 18_000), observation(0, 18_000), observation(1, 18_003),
                      observation(2, 17_999), observation(3, 18_005)]
        let unchanged = summary(jitter)
        precondition(unchanged.naturalResets == 0 && unchanged.unattributedChanges == 0)
        precondition(unchanged.observationCount == 4)

        let rollover = [observation(0, 18_000), observation(18_020, 36_020), observation(18_020, 36_020)]
        precondition(summary(rollover).naturalResets == 1)
        precondition(summary(rollover.reversed()).naturalResets == 1)
        precondition(summary([rollover[0], observation(400_000, 418_000)]).naturalResets == 1,
            "A gap is evidence of one transition, not every elapsed clock-time slot")

        let early = summary([observation(0, 18_000), observation(3_000, 21_000)])
        precondition(early.naturalResets == 0 && early.unattributedChanges == 1)
        let changedWeek = summary([observation(0, 18_000), observation(18_020, 36_020, week: 620_000)])
        precondition(changedWeek.naturalResets == 0 && changedWeek.unattributedChanges == 1)

        let conflict = summary([observation(0, 18_000), observation(0, 24_000), observation(25_000, 43_000)])
        precondition(conflict.naturalResets == 0 && conflict.unattributedChanges == 1)
        let weekConflict = summary([observation(0, 18_000), observation(0, 18_000, week: 620_000),
                                    observation(25_000, 43_000)])
        precondition(weekConflict.naturalResets == 0 && weekConflict.unattributedChanges == 1)

        let accounts = summary([observation(0, 18_000), observation(20_000, 38_000, account: "account-b")])
        precondition(accounts.naturalResets == 0 && accounts.unattributedChanges == 0)
        let unknown = summary([observation(0, 18_000, account: nil), observation(20_000, 38_000, account: nil)])
        precondition(unknown.naturalResets == 0 && unknown.unknownAccountObservations == 2)
        let differentLimits = summary([observation(0, 18_000), observation(20_000, 38_000, limit: "premium"),
                                       observation(21_000, 39_000, limit: "base_model_inference")])
        precondition(differentLimits.naturalResets == 0 && differentLimits.observationCount == 1)

        precondition(summary(rollover, start: 0, end: 18_000).naturalResets == 0,
            "A reset at the right boundary belongs to the next interval")
        precondition(summary(rollover, start: 18_000, end: 36_000).naturalResets == 1)
        precondition(summary(rollover, start: 18_001, end: 36_000).naturalResets == 0)
        let stale = summary(rollover + [observation(19_000, 18_000), observation(20_000, 36_020)])
        precondition(stale.naturalResets == 1 && stale.unattributedChanges == 0)
        let backwards = summary([observation(0, 24_000), observation(1_000, 20_000), observation(25_000, 43_000)])
        precondition(backwards.naturalResets == 0 && backwards.unattributedChanges == 1)
        let boundaryWeek = summary([observation(0, 18_000, week: 18_000),
                                    observation(18_001, 36_001, week: 622_800)])
        precondition(boundaryWeek.naturalResets == 1)
        precondition(summary([]).firstObservationAt == nil)
        print("Codex reset history: 17 conservative attribution checks passed")

        let week: Double = 604_800
        let weeklyRows = [observation(100, 18_000, week: week),
                          observation(week + 10, week + 18_000, week: 2 * week)]
        let periods = CodexResetHistory.periods(weeklyRows, minutes: 10080, now: date(week + 100))
        precondition(periods.count == 2)
        precondition(periods[0].interval == DateInterval(start: date(0), end: date(week)))
        precondition(periods[1].interval == DateInterval(start: date(week), end: date(2 * week)))
        precondition(periods[1].start.kind == .reportedReset)

        let earlyRows = [observation(100, 18_000, week: week),
                         observation(100_010, 118_000, week: week + 100_000)]
        let earlyPeriods = CodexResetHistory.periods(earlyRows, minutes: 10080, now: date(100_020))
        precondition(earlyPeriods.count == 2)
        precondition(earlyPeriods[0].end.date == date(100_010))
        precondition(earlyPeriods[1].start.date == date(100_010))
        precondition(earlyPeriods[0].end.kind == .observedChange)
        precondition(earlyPeriods[1].start.observedBetween == DateInterval(start: date(100), end: date(100_010)))
        precondition(earlyPeriods[0].scheduledResetAt == date(week), "Keep the old scheduled deadline visible")

        let expired = CodexResetHistory.periods([weeklyRows[0]], minutes: 10080, now: date(week + 20))
        precondition(expired.count == 2 && expired[1].start.date == date(week))
        precondition(expired[1].end.kind == .unavailable && expired[1].scheduledResetAt == nil)
        precondition(expired[1].end.date == date(week + 20))

        let noisy = [observation(100, 18_000, week: week), observation(200, 18_000, week: week + 5),
                     observation(300, 18_000, week: week - 6)]
        let stable = CodexResetHistory.periods(noisy, minutes: 10080, now: date(400))
        precondition(stable.count == 1 && stable[0].end.date == date(week))
        let longGap = CodexResetHistory.periods([weeklyRows[0],
            observation(2 * week + 100, 2 * week + 18_100, week: 3 * week + 100)],
            minutes: 10080, now: date(2 * week + 110))
        precondition(longGap.count == 2 && longGap[0].end.date == date(week))
        precondition(longGap[1].start.date == date(2 * week + 100) && longGap[1].start.kind == .inferredStart)

        let five = CodexResetHistory.periods(rollover, minutes: 300, now: date(18_030))
        precondition(five.count == 2 && five[0].end.date == date(18_000) && five[1].start.date == date(18_000),
            "Small deadline jitter must not leave a gap that drops boundary usage")
        let afterIdle = CodexResetHistory.periods([observation(0, 18_000), observation(18_200, 36_200)],
            minutes: 300, now: date(18_210))
        precondition(afterIdle[1].start.date == date(18_200) && afterIdle[0].end.date == date(18_000),
            "A new window starts at its own reset minus five hours, excluding the preceding idle gap")
        precondition(afterIdle[1].interval.duration == 18_000 && afterIdle[1].start.kind == .inferredStart)

        let timerDrift = [observation(100, 18_000, week: week),
                          observation(200, 18_075, week: week + 75),
                          observation(300, 18_090, week: week + 90),
                          observation(400, 18_000, week: week)]
        for minutes in [300, 10080] {
            let driftPeriods = CodexResetHistory.periods(timerDrift, minutes: minutes, now: date(500))
            precondition(driftPeriods.count == 1 && driftPeriods[0].start.date == date(0),
                "Minute-scale deadline jitter must not invent a reset or discard the start of a window")
        }
        precondition(summary(timerDrift).unattributedChanges == 0)
        let accountPeriods = CodexResetHistory.periods([weeklyRows[0],
            observation(500, 18_500, account: "account-b", week: week + 400)],
            minutes: 10080, now: date(600))
        precondition(accountPeriods.count == 1 && accountPeriods[0].accountID == "account-b")
        let noRecords = CodexResetHistory.periods([], minutes: 10080, now: date(100), latestResetsAt: date(week))
        precondition(noRecords.count == 1 && noRecords[0].start.kind == .inferredStart)
        precondition(noRecords[0].end.date == date(week))
        let unknownPeriod = CodexResetHistory.periods([], minutes: 10080, now: date(100))
        precondition(unknownPeriod[0].end.kind == .unavailable)
        let staleLive = CodexResetHistory.periods(earlyRows, minutes: 10080, now: date(100_020), latestResetsAt: date(week))
        precondition(staleLive.count == 2 && staleLive.last?.end.date == date(week + 100_000))
        print("Codex quota periods: natural/early reset, gap, jitter, account and missing-deadline checks passed")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="hopworld-codex-reset-") as temporary:
    directory = Path(temporary)
    source = directory / "Checks.swift"
    binary = directory / "checks"
    source.write_text(fixture)
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library",
        str(root / "HopWorld/Services/Testing/CodexResetHistory.swift"),
        str(source), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True)
