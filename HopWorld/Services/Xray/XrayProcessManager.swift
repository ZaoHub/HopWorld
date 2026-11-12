import Combine
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
            let executable = try await SingBoxBridgeBinary.shared.url()
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

/// The LAN core always listens on this pair. Phones keep the same address across launches.
enum LanForwardPorts {
    static let firstChoice = 17_890
    static let socksChoice = 17_891

    struct Hold {
        var http: Int
        var socks: Int
        fileprivate var descriptors: [Int32]
        mutating func release() {
            descriptors.forEach { close($0) }
            descriptors.removeAll()
        }
    }

    /// HTTP is 17890 and SOCKS5 is 17891. A busy pair fails instead of moving to the next ports.
    static func reserve(avoiding: Set<Int>) throws -> Hold {
        if avoiding.contains(firstChoice) || avoiding.contains(socksChoice) {
            throw SoftwareRouterError.noFreePort
        }
        guard let httpFD = bind(firstChoice) else { throw SoftwareRouterError.noFreePort }
        guard let socksFD = bind(socksChoice) else {
            close(httpFD)
            throw SoftwareRouterError.noFreePort
        }
        return Hold(http: firstChoice, socks: socksChoice, descriptors: [httpFD, socksFD])
    }

    /// Earlier launches can leave a LAN core on 17890. Only those cores are ended, not the main connection.
    static func endStaleLanCores() async {
        let text = await Task.detached(priority: .utility) { () -> String in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/ps")
            task.arguments = ["-axo", "pid=,command="]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            guard (try? task.run()) != nil else { return "" }
            // Drain first. Waiting while the pipe is full never returns.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }.value
        let selfPID = ProcessInfo.processInfo.processIdentifier
        for line in text.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(
                maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" }
            )
            guard parts.count == 2, let pid = Int32(parts[0]), pid > 0, pid != selfPID else { continue }
            guard isStaleLanCore(command: String(parts[1])) else { continue }
            kill(pid, SIGKILL)
        }
    }

    static func isStaleLanCore(command: String) -> Bool {
        let lower = command.lowercased()
        return lower.contains("xray") && lower.contains("lan-") && lower.contains(".json")
            && !lower.contains("config-")
    }

    /// Session directories created under the temp folder. Storage cleanup uses the same list.
    static let sessionDirectoryPrefixes = [
        "hopworld-singbox-", "hopworld-tun-", "HopWorld-batch-", "HopWorld-subscription-", "HopWorld-runtime-"
    ]

    static func isOrphanSessionCore(command: String) -> Bool {
        sessionDirectoryPrefixes.contains { command.contains($0) }
    }

    static func belongsToProcessTree(pid: Int32, root: Int32, parents: [Int32: Int32]) -> Bool {
        if pid == root { return true }
        var current = pid
        var seen = Set<Int32>()
        while seen.insert(current).inserted, current > 1 {
            guard let parent = parents[current], parent != current else { return false }
            if parent == root { return true }
            current = parent
        }
        return false
    }

    private static func bind(_ port: Int) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("0.0.0.0")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { close(fd); return nil }
        return fd
    }
}

struct LanInterface: Equatable {
    var address: String
    var isUp: Bool
    var isLoopback: Bool
}

enum LanAddresses {
    /// shortcut: IPv4 only, add IPv6 when a LAN has no IPv4 address.
    static func current() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return [] }
        defer { freeifaddrs(head) }
        var items: [LanInterface] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let current = cursor {
            let info = current.pointee
            if let addr = info.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let flags = Int32(info.ifa_flags)
                    items.append(LanInterface(
                        address: String(cString: host),
                        isUp: flags & IFF_UP != 0,
                        isLoopback: flags & IFF_LOOPBACK != 0))
                }
            }
            cursor = info.ifa_next
        }
        return usable(items)
    }

    static func usable(_ interfaces: [LanInterface]) -> [String] {
        var seen: [String] = []
        for item in interfaces where item.isUp && !item.isLoopback {
            let ip = item.address
            guard ip.contains("."), !ip.hasPrefix("127."), !ip.hasPrefix("169.254."), ip != "0.0.0.0" else { continue }
            if !seen.contains(ip) { seen.append(ip) }
        }
        return seen
    }
}

