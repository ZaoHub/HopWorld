import Foundation
import SQLite3

/// The response retry log records the same retry states shown beside an active Codex turn.
struct CodexRuntimeHealthReader: Sendable {
    private let databaseURL: URL
    private let startedAt: Date
    private var since: Date
    private var lastID: Int64 = 0
    private var inode: UInt64?

    init(databaseURL: URL? = nil, startedAt: Date = Date()) {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        self.databaseURL = databaseURL ?? home.appendingPathComponent("logs_2.sqlite")
        self.startedAt = startedAt
        since = startedAt
    }

    mutating func reset(since date: Date) {
        since = max(startedAt, date)
        lastID = 0
        inode = nil
    }

    mutating func poll(now: Date = Date(), desktopThreadIDs: Set<String>? = nil) -> [CodexHealthEvent] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: databaseURL.path),
              let fileInode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else { return [] }
        if inode != fileInode { lastID = 0; inode = fileInode }
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            return []
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 100)
        var maximum: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COALESCE(MAX(id), 0) FROM logs", -1, &maximum, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(maximum) }
        guard sqlite3_step(maximum) == SQLITE_ROW else { return [] }
        let maximumID = sqlite3_column_int64(maximum, 0)
        if maximumID < lastID { lastID = 0 }
        guard maximumID > lastID else { return [] }

        // Advance over unrelated logs as well, avoiding repeated scans while Codex is idle.
        let sql = """
        SELECT id, ts, ts_nanos, level, feedback_log_body, thread_id FROM logs
        WHERE id > ? AND id <= ? AND ts >= ? AND target = 'codex_core::responses_retry'
        ORDER BY id LIMIT 256
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, lastID)
        sqlite3_bind_int64(statement, 2, maximumID)
        sqlite3_bind_int64(statement, 3, Int64(floor(since.timeIntervalSince1970)))
        var events: [CodexHealthEvent] = []
        var count = 0
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            let seconds = sqlite3_column_int64(statement, 1)
            let nanoseconds = sqlite3_column_int64(statement, 2)
            let date = Date(timeIntervalSince1970: Double(seconds) + Double(nanoseconds) / 1_000_000_000)
            let validTimestamp = (0..<1_000_000_000).contains(nanoseconds)
            // Keep a future row unread until its time arrives; never classify it early.
            if validTimestamp, date > now, date <= now.addingTimeInterval(5) { return events }
            lastID = id
            count += 1
            // The runtime database also contains CLI traffic; production supplies verified Desktop session IDs.
            let desktopSession = desktopThreadIDs.map { allowed in
                guard sqlite3_column_bytes(statement, 5) <= 128,
                      let threadBytes = sqlite3_column_text(statement, 5) else { return false }
                return allowed.contains(String(cString: threadBytes))
            } ?? true
            if desktopSession, date >= since, date <= now, validTimestamp,
               let levelBytes = sqlite3_column_text(statement, 3),
               String(cString: levelBytes) == "WARN",
               sqlite3_column_bytes(statement, 4) <= 64 * 1024,
               let bodyBytes = sqlite3_column_text(statement, 4),
               let event = Self.parse(body: String(cString: bodyBytes), date: date) {
                events.append(event)
            }
            result = sqlite3_step(statement)
        }
        if result == SQLITE_DONE, count < 256 { lastID = maximumID }
        return events
    }

    static func parse(body: String, date: Date) -> CodexHealthEvent? {
        guard body.utf8.count <= 64 * 1024, !body.contains("\n"),
              let marker = body.range(of: #"(?:^|\}: )(stream disconnected - retrying sampling request \(|stream connection failed; waiting to retry )"#,
                                      options: .regularExpression) else { return nil }
        let message = String(body[marker.lowerBound...]).lowercased()
        let kind: CodexHealthEvent.Kind
        // Service failures may also retry; those must not be mistaken for a broken node.
        let statusPrefix = #"(?:status(?:[_ ]code)?[=: ]+["']?|http[ /]+)"#
        if message.range(of: statusPrefix + #"(?:401|403)\b"#, options: .regularExpression) != nil
            || message.contains("unauthorized") || message.contains("authentication") {
            kind = .authenticationFailure
        } else if message.range(of: statusPrefix + #"429\b"#, options: .regularExpression) != nil
                    || message.contains("rate limit") || message.contains("too many requests") {
            kind = .rateLimited
        } else if message.range(of: statusPrefix + #"5\d\d\b"#, options: .regularExpression) != nil
                    || message.contains("server overloaded") || message.contains("server is overloaded") {
            kind = .serviceFailure
        } else {
            kind = message.contains("stream connection failed; waiting to retry ") ? .waitingForNetwork : .reconnecting
        }
        return CodexHealthEvent(date: date, kind: kind, scope: "unknown", recoveryOrigin: .responseStream)
    }
}
