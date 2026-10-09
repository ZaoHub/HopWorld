import Foundation
import Darwin
import AppKit

enum TunAuthorizationCommand {
    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func appleScript(_ command: String) -> String {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    static func make(binary: URL, supervisor: URL, config: URL, lease: URL, status: URL, uid: uid_t) throws -> String {
        // Copy to a root-only snapshot BEFORE verifying hashes and executing.
        // Root never runs a writable user-path binary or reopens its config.
        let inputs = [(binary, "sing-box"), (supervisor, "supervisor"), (config, "config.json")]
        var commands = [
            "set -eu", "umask 077", "export PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            "runtime=$(/usr/bin/mktemp -d /private/var/run/hopworld-tun.XXXXXXXX)",
            "trap '/bin/rm -f \"$runtime/sing-box\" \"$runtime/supervisor\" \"$runtime/config.json\" \"$runtime/launch.log\"; /bin/rmdir \"$runtime\" 2>/dev/null || true' EXIT"
        ]
        for (source, name) in inputs {
            let digest = try SingBoxInstaller.digest(source)
            commands.append("/bin/cp -X \(shellQuote(source.path)) \"$runtime/\(name)\"")
            commands.append("test \"$(/usr/bin/shasum -a 256 \"$runtime/\(name)\" | /usr/bin/awk '{print $1}')\" = '\(digest)'")
        }
        commands += [
            "/bin/chmod 700 \"$runtime/sing-box\" \"$runtime/supervisor\"",
        ]
        commands += launchCommands(lease: lease, status: status, uid: uid)
        commands.append("trap - EXIT")
        return appleScript(commands.joined(separator: "\n"))
    }

    /// Launch the resident helper only. Later connects reuse its socket and do
    /// not build another administrator script.
    static func makeHelper(supervisor: URL, uid: uid_t) throws -> String {
        let digest = try SingBoxInstaller.digest(supervisor)
        let commands = [
            "set -eu",
            "umask 077",
            "export PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            "runtime=$(/usr/bin/mktemp -d /private/var/run/hopworld-tun.XXXXXXXX)",
            "trap '/bin/rm -f \"$runtime/supervisor\" \"$runtime/launch.log\"; /bin/rmdir \"$runtime\" 2>/dev/null || true' EXIT",
            "/bin/cp -X \(shellQuote(supervisor.path)) \"$runtime/supervisor\"",
            "test \"$(/usr/bin/shasum -a 256 \"$runtime/supervisor\" | /usr/bin/awk '{print $1}')\" = '\(digest)'",
            "/bin/chmod 700 \"$runtime/supervisor\"",
            "(trap '' HUP; exec /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin \"$runtime/supervisor\" --serve \(uid)) </dev/null >\"$runtime/launch.log\" 2>&1 &",
            "supervisor_pid=$!",
            "attempt=0",
            "while [ \"$attempt\" -lt 200 ]; do",
            "  if ! /bin/kill -0 \"$supervisor_pid\" 2>/dev/null; then",
            "    supervisor_exit=0; wait \"$supervisor_pid\" || supervisor_exit=$?",
            "    echo \"TUN 辅助服务在启动阶段退出（退出码 $supervisor_exit）。\" >&2",
            "    /usr/bin/tail -c 2048 \"$runtime/launch.log\" >&2 2>/dev/null || true",
            "    exit 1",
            "  fi",
            "  if [ -S \(shellQuote(TunHelperChannel.socketPath)) ]; then",
            "    trap - EXIT",
            "    exit 0",
            "  fi",
            "  /bin/sleep 0.1",
            "  attempt=$((attempt + 1))",
            "done",
            "if /bin/kill -0 \"$supervisor_pid\" 2>/dev/null; then",
            "  trap - EXIT",
            "  exit 0",
            "fi",
            "echo \"TUN 辅助服务未在期限内开始监听。\" >&2",
            "exit 1"
        ]
        return appleScript(commands.joined(separator: "\n"))
    }

    /// Keep the privileged shell alive briefly so exec/signature failures are
    /// returned by osascript instead of being lost in a background process.
    /// Ignore SIGHUP in the child shell and inherit it across exec. Unlike
    /// macOS nohup, this does not require a controlling terminal.
    /// launch.log is created only inside the root-owned snapshot directory.
    static func launchCommands(lease: URL, status: URL, uid: uid_t) -> [String] {
        [
            "(trap '' HUP; exec /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin \"$runtime/supervisor\" \(shellQuote(lease.path)) \(shellQuote(status.path)) \(uid)) </dev/null >\"$runtime/launch.log\" 2>&1 &",
            "supervisor_pid=$!",
            "attempt=0",
            "while [ \"$attempt\" -lt 20 ]; do",
            "  if ! /bin/kill -0 \"$supervisor_pid\" 2>/dev/null; then",
            "    supervisor_exit=0; wait \"$supervisor_pid\" || supervisor_exit=$?",
            "    echo \"TUN 监护程序在启动阶段退出（退出码 $supervisor_exit）。请检查辅助程序签名及 macOS 执行许可。\" >&2",
            "    /usr/bin/tail -c 2048 \"$runtime/launch.log\" >&2 2>/dev/null || true",
            "    exit 1",
            "  fi",
            "  /bin/sleep 0.1",
            "  attempt=$((attempt + 1))",
            "done"
        ]
    }

}

@MainActor
final class ApplicationProxyManager {
    private var directory: URL?
    private var leaseHandle: FileHandle?
    private var heartbeat: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var authorizationPending = false
    private var sawSupervisor = false
    private var helper: TunHelperClient?
    private var helperPulse: Task<Void, Never>?
    var onUnexpectedStop: ((String) -> Void)?
    private var terminationObserver: NSObjectProtocol?

