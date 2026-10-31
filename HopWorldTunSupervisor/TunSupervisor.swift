import Foundation
import Darwin
import CryptoKit

enum TunProcessIsolation {
    static func detachFromLauncher() throws {
        guard getpgrp() != getpid() else { return }
        guard setsid() >= 0 else {
            let code = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                          userInfo: [NSLocalizedDescriptionKey: "无法将 TUN 辅助服务与授权启动器分离：errno=\(code)"])
        }
    }
}

/// Foundation may canonicalize /private/var/run to /var/run on macOS.
/// Compare canonical parents, never one spelling of an absolute prefix.
enum TunRuntimeDirectory {
    static func hasExpectedLocation(_ directory: URL) -> Bool {
        let parent = directory.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let expected = URL(fileURLWithPath: "/private/var/run", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let name = directory.lastPathComponent
        return parent.path == expected.path && name.hasPrefix("hopworld-tun.") &&
            name.count > "hopworld-tun.".count
    }

    static func hasSafeOwnership(owner: uid_t, mode: mode_t) -> Bool {
        owner == 0 && mode & S_IFMT == S_IFDIR && mode & 0o077 == 0
    }

    static func validate(_ directory: URL) throws {
        guard hasExpectedLocation(directory) else {
            throw ApplicationRuntimeError.invalid("TUN 运行目录位置无效：\(directory.path)")
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0 else {
            throw ApplicationRuntimeError.invalid("无法检查 TUN 运行目录：\(directory.path)，errno=\(errno)")
        }
        guard hasSafeOwnership(owner: info.st_uid, mode: info.st_mode) else {
            throw ApplicationRuntimeError.invalid("TUN 运行目录所有权或权限无效：uid=\(info.st_uid)，mode=\(String(info.st_mode, radix: 8))")
        }
    }

    private enum ApplicationRuntimeError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let message): return message }
        }
    }
}

/// Open once with O_NOFOLLOW. A privileged process must never write status by
/// reopening a user-controlled pathname (symlink/hard-link replacement).
final class TunControlFile {
    let fd: Int32
    init(path: String, uid: uid_t, writable: Bool) throws {
        fd = open(path, (writable ? O_RDWR : O_RDONLY) | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        var info = stat()
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == uid, info.st_nlink == 1, info.st_mode & 0o077 == 0,
              info.st_size <= 8192 else {
            close(fd)
            throw CocoaError(.fileReadNoPermission)
        }
    }
    deinit { close(fd) }
    var recentlyModified: Bool {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return false }
        let age = Date().timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec)
        return age >= -1 && age < 12
    }
    func read() -> Data? {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_nlink == 1 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 128)
        let count = pread(fd, &bytes, bytes.count, 0)
        guard count > 0 else { return nil }
        return Data(bytes.prefix(count))
    }
    func publish(_ status: TunSessionStatus) {
        guard let data = try? JSONEncoder().encode(status) else { return }
        data.withUnsafeBytes { buffer in
            _ = pwrite(fd, buffer.baseAddress, buffer.count, 0)
        }
        _ = ftruncate(fd, off_t(data.count))
    }
}

/// Lease uses changing bytes + monotonic time; wall-clock changes cannot keep
/// an orphan alive. Removing the lease requests immediate shutdown.
struct TunLeaseWatchdog {
    var lastValue: Data?
    var lastChange: TimeInterval
    let timeout: TimeInterval
    mutating func isAlive(value: Data?, now: TimeInterval) -> Bool {
        guard let value, !value.isEmpty else { return false }
        if value != lastValue { lastValue = value; lastChange = now }
        return now - lastChange < timeout
    }
}

final class TunSupervisor {
    private let lock = NSLock()
    private var stopping = false
    private var stopSignal: Int32?
    private var signalSenderPID: Int32?
    private var signalSenderUID: UInt32?
    private var signalSenderName: String?
    func requestStop(signal: Int32? = nil, senderPID: Int32? = nil, senderUID: UInt32? = nil, senderName: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopping else { return }
        stopping = true
        stopSignal = signal
        signalSenderPID = senderPID
        signalSenderUID = senderUID
        signalSenderName = senderName
    }
    private var shouldStop: Bool { lock.lock(); defer { lock.unlock() }; return stopping }

