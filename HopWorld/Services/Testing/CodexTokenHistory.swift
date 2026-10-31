import Foundation

struct CodexTokenEvent: Sendable {
    let timestamp: Date
    let inputTokens: Int64
    let outputTokens: Int64
    let cachedInputTokens: Int64
    let model: String?
    let reasoningEffort: String?
    let accountID: String?
    var modelID: String { CodexTokenModelUsage.identifier(model: model, reasoningEffort: reasoningEffort) }

    init(timestamp: Date, inputTokens: Int64, outputTokens: Int64, cachedInputTokens: Int64,
         model: String? = nil, reasoningEffort: String? = nil, accountID: String? = nil) {
        self.timestamp = timestamp
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.accountID = accountID
    }
}

struct CodexTokenModelUsage: Identifiable, Sendable {
    let model: String?
    let reasoningEffort: String?
    var inputTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var cachedInputTokens: Int64 = 0
    var eventCount: Int = 0
    var id: String { Self.identifier(model: model, reasoningEffort: reasoningEffort) }
    var displayName: String {
        let modelName: String
        if let model {
            let parts = model.split(separator: "-")
            if parts.count >= 2, parts[0].lowercased() == "gpt" {
                modelName = "GPT-" + parts[1] + parts.dropFirst(2).map { " " + $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
            } else {
                modelName = model
            }
        } else {
            modelName = "未记录模型"
        }
        let effortName = reasoningEffort.map { effort in
            ["none": "None", "minimal": "Minimal", "low": "Low", "medium": "Medium",
             "high": "High", "xhigh": "XHigh", "max": "Max", "ultra": "Ultra"][effort] ?? effort
        } ?? "未记录档位"
        return modelName + " " + effortName
    }

    static func identifier(model: String?, reasoningEffort: String?) -> String {
        // Length prefixes distinguish absent values from literal names and names containing delimiters.
        [model, reasoningEffort].map { $0.map { "\($0.utf8.count):\($0)" } ?? "-" }.joined(separator: "/")
    }
}

struct CodexTokenBucket: Identifiable, Sendable {
    var id: Date { start }
    let start: Date
    let end: Date
    var inputTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var cachedInputTokens: Int64 = 0
}

struct CodexQuotaComparison: Identifiable, Sendable {
    enum Status: Sendable {
        case observed, insufficient, unknownAccount, conflicting, resetChanged, mixedModels, noSelectedModel, capped
    }
    var id: Date { start }
    let start: Date
    let end: Date
    var sampledInterval: DateInterval?
    var observationCount = 0
    var fromPercent: Double?
    var toPercent: Double?
    var decline: Double?
    var transientRollbackCount = 0
    var uncachedInputTokens: Int64 = 0
    var cachedInputTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var status: Status = .insufficient
}

struct CodexTokenHistorySnapshot: Sendable {
    let events: [CodexTokenEvent]
    let scannedFiles: Int
    let unreadableFiles: Int
    let skippedRecords: Int
    let resetObservations: [CodexResetObservation]
    var firstEventAt: Date? { events.first?.timestamp }
    var isPartial: Bool { unreadableFiles > 0 || skippedRecords > 0 }

    init(events: [CodexTokenEvent], scannedFiles: Int, unreadableFiles: Int, skippedRecords: Int,
         resetObservations: [CodexResetObservation] = []) {
        self.events = events
        self.scannedFiles = scannedFiles
        self.unreadableFiles = unreadableFiles
        self.skippedRecords = skippedRecords
        self.resetObservations = resetObservations
    }

    /// Half-open intervals keep events on a boundary in exactly one bucket.
    func buckets(in interval: DateInterval, bucketDuration: TimeInterval, modelID: String? = nil,
                 accountID: String? = nil) -> [CodexTokenBucket] {
        guard interval.duration.isFinite, interval.duration > 0,
              bucketDuration.isFinite, bucketDuration > 0 else { return [] }
        let count = ceil(interval.duration / bucketDuration)
        guard count <= 10_000 else { return [] }
        var buckets = (0..<Int(count)).map { index in
            let start = interval.start.addingTimeInterval(Double(index) * bucketDuration)
            return CodexTokenBucket(start: start, end: min(interval.end, start.addingTimeInterval(bucketDuration)))
        }
        for event in events where event.timestamp >= interval.start && event.timestamp < interval.end {
            if let modelID, event.modelID != modelID { continue }
            if let accountID, event.accountID != accountID { continue }
            let index = min(buckets.count - 1, Int(event.timestamp.timeIntervalSince(interval.start) / bucketDuration))
            buckets[index].inputTokens += event.inputTokens
            buckets[index].outputTokens += event.outputTokens
            buckets[index].cachedInputTokens += event.cachedInputTokens
        }
        return buckets
    }