/// Software-router connectivity choices. Stored apart from the main app settings.
enum SoftwareRouteProbe {
    /// Old soft-route ids, kept so a saved Google or YouTube choice still maps onto the connectivity list.
    private static let legacyTargetIDs = [
        "Google": "https://www.google.com/generate_204",
        "YouTube": "https://www.youtube.com/generate_204"
    ]

    struct Rank: Equatable, Codable {
        var passedIDs: Set<String>
        var latencyMs: Int?
        /// Raw exit from this probe. The list shows Chinese, and English only when no Chinese name exists.
        var exit: SoftwareRouteExit? = nil
    }

    /// Country and city are Chinese. English remains only when that place has no Chinese name.
    static func exitText(_ exit: SoftwareRouteExit?, showChinese: Bool) -> String? {
        guard let exit else { return nil }
        let country = showChinese
            ? chineseCountry(exit.country, code: exit.countryCode)
            : ExitMetadataLocalization.country(exit.country, countryCode: exit.countryCode, showChinese: false)
        let city: String? = {
            let trimmed = exit.city?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { return nil }
            let localized = ExitMetadataLocalization.city(trimmed, countryCode: exit.countryCode, showChinese: showChinese)
            return localized == "未知" ? nil : localized
        }()
        let place = [country, city].compactMap { $0 }
        if !place.isEmpty { return place.joined(separator: " · ") }
        let ip = exit.ip?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ip.isEmpty ? nil : ip
    }

    /// Chinese country name. The English label is used only when no Chinese name exists.
    private static func chineseCountry(_ raw: String?, code: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolved = ExitMetadataLocalization.countryCode(from: code) ?? ExitMetadataLocalization.countryCode(from: trimmed)
        if let resolved {
            let name = CountryResolver.displayName(for: resolved)
            if hasChinese(name) { return name }
            if let english = Locale(identifier: "en_US").localizedString(forRegionCode: resolved), !english.isEmpty {
                return english
            }
        }
        if hasChinese(trimmed) { return trimmed }
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func hasChinese(_ value: String) -> Bool {
        value.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
    }

    static func title(_ target: AppProbeTarget) -> String {
        target.displayName
    }

    static func passes(_ passedIDs: Set<String>, targets: [AppProbeTarget]) -> Bool {
        targets.contains { passedIDs.contains($0.id) }
    }

    /// 测速时能取到出口 IP 的节点，经局域网代理的完整 HTTPS 更可能可用。
    static func hasVerifiedExit(_ rank: Rank?) -> Bool {
        guard let rank else { return false }
        let ip = rank.exit?.ip?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !ip.isEmpty
    }

    /// Earlier selected targets outrank later ones, then the faster probe wins.
    static func rank(_ lhs: Rank, before rhs: Rank, order: [AppProbeTarget]) -> Bool {
        let leftExit = hasVerifiedExit(lhs)
        let rightExit = hasVerifiedExit(rhs)
        if leftExit != rightExit { return leftExit }
        for target in order {
            let left = lhs.passedIDs.contains(target.id)
            let right = rhs.passedIDs.contains(target.id)
            if left != right { return left }
        }
        return (lhs.latencyMs ?? Int.max) < (rhs.latencyMs ?? Int.max)
    }

    /// Empty saved ids mean every current address. Unknown old ids fall back to the whole list.
    static func targets(from ids: [String], available: [AppProbeTarget]) -> [AppProbeTarget] {
        guard !available.isEmpty else { return [] }
        if ids.isEmpty { return available }
        let wanted = Set(ids.map { legacyTargetIDs[$0] ?? $0 })
        let picked = available.filter { wanted.contains($0.id) }
        return picked.isEmpty ? available : picked
    }
}

struct SoftwareRouteExit: Equatable, Sendable, Codable {
    var country: String?
    var countryCode: String?
    var city: String?
    var ip: String?
}

/// Which subscription groups the software router may test. A disabled subscription stays eligible.
enum SoftwareRouteGroups {
    static let manual = "manual"

    static func id(for node: ProxyNode) -> String {
        node.subscriptionID?.uuidString ?? manual
    }

