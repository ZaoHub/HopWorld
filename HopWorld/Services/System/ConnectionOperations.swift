import Foundation

/// Latest request wins, but its side effects cannot begin until the previous
/// request has finished cancellation and cleanup. MainActor alone does not
/// provide this guarantee across await points.
@MainActor
final class ConnectionOperations {
    private(set) var generation = 0
    private var active: Task<Void, Error>?

    func perform(_ operation: @escaping @MainActor (Int) async throws -> Void) async throws {
        generation += 1
        let current = generation
        let previous = active
        previous?.cancel()
        let task = Task { @MainActor in
            _ = await previous?.result
            try Task.checkCancellation()
            guard generation == current else { throw CancellationError() }
            try await operation(current)
        }
        active = task
        defer { if generation == current { active = nil } }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    /// Maintenance must not interrupt an explicit connect/disconnect, or invalidate
    /// the current session's metrics. Explicit operations can still cancel it.
    func maintainIfIdle(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        guard active == nil else { return }
        let current = generation
        let task = Task { @MainActor in
            try Task.checkCancellation()
            try await operation()
        }
        active = task
        defer { if generation == current { active = nil } }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

}
