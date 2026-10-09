import Foundation

enum BatchProbeScheduler {
    /// Refill the next slot as soon as any probe completes. The caller's task
    /// owns all probes, so pause/cancel also cancels DNS, sockets and curl.
    @MainActor
    static func run<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        concurrency: Int,
        operation: @escaping @Sendable (Input) async -> Output?,
        onResult: (Output) -> Void
    ) async {
        guard !Task.isCancelled else { return }
        await withTaskGroup(of: Output?.self) { group in
            var next = 0
            func enqueue() {
                guard next < inputs.count, !Task.isCancelled else { return }
                let input = inputs[next]
                next += 1
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    let result = await operation(input)
                    return Task.isCancelled ? nil : result
                }
            }
            for _ in 0..<min(max(1, concurrency), inputs.count) { enqueue() }
            while let result = await group.next() {
                guard !Task.isCancelled else { group.cancelAll(); break }
                if let result { onResult(result) }
                enqueue()
            }
        }
    }
}