    init() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("NSApplicationWillTerminateNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdownHelper() }
        }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        helperPulse?.cancel()
        heartbeat?.cancel()
        monitor?.cancel()
        helper?.close()
        try? leaseHandle?.close()
    }

    func start(applications: [ProxyApplication], socksPort: Int, password: String, xrayBinary: URL,
               captureAll: Bool = false, bootstrapDomains: [String] = []) async throws {
        guard await stop() else { throw ApplicationProxyError.failed("上一个 TUN 尚未确认停止，请稍后重试。") }
        let session = FileManager.default.temporaryDirectory.appendingPathComponent("hopworld-tun-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        directory = session
        do {
            // A default/split-default route already owned by another TUN can
            // recurse through our direct outbound. Refuse instead of stacking.
            for destination in ["1.1.1.1", "2606:4700:4700::1111"] {
                let args = destination.contains(":") ? ["-n", "get", "-inet6", destination] : ["-n", "get", destination]
                let route = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/sbin/route"), arguments: args, timeout: 3)
                let text = String(decoding: route.output, as: UTF8.self)
                if text.components(separatedBy: .newlines).contains(where: { $0.contains("interface:") && $0.contains("utun") }) {
                    throw ApplicationProxyError.invalid("检测到其他 VPN / TUN 路由，请先断开后再启用 TUN。")
                }
            }
            guard let resources = Bundle.main.resourceURL else { throw ApplicationProxyError.failed("缺少应用资源。") }
            let supervisor = resources.appendingPathComponent("HopWorldTunSupervisor")
            guard FileManager.default.isExecutableFile(atPath: supervisor.path) else {
                throw ApplicationProxyError.failed("缺少 TUN 监护程序，请重新构建 HopWorld。")
            }
            let binary = try await SingBoxInstaller.prepare(in: session)
            let config = try ApplicationProxyConfig.build(applications: applications, socksPort: socksPort,
                password: password, bypassExecutables: [xrayBinary.resolvingSymlinksInPath().path,
                    captureAll ? "" : (Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? ""),
                    binary.path].filter { !$0.isEmpty }, captureAll: captureAll, bootstrapDomains: bootstrapDomains)
            let configURL = session.appendingPathComponent("config.json")
            try XrayConfigBuilder.writeJSON(config, to: configURL)
            let checked = try await ProcessRunner.run(executable: binary,
                arguments: ["check", "-c", configURL.path], timeout: 10)
            guard checked.status == 0, !checked.timedOut, !checked.cancelled else {
                throw ApplicationProxyError.failed("TUN 配置校验失败：" + String(decoding: checked.output, as: UTF8.self))
            }
            try Task.checkCancellation()
            let lease = session.appendingPathComponent("lease")
            let status = session.appendingPathComponent("status.json")
            for file in [lease, status] {
                guard FileManager.default.createFile(atPath: file.path, contents: Data("starting".utf8),
                                                      attributes: [.posixPermissions: 0o600]) else {
                    throw ApplicationProxyError.failed("无法创建 TUN 会话控制文件。")
                }
            }
            leaseHandle = try FileHandle(forUpdating: lease)
            pulse()
            heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                    self?.pulse()
                }
            }
            let client = try await ensureHelper(supervisor: supervisor)
            authorizationPending = true
            let binaryDigest = try SingBoxInstaller.digest(binary)
            let configDigest = try SingBoxInstaller.digest(configURL)
            let response = try await Task.detached {
                try client.request(TunHelperRequest(op: "start", binary: binary.path, config: configURL.path,
                    lease: lease.path, status: status.path, binaryDigest: binaryDigest, configDigest: configDigest),
                    timeout: 30)
            }.value
            try Task.checkCancellation()
            guard response.ok else {
                authorizationPending = false
                throw ApplicationProxyError.failed(response.message.isEmpty ? "TUN 辅助服务拒绝启动。" : response.message)
            }
            if let terminal = Self.readStatus(session), ["failed", "stopped"].contains(terminal.state) {
                sawSupervisor = true
                throw ApplicationProxyError.failed("TUN 启动结束（\(terminal.state)）：" + terminal.message)
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 20
            while ProcessInfo.processInfo.systemUptime < deadline {
                try Task.checkCancellation()
                if let current = Self.readStatus(session) {
                    sawSupervisor = true
                    if current.state == "running", Date().timeIntervalSince(current.updatedAt) < 3 {
                        monitor = Task { [weak self] in
                            var lastHealthy = ProcessInfo.processInfo.systemUptime
                            var lastStatusDate = current.updatedAt
                            while !Task.isCancelled {
                                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                                guard let self else { return }
                                let state = Self.readStatus(session)
                                if let state, state.state == "running", state.updatedAt != lastStatusDate {
                                    lastHealthy = ProcessInfo.processInfo.systemUptime
                                    lastStatusDate = state.updatedAt
                                }
                                if state?.state == "failed" || state?.state == "stopped" ||
                                    ProcessInfo.processInfo.systemUptime - lastHealthy > 5 {
                                    // Stop the lease before notifying ConnectionManager.
                                    self.revokeLease()
                                    self.onUnexpectedStop?(state?.message ?? "TUN 监护进程失去响应")
                                    return
                                }
                            }
                        }
                        return
                    }
                    if ["failed", "stopped"].contains(current.state) {
                        throw ApplicationProxyError.failed(current.message)
                    }
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            let lastStatus = Self.readStatus(session)
            let detail = lastStatus.map { "最后状态：\($0.state)。\($0.message)" }
                ?? "未收到监护程序状态；请检查辅助程序签名及 macOS 执行许可。"
            throw ApplicationProxyError.failed("TUN 未在期限内启动。" + detail)
        } catch {
            _ = await stop()
            if error is CancellationError { throw error }
            throw ApplicationProxyError.failed(error.localizedDescription)
        }
    }

    /// Password is required only when this process has no live helper. Disconnect
    /// leaves the helper running, so the next connect reuses it.
    private func ensureHelper(supervisor: URL) async throws -> TunHelperClient {
        if let helper {
            let alive = await Task.detached { helper.ping() }.value
            if alive { return helper }
            helper.close()
            self.helper = nil
            helperPulse?.cancel()
        }
        if let existing = try? await Task.detached(priority: .userInitiated, operation: {
            try TunHelperClient.connect(TunHelperChannel.socketPath, timeout: 0.4)
        }).value {
            helper = existing
            startHelperPulse(existing)
            return existing
        }
        let script = try TunAuthorizationCommand.makeHelper(supervisor: supervisor, uid: getuid())
        AppLogger.shared.info("正在等待系统授权。请在密码窗口输入登录密码并点「允许访问」。", category: .systemProxy)
        NSApplication.shared.activate()
        let outcome = TunHelperAuthorizationOutcome()
        let authorization = Task.detached {
            do {
                let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/osascript"),
                    arguments: ["-e", script], timeout: 180)
                outcome.finish(.success(result))
            } catch {
                outcome.finish(.failure(error))
            }
        }
        do {
            let client = try await withTaskCancellationHandler {
                try await TunHelperAuthorizationWait.wait(timeout: 180, connect: {
                    try TunHelperClient.connect(TunHelperChannel.socketPath, timeout: 0.3)
                }, authorization: { outcome.current })
            } onCancel: {
                authorization.cancel()
            }
            helper = client
            startHelperPulse(client)
            return client
        } catch {
            authorization.cancel()
            throw error
        }
    }

    private func startHelperPulse(_ client: TunHelperClient) {
        helperPulse?.cancel()
        helperPulse = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self else { return }
                // A running job is kept alive by the lease. Pinging now would only
                // fill the socket while the helper is blocked inside that job.
                if self.leaseHandle != nil { continue }
                let alive = await Task.detached { client.ping() }.value
                if Task.isCancelled || self.helper !== client { return }
                if !alive {
                    client.close()
                    self.helper = nil
                    return
                }
            }
        }
    }

    private func shutdownHelper() {
        helperPulse?.cancel()
        helperPulse = nil
        revokeLease()
        helper?.quitAndClose()
        helper = nil
    }

    private func pulse() {
        guard let leaseHandle else { return }
        var value = DispatchTime.now().uptimeNanoseconds
        _ = withUnsafeBytes(of: &value) { pwrite(leaseHandle.fileDescriptor, $0.baseAddress, $0.count, 0) }
    }

    private func revokeLease() {
        heartbeat?.cancel(); heartbeat = nil
        if let directory { try? FileManager.default.removeItem(at: directory.appendingPathComponent("lease")) }
        try? leaseHandle?.close(); leaseHandle = nil
    }

    /// Cancellation-shielded cleanup: never report disconnected before the root
    /// supervisor confirms that the TUN child (and its utun routes) has stopped.
    @discardableResult
    func stop() async -> Bool {
        monitor?.cancel(); monitor = nil
        let mayHaveStarted = authorizationPending
        let observed = sawSupervisor
        revokeLease()
        guard let session = directory else { return true }
        let ended = await Task.detached {
            let deadline = ProcessInfo.processInfo.systemUptime + 7
            repeat {
                let state = Self.readStatus(session)
                if state?.state == "stopped" || state?.state == "failed" { return true }
                // No authorized helper exists during prepare/download.
                if !mayHaveStarted { return true }
                try? await Task.sleep(nanoseconds: 100_000_000)
            } while ProcessInfo.processInfo.systemUptime < deadline
            // No published status means authorization never launched a helper;
            // a late helper cannot start after the lease was unlinked.
            return !observed && Self.readStatus(session) == nil
        }.value
        if ended {
            try? FileManager.default.removeItem(at: session)
            directory = nil
            authorizationPending = false
            sawSupervisor = false
        }
        return ended
    }

    nonisolated private static func readStatus(_ directory: URL) -> TunSessionStatus? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("status.json")) else { return nil }
        return try? JSONDecoder().decode(TunSessionStatus.self, from: data)
    }
}

