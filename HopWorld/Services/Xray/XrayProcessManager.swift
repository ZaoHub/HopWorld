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
    private let singBoxBridge = SingBoxConnectionBridge()
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
        await stop()

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

        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
        if let outbounds = config?["outbounds"] as? [[String: Any]], outbounds.contains(where: { $0["protocol"] as? String == "masque" }) {
            guard let version = XrayInstaller.version(of: binary), XrayInstaller.isVersion(version, atLeast: XrayInstaller.masqueMinimumVersion) else {
                throw XrayProcessError.startFailed("MASQUE 需要 Xray \(XrayInstaller.masqueMinimumVersion) 或更新版本，请在设置中更新内核")
            }
        }
        let runtimeConfig = try await singBoxBridge.prepare(configURL: configURL) { [weak self] in
            Task { await self?.bridgeTerminated() }
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["run", "-config", runtimeConfig.path]
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
            await singBoxBridge.stop()
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
            await singBoxBridge.stop()
            throw XrayProcessError.startFailed(detail)
        }
        if Task.isCancelled {
            await stop()
            throw CancellationError()
        }
    }

    func connectionCoreExecutables() async -> [String] {
        if let path = await singBoxBridge.executablePath() { return [path] }
        return []
    }

    private func bridgeTerminated() async {
        guard process?.isRunning == true else { return }
        await stop()
        onTerminated?()
    }

    func stop() async {
        await singBoxBridge.stop()
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

    func readRecentOutput(maxBytes: Int = 8192) async -> String {
        let primary = outputCapture.map { String(decoding: $0.snapshot(maxBytes: maxBytes), as: UTF8.self) } ?? ""
        let secondary = await singBoxBridge.readRecentOutput(maxBytes: maxBytes)
        return String(decoding: Data((primary + "\n" + secondary).utf8).suffix(max(0, maxBytes)), as: UTF8.self)
    }

    private func handleTermination(pid endedPID: Int32) async {
        let wasCurrent = self.process?.processIdentifier == endedPID
        if wasCurrent {
            self.process = nil
            self.pid = nil
        }

        if intentionallyStoppedPIDs.remove(endedPID) != nil {
            return
        }
        if wasCurrent {
            await singBoxBridge.stop()
            onTerminated?()
        }
    }

    /// Version discovery may launch a subprocess; never inherit the UI executor.
    nonisolated static func resolveBinaryURLForTesting() async -> URL? {
        resolveBinaryURL()
    }

    static func resolveBinaryURL() -> URL? {
        if let selected = XrayInstaller.managedBinaryURL { return selected }
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
        return executable.reduce(nil as URL?) { best, candidate in
            guard let best else { return candidate }
            guard let version = XrayInstaller.version(of: candidate) else { return best }
            guard let current = XrayInstaller.version(of: best) else { return candidate }
            return version != current && XrayInstaller.isVersion(version, atLeast: current) ? candidate : best
        }
    }

    private static let runtimeDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("HopWorld-runtime-\(UUID().uuidString)", isDirectory: true)

    static func configDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return runtimeDirectory
    }
}

