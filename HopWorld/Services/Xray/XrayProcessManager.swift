import Foundation
import Darwin

enum XrayProcessError: LocalizedError, Sendable {
    case binaryMissing
    case alreadyRunning
    case startFailed(String)
    case notRunning

    var errorDescription: String? {
        switch self {
        case .binaryMissing:
            return "未找到 xray 可执行文件，自动安装也失败了。请检查网络后重试，或运行 Scripts/fetch_xray.sh"
        case .alreadyRunning:
            return "Xray 已在运行"
        case .startFailed(let message):
            return "启动 Xray 失败：\(message)"
        case .notRunning:
            return "Xray 未运行"
        }
    }
}

actor XrayProcessManager {
    private let binaryOverride: URL?
    init(binaryURL: URL? = nil) { binaryOverride = binaryURL }
    private var process: Process?
    private var outputCapture: ProcessOutputCapture?
    private(set) var pid: Int32?
    private var onTerminated: (@Sendable () -> Void)?
    /// PIDs we stopped on purpose — their termination must not trigger crash recovery.
    private var intentionallyStoppedPIDs: Set<Int32> = []

    func setTerminationHandler(_ handler: (@Sendable () -> Void)?) {
        onTerminated = handler
    }

    func isRunning() -> Bool {
        process?.isRunning == true
    }

    func start(configURL: URL) async throws {
        if let process, process.isRunning {
            await stop()
        }

        let binary: URL
        if let existing = binaryOverride ?? Self.resolveBinaryURL() {
            binary = existing
        } else {
            do {
                binary = try await XrayInstaller.ensureInstalled()
            } catch {
                throw XrayProcessError.binaryMissing
            }
        }

        let process = Process()
        process.executableURL = binary
        process.arguments = ["run", "-config", configURL.path]
        // Help xray find geoip/geosite next to the binary when possible.
        process.currentDirectoryURL = binary.deletingLastPathComponent()
        if let assets = XrayInstaller.assetDirectory(for: binary) {
            var environment = ProcessInfo.processInfo.environment
            environment["XRAY_LOCATION_ASSET"] = assets.path
            process.environment = environment
        }

        let capture = ProcessOutputCapture()
        process.standardOutput = capture.pipe
        process.standardError = capture.pipe
        self.outputCapture = capture

        process.terminationHandler = { [weak self] terminated in
            let endedPID = terminated.processIdentifier
            Task {
                await self?.handleTermination(pid: endedPID)
            }
        }

        do {
            try process.run()
        } catch {
            await Task.detached(priority: .utility) { capture.finish() }.value
            throw XrayProcessError.startFailed(error.localizedDescription)
        }

        self.process = process
        self.pid = process.processIdentifier

        // Output is continuously drained, including during startup failures.
        try? await Task.sleep(nanoseconds: 250_000_000)
        if !process.isRunning {
            await Task.detached(priority: .utility) { capture.finish() }.value
            let log = String(data: capture.snapshot(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if self.process === process {
                self.process = nil
                self.pid = nil
            }
            let detail = log.isEmpty ? "Xray 启动后立即退出" : String(log.suffix(500))
            throw XrayProcessError.startFailed(detail)
        }
    }

    func stop() async {
        guard let process else { return }
        let endedPID = process.processIdentifier
        intentionallyStoppedPIDs.insert(endedPID)
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline {
                do { try await Task.sleep(nanoseconds: 50_000_000) }
                catch { break }
            }
            if process.isRunning {
                // Only this manager's child; do not leave an old core holding ports.
                kill(process.processIdentifier, SIGKILL)
            }
            await Task.detached(priority: .utility) { process.waitUntilExit() }.value
        }
        // If the handler already ran, clean up; otherwise handler will no-op via the set.
        if self.process?.processIdentifier == endedPID {
            self.process = nil
            self.pid = nil
        }
    }

    func readRecentOutput(maxBytes: Int = 8192) -> String {
        guard let capture = outputCapture else { return "" }
        return String(decoding: capture.snapshot(maxBytes: maxBytes), as: UTF8.self)
    }

    private func handleTermination(pid endedPID: Int32) {
        let wasCurrent = self.process?.processIdentifier == endedPID
        if wasCurrent {
            self.process = nil
            self.pid = nil
        }

        if intentionallyStoppedPIDs.remove(endedPID) != nil {
            return
        }
        if wasCurrent { onTerminated?() }
    }

    static func resolveBinaryURL() -> URL? {
        let fm = FileManager.default

        var candidates: [URL] = [
            XrayInstaller.supportBinaryURL,
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/xray"),
            URL(fileURLWithPath: "/opt/homebrew/bin/xray"),
            URL(fileURLWithPath: "/usr/local/bin/xray")
        ]
        if let bundled = Bundle.main.url(forResource: "xray", withExtension: nil) {
            candidates.insert(bundled, at: 1)
        }

        let executable = candidates.filter { fm.isExecutableFile(atPath: $0.path) }
        if let preferred = executable.first(where: {
            XrayInstaller.version(of: $0) == XrayInstaller.preferredVersion
        }) {
            return preferred
        }
        return executable.first
    }

    private static let runtimeDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("HopWorld-runtime-\(UUID().uuidString)", isDirectory: true)

    static func configDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return runtimeDirectory
    }
}
