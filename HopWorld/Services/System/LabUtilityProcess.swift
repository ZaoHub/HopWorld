import CoreWLAN
import Darwin
import Foundation
import Network

/// 下载和网络工具在这个进程里做。主程序只收文字进度，不承接流量和 networksetup。
enum LabUtilityProcess {
    static let flag = "--lab-utility"

    struct Event: Codable, Equatable {
        var p: Double?
        var u: String?
        var r: String?
        var e: String?
    }

    enum Command: Equatable {
        case download(url: URL, mirror: XrayDownloadMirror, folder: String)
        case diagnose(connected: Bool)
        case repairPreview
        case repair(deleteBackup: Bool)
        case flushDNS
        case networkRepairPreview
        case networkRepair
        case networkRepairRestoreHosts
        case speed(String)
        case latency(host: String, count: Int)
    }

    struct LatencyChoice: Equatable, Identifiable {
        var name: String
        var host: String
        var id: String { host }
    }

    static let latencyChoices: [LatencyChoice] = [
        LatencyChoice(name: "阿里 DNS", host: "223.5.5.5"),
        LatencyChoice(name: "阿里备用", host: "223.6.6.6"),
        LatencyChoice(name: "腾讯 DNS", host: "119.29.29.29"),
        LatencyChoice(name: "腾讯备用", host: "119.28.28.28"),
        LatencyChoice(name: "114 DNS", host: "114.114.114.114"),
        LatencyChoice(name: "114 备用", host: "114.114.115.115"),
        LatencyChoice(name: "百度 DNS", host: "180.76.76.76"),
        LatencyChoice(name: "CNNIC", host: "1.2.4.8"),
        LatencyChoice(name: "CNNIC 备用", host: "210.2.4.8"),
        LatencyChoice(name: "Cloudflare", host: "1.1.1.1"),
        LatencyChoice(name: "Cloudflare 备用", host: "1.0.0.1"),
        LatencyChoice(name: "Google", host: "8.8.8.8"),
        LatencyChoice(name: "Google 备用", host: "8.8.4.4"),
        LatencyChoice(name: "Quad9", host: "9.9.9.9"),
        LatencyChoice(name: "Quad9 备用", host: "149.112.112.112")
    ]
    static let latencyDurations = [30, 60, 300, 600]

    enum Failure: LocalizedError {
        case usage
        case message(String)

        var errorDescription: String? {
            switch self {
            case .usage: return "工具参数无效"
            case .message(let text): return text
            }
        }
    }

    private static let temporaryLock = NSLock()
    private static var activeTemporary: URL?
    private static var terminationSource: DispatchSourceSignal?

    static func trackTemporary(_ url: URL?) {
        temporaryLock.lock()
        activeTemporary = url
        temporaryLock.unlock()
    }

    static func runIfInvoked() {
        let args = CommandLine.arguments
        guard args.count >= 2, args[1] == flag else { return }
        installTerminationCleanup()
        exit(execute(Array(args.dropFirst(2))))
    }

