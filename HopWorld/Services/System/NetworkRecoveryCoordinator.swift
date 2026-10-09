import Foundation

/// Debounces route flapping and suppresses recovery while sleeping/offline.
/// ConnectionManager still checks its session generation before any side effects.
@MainActor
final class NetworkRecoveryCoordinator {
    private(set) var available = true
    private(set) var sleeping = false
    private var hasInitialPath = false
    private var pending: Task<Void, Never>?
    private let delay: UInt64
    private let recover: @MainActor () async -> Void
    var canRecover: Bool { available && !sleeping }

    init(delay: UInt64 = 1_500_000_000, recover: @escaping @MainActor () async -> Void) {
        self.delay = delay
        self.recover = recover
    }

    func pathChanged(available: Bool) {
        self.available = available
        if !hasInitialPath {
            hasInitialPath = true
            return
        }
        schedule()
    }

    func willSleep() {
        sleeping = true
        pending?.cancel()
        pending = nil
    }

    func didWake() {
        sleeping = false
        schedule()
    }

    private func schedule() {
        pending?.cancel()
        guard canRecover else { pending = nil; return }
        pending = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: self.delay) } catch { return }
            guard self.canRecover, !Task.isCancelled else { return }
            await self.recover()
        }
    }

    deinit { pending?.cancel() }
}

/// Tracks a continuous lock interval; unlocking cancels the pending disconnect.
@MainActor
final class ScreenLockDisconnectCoordinator {
    private var lockedAt: Date?
    private var pending: Task<Void, Never>?
    private var enabled = true
    private var delaySeconds: TimeInterval = 15 * 60
    private let disconnect: @MainActor () async -> Void

    init(disconnect: @escaping @MainActor () async -> Void) {
        self.disconnect = disconnect
    }

    func configure(enabled: Bool, delaySeconds: TimeInterval) {
        self.enabled = enabled
        self.delaySeconds = max(0, delaySeconds)
        schedule()
    }

    func screenLocked() {
        if lockedAt == nil { lockedAt = Date() }
        schedule()
    }

    func screenUnlocked() {
        lockedAt = nil
        pending?.cancel()
        pending = nil
    }

    private func schedule() {
        pending?.cancel()
        pending = nil
        guard enabled, let lockedAt else { return }
        let remaining = max(0, lockedAt.addingTimeInterval(delaySeconds).timeIntervalSinceNow)
        pending = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
            catch { return }
            guard let self, self.enabled, self.lockedAt != nil, !Task.isCancelled else { return }
            await self.disconnect()
        }
    }

    deinit { pending?.cancel() }
}
