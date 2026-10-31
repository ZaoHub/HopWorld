#!/usr/bin/env python3
"""Exercise production save recovery with failed I/O and a controllable retry clock."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / "HopWorld/App/AppState.swift").read_text()


def method(signature):
    start = source.index("    " + signature)
    end = source.index("\n    }", start) + len("\n    }")
    return source[start:end]


fixture = r'''
import Foundation

struct LibrarySnapshot {
    var nodes: [Int]
    var subscriptions: [Int]
    var updateLogs: [Int]
}
@MainActor final class Store {
    var failure: String? = "Access denied"
    var saves: [LibrarySnapshot] = []
    var committed: LibrarySnapshot?
    func saveLibrary(_ snapshot: LibrarySnapshot, completion: @escaping @Sendable (String?) -> Void) {
        saves.append(snapshot)
        if failure == nil { committed = snapshot }
        completion(failure)
    }
    func saveSettings(_ value: Int) {}
    func saveConnectionState(_ value: Int) {}
    func savePinnedNodeIDs(_ value: [Int]) {}
    func saveDailyUsage(_ value: Int) {}
}
@MainActor final class Logger {
    var errors: [String] = []
    var recoveryMessages: [String] = []
    func error(_ message: String) { errors.append(message) }
    func info(_ message: String) { recoveryMessages.append(message) }
}
@MainActor enum RetryClock {
    static var waiters: [(UInt64, CheckedContinuation<Void, Never>)] = []
    static func sleep(nanoseconds: UInt64) async throws {
        await withCheckedContinuation { waiters.append((nanoseconds, $0)) }
    }
    static func fire() {
        let ready = waiters
        waiters = []
        for (_, continuation) in ready { continuation.resume() }
    }
}
@MainActor final class AppState {
    var libraryAvailable = true
    var isTerminating = false
    var persistenceError: String?
    var librarySaveRetryTask: Task<Void, Never>?
    var librarySaveRetryAttempt = 0
    var nodes = [1]
    var subscriptions = [1]
    var updateLogs = [1]
    var settings = 0
    var pinnedNodeIDs: [Int] = []
    var dailyUsage = 0
    struct Connection { var state = 0 }
    var connection = Connection()
    let store = Store()
    let logger = Logger()
    var reloads = 0
    func retryLoadLibrary() { reloads += 1 }
    func resume() { retryLibraryPersistenceIfNeeded() }
__METHODS__
}

@main struct Checks {
    @MainActor static func drain() async {
        for _ in 0..<50 { await Task.yield() }
    }

    @MainActor static func main() async {
        // Recovery writes the latest edits, never a captured pre-failure snapshot.
        let transient = AppState()
        transient.persist()
        await drain()
        precondition(transient.persistenceError != nil)
        precondition(RetryClock.waiters.map { $0.0 } == [2_000_000_000])
        transient.nodes = [2]
        transient.subscriptions = [3]
        transient.updateLogs = [4]
        transient.store.failure = nil
        RetryClock.fire()
        await drain()
        precondition(transient.store.committed?.nodes == [2])
        precondition(transient.store.committed?.subscriptions == [3])
        precondition(transient.store.committed?.updateLogs == [4])
        precondition(transient.persistenceError == nil)
        precondition(transient.librarySaveRetryAttempt == 0)
        precondition(transient.librarySaveRetryTask == nil)
        precondition(transient.logger.recoveryMessages.count == 1)
        precondition(transient.reloads == 0)

        // Repeated failures share one timer and stop after five retries.
        let permanent = AppState()
        permanent.persist()
        await drain()
        permanent.persist()
        await drain()
        precondition(RetryClock.waiters.count == 1)
        precondition(permanent.logger.errors.count == 1)
        for delay: UInt64 in [2, 5, 15, 30, 60] {
            precondition(RetryClock.waiters.map { $0.0 } == [delay * 1_000_000_000])
            RetryClock.fire()
            await drain()
        }
        precondition(permanent.store.saves.count == 7)
        precondition(permanent.store.committed == nil)
        precondition(permanent.persistenceError != nil)
        precondition(permanent.librarySaveRetryTask == nil)
        precondition(RetryClock.waiters.isEmpty)
        permanent.nodes = [5]
        permanent.store.failure = nil
        permanent.resume()
        await drain()
        precondition(permanent.store.committed?.nodes == [5])
        precondition(permanent.persistenceError == nil)
        precondition(permanent.reloads == 0)

        // A successful ordinary save cancels an already scheduled retry.
        let cancelled = AppState()
        cancelled.persist()
        await drain()
        cancelled.store.failure = nil
        cancelled.persist()
        await drain()
        let saveCount = cancelled.store.saves.count
        RetryClock.fire()
        await drain()
        precondition(cancelled.store.saves.count == saveCount)

        // Failed initial reads remain blocked; only the read path may recover them.
        let unreadable = AppState()
        unreadable.libraryAvailable = false
        unreadable.persistenceError = "Read failed"
        unreadable.persist()
        unreadable.resume()
        await drain()
        precondition(unreadable.store.saves.isEmpty)
        precondition(unreadable.reloads == 1)
        precondition(RetryClock.waiters.isEmpty)

        // Shutdown prevents both delayed writes and notification-triggered recovery.
        let terminating = AppState()
        terminating.persist()
        await drain()
        terminating.isTerminating = true
        RetryClock.fire()
        terminating.resume()
        await drain()
        precondition(terminating.store.saves.count == 1)
        precondition(terminating.reloads == 0)
        precondition(RetryClock.waiters.isEmpty)

        let idle = AppState()
        idle.resume()
        precondition(idle.store.saves.isEmpty && idle.reloads == 0)
        print("PASS: latest-edit recovery, bounded retries, cancellation, read safety, shutdown, idle")
    }
}
'''

methods = "\n".join(method(signature) for signature in [
    "func persist()",
    "private func scheduleLibrarySaveRetry()",
    "private func retryLibraryPersistenceIfNeeded()",
])
# Only replace the clock; run the production retry and completion logic unchanged.
methods = methods.replace("try await Task.sleep(nanoseconds: delay)",
                          "try await RetryClock.sleep(nanoseconds: delay)")
with tempfile.TemporaryDirectory(prefix="hopworld-persistence-retry-") as temporary:
    directory = Path(temporary)
    check = directory / "Check.swift"
    binary = directory / "check"
    check.write_text(fixture.replace("__METHODS__", methods))
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(check), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=20)