    func models(in interval: DateInterval, accountID: String? = nil) -> [CodexTokenModelUsage] {
        var models: [String: CodexTokenModelUsage] = [:]
        for event in events where event.timestamp >= interval.start && event.timestamp < interval.end {
            if let accountID, event.accountID != accountID { continue }
            let id = event.modelID
            var usage = models[id] ?? CodexTokenModelUsage(model: event.model, reasoningEffort: event.reasoningEffort)
            usage.inputTokens += event.inputTokens
            usage.outputTokens += event.outputTokens
            usage.cachedInputTokens += event.cachedInputTokens
            usage.eventCount += 1
            models[id] = usage
        }
        return models.values.sorted {
            let lhs = $0.inputTokens + $0.outputTokens
            let rhs = $1.inputTokens + $1.outputTokens
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
    }

    /// Tokens and quota deltas cover the same (first observation, last observation] interval.
    func quotaComparisons(in interval: DateInterval, bucketDuration: TimeInterval, minutes: Int,
                          accountID: String?, modelID: String? = nil) -> [CodexQuotaComparison] {
        guard [300, 10080].contains(minutes), interval.duration.isFinite, interval.duration > 0,
              bucketDuration.isFinite, bucketDuration > 0 else { return [] }
        let count = ceil(interval.duration / bucketDuration)
        guard count <= 10_000 else { return [] }
        let observations = resetObservations.filter {
            $0.limitID == "codex" && $0.timestamp >= interval.start && $0.timestamp < interval.end
        }
        return (0..<Int(count)).map { index in
            let start = interval.start.addingTimeInterval(Double(index) * bucketDuration)
            let end = min(interval.end, start.addingTimeInterval(bucketDuration))
            var row = CodexQuotaComparison(start: start, end: end)
            guard let accountID, !accountID.isEmpty else { row.status = .unknownAccount; return row }
            let raw = observations.filter { $0.accountID == accountID && $0.timestamp >= start && $0.timestamp <= end }
            let grouped = Dictionary(grouping: raw, by: \.timestamp)
            var samples: [(time: Date, used: Double, reset: Date)] = []
            for time in grouped.keys.sorted() {
                let values = (grouped[time] ?? []).compactMap { observation -> (Double, Date)? in
                    let used = minutes == 300 ? observation.fiveHourUsedPercent : observation.weeklyUsedPercent
                    let reset = minutes == 300 ? observation.fiveHourResetsAt : observation.weeklyResetsAt
                    guard let used, used.isFinite, (0...100).contains(used), let reset,
                          reset.timeIntervalSince1970.isFinite,
                          reset.timeIntervalSince(time) >= -60,
                          reset.timeIntervalSince(time) <= Double(minutes * 60) + 60 else { return nil }
                    return (used, reset)
                }
                guard let first = values.first else { continue }
                guard values.allSatisfy({ abs($0.0 - first.0) < 0.01 && abs($0.1.timeIntervalSince(first.1)) <= CodexResetHistory.tolerance }) else {
                    row.status = .conflicting
                    return row
                }
                samples.append((time, first.0, first.1))
            }
            row.observationCount = samples.count
            guard let first = samples.first, let last = samples.last, last.time > first.time else { return row }
            row.sampledInterval = DateInterval(start: first.time, end: last.time)
            row.fromPercent = first.used
            row.toPercent = last.used
            let recorded = events.filter {
                $0.accountID == accountID && $0.timestamp > first.time && $0.timestamp <= last.time
            }
            for event in recorded where modelID == nil || event.modelID == modelID {
                row.uncachedInputTokens += event.inputTokens - event.cachedInputTokens
                row.cachedInputTokens += event.cachedInputTokens
                row.outputTokens += event.outputTokens
            }
            guard samples.allSatisfy({ abs($0.reset.timeIntervalSince(first.reset)) <= CodexResetHistory.tolerance }) else {
                row.status = .resetChanged
                return row
            }
            // Recovered intermediate regressions do not invalidate the observed first-to-last net change.
            guard samples.allSatisfy({ $0.used + 0.01 >= first.used && $0.used <= last.used + 0.01 }) else {
                row.status = .conflicting
                return row
            }
            row.transientRollbackCount = zip(samples, samples.dropFirst()).filter { $1.used + 0.01 < $0.used }.count
            guard last.used < 100 else { row.status = .capped; return row }
            if let modelID {
                guard recorded.contains(where: { $0.modelID == modelID }) else { row.status = .noSelectedModel; return row }
                guard recorded.allSatisfy({ $0.modelID == modelID }) else { row.status = .mixedModels; return row }
            }
            row.decline = max(0, last.used - first.used)
            row.status = .observed
            return row
        }
    }
}

/// Reads only local usage events. No authentication, conversation content, or log copies are retained.
enum CodexTokenHistoryReader {
    private struct Counts: Decodable, Hashable {
        let input_tokens: Int64
        let output_tokens: Int64
        let cached_input_tokens: Int64?
        var cached: Int64 { cached_input_tokens ?? 0 }
        var isValid: Bool {
            // Keep malformed counters out of sums while allowing far more than a lifetime of normal use.
            (0...1_000_000_000_000).contains(input_tokens)
                && (0...1_000_000_000_000).contains(output_tokens)
                && (0...input_tokens).contains(cached)
        }
    }
    private struct Envelope: Decodable {
        struct Payload: Decodable {
            struct Info: Decodable {
                let total_token_usage: Counts?
                let last_token_usage: Counts?
            }
            struct RateLimits: Decodable {
                struct Window: Decodable {
                    let used_percent: Double?
                    let window_minutes: Int?
                    let resets_at: Double?
                    var resetDate: Date? {
                        resets_at.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
                    }
                    var usedPercent: Double? {
                        used_percent.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
                    }
                }
                let limit_id: String?
                let primary: Window?
                let secondary: Window?
                func window(minutes: Int) -> Window? {
                    [primary, secondary].compactMap { $0 }.first { $0.window_minutes == minutes }
                }
            }
            let type: String?
            let info: Info?
            let rate_limits: RateLimits?
        }
        let timestamp: String?
        let ordinal: Int64?
        let type: String
        let payload: Payload
    }
    private struct Record {
        let threadID: String
        let accountID: String?
        let timestamp: Date
        let ordinal: Int64?
        let total: Counts?
        let last: Counts?
    }
    private struct TurnContextEnvelope: Decodable {
        struct Payload: Decodable {
            let model: String?
            let effort: String?
        }
        let type: String
        let timestamp: String?
        let ordinal: Int64?
        let payload: Payload
    }
    private struct ModelContext {
        let threadID: String
        let timestamp: Date
        let ordinal: Int64?
        let model: String?
        let reasoningEffort: String?
    }
    private struct Fingerprint: Hashable {
        let threadID: String
        let timestamp: Date
        let total: Counts?
        let last: Counts?
    }
    private struct Inheritance {
        let parentID: String
        let beforeOrdinal: Int64?
        let beforeDate: Date?
        func contains(timestamp: Date, ordinal: Int64?) -> Bool {
            if let beforeOrdinal, let ordinal { return ordinal < beforeOrdinal }
            return beforeDate.map { timestamp < $0 } ?? false
        }
    }

