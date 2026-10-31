import Foundation

enum ConnectionPatiencePolicy {
    static func initialTimeout(configured: Int, relaxedHandshake: Bool = false) -> TimeInterval {
        let configured = min(99, max(1, configured))
        return TimeInterval(relaxedHandshake ? max(12, configured) : configured)
    }

    /// One retry shares a fixed total deadline; repeated failures cannot keep extending it.
    static func maximumWait(initialTimeout: TimeInterval) -> TimeInterval {
        guard initialTimeout.isFinite else { return 0 }
        let initial = min(99, max(1, initialTimeout))
        return min(99, max(initial * 2, initial + 15))
    }

    static func remainingWait(initialTimeout: TimeInterval, elapsed: TimeInterval) -> TimeInterval {
        guard elapsed.isFinite else { return 0 }
        return max(0, maximumWait(initialTimeout: initialTimeout) - max(0, elapsed))
    }

    static func applicationFailureDuration(configuredTimeout: Int, needsExtendedObservation: Bool) -> TimeInterval {
        max(needsExtendedObservation ? 60 : 30, initialTimeout(configured: configuredTimeout))
    }
}
