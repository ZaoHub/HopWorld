import XCTest

@MainActor
final class NetworkRecoveryTests: XCTestCase {
    func testDebouncesChangesAndDoesNotRecoverOnInitialPath() async throws {
        var recoveries = 0
        let coordinator = NetworkRecoveryCoordinator(delay: 20_000_000) { recoveries += 1 }
        coordinator.pathChanged(available: true)
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(recoveries, 0)
        for _ in 0..<5 { coordinator.pathChanged(available: true) }
        try await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertEqual(recoveries, 1)
    }

    func testOfflineAndSleepCancelPendingRecoveryAndWakeRevalidates() async throws {
        var recoveries = 0
        let coordinator = NetworkRecoveryCoordinator(delay: 20_000_000) { recoveries += 1 }
        coordinator.pathChanged(available: true)
        coordinator.pathChanged(available: true)
        coordinator.pathChanged(available: false)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(coordinator.canRecover)
        XCTAssertEqual(recoveries, 0)
        coordinator.pathChanged(available: true)
        coordinator.willSleep()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(recoveries, 0)
        coordinator.didWake()
        try await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertEqual(recoveries, 1)
    }

    func testMaintenanceKeepsSessionGenerationAndYieldsToDisconnect() async throws {
        let operations = ConnectionOperations()
        try await operations.perform { _ in }
        let generation = operations.generation
        var events: [String] = []
        let maintenance = Task {
            try await operations.maintainIfIdle {
                events.append("check")
                do { try await Task.sleep(nanoseconds: 10_000_000_000) }
                catch { events.append("cancel-check"); throw error }
            }
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(operations.generation, generation)
        try await operations.perform { _ in events.append("disconnect") }
        _ = await maintenance.result
        XCTAssertEqual(events, ["check", "cancel-check", "disconnect"])
    }

    func testMaintenanceCannotInterruptUserConnection() async throws {
        let operations = ConnectionOperations()
        var maintained = false
        let connecting = Task {
            try await operations.perform { _ in try await Task.sleep(nanoseconds: 100_000_000) }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        try await operations.maintainIfIdle { maintained = true }
        try await connecting.value
        XCTAssertFalse(maintained)
    }

    func testScreenLockDelayAndUnlockCancellation() async throws {
        var disconnects = 0
        let coordinator = ScreenLockDisconnectCoordinator { disconnects += 1 }
        coordinator.configure(enabled: true, delaySeconds: 0.05)
        coordinator.screenLocked()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(disconnects, 0)
        coordinator.screenUnlocked()
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(disconnects, 0)
        coordinator.screenLocked()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(disconnects, 1)
        coordinator.screenUnlocked()
    }

    func testScreenLockDisablingAndChangingDelay() async throws {
        var disconnects = 0
        let coordinator = ScreenLockDisconnectCoordinator { disconnects += 1 }
        coordinator.configure(enabled: true, delaySeconds: 0.05)
        coordinator.screenLocked()
        coordinator.configure(enabled: false, delaySeconds: 0.05)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(disconnects, 0)
        // The original lock interval has already exceeded the new delay.
        coordinator.configure(enabled: true, delaySeconds: 0.01)
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(disconnects, 1)
        coordinator.screenUnlocked()
        XCTAssertEqual(AppSettings().screenLockDisconnectDelayMinutes, 15)
    }

}