    static func read(codexHomeURL: URL? = nil) throws -> CodexTokenHistorySnapshot {
        let fileManager = FileManager.default
        let environmentHome = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        let home = codexHomeURL ?? environmentHome.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        var files: [URL] = []
        var unreadableFiles = 0
        for directory in ["sessions", "archived_sessions"] {
            let root = home.appendingPathComponent(directory, isDirectory: true)
            guard fileManager.fileExists(atPath: root.path) else { continue }
            guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles], errorHandler: { _, _ in unreadableFiles += 1; return true }) else {
                unreadableFiles += 1
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append(url) }
            }
        }

        let decoder = JSONDecoder()
        let fractionalDate = ISO8601DateFormatter()
        fractionalDate.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let wholeDate = ISO8601DateFormatter()
        var records: [Record] = []
        var contexts: [ModelContext] = []
        var resetObservations: [CodexResetObservation] = []
        var accountsByThread: [String: String] = [:]
        var inheritance: [String: [Inheritance]] = [:]
        var skippedRecords = 0
        let tokenMarker = Data(#""token_count""#.utf8)
        let metadataMarker = Data(#""session_meta""#.utf8)
        let contextMarker = Data(#""turn_context""#.utf8)
        for file in files.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            var threadID = file.lastPathComponent
            var accountID: String?
            var foundMetadata = false
            do {
                try readLines(file) { line in
                    if !foundMetadata, line.range(of: metadataMarker) != nil,
                       let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                       object["type"] as? String == "session_meta",
                       let payload = object["payload"] as? [String: Any], let id = payload["id"] as? String {
                        threadID = id
                        accountID = payload["creator_account_id"] as? String
                        if let accountID { accountsByThread[threadID] = accountID }
                        foundMetadata = true
                        if let base = payload["history_base"] as? [String: Any],
                           let parent = base["thread_id"] as? String, parent != id,
                           let cutoff = base["end_ordinal_exclusive"] as? Int64 {
                            inheritance[id, default: []].append(Inheritance(parentID: parent, beforeOrdinal: cutoff, beforeDate: nil))
                        }
                        if let parent = payload["forked_from_id"] as? String, parent != id {
                            if let date = payload["timestamp"] as? String,
                               let cutoff = fractionalDate.date(from: date) ?? wholeDate.date(from: date) {
                                inheritance[id, default: []].append(Inheritance(parentID: parent, beforeOrdinal: nil, beforeDate: cutoff))
                            } else {
                                skippedRecords += 1
                            }
                        }
                    }
                    if line.range(of: contextMarker) != nil,
                       let context = try? decoder.decode(TurnContextEnvelope.self, from: line), context.type == "turn_context",
                       let rawDate = context.timestamp,
                       let date = fractionalDate.date(from: rawDate) ?? wholeDate.date(from: rawDate) {
                        func name(_ value: String?) -> String? {
                            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                                  !value.isEmpty, value.utf8.count <= 200 else { return nil }
                            return value
                        }
                        contexts.append(ModelContext(threadID: threadID, timestamp: date, ordinal: context.ordinal,
                                                     model: name(context.payload.model), reasoningEffort: name(context.payload.effort)))
                    }
                    guard line.range(of: tokenMarker) != nil else { return }
                    guard let record = try? decoder.decode(Envelope.self, from: line) else {
                        skippedRecords += 1
                        return
                    }
                    guard record.type == "event_msg", record.payload.type == "token_count" else { return }
                    guard let rawDate = record.timestamp,
                          let date = fractionalDate.date(from: rawDate) ?? wholeDate.date(from: rawDate) else {
                        skippedRecords += 1
                        return
                    }
                    if let limits = record.payload.rate_limits, limits.limit_id == "codex" {
                        let fiveHour = limits.window(minutes: 300)
                        let weekly = limits.window(minutes: 10080)
                        if fiveHour != nil || weekly != nil {
                            resetObservations.append(CodexResetObservation(timestamp: date, accountID: accountID,
                                limitID: "codex", fiveHourResetsAt: fiveHour?.resetDate,
                                fiveHourUsedPercent: fiveHour?.usedPercent, weeklyResetsAt: weekly?.resetDate,
                                weeklyUsedPercent: weekly?.usedPercent))
                        }
                    }
                    // Rate-limit-only notifications legitimately have no token usage.
                    guard let info = record.payload.info else { return }
                    guard info.total_token_usage?.isValid != false,
                          info.last_token_usage?.isValid != false,
                          info.total_token_usage != nil || info.last_token_usage != nil else {
                        skippedRecords += 1
                        return
                    }
                    records.append(Record(threadID: threadID, accountID: accountID, timestamp: date, ordinal: record.ordinal,
                                          total: info.total_token_usage, last: info.last_token_usage))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                unreadableFiles += 1
            }
        }

        func origin(threadID: String, timestamp: Date, ordinal: Int64?) -> String {
            var id = threadID
            var visited: Set<String> = []
            while visited.insert(id).inserted,
                  let parent = inheritance[id]?.first(where: { $0.contains(timestamp: timestamp, ordinal: ordinal) }) {
                id = parent.parentID
            }
            return id
        }
        var contextsByThread: [String: [ModelContext]] = [:]
        for context in contexts.sorted(by: {
            $0.timestamp == $1.timestamp ? ($0.ordinal ?? .min) < ($1.ordinal ?? .min) : $0.timestamp < $1.timestamp
        }) {
            let id = origin(threadID: context.threadID, timestamp: context.timestamp, ordinal: context.ordinal)
            contextsByThread[id, default: []].append(context)
        }
        records.sort {
            $0.timestamp == $1.timestamp ? ($0.ordinal ?? .min) < ($1.ordinal ?? .min) : $0.timestamp < $1.timestamp
        }
        var seen: Set<Fingerprint> = []
        var previousTotals: [String: Counts] = [:]
        var events: [CodexTokenEvent] = []
        for record in records {
            let originID = origin(threadID: record.threadID, timestamp: record.timestamp, ordinal: record.ordinal)
            let fingerprint = Fingerprint(threadID: originID, timestamp: record.timestamp, total: record.total, last: record.last)
            let previous = previousTotals[record.threadID]
            if let total = record.total {
                previousTotals[record.threadID] = total
            }
            // An inherited event still establishes the child's counter baseline after global de-duplication.
            guard seen.insert(fingerprint).inserted else { continue }
            if let total = record.total {
                // Codex can repeat the same inference usage when publishing a second rate-limit bucket.
                if total == previous { continue }
            }
            let counts: Counts
            if let last = record.last {
                // A resumed log may start with a large lifetime total; only its last inference belongs here.
                counts = last
            } else if let total = record.total, let previous,
                      total.input_tokens >= previous.input_tokens,
                      total.output_tokens >= previous.output_tokens, total.cached >= previous.cached {
                counts = Counts(input_tokens: total.input_tokens - previous.input_tokens,
                                output_tokens: total.output_tokens - previous.output_tokens,
                                cached_input_tokens: total.cached - previous.cached)
            } else {
                skippedRecords += 1
                continue
            }
            guard counts.isValid else {
                skippedRecords += 1
                continue
            }
            if counts.input_tokens > 0 || counts.output_tokens > 0 {
                let context = contextsByThread[originID]?.last {
                    if $0.timestamp != record.timestamp { return $0.timestamp < record.timestamp }
                    if let contextOrdinal = $0.ordinal, let eventOrdinal = record.ordinal { return contextOrdinal <= eventOrdinal }
                    return true
                }
                events.append(CodexTokenEvent(timestamp: record.timestamp, inputTokens: counts.input_tokens,
                                             outputTokens: counts.output_tokens, cachedInputTokens: counts.cached,
                                             model: context?.model, reasoningEffort: context?.reasoningEffort,
                                             accountID: accountsByThread[originID] ?? record.accountID))
            }
        }
        return CodexTokenHistorySnapshot(events: events, scannedFiles: files.count,
                                         unreadableFiles: unreadableFiles, skippedRecords: skippedRecords,
                                         resetObservations: resetObservations)
    }

    private static func readLines(_ url: URL, consume: (Data) -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var buffer = Data()
        var discardingLongLine = false
        let newlineMarker = Data([10])
        while let chunk = try handle.read(upToCount: 128 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            if discardingLongLine {
                guard let newline = chunk.range(of: newlineMarker) else { continue }
                buffer.append(chunk.suffix(from: newline.upperBound))
                discardingLongLine = false
            } else {
                buffer.append(chunk)
            }
            var start = buffer.startIndex
            while let newline = buffer.range(of: newlineMarker, in: start..<buffer.endIndex) {
                consume(buffer.subdata(in: start..<newline.lowerBound))
                start = newline.upperBound
            }
            if start > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<start) }
            // Embedded media can make conversation lines huge; usage events fit comfortably in this bound.
            if buffer.count > 8 * 1024 * 1024 {
                buffer.removeAll(keepingCapacity: false)
                discardingLongLine = true
            }
        }
        // A final, still-being-written JSONL record is intentionally retried on the next refresh.
    }
}
