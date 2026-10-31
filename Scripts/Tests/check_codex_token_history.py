#!/usr/bin/env python3
"""Compile the production local token reader and exercise real JSONL fixtures."""
from pathlib import Path
import subprocess
import tempfile
import sys

root = Path(__file__).resolve().parents[2]
fixture = r'''
import Foundation

@main struct Checks {
    static let base = ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!
    static func counts(_ input: Int64, _ output: Int64, _ cached: Int64) -> [String: Int64] {
        ["input_tokens": input, "output_tokens": output, "cached_input_tokens": cached]
    }
    static func event(_ seconds: Double, total: [String: Int64]? = nil,
                      last: [String: Int64]? = nil) -> [String: Any] {
        var info: [String: Any] = [:]
        if let total { info["total_token_usage"] = total }
        if let last { info["last_token_usage"] = last }
        return ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: base.addingTimeInterval(seconds)),
                "payload": ["type": "token_count", "info": info]]
    }
    static func context(_ seconds: Double, model: String?, effort: String?) -> [String: Any] {
        var payload: [String: Any] = [:]
        if let model { payload["model"] = model }
        if let effort { payload["effort"] = effort }
        return ["type": "turn_context", "timestamp": ISO8601DateFormatter().string(from: base.addingTimeInterval(seconds)),
                "payload": payload]
    }
    static func write(_ root: URL, _ filename: String, thread: String,
                      events: [[String: Any]], suffix: String = "", metadata: [String: Any] = [:]) throws {
        let file = root.appendingPathComponent(filename)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var payload = metadata
        payload["id"] = thread
        let rows = [["type": "session_meta", "payload": payload]] + events
        var data = Data()
        for row in rows {
            data.append(try JSONSerialization.data(withJSONObject: row))
            data.append(10)
        }
        data.append(Data(suffix.utf8))
        try data.write(to: file)
    }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = event(0, total: counts(1000, 200, 800), last: counts(100, 20, 80))
        let second = event(1800, total: counts(1100, 230, 870), last: counts(100, 30, 70))
        try write(root, "sessions/2026/01/original.jsonl", thread: "thread-a", events: [
            first, event(1, total: counts(1000, 200, 800), last: counts(100, 20, 80)), second,
            ["type": "event_msg", "timestamp": "2026-01-01T00:00:02Z", "payload": ["type": "token_count", "info": NSNull()]]
        ])
        // A copied fork and an archived duplicate must not count inherited requests again.
        try write(root, "sessions/fork.jsonl", thread: "thread-b", events: [first, second,
            event(3600, total: counts(50, 5, 20), last: counts(50, 5, 20)),
            event(3601, total: counts(50, 5, 20), last: counts(50, 5, 20)),
            event(7200, total: counts(70, 10, 25), last: counts(20, 5, 5))
        ], metadata: ["forked_from_id": "thread-a", "timestamp": "2026-01-01T01:00:00Z"])
        try write(root, "archived_sessions/duplicate.jsonl", thread: "thread-a", events: [first, second])
        // A resumed page continues the same thread; cumulative totals are never treated as this request.
        try write(root, "sessions/resumed.jsonl", thread: "thread-a", events: [
            event(10800, total: counts(2000, 500, 1500), last: counts(200, 40, 100))
        ], suffix: "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\"")
        let history = try CodexTokenHistoryReader.read(codexHomeURL: root)
        precondition(history.events.count == 5)
        precondition(history.events.map(\.inputTokens) == [100, 100, 50, 20, 200])
        precondition(history.events.reduce(Int64(0)) { $0 + $1.outputTokens } == 100)
        precondition(history.events.reduce(Int64(0)) { $0 + $1.cachedInputTokens } == 275)
        precondition(history.scannedFiles == 4 && !history.isPartial && history.firstEventAt == base)
        let interval = DateInterval(start: base, duration: 5 * 3600)
        let buckets = history.buckets(in: interval, bucketDuration: 1800)
        precondition(buckets.count == 10 && buckets[0].inputTokens == 100 && buckets[1].inputTokens == 100)
        precondition(buckets.reduce(Int64(0)) { $0 + $1.inputTokens } == 470)
        precondition(buckets.last?.end == interval.end)
        let week = history.buckets(in: DateInterval(start: base, duration: 7 * 24 * 3600), bucketDuration: 5 * 3600)
        precondition(week.count == 34 && week[0].inputTokens == 470 && week.dropFirst().allSatisfy { $0.inputTokens == 0 })
        precondition(week.last?.end.timeIntervalSince(week.last!.start) == 3 * 3600)
        precondition(history.buckets(in: interval, bucketDuration: 0).isEmpty)
        precondition(history.buckets(in: interval, bucketDuration: .nan).isEmpty)

        // Identical request timestamps and counters do not merge independent threads.
        let independent = root.appendingPathComponent("independent")
        try write(independent, "sessions/a.jsonl", thread: "independent-a", events: [first])
        try write(independent, "sessions/b.jsonl", thread: "independent-b", events: [first])
        let separate = try CodexTokenHistoryReader.read(codexHomeURL: independent)
        precondition(separate.events.count == 2 && separate.events.reduce(Int64(0)) { $0 + $1.inputTokens } == 200)

        // Deduplicated inherited usage must still seed the child's baseline for a total-only next event.
        let baseline = root.appendingPathComponent("baseline")
        try write(baseline, "sessions/parent.jsonl", thread: "parent", events: [first])
        try write(baseline, "sessions/child.jsonl", thread: "child", events: [
            first, event(3600, total: counts(1100, 230, 870))
        ], metadata: ["forked_from_id": "parent", "timestamp": "2026-01-01T00:30:00Z"])
        let seeded = try CodexTokenHistoryReader.read(codexHomeURL: baseline)
        precondition(seeded.events.count == 2 && !seeded.isPartial)
        precondition(seeded.events.map(\.inputTokens) == [100, 100])

        // Paginated history uses its explicit exclusive ordinal boundary, not an inferred session time.
        let paginated = root.appendingPathComponent("paginated")
        var inherited = first
        inherited["ordinal"] = 3
        try write(paginated, "sessions/parent.jsonl", thread: "parent", events: [inherited])
        try write(paginated, "sessions/child.jsonl", thread: "child", events: [inherited], metadata: [
            "history_base": ["thread_id": "parent", "end_ordinal_exclusive": 4]
        ])
        let pages = try CodexTokenHistoryReader.read(codexHomeURL: paginated)
        precondition(pages.events.count == 1 && !pages.isPartial)

        // Model/effort comes from the matching thread's latest preceding actual turn context.
        let modelRoot = root.appendingPathComponent("models")
        let ultra = context(10, model: "gpt-6.1-sol", effort: "ultra")
        let ultraEvent = event(20, total: counts(11, 3, 7), last: counts(10, 2, 7))
        let astra = context(30, model: "gpt-6-astra", effort: "high")
        let astraEvent = event(40, total: counts(31, 6, 17), last: counts(20, 3, 10))
        try write(modelRoot, "sessions/a.jsonl", thread: "a", events: [
            event(0, total: counts(1, 1, 0), last: counts(1, 1, 0)), ultra, ultraEvent, astra, astraEvent
        ])
        // A resumed page can refer to a context recorded in an earlier page of the same thread.
        try write(modelRoot, "sessions/a-resumed.jsonl", thread: "a", events: [
            event(50, total: counts(61, 12, 37), last: counts(30, 6, 20))
        ])
        try write(modelRoot, "sessions/b.jsonl", thread: "b", events: [
            context(5, model: "gpt-6-luna", effort: "low"), ultraEvent
        ])
        try write(modelRoot, "sessions/fork.jsonl", thread: "fork", events: [
            ultra, ultraEvent, astra, astraEvent,
            event(110, total: counts(5, 1, 3), last: counts(5, 1, 3)),
            context(120, model: "gpt-6.1-sol", effort: "xhigh"),
            event(130, total: counts(45, 9, 33), last: counts(40, 8, 30))
        ], metadata: ["forked_from_id": "a", "timestamp": "2026-01-01T00:01:40Z"])
        let withModels = try CodexTokenHistoryReader.read(codexHomeURL: modelRoot)
        precondition(withModels.events.count == 7 && !withModels.isPartial)
        let modelUsage = withModels.models(in: interval)
        precondition(modelUsage.count == 5)
        precondition(modelUsage[0].displayName == "GPT-6 Astra High" && modelUsage[0].inputTokens == 50 && modelUsage[0].eventCount == 2)
        let solUltra = modelUsage.first { $0.displayName == "GPT-6.1 Sol Ultra" }!
        precondition(solUltra.inputTokens == 10 && solUltra.outputTokens == 2 && solUltra.cachedInputTokens == 7)
        precondition(modelUsage.first { $0.model == nil }?.inputTokens == 6)
        let selected = withModels.buckets(in: interval, bucketDuration: 1800, modelID: solUltra.id)
        precondition(selected.reduce(Int64(0)) { $0 + $1.inputTokens } == 10)
        precondition(selected.reduce(Int64(0)) { $0 + $1.outputTokens } == 2)
        precondition(withModels.models(in: DateInterval(start: base, duration: 20)).allSatisfy { $0.model == nil })
        precondition(CodexTokenModelUsage(model: nil, reasoningEffort: nil).displayName == "未记录模型 未记录档位")
        precondition(CodexTokenModelUsage(model: "gpt-6.1-sol", reasoningEffort: nil).displayName == "GPT-6.1 Sol 未记录档位")
        precondition(CodexTokenModelUsage(model: "gpt-6.2-sol-pro", reasoningEffort: "future-effort").displayName == "GPT-6.2 Sol Pro future-effort")
        precondition(CodexTokenModelUsage(model: nil, reasoningEffort: nil).id != CodexTokenModelUsage(model: "unknown", reasoningEffort: nil).id)

        // Same-timestamp context changes respect the log ordinal, and missing fields stay unknown.
        let sameTime = root.appendingPathComponent("same-time")
        var before = event(10, total: counts(10, 1, 0), last: counts(10, 1, 0))
        before["ordinal"] = 4
        var turn = context(10, model: "gpt-6.1-sol", effort: nil)
        turn["ordinal"] = 5
        var after = event(10, total: counts(30, 3, 0), last: counts(20, 2, 0))
        after["ordinal"] = 6
        try write(sameTime, "sessions/t.jsonl", thread: "same", events: [before, turn, after])
        let timed = try CodexTokenHistoryReader.read(codexHomeURL: sameTime)
        precondition(timed.events[0].model == nil && timed.events[1].model == "gpt-6.1-sol")
        precondition(timed.events[1].reasoningEffort == nil && !timed.isPartial)

        // Reset observations also come from rate-limit-only messages and never mix reserve/premium buckets.
        let resetRoot = root.appendingPathComponent("resets")
        func rateOnly(_ seconds: Double, limitID: String?, fiveHour: Double, weekly: Double) -> [String: Any] {
            var limits: [String: Any] = [
                "primary": ["used_percent": 75.0, "window_minutes": 300, "resets_at": fiveHour],
                "secondary": ["used_percent": 25.0, "window_minutes": 10080, "resets_at": weekly]
            ]
            if let limitID { limits["limit_id"] = limitID }
            return ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: base.addingTimeInterval(seconds)),
                    "payload": ["type": "token_count", "info": NSNull(), "rate_limits": limits]]
        }
        let fiveHourReset = base.addingTimeInterval(18000).timeIntervalSince1970
        let weeklyReset = base.addingTimeInterval(604800).timeIntervalSince1970
        try write(resetRoot, "sessions/rates.jsonl", thread: "rates", events: [
            rateOnly(0, limitID: "codex", fiveHour: fiveHourReset, weekly: weeklyReset),
            rateOnly(10, limitID: "premium", fiveHour: fiveHourReset, weekly: weeklyReset),
            rateOnly(20, limitID: "base_model_inference", fiveHour: fiveHourReset, weekly: weeklyReset),
            rateOnly(30, limitID: nil, fiveHour: fiveHourReset, weekly: weeklyReset),
            rateOnly(40, limitID: "codex", fiveHour: fiveHourReset, weekly: weeklyReset)
        ], metadata: ["creator_account_id": "fixture-account"])
        let rates = try CodexTokenHistoryReader.read(codexHomeURL: resetRoot)
        precondition(rates.events.isEmpty && !rates.isPartial && rates.resetObservations.count == 2)
        precondition(rates.resetObservations.allSatisfy { $0.accountID == "fixture-account" && $0.limitID == "codex" })
        precondition(rates.resetObservations[0].fiveHourResetsAt == base.addingTimeInterval(18000))
        precondition(rates.resetObservations[0].fiveHourUsedPercent == 75)
        precondition(rates.resetObservations[0].weeklyResetsAt == base.addingTimeInterval(604800))
        precondition(rates.resetObservations[0].weeklyUsedPercent == 25)

        // Bucket end is exclusive, and cache reads remain a subset of input instead of being added again.
        let boundaries = CodexTokenHistorySnapshot(events: [
            CodexTokenEvent(timestamp: base.addingTimeInterval(-1), inputTokens: 99, outputTokens: 99, cachedInputTokens: 0),
            CodexTokenEvent(timestamp: base, inputTokens: 10, outputTokens: 2, cachedInputTokens: 7),
            CodexTokenEvent(timestamp: base.addingTimeInterval(1800), inputTokens: 20, outputTokens: 4, cachedInputTokens: 14),
            CodexTokenEvent(timestamp: interval.end, inputTokens: 99, outputTokens: 99, cachedInputTokens: 0)
        ], scannedFiles: 0, unreadableFiles: 0, skippedRecords: 0)
        let exact = boundaries.buckets(in: interval, bucketDuration: 1800)
        precondition(exact[0].inputTokens == 10 && exact[1].inputTokens == 20)
        precondition(exact.reduce(Int64(0)) { $0 + $1.inputTokens } == 30)

        // A weekly reset partitions totals exactly once and never includes another account's usage.
        let quotaWeekSeconds: Double = 604800
        let quotaEvents = CodexTokenHistorySnapshot(events: [
            CodexTokenEvent(timestamp: base, inputTokens: 1, outputTokens: 1,
                cachedInputTokens: 0, model: "gpt-6.1-sol", reasoningEffort: "ultra", accountID: "account-a"),
            CodexTokenEvent(timestamp: base.addingTimeInterval(18000), inputTokens: 2, outputTokens: 1,
                cachedInputTokens: 1, model: "gpt-6.1-sol", reasoningEffort: "ultra", accountID: "account-a"),
            CodexTokenEvent(timestamp: base.addingTimeInterval(18000), inputTokens: 3, outputTokens: 1,
                cachedInputTokens: 2, model: "gpt-6-astra", reasoningEffort: "high", accountID: "account-a"),
            CodexTokenEvent(timestamp: base.addingTimeInterval(quotaWeekSeconds - 1), inputTokens: 10, outputTokens: 1,
                cachedInputTokens: 5, model: "gpt-6.1-sol", reasoningEffort: "ultra", accountID: "account-a"),
            CodexTokenEvent(timestamp: base.addingTimeInterval(quotaWeekSeconds), inputTokens: 20, outputTokens: 2,
                cachedInputTokens: 10, model: "gpt-6.1-sol", reasoningEffort: "ultra", accountID: "account-a"),
            CodexTokenEvent(timestamp: base.addingTimeInterval(quotaWeekSeconds + 1), inputTokens: 30, outputTokens: 3,
                cachedInputTokens: 15, model: "gpt-6.1-sol", reasoningEffort: "ultra", accountID: "account-a"),
            CodexTokenEvent(timestamp: base.addingTimeInterval(quotaWeekSeconds + 1), inputTokens: 999, outputTokens: 99,
                cachedInputTokens: 0, model: "gpt-6.1-sol", reasoningEffort: "ultra", accountID: "account-b")
        ], scannedFiles: 0, unreadableFiles: 0, skippedRecords: 0)
        let observed = [
            CodexResetObservation(timestamp: base, accountID: "account-a", limitID: "codex",
                fiveHourResetsAt: nil, fiveHourUsedPercent: nil, weeklyResetsAt: base.addingTimeInterval(quotaWeekSeconds)),
            CodexResetObservation(timestamp: base.addingTimeInterval(quotaWeekSeconds + 1), accountID: "account-a", limitID: "codex",
                fiveHourResetsAt: nil, fiveHourUsedPercent: nil, weeklyResetsAt: base.addingTimeInterval(2 * quotaWeekSeconds))
        ]
        let quotaPeriods = CodexResetHistory.periods(observed, minutes: 10080, now: base.addingTimeInterval(quotaWeekSeconds + 2))
        precondition(quotaPeriods.count == 2)
        let beforeReset = quotaEvents.buckets(in: quotaPeriods[0].interval, bucketDuration: 18000, accountID: "account-a")
        let afterReset = quotaEvents.buckets(in: quotaPeriods[1].interval, bucketDuration: 18000, accountID: "account-a")
        precondition(beforeReset.count == 34 && beforeReset[0].start == quotaPeriods[0].start.date)
        precondition(beforeReset[0].inputTokens == 1 && beforeReset[1].inputTokens == 5)
        precondition(zip(beforeReset, beforeReset.dropFirst()).allSatisfy { $0.end == $1.start })
        precondition(beforeReset.last?.end == quotaPeriods[0].end.date && beforeReset.last?.inputTokens == 10)
        precondition(beforeReset.reduce(Int64(0)) { $0 + $1.inputTokens } == 16)
        precondition(afterReset.reduce(Int64(0)) { $0 + $1.inputTokens } == 50)
        precondition(afterReset[0].inputTokens == 50, "Usage at the weekly reset starts the next week's first bucket")
        let solBuckets = quotaEvents.buckets(in: quotaPeriods[0].interval, bucketDuration: 18000,
            modelID: CodexTokenModelUsage(model: "gpt-6.1-sol", reasoningEffort: "ultra").id, accountID: "account-a")
        precondition(solBuckets.reduce(Int64(0)) { $0 + $1.inputTokens } == 13)
        precondition(quotaEvents.models(in: quotaPeriods[1].interval, accountID: "account-a").first?.inputTokens == 50)
        let accountRoot = root.appendingPathComponent("account-events")
        try write(accountRoot, "sessions/a.jsonl", thread: "account-thread", events: [first],
            metadata: ["creator_account_id": "account-a"])
        let accountHistory = try CodexTokenHistoryReader.read(codexHomeURL: accountRoot)
        precondition(accountHistory.events.first?.accountID == "account-a")

        let invalid = root.appendingPathComponent("bad")
        try write(invalid, "sessions/bad.jsonl", thread: "bad", events: [
            event(0, total: counts(100, 20, 50)), // No baseline/last request: do not invent usage.
            event(10, total: counts(130, 25, 60)),
            event(20, total: counts(1, 1, 0)), // Reset without last usage is unknown.
            event(30, total: counts(2, 2, 0), last: counts(-1, 1, 0)),
            event(40, total: counts(3, 3, 0), last: counts(1, 1, 2))
        ], suffix: "{\"type\":\"token_count\", broken}\n")
        let partial = try CodexTokenHistoryReader.read(codexHomeURL: invalid)
        precondition(partial.isPartial && partial.skippedRecords == 5 && partial.events.count == 1)
        precondition(partial.events[0].inputTokens == 30 && partial.events[0].outputTokens == 5)

        // Large embedded-media lines must not grow the reader buffer without bound or hide later events.
        let large = root.appendingPathComponent("large")
        let largeFile = large.appendingPathComponent("sessions/large.jsonl")
        try write(large, "sessions/large.jsonl", thread: "large", events: [])
        let handle = try FileHandle(forWritingTo: largeFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(String(repeating: "x", count: 9 * 1024 * 1024).utf8))
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: first))
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()
        let afterLargeLine = try CodexTokenHistoryReader.read(codexHomeURL: large)
        precondition(afterLargeLine.events.count == 1 && afterLargeLine.events[0].inputTokens == 100)
        let empty = try CodexTokenHistoryReader.read(codexHomeURL: root.appendingPathComponent("absent"))
        precondition(empty.events.isEmpty && empty.scannedFiles == 0 && !empty.isPartial)
        let cancelled = Task.detached { () throws -> CodexTokenHistorySnapshot in
            while !Task.isCancelled { await Task.yield() }
            return try CodexTokenHistoryReader.read(codexHomeURL: root)
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("Reader must honor cancellation") }
        catch is CancellationError {}
        print("Codex token history: all fixture checks passed")

        if CommandLine.arguments.contains("--live") {
            let start = Date()
            let live = try CodexTokenHistoryReader.read()
            print("Local read: files=\(live.scannedFiles), events=\(live.events.count), unreadable=\(live.unreadableFiles), skipped=\(live.skippedRecords), elapsed=\(String(format: "%.2f", Date().timeIntervalSince(start)))s")
            for model in live.models(in: DateInterval(start: .distantPast, end: .distantFuture)) {
                print("\(model.displayName): events=\(model.eventCount)")
            }
            for minutes in [300, 10080] {
                let periods = CodexResetHistory.periods(live.resetObservations, minutes: minutes, now: Date())
                precondition(zip(periods, periods.dropFirst()).allSatisfy { $0.end.date <= $1.start.date })
                precondition(Set(periods.map(\.id)).count == periods.count)
                print("Quota history: minutes=\(minutes), periods=\(periods.count), boundaries do not overlap")
            }
        }
    }
}
'''

with tempfile.TemporaryDirectory(prefix="hopworld-token-check-") as directory:
    directory = Path(directory)
    checks = directory / "Checks.swift"
    binary = directory / "checks"
    checks.write_text(fixture)
    subprocess.run(["xcrun", "swiftc", "-parse-as-library",
                    str(root / "HopWorld/Services/Testing/CodexTokenHistory.swift"),
                    str(root / "HopWorld/Services/Testing/CodexResetHistory.swift"),
                    str(checks), "-o", str(binary)], check=True)
    subprocess.run([str(binary), *sys.argv[1:]], check=True)
