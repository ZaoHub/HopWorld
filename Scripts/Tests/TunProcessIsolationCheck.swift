import Foundation
import Darwin

/// Runs only disposable, unprivileged processes; no network/TUN or administrator authorization.
@main
struct TunProcessIsolationCheck {
    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    private static func run() throws {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--fixture" {
            try runFixture(directory: URL(fileURLWithPath: CommandLine.arguments[3]),
                           isolated: CommandLine.arguments[2] != "inherited")
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hopworld-isolation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for mode in ["inherited", "isolated-signal", "isolated-lease"] {
            try check(mode: mode, root: root)
        }
        print("TUN process isolation checks passed: inherited group reproduces SIGTERM; isolated helper survives launcher exit; direct SIGTERM and lease cleanup still stop the core.")
    }

    private static func runFixture(directory: URL, isolated: Bool) throws {
        if isolated { try TunProcessIsolation.detachFromLauncher() }
        let supervisor = TunSupervisor()
        let source = try TunTerminationSignals.install { event in
            supervisor.requestStop(signal: event.number, senderPID: event.senderPID, senderUID: event.senderUID,
                                   senderName: event.senderName)
        }
        defer { source.cancel() }
        try Data("\(getpid())".utf8).write(to: directory.appendingPathComponent("pid"))
        let lease = try TunControlFile(path: directory.appendingPathComponent("lease").path, uid: getuid(), writable: false)
        let status = try TunControlFile(path: directory.appendingPathComponent("status.json").path, uid: getuid(), writable: true)
        try supervisor.run(executable: URL(fileURLWithPath: "/bin/sh"),
                           arguments: ["-c", "echo 'sing-box started'; exec /bin/sleep 20"],
                           lease: lease, status: status, leaseTimeout: 5)
        try Data("exited".utf8).write(to: directory.appendingPathComponent("exited"))
    }

    private static func check(mode: String, root: URL) throws {
        let directory = root.appendingPathComponent(mode)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        for name in ["lease", "status.json"] {
            guard FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path,
                                                  contents: Data("pulse".utf8), attributes: [.posixPermissions: 0o600]) else {
                throw failure("无法创建测试控制文件")
            }
        }
        let wrapper = Process()
        wrapper.executableURL = URL(fileURLWithPath: "/bin/sh")
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        let command = "(trap '' HUP; exec \(quote(executable)) --fixture \(quote(mode)) \(quote(directory.path))) </dev/null >/dev/null 2>&1 & exec /bin/sleep 20"
        wrapper.arguments = ["-c", command]
        wrapper.standardInput = FileHandle.nullDevice
        wrapper.standardOutput = FileHandle.nullDevice
        wrapper.standardError = FileHandle.nullDevice
        try wrapper.run()
        var fixturePID: Int32 = 0
        defer {
            // PIDs and process groups belong only to this fixture invocation.
            if fixturePID > 1, kill(fixturePID, 0) == 0 {
                kill(fixturePID, SIGTERM)
                _ = wait(seconds: 2) { FileManager.default.fileExists(atPath: directory.appendingPathComponent("exited").path) }
                if kill(fixturePID, 0) == 0 { kill(fixturePID, SIGKILL) }
            }
            if wrapper.isRunning { kill(-wrapper.processIdentifier, SIGKILL) }
            wrapper.waitUntilExit()
        }
        guard wait(seconds: 4, until: { readStatus(directory)?.state == "running" }) else {
            throw failure("\(mode): 测试核心未启动")
        }
        let pidText = try String(contentsOf: directory.appendingPathComponent("pid"), encoding: .utf8)
        guard let pid = Int32(pidText), pid > 1 else { throw failure("无效测试 PID") }
        fixturePID = pid
        let fixtureGroup = getpgid(pid)
        let wrapperGroup = getpgid(wrapper.processIdentifier)
        guard mode == "inherited" ? fixtureGroup == wrapperGroup : fixtureGroup == pid else {
            throw failure("\(mode): 进程组不符合预期")
        }
        wrapper.terminate()
        if mode == "inherited" {
            guard wait(seconds: 3, until: { readStatus(directory)?.stopReason == .systemSignal }) else {
                throw failure("旧启动方式未复现授权启动器进程组 SIGTERM 传播")
            }
            print("Baseline reproduced: inherited helper stopped on launcher SIGTERM.")
            return
        }
        Thread.sleep(forTimeInterval: 0.4)
        guard kill(pid, 0) == 0, readStatus(directory)?.state == "running" else {
            throw failure("\(mode): 隔离后的辅助进程仍被启动器 SIGTERM 中止")
        }
        if mode == "isolated-signal" {
            kill(pid, SIGTERM)
        } else {
            try FileManager.default.removeItem(at: directory.appendingPathComponent("lease"))
        }
        let expected: TunStopReason = mode == "isolated-signal" ? .systemSignal : .leaseExpired
        guard wait(seconds: 3, until: { readStatus(directory)?.stopReason == expected }) else {
            throw failure("\(mode): 隔离后直接信号或租约清理失效")
        }
        if mode == "isolated-signal" {
            let status = readStatus(directory)
            guard status?.signal == SIGTERM, status?.signalSenderPID == getpid(),
                  status?.signalSenderUID == getuid(), status?.signalSenderName?.isEmpty == false else {
                throw failure("直接 SIGTERM 未记录正确发送进程 PID、UID 和进程名")
            }
        }
        guard wait(seconds: 2, until: { FileManager.default.fileExists(atPath: directory.appendingPathComponent("exited").path) }) else {
            throw failure("\(mode): 停止后辅助进程未正常退出")
        }
        print("Passed: \(mode), launcher PGID \(wrapperGroup), helper PGID \(fixtureGroup).")
    }

    private static func readStatus(_ directory: URL) -> TunSessionStatus? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("status.json")) else { return nil }
        return try? JSONDecoder().decode(TunSessionStatus.self, from: data)
    }

    private static func wait(seconds: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return condition()
    }

    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "TunProcessIsolationCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