    /// `nil` means every group. Individually disabled or pending-removal nodes stay out.
    static func includes(_ node: ProxyNode, selection: Set<String>?) -> Bool {
        guard node.enabled, !node.pendingRemoval else { return false }
        guard let selection else { return true }
        return selection.contains(id(for: node))
    }
}

/// The soft route restarts its own last node. The main connection is not consulted.
enum SoftwareRouteRestore {
    static func nodeID(saved: String?, nodes: [ProxyNode]) -> UUID? {
        guard let saved, let id = UUID(uuidString: saved) else { return nil }
        guard let node = nodes.first(where: { $0.id == id }), node.enabled, !node.pendingRemoval else { return nil }
        return id
    }
}

/// Interval timers for the software router. Independent of the main app's schedules.
enum SoftwareRouteSchedule {
    /// A missing last run is not due, so turning a timer on does not fire immediately.
    static func isDue(now: Date, enabled: Bool, interval: TimeInterval, lastRun: Date?) -> Bool {
        guard enabled, interval > 0, let lastRun else { return false }
        return now.timeIntervalSince(lastRun) >= interval
    }
}

enum SoftwareRoutePreferences {
    private static let targetsKey = "HopWorld.softwareRoute.targets"
    private static let autoKey = "HopWorld.softwareRoute.autoSelect"
    private static let groupsKey = "HopWorld.softwareRoute.groups"
    private static let updateEnabledKey = "HopWorld.softwareRoute.updateEnabled"
    private static let updateHoursKey = "HopWorld.softwareRoute.updateHours"
    private static let updateLastKey = "HopWorld.softwareRoute.updateLast"
    private static let testEnabledKey = "HopWorld.softwareRoute.testEnabled"
    private static let testMinutesKey = "HopWorld.softwareRoute.testMinutes"
    private static let testLastKey = "HopWorld.softwareRoute.testLast"
    private static let ranksKey = "HopWorld.softwareRoute.ranks"
    private static let nodeKey = "HopWorld.softwareRoute.node"
    private static let latencyFailoverKey = "HopWorld.softwareRoute.latencyFailover"
    private static let latencyFailoverSecondsKey = "HopWorld.softwareRoute.latencyFailoverSeconds"
    private static let latencyFailoverTopKey = "HopWorld.softwareRoute.latencyFailoverTop"

    static func loadAutoSelect() -> Bool {
        UserDefaults.standard.bool(forKey: autoKey)
    }

    static func loadTargetIDs() -> [String] {
        UserDefaults.standard.stringArray(forKey: targetsKey) ?? []
    }

    static func save(targets: [AppProbeTarget], autoSelect: Bool) {
        UserDefaults.standard.set(targets.map(\.id), forKey: targetsKey)
        UserDefaults.standard.set(autoSelect, forKey: autoKey)
    }

    static func loadLatencyFailover() -> (enabled: Bool, maxSeconds: Int, topCount: Int) {
        let defaults = UserDefaults.standard
        let enabled: Bool = {
            guard defaults.object(forKey: latencyFailoverKey) != nil else { return true }
            return defaults.bool(forKey: latencyFailoverKey)
        }()
        let seconds = min(120, max(1, defaults.object(forKey: latencyFailoverSecondsKey) as? Int ?? 10))
        let top = min(100, max(1, defaults.object(forKey: latencyFailoverTopKey) as? Int ?? 10))
        return (enabled, seconds, top)
    }

    static func saveLatencyFailover(enabled: Bool, maxSeconds: Int, topCount: Int) {
        UserDefaults.standard.set(enabled, forKey: latencyFailoverKey)
        UserDefaults.standard.set(min(120, max(1, maxSeconds)), forKey: latencyFailoverSecondsKey)
        UserDefaults.standard.set(min(100, max(1, topCount)), forKey: latencyFailoverTopKey)
    }

    /// Missing key means every subscription group, including disabled ones.
    static func loadGroups() -> Set<String>? {
        guard let raw = UserDefaults.standard.stringArray(forKey: groupsKey) else { return nil }
        return Set(raw)
    }

    static func saveGroups(_ groups: Set<String>) {
        UserDefaults.standard.set(groups.sorted(), forKey: groupsKey)
    }