    /// 取消下载时先发 SIGTERM。这里删掉未下完的文件，避免留在系统临时目录。
    private static func installTerminationCleanup() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            temporaryLock.lock()
            let url = activeTemporary
            temporaryLock.unlock()
            if let url { try? FileManager.default.removeItem(at: url) }
            exit(143)
        }
        source.resume()
        terminationSource = source
    }

    static func parseCommand(_ args: [String]) throws -> Command {
        switch args.first {
        case "download":
            guard args.count == 4, let mirror = XrayDownloadMirror(rawValue: args[2]) else { throw Failure.usage }
            return .download(url: try GitHubFileDownloader.canonicalURL(args[1]), mirror: mirror, folder: args[3])
        case "diagnose":
            guard args.count == 2, args[1] == "connected" || args[1] == "idle" else { throw Failure.usage }
            return .diagnose(connected: args[1] == "connected")
        case "repair-preview":
            guard args.count == 1 else { throw Failure.usage }
            return .repairPreview
        case "repair":
            guard args.count == 2, args[1] == "keep" || args[1] == "delete" else { throw Failure.usage }
            return .repair(deleteBackup: args[1] == "delete")
        case "flush-dns":
            guard args.count == 1 else { throw Failure.usage }
            return .flushDNS
        case "network-repair-preview":
            guard args.count == 1 else { throw Failure.usage }
            return .networkRepairPreview
        case "network-repair":
            guard args.count == 1 else { throw Failure.usage }
            return .networkRepair
        case "network-repair-restore-hosts":
            guard args.count == 1 else { throw Failure.usage }
            return .networkRepairRestoreHosts
        case "speed":
            guard args.count == 2, LocalNetworkSpeedTest.line(id: args[1]) != nil else { throw Failure.usage }
            return .speed(args[1])
        case "latency":
            guard args.count == 3,
                  latencyChoices.contains(where: { $0.host == args[1] }),
                  let count = Int(args[2]),
                  latencyDurations.contains(count) else { throw Failure.usage }
            return .latency(host: args[1], count: count)
        default:
            throw Failure.usage
        }
    }

    static func encodeLine(_ event: Event) -> String {
        String(decoding: (try? JSONEncoder().encode(event)) ?? Data(), as: UTF8.self)
    }

    static func decodeLine(_ line: String) -> Event? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8), !trimmed.isEmpty else { return nil }
        return try? JSONDecoder().decode(Event.self, from: data)
    }

    private static func execute(_ args: [String]) -> Int32 {
        let gate = ExitGate()
        let emit: @Sendable (Event) -> Void = { event in
            var data = Data(encodeLine(event).utf8)
            data.append(0x0A)
            gate.write(data)
        }
        Task {
            do {
                let text = try await perform(try parseCommand(args), emit: emit)
                emit(Event(r: text))
                gate.finish(0)
            } catch {
                emit(Event(e: error.localizedDescription))
                gate.finish(1)
            }
        }
        while true {
            if gate.isDone { return gate.code }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.2))
        }
    }

    private static func perform(_ command: Command, emit: @escaping @Sendable (Event) -> Void) async throws -> String {
        switch command {
        case .download(let official, let mirror, let folder):
            let swept = GitHubFileDownloader.sweepAbandonedDownloads()
            let partial = GitHubFileDownloader.partialFileURL()
            trackTemporary(partial)
            defer {
                trackTemporary(nil)
                try? FileManager.default.removeItem(at: partial)
            }
            emit(Event(u: [swept, "正在通过\(mirror.statusLabel)下载…"].compactMap { $0 }.joined(separator: "\n")))
            try await GitHubFileDownloader.download(mirror.rewrite(official), to: partial) { fraction in
                emit(Event(p: fraction))
            }
            trackTemporary(nil)
            let destination = try GitHubFileDownloader.save(
                temporary: partial,
                to: URL(fileURLWithPath: folder, isDirectory: true),
                filename: GitHubFileDownloader.filename(for: official)
            )
            return [swept, "已保存：\(destination.path)"].compactMap { $0 }.joined(separator: "\n")
        case .diagnose(let connected):
            return await diagnose(connected: connected)
        case .repairPreview:
            return await repairPreview()
        case .repair(let deleteBackup):
            let turnedOff = try await SystemProxyManager().repairLoopbackProxies(deleteBackup: deleteBackup)
            let fileNote = deleteBackup ? "已删除备份文件。" : "已保留备份文件。"
            if turnedOff == 0 { return "没有需要关闭的本机残留代理。\(fileNote)" }
            return "已关闭 \(turnedOff) 项指向本机的系统代理。\(fileNote)"
        case .flushDNS:
            _ = try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/dscacheutil"),
                arguments: ["-flushcache"],
                timeout: 5
            )
            _ = try? await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/killall"),
                arguments: ["-HUP", "mDNSResponder"],
                timeout: 5
            )
            return "已刷新 DNS 缓存。"
        case .networkRepairPreview:
            return await networkRepairPreview(emit: emit)
        case .networkRepair:
            return await networkRepair()
        case .networkRepairRestoreHosts:
            return try await restoreHosts()
        case .speed(let lineID):
            let result = await LocalNetworkSpeedTest.run(lineID: lineID) { emit(Event(u: $0)) }
            switch result {
            case .success(let measured): return SpeedSnapshot(measured).encoded()
            case .failure(let error): throw error
            }
        case .latency(let host, let count):
            return try await runLatency(host: host, count: count, emit: emit)
        }
    }

    static func latencyMilliseconds(in output: String) -> Double? {
        for line in output.split(whereSeparator: \.isNewline) {
            for token in line.split(separator: " ") where token.hasPrefix("time=") {
                return Double(token.dropFirst(5))
            }
        }
        return nil
    }

    static func latencyReport(name: String, host: String, planned: Int, samples: [Double?], done: Bool) -> String {
        let times = samples.compactMap { $0 }
        let sent = samples.count
        let loss = sent == 0 ? "—" : String(format: "%.1f%%", Double(sent - times.count) / Double(sent) * 100)
        func ms(_ value: Double?) -> String {
            guard let value else { return "—" }
            return String(format: "%.1f ms", value)
        }
        let latest: String = {
            guard let last = samples.last else { return "—" }
            guard let value = last else { return "超时" }
            return String(format: "%.1f ms", value)
        }()
        let average = times.isEmpty ? nil : times.reduce(0, +) / Double(times.count)
        let wave = samples.map { $0.map { String(format: "%.1f", $0) } ?? "-" }.joined(separator: " ")
        return [
            done ? "时延测试完成" : "正在测试时延…",
            "目标：\(name)（\(host)）",
            "进度：\(sent) / \(planned)",
            "丢包：\(loss)",
            "最小：\(ms(times.min()))",
            "平均：\(ms(average))",
            "最大：\(ms(times.max()))",
            "最近：\(latest)",
            sent == 0 ? nil : "电波时延：\(wave)",
            "本机 ICMP，不走代理。"
        ].compactMap { $0 }.joined(separator: "\n")
    }

    static func latencySamples(in text: String) -> [Double?] {
        guard let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("电波时延：") }) else { return [] }
        return line.dropFirst("电波时延：".count).split(separator: " ").map { token in
            token == "-" ? nil : Double(token)
        }
    }

    /// 30 秒内每秒一个刻度，再长就按整段稀疏，避免 10 分钟挤成一条。
    static func latencyAxisSeconds(_ slots: Int) -> [Int] {
        guard slots > 0 else { return [] }
        if slots <= 30 { return Array(1...slots) }
        let step = slots <= 60 ? 5 : slots <= 300 ? 30 : 60
        return Array(stride(from: step, through: slots, by: step))
    }

    static func latencyPlannedCount(in text: String) -> Int? {
        guard let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("进度：") }) else { return nil }
        let parts = line.dropFirst("进度：".count).split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }
        return Int(parts[1])
    }

    /// 一次只发一个包，再补足到 1 秒。count 就是秒数，取消时留下已经打到的结果。
    private static func runLatency(host: String, count: Int, emit: @escaping @Sendable (Event) -> Void) async throws -> String {
        guard let choice = latencyChoices.first(where: { $0.host == host }) else { throw Failure.usage }
        var samples: [Double?] = []
        func text(done: Bool) -> String {
            latencyReport(name: choice.name, host: host, planned: count, samples: samples, done: done)
        }
        while samples.count < count {
            let started = Date()
            let result: ProcessRunResult
            do {
                try Task.checkCancellation()
                result = try await ProcessRunner.run(
                    executable: URL(fileURLWithPath: "/sbin/ping"),
                    arguments: ["-c", "1", "-W", "2000", host],
                    timeout: 4
                )
            } catch is CancellationError {
                return text(done: false)
            }
            if result.cancelled { return text(done: false) }
            let output = String(decoding: result.output, as: UTF8.self)
            samples.append(latencyMilliseconds(in: output))
            let done = samples.count == count
            let current = text(done: done)
            emit(Event(u: current))
            if done { return current }
            let remain = 1 - Date().timeIntervalSince(started)
            if remain > 0 {
                do { try await Task.sleep(nanoseconds: UInt64(remain * 1_000_000_000)) }
                catch is CancellationError { return text(done: false) }
            }
        }
        return text(done: true)
    }

    private static func diagnose(connected: Bool) async -> String {
        var lines = ["本地网络检测"]
        lines.append("网络：\(await pathDescription())")
        let proxies = (try? await SystemProxyManager().enabledProxySummary()) ?? []
        if proxies.isEmpty {
            lines.append("系统代理：未启用")
        } else {
            lines.append("系统代理：")
            lines.append(contentsOf: proxies.map { "· \($0)" })
            if !connected && proxies.contains(where: { $0.contains("127.0.0.1") || $0.contains("localhost") || $0.contains("::1") }) {
                lines.append("发现指向本机的代理，且当前未连接。可点「修复残留代理」。")
            }
        }
        let facts = await linkFacts()
        let probe = await probe(url: URL(string: "https://www.apple.com/library/test/success.html")!)
        if probe.ok {
            lines.append("直连 HTTPS：成功 \(probe.milliseconds) ms")
        } else {
            let notice = OfflineNotice.choose(
                ethernetActive: facts.ethernetActive,
                cableUnplugged: facts.cableUnplugged,
                wifiDisabled: facts.wifiDisabled
            )
            lines.append("直连 HTTPS：失败")
            lines.append(notice.title)
            lines.append(notice.message)
        }
        return lines.joined(separator: "\n")
    }

    private static func repairPreview() async -> String {
        let manager = SystemProxyManager()
        let loopback = ((try? await manager.enabledProxySummary()) ?? []).filter {
            $0.contains("127.0.0.1") || $0.contains("localhost") || $0.contains("::1")
        }
        var lines = ["将关闭当前指向本机的系统代理。"]
        if loopback.isEmpty {
            lines.append("当前没有检测到这类代理。")
        } else {
            lines.append(contentsOf: loopback.map { "· \($0)" })
        }
        lines.append("")
        lines.append(manager.backupDeletionDescription())
        return lines.joined(separator: "\n")
    }

    private static func pathDescription() async -> String {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "HopWorld.lab-utility.path")
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            monitor.pathUpdateHandler = { path in
                guard !once.done else { return }
                once.done = true
                monitor.cancel()
                let state = path.status == .satisfied ? "可用" : "不可用"
                let kind = path.usesInterfaceType(.wifi) ? "Wi-Fi"
                    : path.usesInterfaceType(.wiredEthernet) ? "有线"
                    : path.usesInterfaceType(.cellular) ? "蜂窝" : "其它"
                continuation.resume(returning: "\(state) · \(kind)")
            }
            monitor.start(queue: queue)
        }
    }

    struct OfflineNotice: Equatable, Sendable {
        var title: String
        var message: String
        /// 网线未插、Wi-Fi 未启用要打断操作，用弹窗。其余只进消息。
        var presentsAlert = false

        static let unreachable = OfflineNotice(
            title: "当前上不了网",
            message: "网卡可能仍显示已连接，但访问互联网失败了。请检查网线或 Wi-Fi，断开后重新连接，再使用跃界。"
        )

        static let poorByteCount = 16 * 1024

        /// 大文件在限定时间里只到了几 KB，才算网络很差。文件本身就这么小，不算。
        static func isPoorLink(bytes: Int, expected: Int64) -> Bool {
            guard bytes > 0, bytes < poorByteCount else { return false }
            return expected < 0 || expected >= Int64(poorByteCount)
        }

        static func poor(ethernetActive: Bool) -> OfflineNotice {
            if ethernetActive {
                return OfflineNotice(
                    title: "网络异常",
                    message: "网线已经接通，但网络很差，几乎只能传几 KB 数据。请检查路由器或宽带，可以断开网线后再连接。"
                )
            }
            return OfflineNotice(
                title: "网络异常",
                message: "网络已经连上，但很差，几乎只能传几 KB 数据。请断开后重新连接。"
            )
        }

        static func choose(ethernetActive: Bool, cableUnplugged: Bool, wifiDisabled: Bool) -> OfflineNotice {
            if ethernetActive { return .unreachable }
            if cableUnplugged && wifiDisabled {
                return OfflineNotice(
                    title: "当前上不了网",
                    message: "网线未插，Wi-Fi 也未启用。请插上网线或打开 Wi-Fi 后再使用跃界。",
                    presentsAlert: true
                )
            }
            if cableUnplugged {
                return OfflineNotice(
                    title: "网线未插",
                    message: "以太网没有插上网线。请插好网线；如果用 Wi-Fi，请先打开并连接。",
                    presentsAlert: true
                )
            }
            if wifiDisabled {
                return OfflineNotice(
                    title: "Wi-Fi 未启用",
                    message: "Wi-Fi 没有打开。请打开 Wi-Fi，或改用网线后再使用跃界。",
                    presentsAlert: true
                )
            }
            return .unreachable
        }
    }

    static var offlineTitle: String { OfflineNotice.unreachable.title }
    static var offlineMessage: String { OfflineNotice.unreachable.message }
    /// 主程序安装。没装上时（工具进程、测试）不拦截。
    static var confirmInternet: (@Sendable (_ userInitiated: Bool) async -> Bool)?

    static func allowInternet(userInitiated: Bool) async -> Bool {
        if let confirmInternet { return await confirmInternet(userInitiated) }
        return true
    }

    /// `networksetup -getdnsservers` 没手动指定时是一句说明，指定了则每行一个地址。
    static func manualDNSServers(from output: String) -> [String] {
        let lines = output.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard let first = lines.first else { return [] }
        if first.localizedCaseInsensitiveContains("aren't any") || first.contains("没有") { return [] }
        return lines.filter { line in
            line.allSatisfy { $0.isASCII && ($0.isHexDigit || $0 == "." || $0 == ":") }
        }
    }

    /// 没改过白名单时用这批。顺序就是界面上的默认顺序。
    static let builtinTrustedDNS: [String] = [
        "114.114.114.114", "114.114.115.115",
        "223.5.5.5", "223.6.6.6",
        "119.29.29.29", "119.28.28.28",
        "180.76.76.76",
        "1.2.4.8", "210.2.4.8",
        "8.8.8.8", "8.8.4.4",
        "1.1.1.1", "1.0.0.1",
        "9.9.9.9", "149.112.112.112"
    ]
    static let trustedDNSDefaultsKey = "networkRepair.trustedDNS"

    static func isDNSAddress(_ value: String) -> Bool {
        let line = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return false }
        return line.allSatisfy { $0.isASCII && ($0.isHexDigit || $0 == "." || $0 == ":") }
    }

    static func normalizedTrustedDNS(_ servers: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in servers {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isDNSAddress(line), seen.insert(line).inserted else { continue }
            result.append(line)
        }
        return result
    }

    static func trustedDNSList(defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: trustedDNSDefaultsKey) ?? builtinTrustedDNS
    }

    static func trustedDNSServers(defaults: UserDefaults = .standard) -> Set<String> {
        Set(trustedDNSList(defaults: defaults))
    }

    static func saveTrustedDNS(_ servers: [String], defaults: UserDefaults = .standard) {
        let cleaned = normalizedTrustedDNS(servers)
        if cleaned == builtinTrustedDNS {
            defaults.removeObject(forKey: trustedDNSDefaultsKey)
        } else {
            defaults.set(cleaned, forKey: trustedDNSDefaultsKey)
        }
    }

    static func untrustedDNSServers(from output: String, trusted: Set<String> = Set(builtinTrustedDNS)) -> [String] {
        manualDNSServers(from: output).filter { !trusted.contains($0) }
    }

    static let hostsBackupPath = "/etc/hosts.hopworld.bak"
    static let resolverDirectory = "/etc/resolver"
    static let resolverBackupDirectory = "/etc/resolver.hopworld.bak"

    static func repairDNSAddress(defaults: UserDefaults = .standard) -> String {
        trustedDNSList(defaults: defaults).first ?? "114.114.114.114"
    }

    static func dnsRepairLine(
        service: String,
        servers: [String],
        untrusted: [String],
        trusted: Set<String> = Set(builtinTrustedDNS),
        automatic: Bool = false,
        replacement: String = "114.114.114.114"
    ) -> String {
        if automatic {
            return "\(service)：自动获取 \(servers.joined(separator: "、"))，将改为 \(replacement)。"
        }
        let bad = untrusted.joined(separator: "、")
        let kept = servers.filter { trusted.contains($0) }
        if kept.isEmpty { return "\(service)：\(bad)，改回自动获取。" }
        return "\(service)：去掉 \(bad)，保留 \(kept.joined(separator: "、"))。"
    }

    /// 手动地址里还有白名单就只留白名单；整组都不在白名单时改回自动获取。
    /// 自动获取到的是名单外的公网地址时，改成 replacement，避免一刷新又回到路由器下发的地址。
    static func dnsRepairArguments(
        service: String,
        servers: [String],
        trusted: Set<String> = Set(builtinTrustedDNS),
        automatic: Bool = false,
        fallback: String = "114.114.114.114"
    ) -> [String] {
        if automatic { return ["-setdnsservers", service, fallback] }
        let kept = servers.filter { trusted.contains($0) }
        if kept.isEmpty { return ["-setdnsservers", service, "Empty"] }
        return ["-setdnsservers", service] + kept
    }

    /// 路由器、本机和运营商内网地址。自动获取到这些时保留。
    static func isRouterDNS(_ address: String) -> Bool {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.contains(":") {
            return value == "::1" || value.hasPrefix("fe80:") || value.hasPrefix("fc") || value.hasPrefix("fd")
        }
        let parts = value.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        let a = parts[0], b = parts[1]
        if a == 10 || a == 127 { return true }
        if a == 192 && b == 168 { return true }
        if a == 172 && (16...31).contains(b) { return true }
        if a == 169 && b == 254 { return true }
        if a == 100 && (64...127).contains(b) { return true }
        return false
    }

    static func dhcpDNSServers(from packet: String) -> [String] {
        guard let raw = packet.split(whereSeparator: \.isNewline).first(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("domain_name_server")
        }) else { return [] }
        var value = raw.split(separator: ":", maxSplits: 1).dropFirst().joined()
            .trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("{"), value.hasSuffix("}") {
            value = String(value.dropFirst().dropLast())
        }
        return value.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter(isDNSAddress)
    }

    static func untrustedAutomaticDNS(_ servers: [String], trusted: Set<String> = Set(builtinTrustedDNS)) -> [String] {
        servers.filter { !trusted.contains($0) && !isRouterDNS($0) }
    }

    static func hardwareDevices(in listing: String) -> [String: String] {
        var map: [String: String] = [:]
        var port = ""
        for raw in listing.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Hardware Port:") {
                port = line.replacingOccurrences(of: "Hardware Port:", with: "").trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Device:") {
                let device = line.replacingOccurrences(of: "Device:", with: "").trimmingCharacters(in: .whitespaces)
                if !port.isEmpty, device.allSatisfy({ $0.isLetter || $0.isNumber }) { map[port] = device }
                port = ""
            }
        }
        return map
    }

    static func resolverNameservers(in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let parts = raw.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2, parts[0].lowercased() == "nameserver", isDNSAddress(parts[1]) else { return nil }
            return parts[1]
        }
    }

    static func isResolverFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }

    static func resolverRepairs(_ files: [String: String], trusted: Set<String> = Set(builtinTrustedDNS)) -> [(name: String, servers: [String])] {
        files.compactMap { name, text in
            guard isResolverFileName(name) else { return nil }
            let bad = untrustedAutomaticDNS(resolverNameservers(in: text), trusted: trusted)
            guard !bad.isEmpty else { return nil }
            return (name, bad)
        }.sorted { $0.name < $1.name }
    }

    struct LinkInput: Equatable {
        var service: String
        var device: String
        var info: String
        var summary: String
        var mtuText: String
        var active: Bool
        var isWiFi: Bool
    }

    struct LinkPlan {
        var renew: [String] = []
        var mtu: [(service: String, value: Int)] = []
        var cycleWiFi: String?
        var flushRoutes = false
        var isEmpty: Bool { renew.isEmpty && mtu.isEmpty && cycleWiFi == nil && !flushRoutes }
    }

    static func serviceIPv4(from info: String) -> String? {
        for raw in info.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("IP address:") else { continue }
            let value = line.dropFirst("IP address:".count).trimmingCharacters(in: .whitespaces)
            if value.isEmpty || value == "none" { return nil }
            return String(value)
        }
        return nil
    }

    static func mtuSetting(from text: String) -> Int? {
        guard let range = text.range(of: "Current Setting:") else { return nil }
        let digits = text[range.upperBound...].drop(while: { $0.isWhitespace }).prefix(while: \.isNumber)
        return Int(digits)
    }

    /// 只改被 VPN 或错误配置改小的 MTU。1500 和万兆上的 9000 保持原样。
    static func shouldResetMTU(_ value: Int) -> Bool { (1..<1500).contains(value) }

    static func leaseExpiration(in summary: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "MM/dd/yyyy HH:mm:ss"
        for raw in summary.split(whereSeparator: \.isNewline) {
            let parts = raw.components(separatedBy: " : ")
            guard parts.count >= 2, parts[0].trimmingCharacters(in: .whitespaces) == "LeaseExpirationTime" else { continue }
            return formatter.date(from: parts[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    static func dhcpState(in summary: String) -> String? {
        for raw in summary.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("State") else { continue }
            let value = line.split(separator: ":", maxSplits: 1).dropFirst().joined()
                .trimmingCharacters(in: .whitespaces).lowercased()
            return value.isEmpty ? nil : value
        }
        return nil
    }

    static func dhcpNeedsRenew(info: String, summary: String, now: Date) -> Bool {
        guard info.contains("DHCP Configuration") else { return false }
        if serviceIPv4(from: info) == nil { return true }
        if let state = dhcpState(in: summary), ["init", "selecting", "requesting"].contains(state) { return true }
        if let expiry = leaseExpiration(in: summary), expiry <= now { return true }
        return false
    }

    static func routeInterface(in text: String) -> String? {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("interface:") else { continue }
            let name = line.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : String(name)
        }
        return nil
    }

    static func isEthernetFamilyDevice(_ name: String) -> Bool {
        let suffix = name.dropFirst(2)
        return name.hasPrefix("en") && !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }

    /// shortcut: 看不到断开历史。只有 Wi-Fi 开着、自己没地址、而且没有别的默认路由时才重开。
    static func makeLinkPlan(interfaces: [LinkInput], wifiPowerOn: Bool, route: String, now: Date) -> LinkPlan {
        var plan = LinkPlan()
        var anyAddress = false
        for item in interfaces {
            if let value = mtuSetting(from: item.mtuText), shouldResetMTU(value) {
                plan.mtu.append((item.service, value))
            }
            if serviceIPv4(from: item.info) != nil { anyAddress = true }
            guard item.active, isEthernetFamilyDevice(item.device), dhcpNeedsRenew(info: item.info, summary: item.summary, now: now) else { continue }
            plan.renew.append(item.device)
        }
        let wifi = interfaces.first { $0.isWiFi }
        let wifiDevice = wifi?.device
        let wifiHasAddress = wifi.map { serviceIPv4(from: $0.info) != nil } ?? false
        if wifiPowerOn, let wifiDevice, isEthernetFamilyDevice(wifiDevice), !wifiHasAddress, routeInterface(in: route) == nil {
            plan.cycleWiFi = wifiDevice
            if wifi?.info.contains("DHCP Configuration") == true, !plan.renew.contains(wifiDevice) {
                plan.renew.append(wifiDevice)
            }
        }
        plan.flushRoutes = anyAddress && routeInterface(in: route) == nil
        return plan
    }

    static func linkRepairLines(_ plan: LinkPlan, done: Bool) -> [String] {
        let will = done ? "已" : "将"
        var lines: [String] = []
        if plan.isEmpty {
            lines.append("DHCP 租约、MTU、Wi-Fi 和默认路由都正常，不重置。")
        }
        if let device = plan.cycleWiFi {
            lines.append("\(will)关闭再打开 Wi-Fi（\(device)），然后重新获取地址。")
        }
        for device in plan.renew where device != plan.cycleWiFi {
            lines.append("\(will)重新获取 \(device) 的 DHCP。")
        }
        for item in plan.mtu {
            lines.append("\(will)把 \(item.service) 的 MTU 从 \(item.value) 改回 1500。")
        }
        if plan.flushRoutes {
            lines.append(done ? "已清空路由表，并重新获取 DHCP。" : "没有默认路由，将清空路由表并重新获取 DHCP。")
        }
        return lines
    }

    static func repairCheckLine(_ name: String, _ abnormal: [String]) -> String {
        guard !abnormal.isEmpty else { return "\(name)：正常" }
        return (["\(name)：异常"] + abnormal).joined(separator: "\n")
    }

    static func repairNeeded(_ report: String) -> Bool {
        report.contains("发现异常。")
    }

    private static let stockHosts: Set<String> = [
        "127.0.0.1 localhost",
        "255.255.255.255 broadcasthost",
        "::1 localhost",
        "fe80::1%lo0 localhost"
    ]

    static func hostKey(_ raw: String) -> String {
        let visible = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first
            .map { String($0) } ?? ""
        return visible.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// hosts 里除掉系统自带的本机记录和注释。
    static func extraHostLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = String(raw)
            let folded = hostKey(line)
            guard !folded.isEmpty, !stockHosts.contains(folded) else { return nil }
            let visible = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first
                .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            return visible
        }
    }

    /// 去掉额外记录，留下注释和系统自带行。文件里已经没有本机记录时补回这三行。
    static func cleanedHosts(_ text: String) -> String {
        let fallback = "127.0.0.1\tlocalhost\n255.255.255.255\tbroadcasthost\n::1             localhost\n"
        guard !text.isEmpty else { return fallback }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var kept = lines.filter { line in
            let key = hostKey(line)
            return key.isEmpty || stockHosts.contains(key)
        }
        if !kept.contains(where: { hostKey($0) == "127.0.0.1 localhost" }) {
            kept.append("127.0.0.1\tlocalhost")
            kept.append("255.255.255.255\tbroadcasthost")
            kept.append("::1             localhost")
        }
        if kept.last?.isEmpty == true { return kept.joined(separator: "\n") }
        return kept.joined(separator: "\n") + "\n"
    }

    private static func networkRepairPreview(emit: @escaping @Sendable (Event) -> Void) async -> String {
        let trusted = trustedDNSServers()
        let fallback = repairDNSAddress()
        var done: [String] = []
        func publish(_ checking: String? = nil) {
            let lines = done + (checking.map { ["正在检查 \($0)…"] } ?? [])
            emit(Event(u: lines.joined(separator: "\n")))
        }
        publish("DNS")
        let survey = await dnsSurvey(trusted: trusted)
        done.append(repairCheckLine("DNS", survey.repairs.map {
            dnsRepairLine(service: $0.service, servers: $0.servers, untrusted: $0.untrusted, trusted: trusted, automatic: $0.automatic, replacement: fallback)
        }))
        publish("hosts")
        let hosts = extraHostLines(currentHosts())
        done.append(repairCheckLine("hosts", hosts.map { "· \($0)" }))
        publish("按域名的 DNS")
        let resolvers = resolverRepairs(currentResolverFiles(), trusted: trusted)
        done.append(repairCheckLine("按域名的 DNS", resolvers.map { "· \($0.name)：\($0.servers.joined(separator: "、"))" }))
        publish("DHCP、MTU、Wi-Fi 和默认路由")
        let plan = await collectLinkPlan()
        done.append(repairCheckLine("DHCP", plan.renew.map { "\($0) 的租约异常" }))
        done.append(repairCheckLine("MTU", plan.mtu.map { "\($0.service) 当前是 \($0.value)" }))
        done.append(repairCheckLine("Wi-Fi", plan.cycleWiFi.map { ["\($0) 没有地址"] } ?? []))
        done.append(repairCheckLine("默认路由", plan.flushRoutes ? ["没有默认路由"] : []))
        let needed = done.contains { $0.contains("：异常") }
        done.append(needed ? "发现异常。" : "全部正常，不需要修复。")
        let text = done.joined(separator: "\n")
        emit(Event(u: text))
        return text
    }

    private static func networkRepair() async -> String {
        let trusted = trustedDNSServers()
        let fallback = repairDNSAddress()
        let survey = await dnsSurvey(trusted: trusted)
        var lines: [String] = []
        if survey.repairs.isEmpty {
            lines.append("没有发现白名单以外的 DNS。")
        }
        for item in survey.repairs {
            let arguments = dnsRepairArguments(service: item.service, servers: item.servers, trusted: trusted, automatic: item.automatic, fallback: fallback)
            do {
                _ = try await runChecked("/usr/sbin/networksetup", arguments, timeout: 120)
                lines.append("已处理。\(dnsRepairLine(service: item.service, servers: item.servers, untrusted: item.untrusted, trusted: trusted, automatic: item.automatic, replacement: fallback))")
            } catch {
                lines.append("\(item.service)：没能改（\(error.localizedDescription)）")
            }
        }
        let hostsText = currentHosts()
        let hosts = extraHostLines(hostsText)
        let resolvers = resolverRepairs(currentResolverFiles(), trusted: trusted)
        let plan = await collectLinkPlan()
        let link = linkCommands(plan)
        do {
            if !hosts.isEmpty || !resolvers.isEmpty || !link.isEmpty {
                try await applyPrivilegedRepair(
                    hostsText: hosts.isEmpty ? nil : cleanedHosts(hostsText),
                    resolverNames: resolvers.map(\.name),
                    linkCommands: link
                )
            }
            lines.append(hosts.isEmpty ? "hosts 没有额外记录。" : "已删掉 hosts 里的额外记录。原文件备份在 \(hostsBackupPath)。")
            if resolvers.isEmpty {
                lines.append("没有按域名单独指定的异常 DNS。")
            } else {
                lines.append("已移走 \(resolvers.map(\.name).joined(separator: "、"))。备份在 \(resolverBackupDirectory)。")
            }
            lines.append(contentsOf: linkRepairLines(plan, done: !link.isEmpty))
        } catch {
            lines.append("hosts、DHCP 或 Wi-Fi 没改：\(error.localizedDescription)")
        }
        do {
            _ = try await runChecked("/usr/bin/dscacheutil", ["-flushcache"], timeout: 5)
            _ = try? await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/killall"),
                arguments: ["-HUP", "mDNSResponder"],
                timeout: 5
            )
            lines.append("已刷新 DNS 缓存。")
        } catch {
            lines.append("刷新 DNS 缓存失败：\(error.localizedDescription)")
        }
        return lines.joined(separator: "\n")
    }

    private static func restoreHosts() async throws -> String {
        guard FileManager.default.fileExists(atPath: hostsBackupPath) else { return "没有 hosts 备份。" }
        let command = [
            "set -eu",
            "cp \(TunAuthorizationCommand.shellQuote(hostsBackupPath)) /etc/hosts",
            "chmod 644 /etc/hosts"
        ].joined(separator: "\n")
        _ = try await runChecked("/usr/bin/osascript", ["-e", TunAuthorizationCommand.appleScript(command)], timeout: 120)
        _ = try? await runChecked("/usr/bin/dscacheutil", ["-flushcache"], timeout: 5)
        _ = try? await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/killall"),
            arguments: ["-HUP", "mDNSResponder"],
            timeout: 5
        )
        return "已用 \(hostsBackupPath) 还原 hosts，并刷新了 DNS 缓存。"
    }

    private static func linkCommands(_ plan: LinkPlan) -> [String] {
        var command: [String] = []
        if plan.flushRoutes { command.append("/sbin/route -n flush || true") }
        if let device = plan.cycleWiFi, isEthernetFamilyDevice(device) {
            let quoted = TunAuthorizationCommand.shellQuote(device)
            command.append("/usr/sbin/networksetup -setairportpower \(quoted) off")
            command.append("/bin/sleep 1")
            command.append("/usr/sbin/networksetup -setairportpower \(quoted) on")
            command.append("/bin/sleep 2")
        }
        for device in plan.renew where isEthernetFamilyDevice(device) {
            command.append("/usr/sbin/ipconfig set \(TunAuthorizationCommand.shellQuote(device)) DHCP")
        }
        for item in plan.mtu where shouldResetMTU(item.value) {
            command.append("/usr/sbin/networksetup -setMTU \(TunAuthorizationCommand.shellQuote(item.service)) 1500")
        }
        return command
    }

    private static func collectLinkPlan(now: Date = Date()) async -> LinkPlan {
        let devices = await hardwareDeviceMap()
        let services = (try? await SystemProxyManager().activeNetworkServices()) ?? []
        let route = await commandOutput("/sbin/route", ["-n", "get", "default"])
        var inputs: [LinkInput] = []
        for service in services {
            guard let device = devices[service] else { continue }
            inputs.append(LinkInput(
                service: service,
                device: device,
                info: await commandOutput("/usr/sbin/networksetup", ["-getinfo", service]),
                summary: await commandOutput("/usr/sbin/ipconfig", ["getsummary", device]),
                mtuText: await commandOutput("/usr/sbin/networksetup", ["-getMTU", service]),
                active: await interfaceIsActive(device),
                isWiFi: service.localizedCaseInsensitiveContains("wi-fi") || service.localizedCaseInsensitiveContains("wifi") || service.contains("无线")
            ))
        }
        return makeLinkPlan(interfaces: inputs, wifiPowerOn: wifiPower() == true, route: route, now: now)
    }

    private static func commandOutput(_ path: String, _ arguments: [String]) async -> String {
        guard let run = try? await ProcessRunner.run(
            executable: URL(fileURLWithPath: path),
            arguments: arguments,
            timeout: 8
        ) else { return "" }
        return String(decoding: run.output, as: UTF8.self)
    }

    private static func applyPrivilegedRepair(hostsText: String?, resolverNames: [String], linkCommands: [String] = []) async throws {
        guard hostsText != nil || !resolverNames.isEmpty || !linkCommands.isEmpty else { return }
        var temp: URL?
        defer { if let temp { try? FileManager.default.removeItem(at: temp) } }
        var command = ["set -eu"]
        if let hostsText {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("hopworld-hosts-\(UUID().uuidString)")
            try hostsText.write(to: file, atomically: true, encoding: .utf8)
            temp = file
            let quoted = TunAuthorizationCommand.shellQuote(file.path)
            command += [
                "cp /etc/hosts \(TunAuthorizationCommand.shellQuote(hostsBackupPath))",
                "cp -X \(quoted) /etc/hosts",
                "chmod 644 /etc/hosts"
            ]
        }
        if !resolverNames.isEmpty {
            command.append("mkdir -p \(TunAuthorizationCommand.shellQuote(resolverBackupDirectory))")
            for name in resolverNames where isResolverFileName(name) {
                let source = TunAuthorizationCommand.shellQuote(resolverDirectory + "/" + name)
                let backup = TunAuthorizationCommand.shellQuote(resolverBackupDirectory + "/" + name)
                command.append("cp \(source) \(backup)")
                command.append("rm -f \(source)")
            }
        }
        command.append(contentsOf: linkCommands)
        _ = try await runChecked("/usr/bin/osascript", ["-e", TunAuthorizationCommand.appleScript(command.joined(separator: "\n"))], timeout: 120)
    }

    private static func runChecked(_ path: String, _ arguments: [String], timeout: TimeInterval) async throws -> String {
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: path),
            arguments: arguments,
            timeout: timeout
        )
        let text = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if result.cancelled { throw CancellationError() }
        if result.timedOut { throw Failure.message(text.isEmpty ? "等待超时" : text) }
        guard result.status == 0 else {
            let lower = text.lowercased()
            if lower.contains("user canceled") || text.contains("-128") {
                throw Failure.message("没有输入管理员密码")
            }
            throw Failure.message(text.isEmpty ? "没有成功" : text)
        }
        return text
    }

    private struct DNSSurvey {
        var repairs: [(service: String, servers: [String], untrusted: [String], automatic: Bool)] = []
        var keeps: [(service: String, servers: [String])] = []
    }

    private static func dnsSurvey(trusted: Set<String>) async -> DNSSurvey {
        let services = (try? await SystemProxyManager().activeNetworkServices()) ?? []
        let devices = await hardwareDeviceMap()
        var survey = DNSSurvey()
        for service in services {
            guard let run = try? await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/usr/sbin/networksetup"),
                arguments: ["-getdnsservers", service],
                timeout: 8
            ) else { continue }
            let text = String(decoding: run.output, as: UTF8.self)
            let manual = manualDNSServers(from: text)
            if !manual.isEmpty {
                let untrusted = manual.filter { !trusted.contains($0) }
                if !untrusted.isEmpty { survey.repairs.append((service, manual, untrusted, false)) }
                continue
            }
            guard let device = devices[service] else { continue }
            guard let packet = try? await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/usr/sbin/ipconfig"),
                arguments: ["getpacket", device],
                timeout: 8
            ) else { continue }
            let servers = dhcpDNSServers(from: String(decoding: packet.output, as: UTF8.self))
            guard !servers.isEmpty else { continue }
            let untrusted = untrustedAutomaticDNS(servers, trusted: trusted)
            if untrusted.isEmpty {
                survey.keeps.append((service, servers))
            } else {
                survey.repairs.append((service, servers, untrusted, true))
            }
        }
        return survey
    }

    private static func hardwareDeviceMap() async -> [String: String] {
        guard let run = try? await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/sbin/networksetup"),
            arguments: ["-listallhardwareports"],
            timeout: 8
        ) else { return [:] }
        return hardwareDevices(in: String(decoding: run.output, as: UTF8.self))
    }

    private static func currentResolverFiles() -> [String: String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: resolverDirectory)) ?? []
        var files: [String: String] = [:]
        for name in names where isResolverFileName(name) {
            let path = resolverDirectory + "/" + name
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            files[name] = text
        }
        return files
    }

    private static func currentHosts() -> String {
        (try? String(contentsOfFile: "/etc/hosts", encoding: .utf8)) ?? ""
    }

    /// 上得了网返回 nil。网线未插、Wi-Fi 未启用，或网卡亮着但出不去，返回对应说明。
    static func offlineNotice() async -> OfflineNotice? {
        let facts = await linkFacts()
        if !facts.ethernetActive, facts.cableUnplugged || facts.wifiDisabled, facts.wifiDisabled || !facts.hasWifi {
            return OfflineNotice.choose(
                ethernetActive: false,
                cableUnplugged: facts.cableUnplugged,
                wifiDisabled: facts.wifiDisabled
            )
        }
        let sample = await bulkSample()
        if OfflineNotice.isPoorLink(bytes: sample.bytes, expected: sample.expected) {
            return OfflineNotice.poor(ethernetActive: facts.ethernetActive)
        }
        if sample.bytes >= OfflineNotice.poorByteCount { return nil }
        let ok = await probe(url: URL(string: "https://www.apple.com/library/test/success.html")!, timeout: 6).ok
        if ok { return nil }
        return OfflineNotice.choose(
            ethernetActive: facts.ethernetActive,
            cableUnplugged: facts.cableUnplugged,
            wifiDisabled: facts.wifiDisabled
        )
    }

    struct LinkFacts: Equatable, Sendable {
        var hasWifi: Bool
        var ethernetActive: Bool
        var cableUnplugged: Bool
        var wifiDisabled: Bool
    }

    static func linkFacts() async -> LinkFacts {
        let wifi = wifiPower()
        let devices = await ethernetDeviceNames()
        var active = false
        for name in devices where await interfaceIsActive(name) {
            active = true
            break
        }
        return LinkFacts(
            hasWifi: wifi != nil,
            ethernetActive: active,
            cableUnplugged: !devices.isEmpty && !active,
            wifiDisabled: wifi == false
        )
    }

    static func ethernetDeviceNames(in listing: String) -> [String] {
        var names: [String] = []
        var port = ""
        for raw in listing.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Hardware Port:") {
                port = line.replacingOccurrences(of: "Hardware Port:", with: "").trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Device:") {
                let device = line.replacingOccurrences(of: "Device:", with: "").trimmingCharacters(in: .whitespaces)
                if isEthernetPort(port), device.hasPrefix("en") { names.append(device) }
                port = ""
            }
        }
        return names
    }

    private static func isEthernetPort(_ name: String) -> Bool {
        let excluded = ["Wi-Fi", "WiFi", "Thunderbolt", "Bridge", "iPhone", "VPN", "蓝牙", "Bluetooth"]
        if excluded.contains(where: { name.localizedCaseInsensitiveContains($0) }) { return false }
        return name.localizedCaseInsensitiveContains("Ethernet")
            || name.localizedCaseInsensitiveContains("LAN")
            || name.contains("以太网")
    }

    private static func wifiPower() -> Bool? {
        guard let interfaces = CWWiFiClient.shared().interfaces(), !interfaces.isEmpty else { return nil }
        return interfaces.contains { $0.powerOn() }
    }

    private static func ethernetDeviceNames() async -> [String] {
        guard let run = try? await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/sbin/networksetup"),
            arguments: ["-listallhardwareports"],
            timeout: 3
        ) else { return [] }
        return ethernetDeviceNames(in: String(decoding: run.output, as: UTF8.self))
    }

    private static func interfaceIsActive(_ name: String) async -> Bool {
        guard let run = try? await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/sbin/ifconfig"),
            arguments: [name],
            timeout: 3
        ) else { return false }
        return String(decoding: run.output, as: UTF8.self).contains("status: active")
    }

    private struct BulkRead {
        var bytes = 0
        var expected: Int64 = -1
    }

    /// shortcut: 用测速那张大图看前 2 秒。小页面本身只有几 KB，看不出网络差。
    private static func bulkSample() async -> BulkRead {
        let sample = BulkCounter(enough: OfflineNotice.poorByteCount)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 4
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.connectionProxyDictionary = [
            "HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0, "ProxyAutoConfigEnable": 0
        ]
        let session = URLSession(configuration: config, delegate: sample, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://speedtest1.online.sh.cn:8080/speedtest/random4000x4000.jpg")!
        let sleeper = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            sample.stop()
        }
        let read = await sample.read(session: session, url: url)
        sleeper.cancel()
        return read
    }

    /// 启动时用：网卡显示已连接但出不去，也算没有网。
    static func internetReachable() async -> Bool {
        await offlineNotice() == nil
    }

    private static func probe(url: URL, timeout: TimeInterval = 12) async -> (ok: Bool, milliseconds: Int, detail: String) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = 20
        config.connectionProxyDictionary = [
            "HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0, "ProxyAutoConfigEnable": 0
        ]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let started = Date()
        do {
            let (data, response) = try await session.data(from: url)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            guard (200...299).contains(code), !data.isEmpty else { return (false, ms, "HTTP \(code)") }
            return (true, ms, "")
        } catch {
            return (false, Int(Date().timeIntervalSince(started) * 1000), error.localizedDescription)
        }
    }

    private final class BulkCounter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let enough: Int
        private let lock = NSLock()
        private var bytes = 0
        private var expected: Int64 = -1
        private var continuation: CheckedContinuation<BulkRead, Never>?
        private var task: URLSessionDataTask?
        private var ended = false

        init(enough: Int) { self.enough = enough }

        func read(session: URLSession, url: URL) async -> BulkRead {
            await withCheckedContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
                var request = URLRequest(url: url, timeoutInterval: 4)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let task = session.dataTask(with: request)
                lock.lock()
                self.task = task
                lock.unlock()
                task.resume()
            }
        }

        func stop() {
            lock.lock()
            let task = self.task
            lock.unlock()
            task?.cancel()
            finish()
        }

        private func finish() {
            lock.lock()
            guard !ended else { lock.unlock(); return }
            ended = true
            let read = BulkRead(bytes: bytes, expected: expected)
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: read)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            lock.lock()
            if (200...299).contains(code) { expected = response.expectedContentLength }
            lock.unlock()
            completionHandler((200...299).contains(code) ? .allow : .cancel)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            bytes += data.count
            let stop = bytes >= enough
            lock.unlock()
            if stop { self.stop() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            finish()
        }
    }
}

