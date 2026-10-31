import XCTest

final class ConnectionPatienceTests: XCTestCase {
    func testConfiguredAndRelaxedTimeoutsStayWithinTheUserRange() {
        XCTAssertEqual(ConnectionPatiencePolicy.initialTimeout(configured: 15), 15)
        XCTAssertEqual(ConnectionPatiencePolicy.initialTimeout(configured: 99), 99)
        XCTAssertEqual(ConnectionPatiencePolicy.initialTimeout(configured: Int.max), 99)
        XCTAssertEqual(ConnectionPatiencePolicy.initialTimeout(configured: Int.min), 1)
        XCTAssertEqual(ConnectionPatiencePolicy.initialTimeout(configured: 3, relaxedHandshake: true), 12)
        XCTAssertEqual(ConnectionPatiencePolicy.initialTimeout(configured: 99, relaxedHandshake: true), 99)
    }

    func testOneConfirmationUsesOnlyTheRemainingTotalBudget() {
        XCTAssertEqual(ConnectionPatiencePolicy.maximumWait(initialTimeout: 15), 30)
        XCTAssertEqual(ConnectionPatiencePolicy.remainingWait(initialTimeout: 15, elapsed: 15), 15)
        XCTAssertEqual(ConnectionPatiencePolicy.remainingWait(initialTimeout: 15, elapsed: 29.5), 0.5)
        XCTAssertEqual(ConnectionPatiencePolicy.remainingWait(initialTimeout: 15, elapsed: 30), 0)
        XCTAssertEqual(ConnectionPatiencePolicy.remainingWait(initialTimeout: 15, elapsed: 90), 0)
        XCTAssertEqual(ConnectionPatiencePolicy.maximumWait(initialTimeout: 1), 16)
        XCTAssertEqual(ConnectionPatiencePolicy.maximumWait(initialTimeout: 60), 99)
        XCTAssertEqual(ConnectionPatiencePolicy.maximumWait(initialTimeout: 99), 99)
        XCTAssertEqual(ConnectionPatiencePolicy.remainingWait(initialTimeout: 99, elapsed: 99), 0)
    }

    func testMalformedElapsedTimeCannotExtendTheDeadline() {
        XCTAssertEqual(ConnectionPatiencePolicy.remainingWait(initialTimeout: 15, elapsed: -10), 30)
        XCTAssertEqual(ConnectionPatiencePolicy.remainingWait(initialTimeout: 15, elapsed: .infinity), 0)
        XCTAssertEqual(ConnectionPatiencePolicy.remainingWait(initialTimeout: 15, elapsed: .nan), 0)
        XCTAssertEqual(ConnectionPatiencePolicy.maximumWait(initialTimeout: .infinity), 0)
        XCTAssertEqual(ConnectionPatiencePolicy.maximumWait(initialTimeout: .nan), 0)
    }

    func testUsableSlowOrTimeoutProneNodesGetMoreTimeOnlyForActualApplicationFailures() {
        XCTAssertEqual(ConnectionPatiencePolicy.applicationFailureDuration(configuredTimeout: 15, needsExtendedObservation: false), 30)
        XCTAssertEqual(ConnectionPatiencePolicy.applicationFailureDuration(configuredTimeout: 15, needsExtendedObservation: true), 60)
        XCTAssertEqual(ConnectionPatiencePolicy.applicationFailureDuration(configuredTimeout: 75, needsExtendedObservation: true), 75)
        XCTAssertEqual(ConnectionPatiencePolicy.applicationFailureDuration(configuredTimeout: 99, needsExtendedObservation: false), 99)
        XCTAssertEqual(ConnectionPatiencePolicy.applicationFailureDuration(configuredTimeout: Int.max, needsExtendedObservation: true), 99)
        XCTAssertEqual(ConnectionPatiencePolicy.applicationFailureDuration(configuredTimeout: Int.min, needsExtendedObservation: false), 30)
    }
}
