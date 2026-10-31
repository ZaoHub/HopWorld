import Darwin
import Foundation

// First launch in an app session asks for an administrator. --serve then stays
// up and accepts only start/stop/ping/quit from that user. No setuid, launchd
// job, arbitrary shell, or install that survives the app.
func runSupervisor() -> Int32 {
  guard geteuid() == 0 else { return 64 }
  do { try TunProcessIsolation.detachFromLauncher() }
  catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    return 77
  }
  if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--serve" {
    guard let owner = uid_t(CommandLine.arguments[2]), owner != 0 else { return 64 }
    return runResident(owner: owner)
  }
  guard CommandLine.arguments.count == 4, let owner = uid_t(CommandLine.arguments[3]), owner != 0 else {
    return 64
  }
  return runOneShot(owner: owner)
}

func runResident(owner: uid_t) -> Int32 {
  let runtime = validatedRuntime()
  guard runtime != nil else { return 77 }
  defer { cleanupRuntime(runtime!) }
  guard let lockFD = acquireTunLock() else {
    FileHandle.standardError.write(Data("已有跃界应用代理正在运行，请先断开另一个实例。\n".utf8))
    return 75
  }
  defer { close(lockFD) }
  let server = TunHelperServer()
  let signals: DispatchSourceRead
  do {
    signals = try TunTerminationSignals.install { event in
      server.requestStop(signal: event.number, senderPID: event.senderPID > 0 ? event.senderPID : nil,
                         senderUID: event.senderPID > 0 ? event.senderUID : nil, senderName: event.senderName)
    }
  } catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    return 77
  }
  defer { signals.cancel() }
  let code = server.serve(owner: owner)
  return code
}

func runOneShot(owner: uid_t) -> Int32 {
  guard let runtime = validatedRuntime() else { return 77 }
  defer { cleanupRuntime(runtime) }
  var status: TunControlFile?
  do {
    let control = try TunControlFile(path: CommandLine.arguments[2], uid: owner, writable: true)
    status = control
    let lease = try TunControlFile(path: CommandLine.arguments[1], uid: owner, writable: false)
    guard let lockFD = acquireTunLock() else {
      control.publish(.init(state: "failed", message: "已有跃界应用代理正在运行，请先断开另一个实例。"))
      return 75
    }
    defer { close(lockFD) }
    let supervisor = TunSupervisor()
    let signals = try TunTerminationSignals.install { event in
      supervisor.requestStop(signal: event.number, senderPID: event.senderPID > 0 ? event.senderPID : nil,
                             senderUID: event.senderPID > 0 ? event.senderUID : nil, senderName: event.senderName)
    }
    defer { signals.cancel() }
    let result = try supervisor.run(
      executable: runtime.appendingPathComponent("sing-box"),
      arguments: ["run", "-c", runtime.appendingPathComponent("config.json").path],
      lease: lease, status: control)
    return result.state == "failed" ? 1 : 0
  } catch {
    status?.publish(.init(state: "failed", message: "TUN 监护程序启动失败：\(error.localizedDescription)"))
    return 1
  }
}

func validatedRuntime() -> URL? {
  let runtime = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    .deletingLastPathComponent()
  do {
    try TunRuntimeDirectory.validate(runtime)
    return runtime
  } catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    return nil
  }
}

func cleanupRuntime(_ runtime: URL) {
  for name in ["supervisor", "sing-box", "config.json", "launch.log"] {
    try? FileManager.default.removeItem(at: runtime.appendingPathComponent(name))
  }
  try? FileManager.default.removeItem(at: runtime)
}

func acquireTunLock() -> Int32? {
  let lockFD = open("/private/var/run/hopworld-tun.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
  guard lockFD >= 0 else { return nil }
  var info = stat()
  guard fstat(lockFD, &info) == 0, info.st_uid == 0, info.st_mode & S_IFMT == S_IFREG,
    flock(lockFD, LOCK_EX | LOCK_NB) == 0
  else {
    close(lockFD)
    return nil
  }
  return lockFD
}

exit(runSupervisor())