private final class ExitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private(set) var code: Int32 = 1

    var isDone: Bool {
        lock.lock(); defer { lock.unlock() }
        return done
    }

    func write(_ data: Data) {
        lock.lock()
        FileHandle.standardOutput.write(data)
        lock.unlock()
    }

    func finish(_ code: Int32) {
        lock.lock()
        self.code = code
        done = true
        lock.unlock()
        CFRunLoopStop(CFRunLoopGetMain())
    }
}

final class LabUtilityClient: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        guard let process else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.4) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func run(arguments: [String], onEvent: @escaping @Sendable (LabUtilityProcess.Event) -> Void) async throws -> String {
        let executable = Bundle.main.executableURL
        guard let executable else { throw LabUtilityProcess.Failure.message("找不到工具进程") }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                let process = Process()
                process.executableURL = executable
                process.arguments = [LabUtilityProcess.flag] + arguments
                process.qualityOfService = .utility
                process.standardInput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                let pipe = Pipe()
                process.standardOutput = pipe
                let reader = LineReader(onEvent: onEvent) { result in
                    continuation.resume(with: result)
                }
                pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        DispatchQueue.global(qos: .utility).async {
                            process.waitUntilExit()
                            reader.finish(status: process.terminationStatus, cancelled: self?.isCancelled == true)
                        }
                        return
                    }
                    reader.append(data)
                }
                do {
                    lock.lock()
                    self.process = process
                    lock.unlock()
                    try process.run()
                } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    reader.fail(error)
                }
            }
        } onCancel: {
            cancel()
        }
    }
}