    static func loadIntervals() -> (updateOn: Bool, updateHours: Int, updateLast: Date?, testOn: Bool, testMinutes: Int, testLast: Date?) {
        (
            UserDefaults.standard.bool(forKey: updateEnabledKey),
            min(168, max(1, UserDefaults.standard.object(forKey: updateHoursKey) as? Int ?? 6)),
            date(forKey: updateLastKey),
            UserDefaults.standard.bool(forKey: testEnabledKey),
            min(1440, max(1, UserDefaults.standard.object(forKey: testMinutesKey) as? Int ?? 30)),
            date(forKey: testLastKey)
        )
    }

    static func saveIntervals(updateOn: Bool, updateHours: Int, updateLast: Date?, testOn: Bool, testMinutes: Int, testLast: Date?) {
        UserDefaults.standard.set(updateOn, forKey: updateEnabledKey)
        UserDefaults.standard.set(updateHours, forKey: updateHoursKey)
        UserDefaults.standard.set(updateLast?.timeIntervalSince1970, forKey: updateLastKey)
        UserDefaults.standard.set(testOn, forKey: testEnabledKey)
        UserDefaults.standard.set(testMinutes, forKey: testMinutesKey)
        UserDefaults.standard.set(testLast?.timeIntervalSince1970, forKey: testLastKey)
    }

    private static func date(forKey key: String) -> Date? {
        guard let stamp = UserDefaults.standard.object(forKey: key) as? Double else { return nil }
        return Date(timeIntervalSince1970: stamp)
    }

    /// Only rows with a measured latency. These stay off the node and off the main settings.
    static func loadRanks() -> [UUID: SoftwareRouteProbe.Rank] {
        guard let data = UserDefaults.standard.data(forKey: ranksKey) else { return [:] }
        return decodeRanks(data)
    }

    static func saveRanks(_ ranks: [UUID: SoftwareRouteProbe.Rank]) {
        UserDefaults.standard.set(encodeRanks(ranks), forKey: ranksKey)
    }

    static func encodeRanks(_ ranks: [UUID: SoftwareRouteProbe.Rank]) -> Data? {
        let shown = ranks.filter { $0.value.latencyMs != nil }
        let raw = Dictionary(uniqueKeysWithValues: shown.map { ($0.key.uuidString, $0.value) })
        return try? JSONEncoder().encode(raw)
    }

    static func consumePreviousMultiNodeIDs() -> [UUID] {
        let defaults = UserDefaults.standard
        let ids = (defaults.stringArray(forKey: "HopWorld.softwareRoute.nodes") ?? []).compactMap(UUID.init(uuidString:))
        defaults.removeObject(forKey: "HopWorld.softwareRoute.nodes")
        defaults.removeObject(forKey: "HopWorld.softwareRoute.multiFallback")
        return ids
    }

    static func loadConnectedNodeID() -> UUID? {
        guard let raw = UserDefaults.standard.string(forKey: nodeKey) else { return nil }
        return UUID(uuidString: raw)
    }

    static func saveConnectedNodeID(_ id: UUID?) {
        if let id {
            UserDefaults.standard.set(id.uuidString, forKey: nodeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: nodeKey)
        }
    }

    static func decodeRanks(_ data: Data) -> [UUID: SoftwareRouteProbe.Rank] {
        guard let raw = try? JSONDecoder().decode([String: SoftwareRouteProbe.Rank].self, from: data) else { return [:] }
        var ranks: [UUID: SoftwareRouteProbe.Rank] = [:]
        for (key, rank) in raw {
            guard let id = UUID(uuidString: key), rank.latencyMs != nil else { continue }
            ranks[id] = rank
        }
        return ranks
    }
}

enum SoftwareRouterError: LocalizedError {
    case noFreePort
    case notReady(String)