final class TunHelperAuthorizationOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<ProcessRunResult, Error>?
    func finish(_ result: Result<ProcessRunResult, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }
    var current: Result<ProcessRunResult, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

enum TunHelperAuthorizationWait {
    /// Returns as soon as the helper accepts a connection. A slow administrator
    /// dialog must not be abandoned at 120 seconds, and a helper that is already
    /// listening must not wait for osascript to finish draining pipes.
    static func wait(
        timeout: TimeInterval,
        connect: @escaping @Sendable () throws -> TunHelperClient,
        authorization: @escaping @Sendable () -> Result<ProcessRunResult, Error>?
    ) async throws -> TunHelperClient {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var authorizedAt: TimeInterval?
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            if let client = try? await Task.detached(operation: connect).value { return client }
            if let outcome = authorization() {
                switch outcome {
                case .failure(let error):
                    throw error
                case .success(let result):
                    if result.status != 0 || result.timedOut || result.cancelled {
                        if let client = try? await Task.detached(operation: connect).value { return client }
                        throw ApplicationProxyError.failed(message(for: result))
                    }
                    authorizedAt = authorizedAt ?? ProcessInfo.processInfo.systemUptime
                    if ProcessInfo.processInfo.systemUptime - (authorizedAt ?? 0) > 20 {
                        throw ApplicationProxyError.failed("管理员已授权，但 TUN 辅助服务没有开始监听。未切换为系统代理。\n" +
                            String(decoding: result.output, as: UTF8.self))
                    }
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if let client = try? await Task.detached(operation: connect).value { return client }
        throw ApplicationProxyError.failed("系统授权窗口超过 3 分钟仍未完成。请在弹出的密码窗口输入登录密码并点「允许访问」。未切换为系统代理。")
    }

    static func message(for result: ProcessRunResult) -> String {
        let output = String(decoding: result.output, as: UTF8.self)
        let reason: String
        if result.timedOut {
            reason = "系统授权窗口超过 3 分钟仍未完成。请在弹出的密码窗口输入登录密码并点「允许访问」。"
        } else if result.cancelled {
            reason = "TUN 启动已取消。"
        } else {
            reason = "管理员授权失败（退出码 \(result.status)）。"
        }
        return reason + "未切换为系统代理。\n" + output
    }
}

final class TunHelperClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "hopworld.tun-helper")
    private var fd: Int32