    private var requestedStopStatus: TunSessionStatus? {
        lock.lock()
        let requested = stopping
        let signal = stopSignal
        let senderPID = signalSenderPID
        let senderUID = signalSenderUID
        let senderName = signalSenderName
        lock.unlock()
        guard requested else { return nil }
        let name = signal.map { $0 == SIGTERM ? "SIGTERM" : $0 == SIGINT ? "SIGINT" : "\($0)" }
        let sender = senderPID.map { "；发送进程：\(senderName ?? "未知")（PID \($0)" +
            (senderUID.map { "，UID \($0)" } ?? "") + "）" } ?? ""
        return .init(state: "stopped", message: "TUN 收到停止信号" + (name.map { "（\($0)）" } ?? "") + sender,
                     stopReason: signal == nil ? .requested : .systemSignal, signal: signal,
                     signalSenderPID: senderPID, signalSenderUID: senderUID, signalSenderName: senderName)
    }

    /// Also exercised unprivileged with a fixture child in the test target.
    @discardableResult
    func run(executable: URL, arguments: [String], lease: TunControlFile, status: TunControlFile,
             leaseTimeout: TimeInterval = 10, startupTimeout: TimeInterval = 15) throws -> TunSessionStatus {
        if let result = requestedStopStatus {
            status.publish(result)
            return result
        }
        var watchdog = TunLeaseWatchdog(lastChange: ProcessInfo.processInfo.systemUptime, timeout: leaseTimeout)
        guard lease.recentlyModified, watchdog.isAlive(value: lease.read(), now: ProcessInfo.processInfo.systemUptime) else {
            let result = TunSessionStatus(state: "stopped", message: "启动租约已失效：心跳文件被移除或超过 12 秒未更新，未启动核心。",
                                          stopReason: .leaseExpired)
            status.publish(result)
            return result
        }
        let child = Process()
        child.executableURL = executable
        child.arguments = arguments
        // Do not inherit root's proxy or dynamic-loader environment.
        child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/var/empty"]
        child.currentDirectoryURL = executable.deletingLastPathComponent()
        let capture = ProcessOutputCapture()
        child.standardOutput = capture.pipe
        child.standardError = capture.pipe
        do { try child.run() }
        catch { capture.finish(); status.publish(.init(state: "failed", message: error.localizedDescription)); throw error }
        let started = ProcessInfo.processInfo.systemUptime
        var ready = false
        var failure: String?
        var lastPublished: TimeInterval = 0
        while child.isRunning {
            let now = ProcessInfo.processInfo.systemUptime
            if shouldStop || !watchdog.isAlive(value: lease.read(), now: now) { break }
            let output = String(decoding: capture.snapshot(), as: UTF8.self)
            if output.contains("sing-box started") { ready = true }
            if !ready && now - started > startupTimeout { failure = "TUN 启动超时"; break }
            if now - lastPublished >= 0.5 {
                status.publish(.init(state: ready ? "running" : "starting", message: ""))
                lastPublished = now
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let unexpectedExit = !child.isRunning
        if child.isRunning {
            child.terminate()
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
        child.waitUntilExit()
        capture.finish()
        let result: TunSessionStatus
        if let requested = requestedStopStatus {
            result = requested
        } else if unexpectedExit || failure != nil {
            let tail = String(decoding: capture.snapshot(maxBytes: 2048), as: UTF8.self)
            result = .init(state: "failed", message: (failure ?? "TUN 核心已退出（退出码 \(child.terminationStatus)）") + "\n" + tail)
        } else {
            result = .init(state: "stopped", message: "TUN 心跳租约失效，已停止核心", stopReason: .leaseExpired)
        }
        status.publish(result)
        return result
    }
}

enum TunRuntimeFactory {
    static func makeTemporary() throws -> URL {
        try make(template: "/private/var/run/hopworld-tun.XXXXXXXX")
    }

    static func make(template: String) throws -> URL {
        var bytes = Array(template.utf8)
        bytes.append(0)
        let created = bytes.withUnsafeMutableBufferPointer { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            return mkdtemp(UnsafeMutableRawPointer(base).assumingMemoryBound(to: CChar.self)) != nil
        }
        guard created else { throw CocoaError(.fileWriteUnknown) }
        let path = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

/// Root helper for one app session. It copies and hashes the two files, then
/// runs sing-box with fixed arguments. Callers cannot supply a shell.
final class TunHelperServer {
    private let lock = NSLock()
    private var stopRequested = false
    private var activeSupervisor: TunSupervisor?

    func requestStop(signal: Int32? = nil, senderPID: Int32? = nil, senderUID: UInt32? = nil, senderName: String? = nil) {
        lock.lock()
        stopRequested = true
        let supervisor = activeSupervisor
        lock.unlock()
        supervisor?.requestStop(signal: signal, senderPID: senderPID, senderUID: senderUID, senderName: senderName)
    }

    private func stopSession() {
        lock.lock()
        let supervisor = activeSupervisor
        lock.unlock()
        supervisor?.requestStop()
    }

    private func beginSession() -> TunSupervisor? {
        lock.lock()
        defer { lock.unlock() }
        guard !stopRequested else { return nil }
        // A stopped session must not leave its stop flag on the next session.
        let supervisor = TunSupervisor()
        activeSupervisor = supervisor
        return supervisor
    }

    private func endSession(_ supervisor: TunSupervisor) {
        lock.lock()
        defer { lock.unlock() }
        if activeSupervisor === supervisor { activeSupervisor = nil }
    }

    private var shouldStop: Bool { lock.lock(); defer { lock.unlock() }; return stopRequested }

    func serve(owner: uid_t, socketPath: String = TunHelperChannel.socketPath, idleTimeout: TimeInterval = 15,
               makeRuntime: () throws -> URL = { try TunRuntimeFactory.makeTemporary() }) -> Int32 {
        unlink(socketPath)
        let listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { return 1 }
        defer { close(listenFD); unlink(socketPath) }
        _ = fcntl(listenFD, F_SETFD, FD_CLOEXEC)
        guard TunHelperSocket.bind(listenFD, socketPath),
              chown(socketPath, owner, gid_t(bitPattern: Int32(-1))) == 0,
              chmod(socketPath, 0o600) == 0,
              listen(listenFD, 1) == 0
        else {
            FileHandle.standardError.write(Data("无法创建 TUN 辅助套接字：\(socketPath)，errno=\(errno)\n".utf8))
            return 1
        }
        // The app connects as soon as the socket exists. Keep the accept open
        // long enough that a slow return from the administrator dialog cannot
        // tear the helper down before that connection arrives.
        guard let client = TunHelperSocket.accept(listenFD, timeout: 90), !shouldStop else { return 0 }
        defer { close(client) }
        var peer = uid_t()
        var peerGroup = gid_t()
        guard getpeereid(client, &peer, &peerGroup) == 0, peer == owner else { return 77 }
        var preparedCore: (runtime: URL, binary: URL, digest: String)?
        defer { if let preparedCore { Self.removeRuntime(preparedCore.runtime) } }
        var lastActivity = ProcessInfo.processInfo.systemUptime
        while !shouldStop {
            let remaining = idleTimeout - (ProcessInfo.processInfo.systemUptime - lastActivity)
            guard remaining > 0, let request = TunHelperSocket.readRequest(client, timeout: remaining),
                  !shouldStop else { return 0 }
            lastActivity = ProcessInfo.processInfo.systemUptime
            switch request.op {
            case "ping":
                guard TunHelperSocket.write(TunHelperResponse(ok: true, message: ""), client) else { return 0 }
            case "quit":
                _ = TunHelperSocket.write(TunHelperResponse(ok: true, message: ""), client)
                return 0
            case "stop":
                stopSession()
                guard TunHelperSocket.write(TunHelperResponse(ok: true, message: ""), client) else { return 0 }
            case "start":
                let runtime: URL
                do { runtime = try makeRuntime() } catch {
                    _ = TunHelperSocket.write(TunHelperResponse(ok: false, message: error.localizedDescription), client)
                    continue
                }
                var accepted = false
                do {
                    defer {
                        if preparedCore?.runtime == runtime {
                            try? FileManager.default.removeItem(at: runtime.appendingPathComponent("config.json"))
                        } else {
                            Self.removeRuntime(runtime)
                        }
                    }
                    let staged = try Self.stage(request, owner: owner, runtime: runtime)
                    guard let supervisor = beginSession() else { throw TunHelperFailure("TUN 辅助服务正在停止，未启动核心。") }
                    defer { endSession(supervisor) }
                    let binary: URL
                    if let preparedCore, preparedCore.digest == request.binaryDigest {
                        binary = preparedCore.binary
                    } else {
                        if let preparedCore { Self.removeRuntime(preparedCore.runtime) }
                        // Every request is still copied and hashed by stage; retain only the verified executable.
                        preparedCore = (runtime, staged.binary, request.binaryDigest!)
                        binary = staged.binary
                    }
                    guard TunHelperSocket.write(TunHelperResponse(ok: true, message: ""), client) else { return 0 }
                    accepted = true
                    _ = try supervisor.run(executable: binary,
                        arguments: ["run", "-c", staged.config.path], lease: staged.lease, status: staged.status)
                } catch {
                    if !accepted {
                        _ = TunHelperSocket.write(TunHelperResponse(ok: false, message: error.localizedDescription), client)
                    }
                }
                lastActivity = ProcessInfo.processInfo.systemUptime
            default:
                guard TunHelperSocket.write(TunHelperResponse(ok: false, message: "不支持的 TUN 辅助操作。"), client) else { return 0 }
            }
        }
        return 0
    }

    struct StagedJob {
        let runtime: URL
        let binary: URL
        let config: URL
        let lease: TunControlFile
        let status: TunControlFile
    }

    static func stage(_ request: TunHelperRequest, owner: uid_t, runtime: URL) throws -> StagedJob {
        guard request.op == "start",
              let binaryPath = request.binary, let configPath = request.config,
              let leasePath = request.lease, let statusPath = request.status,
              let binaryDigest = request.binaryDigest, let configDigest = request.configDigest
        else { throw TunHelperFailure("TUN 启动请求不完整。") }
        let binary = try copyOwned(binaryPath, owner: owner, digest: binaryDigest, maxBytes: 96 * 1024 * 1024,
                                    to: runtime.appendingPathComponent("sing-box"), mode: 0o700)
        let config = try copyOwned(configPath, owner: owner, digest: configDigest, maxBytes: 1024 * 1024,
                                    to: runtime.appendingPathComponent("config.json"), mode: 0o600)
        let lease = try TunControlFile(path: leasePath, uid: owner, writable: false)
        let status = try TunControlFile(path: statusPath, uid: owner, writable: true)
        return StagedJob(runtime: runtime, binary: binary, config: config, lease: lease, status: status)
    }

    static func removeRuntime(_ runtime: URL) {
        for name in ["sing-box", "config.json"] {
            try? FileManager.default.removeItem(at: runtime.appendingPathComponent(name))
        }
        try? FileManager.default.removeItem(at: runtime)
    }

    private static func copyOwned(_ path: String, owner: uid_t, digest: String, maxBytes: Int, to destination: URL,
                                  mode: mode_t) throws -> URL {
        guard isSafePath(path), digest.count == 64, digest.allSatisfy(\.isHexDigit) else {
            throw TunHelperFailure("TUN 启动文件路径或校验值无效。")
        }
        let source = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard source >= 0 else { throw TunHelperFailure("无法打开 TUN 启动文件：\(path)") }
        defer { close(source) }
        var info = stat()
        guard fstat(source, &info) == 0, info.st_uid == owner, info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o022 == 0, info.st_size > 0,
              info.st_size <= maxBytes
        else { throw TunHelperFailure("TUN 启动文件所有权或权限无效：\(path)") }
        FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: mode])
        let output = open(destination.path, O_WRONLY | O_TRUNC | O_CLOEXEC)
        guard output >= 0 else { throw TunHelperFailure("无法写入 TUN 运行副本。") }
        defer { close(output) }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var total = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(source, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            total += count
            guard total <= maxBytes else { throw TunHelperFailure("TUN 启动文件超过大小限制。") }
            hasher.update(data: Data(buffer.prefix(count)))
            var written = 0
            while written < count {
                let step = buffer.withUnsafeBytes { raw -> Int in
                    Darwin.write(output, raw.baseAddress!.advanced(by: written), count - written)
                }
                if step < 0 && errno == EINTR { continue }
                guard step > 0 else { throw TunHelperFailure("写入 TUN 运行副本失败。") }
                written += step
            }
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == digest.lowercased() else { throw TunHelperFailure("TUN 启动文件校验不符，已拒绝执行。") }
        guard fchmod(output, mode) == 0 else { throw TunHelperFailure("无法设置 TUN 运行副本权限。") }
        return destination
    }

    private static func isSafePath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("\0") &&
            !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }
}

private struct TunHelperFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private var tunSignalWriteFD: Int32 = -1

struct TunTerminationSignal {
    var number: Int32 = 0
    var senderPID: Int32 = 0
    var senderUID: UInt32 = 0

    var senderName: String? {
        guard senderPID > 0 else { return nil }
        var name = [CChar](repeating: 0, count: 256)
        guard proc_name(senderPID, &name, UInt32(name.count)) > 0 else { return nil }
        return String(cString: name)
    }
}

enum TunTerminationSignals {
    /// Process-lifetime handlers use only an async-signal-safe pipe write;
    /// resolving process names and stopping the core happen on a normal queue.
    static func install(_ handler: @escaping (TunTerminationSignal) -> Void) throws -> DispatchSourceRead {
        guard tunSignalWriteFD == -1 else { throw TunHelperFailure("停止信号监听已启动。") }
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw TunHelperFailure("无法创建停止信号通道。") }
        for fd in descriptors {
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
                close(descriptors[0]); close(descriptors[1])
                throw TunHelperFailure("无法配置停止信号通道。")
            }
        }
        tunSignalWriteFD = descriptors[1]
        var action = sigaction()
        sigemptyset(&action.sa_mask)
        sigaddset(&action.sa_mask, SIGTERM)
        sigaddset(&action.sa_mask, SIGINT)
        action.sa_flags = SA_SIGINFO | SA_RESTART
        action.__sigaction_u.__sa_sigaction = { number, info, _ in
            let savedErrno = errno
            var event = TunTerminationSignal(number: number, senderPID: info?.pointee.si_pid ?? 0,
                                             senderUID: info?.pointee.si_uid ?? 0)
            _ = withUnsafePointer(to: &event) { Darwin.write(tunSignalWriteFD, $0, MemoryLayout<TunTerminationSignal>.size) }
            errno = savedErrno
        }
        var installed: [(Int32, sigaction)] = []
        for number in [SIGTERM, SIGINT] {
            var previous = sigaction()
            guard sigaction(number, &action, &previous) == 0 else {
                for (number, var previous) in installed { _ = sigaction(number, &previous, nil) }
                tunSignalWriteFD = -1
                close(descriptors[0]); close(descriptors[1])
                throw TunHelperFailure("无法监听停止信号。")
            }
            installed.append((number, previous))
        }
        // The descriptors stay open until process exit so a late signal cannot
        // write to a reused descriptor; CLOEXEC keeps them out of the core.
        let readFD = descriptors[0]
        let source = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: .global())
        source.setEventHandler {
            while true {
                var event = TunTerminationSignal()
                let count = withUnsafeMutablePointer(to: &event) { Darwin.read(readFD, $0, MemoryLayout<TunTerminationSignal>.size) }
                if count < 0 && errno == EINTR { continue }
                guard count == MemoryLayout<TunTerminationSignal>.size else { return }
                handler(event)
            }
        }
        source.resume()
        return source
    }
}