    var errorDescription: String? {
        switch self {
        case .noFreePort: return "局域网端口 17890 仍被占用"
        case .notReady(let detail): return detail
        }
    }
}

/// Own Xray process for other devices on the LAN. Never touches system proxy, TUN, or the main connection.
@MainActor
final class SoftwareRouter: ObservableObject {
    enum Phase: Equatable { case idle, connecting, connected, failed }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var nodeID: UUID?
    @Published private(set) var nodeTitle: String?
    @Published private(set) var httpPort: Int?
    @Published private(set) var socksPort: Int?
    @Published private(set) var lanAddresses: [String] = []
    @Published private(set) var message: String?
    @Published private(set) var probeRunning = false
    @Published private(set) var probeCompleted = 0
    @Published private(set) var probeTotal = 0
    @Published private(set) var passedNodeIDs: Set<UUID> = []
    @Published private(set) var ranks: [UUID: SoftwareRouteProbe.Rank] = [:]
    @Published private(set) var selectedTargets: [AppProbeTarget]
    @Published private(set) var autoSelect: Bool
    /// `nil` tests every subscription group. An explicit set can be empty.
    @Published private(set) var selectedGroupIDs: Set<String>?
    @Published private(set) var updateRunning = false
    @Published private(set) var updateCompleted = 0
    @Published private(set) var updateTotal = 0
    @Published private(set) var updateScheduleEnabled: Bool
    @Published private(set) var updateIntervalHours: Int
    @Published private(set) var testScheduleEnabled: Bool
    @Published private(set) var testIntervalMinutes: Int
    @Published private(set) var latencyFailoverEnabled: Bool
    @Published private(set) var latencyFailoverMaxSeconds: Int
    @Published private(set) var latencyFailoverTopCount: Int
    /// Index within the ranked top-N pool for latency-driven rotation.
    private(set) var failoverRotationIndex: Int = 0
    private(set) var connectedSince: Date?
    private(set) var lastLatencyFailoverCheck: Date?
    private(set) var lastLatencyFailoverAction: Date?
    private(set) var lastUpdateRun: Date?
    private(set) var lastTestRun: Date?

    private let xray = XrayProcessManager()
    private var generation = 0

    init() {
        selectedTargets = []
        autoSelect = SoftwareRoutePreferences.loadAutoSelect()
        let failover = SoftwareRoutePreferences.loadLatencyFailover()
        latencyFailoverEnabled = failover.enabled
        latencyFailoverMaxSeconds = failover.maxSeconds
        latencyFailoverTopCount = failover.topCount
        selectedGroupIDs = SoftwareRoutePreferences.loadGroups()
        let intervals = SoftwareRoutePreferences.loadIntervals()
        updateScheduleEnabled = intervals.updateOn
        updateIntervalHours = intervals.updateHours
        lastUpdateRun = intervals.updateLast
        testScheduleEnabled = intervals.testOn
        testIntervalMinutes = intervals.testMinutes
        lastTestRun = intervals.testLast
        let storedRanks = SoftwareRoutePreferences.loadRanks()
        ranks = storedRanks
        passedNodeIDs = Self.passedIDs(in: storedRanks, targets: selectedTargets)
    }

    func setUpdateSchedule(enabled: Bool) {
        guard updateScheduleEnabled != enabled else { return }
        updateScheduleEnabled = enabled
        if enabled, lastUpdateRun == nil { lastUpdateRun = Date() }
        storeIntervals()
    }

    func setUpdateInterval(hours: Int) {
        updateIntervalHours = min(168, max(1, hours))
        storeIntervals()
    }

    func setTestSchedule(enabled: Bool) {
        guard testScheduleEnabled != enabled else { return }
        testScheduleEnabled = enabled
        if enabled, lastTestRun == nil { lastTestRun = Date() }
        storeIntervals()
    }

    func setTestInterval(minutes: Int) {
        testIntervalMinutes = min(1440, max(1, minutes))
        storeIntervals()
    }

    func markUpdateRan(_ date: Date) {
        lastUpdateRun = date
        storeIntervals()
    }

    func markTestRan(_ date: Date) {
        lastTestRun = date
        storeIntervals()
    }

    private func storeIntervals() {
        SoftwareRoutePreferences.saveIntervals(
            updateOn: updateScheduleEnabled, updateHours: updateIntervalHours, updateLast: lastUpdateRun,
            testOn: testScheduleEnabled, testMinutes: testIntervalMinutes, testLast: lastTestRun
        )
    }

    func beginUpdate(total: Int) {
        updateRunning = total > 0
        updateCompleted = 0
        updateTotal = total
    }

    func noteUpdate(completed: Int) {
        updateCompleted = completed
    }

    func finishUpdate() {
        updateRunning = false
        updateCompleted = updateTotal
    }

    func isGroupSelected(_ id: String) -> Bool {
        selectedGroupIDs?.contains(id) ?? true
    }