    private init(fd: Int32) { self.fd = fd }

    static func connect(_ path: String, timeout: TimeInterval) throws -> TunHelperClient {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var lastError = "无法连接 TUN 辅助服务。"
        while ProcessInfo.processInfo.systemUptime < deadline {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw ApplicationProxyError.failed("无法创建 TUN 辅助套接字。") }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            var one: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            if TunHelperSocket.connect(fd, path) { return TunHelperClient(fd: fd) }
            lastError = "无法连接 TUN 辅助服务（errno=\(errno)）。"
            Darwin.close(fd)
            usleep(50_000)
        }
        throw ApplicationProxyError.failed(lastError)
    }

    func ping() -> Bool {
        (try? request(TunHelperRequest(op: "ping"), timeout: 2))?.ok == true
    }

    func request(_ message: TunHelperRequest, timeout: TimeInterval) throws -> TunHelperResponse {
        try queue.sync {
            guard fd >= 0 else { throw ApplicationProxyError.failed("TUN 辅助服务已断开。") }
            guard TunHelperSocket.send(message, fd) else {
                throw ApplicationProxyError.failed("无法向 TUN 辅助服务发送请求。")
            }
            guard let response = TunHelperSocket.readResponse(fd, timeout: timeout) else {
                throw ApplicationProxyError.failed("TUN 辅助服务没有响应。")
            }
            return response
        }
    }

    func quitAndClose() {
        queue.sync {
            guard fd >= 0 else { return }
            if TunHelperSocket.send(TunHelperRequest(op: "quit"), fd) {
                _ = TunHelperSocket.readResponse(fd, timeout: 1)
            }
            Darwin.close(fd)
            fd = -1
        }
    }

    func close() {
        queue.sync {
            guard fd >= 0 else { return }
            Darwin.close(fd)
            fd = -1
        }
    }
}