private final class LineReader: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var result: String?
    private var failure: String?
    private var finished = false
    private var lastProgress = Date.distantPast
    private let onEvent: @Sendable (LabUtilityProcess.Event) -> Void
    private let complete: @Sendable (Result<String, Error>) -> Void

    init(onEvent: @escaping @Sendable (LabUtilityProcess.Event) -> Void, complete: @escaping @Sendable (Result<String, Error>) -> Void) {
        self.onEvent = onEvent
        self.complete = complete
    }

    func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            lines.append(String(decoding: line, as: UTF8.self))
        }
        lock.unlock()
        lines.forEach(accept)
    }

    func finish(status: Int32, cancelled: Bool) {
        lock.lock()
        let trailing = buffer
        buffer.removeAll()
        lock.unlock()
        if !trailing.isEmpty { accept(String(decoding: trailing, as: UTF8.self)) }
        let outcome: Result<String, Error>? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            if cancelled { return .failure(CancellationError()) }
            if let result { return .success(result) }
            if let failure { return .failure(LabUtilityProcess.Failure.message(failure)) }
            if status == 0 { return .failure(LabUtilityProcess.Failure.message("工具进程没有返回结果")) }
            return .failure(LabUtilityProcess.Failure.message("工具进程已结束"))
        }
        if let outcome { complete(outcome) }
    }

    func fail(_ error: Error) {
        let shouldFinish = lock.withLock { () -> Bool in
            guard !finished else { return false }
            finished = true
            return true
        }
        if shouldFinish { complete(.failure(error)) }
    }

    private func accept(_ line: String) {
        guard let event = LabUtilityProcess.decodeLine(line) else { return }
        if let text = event.r {
            lock.lock(); result = text; lock.unlock()
        }
        if let text = event.e {
            lock.lock(); failure = text; lock.unlock()
        }
        if let fraction = event.p {
            let now = Date()
            if fraction < 1, now.timeIntervalSince(lastProgress) < 0.1 { return }
            lastProgress = now
            onEvent(LabUtilityProcess.Event(p: fraction))
        }
        if let text = event.u {
            onEvent(LabUtilityProcess.Event(u: text))
        }
    }
}
