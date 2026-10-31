import XCTest
import SQLite3

final class CodexRuntimeHealthReaderTests: XCTestCase {
    func testCanonicalRetryStatesAndServiceErrors() {
        let now = Date()
        let prefix = "session_loop{thread_id=fixture}:run_sampling_request{turn_id=fixture}: "
        let retry = "stream disconnected - retrying sampling request (3/5 in 802ms)... turn_id=fixture retries=3 max_retries=5 sampling_error="
        XCTAssertEqual(CodexRuntimeHealthReader.parse(body: prefix + retry + "request timed out", date: now)?.kind, .reconnecting)
        XCTAssertEqual(CodexRuntimeHealthReader.parse(body: prefix + "stream connection failed; waiting to retry turn_id=fixture error=Connection failed: error sending request retry_delay=20s", date: now)?.kind, .waitingForNetwork)
        XCTAssertEqual(CodexRuntimeHealthReader.parse(body: retry + "unexpected status 401 Unauthorized", date: now)?.kind, .authenticationFailure)
        XCTAssertEqual(CodexRuntimeHealthReader.parse(body: retry + "unexpected status 403 Forbidden", date: now)?.kind, .authenticationFailure)
        XCTAssertEqual(CodexRuntimeHealthReader.parse(body: retry + "unexpected status 429 Too Many Requests", date: now)?.kind, .rateLimited)
        XCTAssertEqual(CodexRuntimeHealthReader.parse(body: retry + "unexpected status 503 Service Unavailable", date: now)?.kind, .serviceFailure)
        XCTAssertEqual(CodexRuntimeHealthReader.parse(body: retry + "status='500 Internal Server Error'", date: now)?.kind, .serviceFailure)
        XCTAssertNil(CodexRuntimeHealthReader.parse(body: "user_message=\"stream connection failed; waiting to retry error=timeout\"", date: now))
        XCTAssertNil(CodexRuntimeHealthReader.parse(body: "No response during idle chat", date: now))
    }

    func testPollIsFreshIncrementalAndRestrictsRuntimeSource() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("logs_2.sqlite")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE logs (id INTEGER PRIMARY KEY, ts INTEGER, ts_nanos INTEGER, level TEXT, target TEXT, feedback_log_body TEXT, thread_id TEXT)", nil, nil, nil), SQLITE_OK)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let body = "stream connection failed; waiting to retry turn_id=fixture error=Connection failed: error sending request retry_delay=20s"
        func insert(id: Int, date: Date, target: String = "codex_core::responses_retry", level: String = "WARN", threadID: String? = "desktop-fixture") {
            let thread = threadID.map { "'\($0)'" } ?? "NULL"
            let sql = "INSERT INTO logs VALUES (\(id), \(Int64(date.timeIntervalSince1970)), 0, '\(level)', '\(target)', '\(body)', \(thread))"
            XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        }
        insert(id: 1, date: now.addingTimeInterval(-60))
        insert(id: 2, date: now, target: "codex_core_plugins::manager")
        insert(id: 3, date: now, level: "DEBUG")
        insert(id: 4, date: now)
        insert(id: 5, date: now, threadID: "cli-fixture")
        insert(id: 6, date: now, threadID: nil)
        var reader = CodexRuntimeHealthReader(databaseURL: file, startedAt: now.addingTimeInterval(-10))
        let desktopIDs: Set<String> = ["desktop-fixture"]
        let events = reader.poll(now: now, desktopThreadIDs: desktopIDs)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .waitingForNetwork)
        XCTAssertEqual(events.first?.recoveryOrigin, .responseStream)
        XCTAssertEqual(events.first?.scope, "unknown")
        XCTAssertTrue(reader.poll(now: now, desktopThreadIDs: desktopIDs).isEmpty)
        insert(id: 7, date: now.addingTimeInterval(2))
        XCTAssertTrue(reader.poll(now: now, desktopThreadIDs: desktopIDs).isEmpty)
        XCTAssertEqual(reader.poll(now: now.addingTimeInterval(2), desktopThreadIDs: desktopIDs).count, 1)
        reader.reset(since: now.addingTimeInterval(3))
        XCTAssertTrue(reader.poll(now: now.addingTimeInterval(3), desktopThreadIDs: desktopIDs).isEmpty)
        insert(id: 8, date: now.addingTimeInterval(4))
        XCTAssertEqual(reader.poll(now: now.addingTimeInterval(4), desktopThreadIDs: desktopIDs).count, 1)
        var unfiltered = CodexRuntimeHealthReader(databaseURL: file, startedAt: now.addingTimeInterval(-10))
        XCTAssertEqual(unfiltered.poll(now: now.addingTimeInterval(4)).count, 5)
        var noDesktopSessions = CodexRuntimeHealthReader(databaseURL: file, startedAt: now.addingTimeInterval(-10))
        XCTAssertTrue(noDesktopSessions.poll(now: now.addingTimeInterval(4), desktopThreadIDs: []).isEmpty)
    }

    func testMissingDatabaseIsNotCreated() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var reader = CodexRuntimeHealthReader(databaseURL: file)
        XCTAssertTrue(reader.poll().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
