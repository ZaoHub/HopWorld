import Foundation
import Darwin

/// Drain on a utility queue, not the main actor. Keep only a bounded tail even
/// when a child emits logs faster than the UI can display them.
final class ProcessOutputCapture: @unchecked Sendable {
    let pipe = Pipe()
    private let lock = NSLock()
    private let finished = DispatchGroup()
    private let capacity: Int
    private var tail = Data()

    init(capacity: Int = 64 * 1024) {
        self.capacity = max(1, capacity)
        finished.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer {
                try? pipe.fileHandleForReading.close()
                finished.leave()
            }
            // Foundation's read(upToCount:) may wait to fill the requested
            // buffer on a pipe. A quiet, long-running child must publish its
            // startup line immediately, before EOF or another 16 KiB arrives.
            let descriptor = pipe.fileHandleForReading.fileDescriptor
            var bytes = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = bytes.withUnsafeMutableBytes {
                    Darwin.read(descriptor, $0.baseAddress, $0.count)
                }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                lock.lock()
                tail.append(contentsOf: bytes.prefix(count))
                if tail.count > self.capacity { tail = Data(tail.suffix(self.capacity)) }
                lock.unlock()
            }
        }
    }

    func snapshot(maxBytes: Int = 8192) -> Data {
        lock.lock()
        defer { lock.unlock() }
        return Data(tail.suffix(max(0, maxBytes)))
    }

    /// Only used off the main actor, after child exit (or a failed launch).
    func finish() {
        try? pipe.fileHandleForWriting.close()
        _ = finished.wait(timeout: .now() + 1)
    }
}

struct ProcessRunResult: Sendable {
    let status: Int32
    let output: Data
    let timedOut: Bool
    let cancelled: Bool
}

private final class ProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

enum ProcessRunner {
    /// A bounded, cancellable subprocess for probes and statistics. The worker
    /// owns launch/termination so cancellation never targets an unrelated PID.
    static func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        environment: [String: String]? = nil,
        outputLimit: Int = 64 * 1024
    ) async throws -> ProcessRunResult {
        let cancellation = ProcessCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let process = Process()
                    process.executableURL = executable
                    process.arguments = arguments
                    process.environment = environment
                    let capture = ProcessOutputCapture(capacity: outputLimit)
                    process.standardOutput = capture.pipe
                    process.standardError = capture.pipe
                    do {
                        if cancellation.isCancelled { throw CancellationError() }
                        try process.run()
                    } catch {
                        capture.finish()
                        continuation.resume(throwing: error)
                        return
                    }
                    let deadline = ProcessInfo.processInfo.systemUptime + max(0.05, timeout)
                    while process.isRunning && !cancellation.isCancelled && ProcessInfo.processInfo.systemUptime < deadline {
                        Thread.sleep(forTimeInterval: 0.02)
                    }
                    let cancelled = cancellation.isCancelled
                    let timedOut = process.isRunning && !cancelled
                    if process.isRunning {
                        process.terminate()
                        let grace = ProcessInfo.processInfo.systemUptime + 0.2
                        while process.isRunning && ProcessInfo.processInfo.systemUptime < grace {
                            Thread.sleep(forTimeInterval: 0.01)
                        }
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                    process.waitUntilExit()
                    capture.finish()
                    continuation.resume(returning: ProcessRunResult(
                        status: process.terminationStatus,
                        output: capture.snapshot(maxBytes: outputLimit),
                        timedOut: timedOut,
                        cancelled: cancelled
                    ))
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}