/// A private, authenticated loopback hop for protocols the bundled Xray rejects.
actor SingBoxConnectionBridge {
    private var process: Process?
    private var capture: ProcessOutputCapture?
    private var directory: URL?
    private var binary: URL?
    private var active = false
    private var onTerminated: (@Sendable () -> Void)?

    func executablePath() -> String? { binary?.resolvingSymlinksInPath().path }

    func readRecentOutput(maxBytes: Int) -> String {
        capture.map { String(decoding: $0.snapshot(maxBytes: maxBytes), as: UTF8.self) } ?? ""
    }

    func prepare(configURL: URL, onTerminated: @escaping @Sendable () -> Void) async throws -> URL {
        var config = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any] ?? [:]
        var outbounds = config["outbounds"] as? [[String: Any]] ?? []
        let indices = outbounds.indices.filter { outbounds[$0][SingBoxConnectionConfig.marker] != nil }
        guard !indices.isEmpty else { return configURL }
        let session = FileManager.default.temporaryDirectory.appendingPathComponent("hopworld-singbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        directory = session
        do {
            let executable = try await SingBoxInstaller.prepare(in: session)
            binary = executable
            let reservation = try LocalTestPorts(count: indices.count)
            var inbounds: [[String: Any]] = []
            var upstreams: [[String: Any]] = []
            var rules: [[String: Any]] = []
            for (offset, index) in indices.enumerated() {
                let port = reservation.ports[offset]
                let tag = outbounds[index]["tag"] as? String ?? "bridge-\(offset)"
                let password = UUID().uuidString
                guard var upstream = outbounds[index].removeValue(forKey: SingBoxConnectionConfig.marker) as? [String: Any] else {
                    throw XrayProcessError.startFailed("sing-box 节点配置格式无效")
                }
                upstream["tag"] = tag
                upstreams.append(upstream)
                inbounds.append(["type": "socks", "tag": "in-\(offset)", "listen": "127.0.0.1", "listen_port": port,
                                 "users": [["username": "hopworld", "password": password]]])
                rules.append(["inbound": ["in-\(offset)"], "action": "route", "outbound": tag])
                outbounds[index]["settings"] = ["servers": [["address": "127.0.0.1", "port": port,
                                                           "users": [["user": "hopworld", "pass": password]]]]]
            }
            let bridgeConfig: [String: Any] = [
                "log": ["level": "info", "timestamp": true],
                "dns": ["servers": [["type": "local", "tag": "local-dns"]]],
                "inbounds": inbounds, "outbounds": upstreams,
                "route": ["rules": rules, "default_domain_resolver": "local-dns"]
            ]
            let file = session.appendingPathComponent("sing-box.json")
            try XrayConfigBuilder.writeJSON(bridgeConfig, to: file)
            config["outbounds"] = outbounds
            let runtime = session.appendingPathComponent("xray.json")
            try XrayConfigBuilder.writeJSON(config, to: runtime)
            try Task.checkCancellation()
            let child = Process()
            child.executableURL = executable
            child.arguments = ["run", "-c", file.path]
            let output = ProcessOutputCapture()
            child.standardOutput = output.pipe
            child.standardError = output.pipe
            capture = output
            child.terminationHandler = { [weak self] terminated in
                Task { await self?.exited(pid: terminated.processIdentifier) }
            }
            reservation.release()
            try child.run()
            process = child
            self.onTerminated = onTerminated
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                try Task.checkCancellation()
                guard child.isRunning else {
                    throw XrayProcessError.startFailed("sing-box：" + String(decoding: output.snapshot(maxBytes: 1500), as: UTF8.self))
                }
                var ready = true
                for port in reservation.ports {
                    if await TCPTester.measure(host: "127.0.0.1", port: port, timeout: 0.1) == nil { ready = false; break }
                }
                if ready {
                    active = true
                    await MainActor.run { AppLogger.shared.info("sing-box 连接核心已就绪：\(indices.count) 个节点", category: .xray) }
                    return runtime
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            throw XrayProcessError.startFailed("sing-box 本地连接端口未就绪")
        } catch {
            await stop()
            throw error
        }
    }

    private func exited(pid: Int32) {
        guard process?.processIdentifier == pid, active else { return }
        active = false
        onTerminated?()
    }

    func stop() async {
        active = false
        onTerminated = nil
        let child = process
        process = nil
        if let child, child.isRunning {
            child.terminate()
            let deadline = Date().addingTimeInterval(2)
            while child.isRunning && Date() < deadline {
                do { try await Task.sleep(nanoseconds: 50_000_000) }
                catch { break }
            }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            await Task.detached { child.waitUntilExit() }.value
        }
        if let capture { await Task.detached { capture.finish() }.value }
        capture = nil
        binary = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
}