    @discardableResult
    func setGroup(_ id: String, on: Bool, available: [String]) -> Bool {
        var next = selectedGroupIDs ?? Set(available)
        if on {
            guard !next.contains(id) else { return false }
            next.insert(id)
        } else {
            guard next.contains(id) else { return false }
            next.remove(id)
        }
        selectedGroupIDs = next
        SoftwareRoutePreferences.saveGroups(next)
        return true
    }

    var selectionSummary: String {
        selectedTargets.map(SoftwareRouteProbe.title).joined(separator: "、")
    }

    /// Matches the soft-route choices to the main app's connectivity-test addresses.
    func adoptConnectivityTargets(_ available: [AppProbeTarget]) {
        let saved = SoftwareRoutePreferences.loadTargetIDs()
        let resolved = SoftwareRouteProbe.targets(from: saved, available: available)
        if resolved.map(\.id) != saved, !resolved.isEmpty {
            SoftwareRoutePreferences.save(targets: resolved, autoSelect: autoSelect)
        }
        let sameIDs = selectedTargets.map(\.id) == resolved.map(\.id)
        let sameNames = selectedTargets.map(\.displayName) == resolved.map(\.displayName)
        guard !sameIDs || !sameNames else { return }
        selectedTargets = resolved
        passedNodeIDs = Self.passedIDs(in: ranks, targets: selectedTargets)
    }

    @discardableResult
    func toggleTarget(_ target: AppProbeTarget, on: Bool, available: [AppProbeTarget]) -> Bool {
        guard available.contains(where: { $0.id == target.id }) else { return false }
        var ids = selectedTargets.map(\.id)
        if on {
            guard !ids.contains(target.id) else { return false }
            ids.append(target.id)
        } else {
            guard ids.count > 1 else { return false }
            ids.removeAll { $0 == target.id }
        }
        selectedTargets = available.filter { ids.contains($0.id) }
        SoftwareRoutePreferences.save(targets: selectedTargets, autoSelect: autoSelect)
        passedNodeIDs = Self.passedIDs(in: ranks, targets: selectedTargets)
        return true
    }

    func setAutoSelect(_ on: Bool) {
        guard autoSelect != on else { return }
        autoSelect = on
        SoftwareRoutePreferences.save(targets: selectedTargets, autoSelect: autoSelect)
    }

    func setLatencyFailover(enabled: Bool) {
        guard latencyFailoverEnabled != enabled else { return }
        latencyFailoverEnabled = enabled
        storeLatencyFailover()
    }

    func setLatencyFailoverMaxSeconds(_ seconds: Int) {
        latencyFailoverMaxSeconds = min(120, max(1, seconds))
        storeLatencyFailover()
    }

    func setLatencyFailoverTopCount(_ count: Int) {
        latencyFailoverTopCount = min(100, max(1, count))
        storeLatencyFailover()
    }

    func noteFailoverRotationIndex(_ index: Int) {
        failoverRotationIndex = max(0, index)
    }

    func resetFailoverRotation() {
        failoverRotationIndex = 0
    }

    func noteLatencyFailoverCheck(_ date: Date) {
        lastLatencyFailoverCheck = date
    }

    func noteLatencyFailoverAction(_ date: Date) {
        lastLatencyFailoverAction = date
    }

    private func storeLatencyFailover() {
        SoftwareRoutePreferences.saveLatencyFailover(
            enabled: latencyFailoverEnabled,
            maxSeconds: latencyFailoverMaxSeconds,
            topCount: latencyFailoverTopCount
        )
    }

    func beginProbe(total: Int) {
        probeRunning = total > 0
        probeCompleted = 0
        probeTotal = total
        passedNodeIDs = []
        ranks = [:]
    }

    func noteProbe(completed: Int, ranks: [UUID: SoftwareRouteProbe.Rank]) {
        probeCompleted = completed
        self.ranks = ranks
        passedNodeIDs = Self.passedIDs(in: ranks, targets: selectedTargets)
    }

    func finishProbe(ranks: [UUID: SoftwareRouteProbe.Rank]) {
        probeRunning = false
        probeCompleted = probeTotal
        self.ranks = ranks
        passedNodeIDs = Self.passedIDs(in: ranks, targets: selectedTargets)
        SoftwareRoutePreferences.saveRanks(ranks)
    }

