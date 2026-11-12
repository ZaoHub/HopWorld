#!/usr/bin/env python3
"""Exercise production usage retry scheduling with injected local results."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / "HopWorld/Views/Testing/CodexUsageCard.swift").read_text()
source = source[:source.index("\nstruct CodexUsageCard: View")]
fixture = r'''
@MainActor final class AppLogger {
    static let shared = AppLogger()
    var retries = 0
    func warning(_ text: String) {}
    func info(_ text: String) { retries += 1 }
}

enum LabUtilityProcess {
    static func allowInternet(userInitiated: Bool) async -> Bool { true }
}

final class Attempts: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var failures = 1
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func read() throws -> CodexUsageSnapshot {
        lock.lock()
        count += 1
        let shouldFail = count <= failures
        lock.unlock()
        if shouldFail { throw CodexUsageReader.ReadError.unavailable }
        return try JSONDecoder().decode(CodexUsageSnapshot.self, from: Data(
            #"{"rateLimits":{"primary":{"usedPercent":25}}}"#.utf8))
    }
}

@main struct Checks {
    @MainActor static var checks = 0
    @MainActor static func check(_ value: Bool, _ message: String) {
        checks += 1
        precondition(value, message)
    }
    @MainActor static func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<500 {
            if predicate() { return }
            try! await Task.sleep(nanoseconds: 2_000_000)
        }
        preconditionFailure("Timed out waiting for the local fixture")
    }
    @MainActor static func run() async {
        check(CodexUsageReader.accountIdentifier(["type": "chatgpt", "email": " Example@Example.com ",
              "planType": "pro"]) == "email:example@example.com", "Current ChatgptAccount schema uses normalized email")
        check(CodexUsageReader.accountIdentifier(["type": "chatgpt", "email": NSNull()]) == nil,
              "Absent account identity must remain unknown")
        check(CodexUsageReader.accountIdentifier(["id": " fixture-id ", "email": "other@example.com"]) == "id:fixture-id",
              "Explicit account IDs take precedence")
        let attempts = Attempts()
        let monitor = CodexUsageMonitor(refreshInterval: 3600, retryInterval: 0.12,
                                        readSnapshot: { try attempts.read() })
        var deliveredSnapshots = 0
        monitor.onSnapshot = { _ in deliveredSnapshots += 1 }
        await monitor.refresh()
        check(attempts.calls == 0, "No proxy connection must skip usage queries")
        monitor.proxyConnected = true
        await monitor.refresh()
        check(attempts.calls == 1 && monitor.message != nil, "A failed usage read schedules a retry")
        check(deliveredSnapshots == 0, "Failed reads never evaluate notifications against retained data")
        let scheduled = AppLogger.shared.retries
        for _ in 0..<5 { await monitor.refresh() }
        check(attempts.calls == 1, "Repeated automatic focus, wake and timer requests must honor pending retry")
        check(AppLogger.shared.retries == scheduled, "Automatic refresh must not cancel and reschedule retry logs")
        await waitUntil { monitor.snapshot != nil }
        check(attempts.calls == 2 && monitor.message == nil, "The single pending retry still runs and recovers")
        check(monitor.updatedAt != nil, "Successful retry publishes the usage snapshot")
        check(deliveredSnapshots == 1, "Only fresh successful snapshots enter notification evaluation")
        monitor.proxyConnected = false

        let manualAttempts = Attempts()
        manualAttempts.failures = Int.max
        let manual = CodexUsageMonitor(refreshInterval: 3600, retryInterval: 0.12,
                                       readSnapshot: { try manualAttempts.read() })
        manual.proxyConnected = true
        await manual.refresh()
        await manual.refresh(force: true)
        check(manualAttempts.calls == 2, "An explicit manual refresh may bypass pending retry")
        await manual.refresh()
        check(manualAttempts.calls == 2, "The manual failure restores the automatic retry guard")
        manual.proxyConnected = false
        try! await Task.sleep(nanoseconds: 180_000_000)
        check(manualAttempts.calls == 2, "Disconnect cancels pending usage retries")
        manual.proxyConnected = true
        await manual.refresh()
        check(manualAttempts.calls == 3, "Reconnecting permits a fresh usage query")
        manual.proxyConnected = false

        let suiteName = "hopworld.codex.usage.fixture"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        let savedAttempts = Attempts()
        savedAttempts.failures = 0
        let saving = CodexUsageMonitor(refreshInterval: 3600, retryInterval: 60,
                                       readSnapshot: { try savedAttempts.read() }, store: suite)
        saving.proxyConnected = true
        await saving.refresh()
        check(saving.snapshot?.bucket?.primary?.usedPercent == 25, "A successful read keeps the latest usage")
        var restoredDeliveries = 0
        let restored = CodexUsageMonitor(refreshInterval: 3600, retryInterval: 60, store: suite)
        restored.onSnapshot = { _ in restoredDeliveries += 1 }
        check(restored.snapshot?.bucket?.primary?.usedPercent == 25 && !restored.proxyConnected,
              "Restart shows the last usage before the proxy connects")
        check(restoredDeliveries == 0, "Restored usage is for display and does not notify")
        let loggedOut = CodexUsageMonitor(refreshInterval: 3600, retryInterval: 60,
                                          readSnapshot: { throw CodexUsageReader.ReadError.notLoggedIn }, store: suite)
        loggedOut.proxyConnected = true
        await loggedOut.refresh()
        let afterLogout = CodexUsageMonitor(refreshInterval: 3600, retryInterval: 60, store: suite)
        check(loggedOut.snapshot == nil && afterLogout.snapshot == nil, "Logging out removes the saved usage")
        suite.removePersistentDomain(forName: suiteName)
        print("Codex usage retry: \(checks) checks, 0 failures; no real account requests")
        exit(0)
    }
    static func main() {
        Task { @MainActor in await run() }
        RunLoop.main.run()
    }
}
'''
with tempfile.TemporaryDirectory(prefix="hopworld-usage-retry-") as temporary:
    path = Path(temporary)
    swift = path / "Check.swift"
    swift.write_text(source + fixture)
    binary = path / "check"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