    private static func passedIDs(in ranks: [UUID: SoftwareRouteProbe.Rank], targets: [AppProbeTarget]) -> Set<UUID> {
        Set(ranks.compactMap { SoftwareRouteProbe.passes($0.value.passedIDs, targets: targets) ? $0.key : nil })
    }

    func cancelProbe() {
        probeRunning = false
        SoftwareRoutePreferences.saveRanks(ranks)
    }

    func start(node: ProxyNode, title: String, avoidingPorts: Set<Int>) async {
        generation += 1
        let token = generation
        phase = .connecting
        message = nil
        nodeID = node.id
        nodeTitle = title
        httpPort = nil
        socksPort = nil
        lanAddresses = []
        await xray.setTerminationHandler { [weak self] in
            Task { @MainActor in self?.noteUnexpectedExit() }
        }
        await xray.stop()
        await LanForwardPorts.endStaleLanCores()
        do {
            var held = try await reserveFixedPorts(avoiding: avoidingPorts)
            defer { held.release() }
            guard token == generation else { return }
            let http = held.http
            let socks = held.socks
            let config = try XrayConfigBuilder.buildLanForward(node: node, httpPort: http, socksPort: socks)
            let file = try XrayProcessManager.configDirectory().appendingPathComponent("lan-\(UUID().uuidString).json")
            try XrayConfigBuilder.writeJSON(config, to: file)
            held.release()
            guard token == generation else {
                try? FileManager.default.removeItem(at: file)
                return
            }
            do { try await xray.start(configURL: file) }
            catch {
                try? FileManager.default.removeItem(at: file)
                throw error
            }
            try? FileManager.default.removeItem(at: file)
            guard token == generation else { await xray.stop(); return }
            let ready = await waitUntilListening(http: http, socks: socks, token: token)
            guard token == generation else { await xray.stop(); return }
            guard await xray.isRunning(), ready else {
                let log = await xray.readRecentOutput()
                let detail = log.isEmpty ? "局域网端口未就绪" : "局域网端口未就绪：\(log.suffix(300))"
                throw SoftwareRouterError.notReady(detail)
            }
            httpPort = http
            socksPort = socks
            lanAddresses = LanAddresses.current()
            phase = .connected
            connectedSince = Date()
            SoftwareRoutePreferences.saveConnectedNodeID(node.id)
            AppLogger.shared.info("软路由已开启：\(title)，HTTP \(http)，SOCKS \(socks)。主连接未改动", category: .network)
        } catch {
            guard token == generation else { return }
            await xray.stop()
            phase = .failed
            message = error.localizedDescription
            AppLogger.shared.warning("软路由连接失败：\(error.localizedDescription)。主连接未改动", category: .network)
        }
    }

    private func reserveFixedPorts(avoiding: Set<Int>) async throws -> LanForwardPorts.Hold {
        var lastError: Error = SoftwareRouterError.noFreePort
        for attempt in 0..<8 {
            do { return try LanForwardPorts.reserve(avoiding: avoiding) }
            catch {
                lastError = error
                if attempt == 7 { break }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        throw lastError
    }

    /// `forget` is false when the app is quitting, so the next launch can start this node again.
    func stop(forget: Bool = true) async {
        generation += 1
        let wasRunning = phase == .connected || phase == .connecting
        phase = .idle
        message = nil
        httpPort = nil
        socksPort = nil
        lanAddresses = []
        connectedSince = nil
        if forget { SoftwareRoutePreferences.saveConnectedNodeID(nil) }
        await xray.stop()
        if wasRunning {
            AppLogger.shared.info("软路由已关闭。主连接未改动", category: .network)
        }
    }

    private func noteUnexpectedExit() {
        guard phase == .connected else { return }
        phase = .failed
        httpPort = nil
        socksPort = nil
        lanAddresses = []
        connectedSince = nil
        message = "软路由进程已退出，当前主连接没有改动"
    }

    private func waitUntilListening(http: Int, socks: Int, token: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if Task.isCancelled || token != generation { return false }
            let httpReady = await TCPTester.measure(host: "127.0.0.1", port: http, timeout: 0.2) != nil
            let socksReady = await TCPTester.measure(host: "127.0.0.1", port: socks, timeout: 0.2) != nil
            if httpReady && socksReady { return true }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        return false
    }
}
