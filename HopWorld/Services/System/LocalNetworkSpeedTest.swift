import CoreWLAN
import Foundation

/// 本机到默认网关的延迟，加上所选线路的下行和上行。不使用 Cloudflare。
enum LocalNetworkSpeedTest {
    struct Line: Identifiable, Equatable, Sendable {
        var id: String
        var name: String
        var downloadURL: URL
        /// 镜像站会拒绝大体积上传，这时上行改走能收下数据的线路。
        var uploadName: String
        var uploadURL: URL
        var note: String
    }

    struct LocalLink: Sendable {
        var interfaceName: String
        var gateway: String
        var averageMs: Double?
        var jitterMs: Double?
        var loss: String
        var signal: String?
    }

    struct Report: Sendable {
        var local: LocalLink?
        var source: String?
        var downloadMbps: Double?
        var downloadBytes: Int
        var downloadSeconds: TimeInterval
        var downloadError: String?
        var uploadSource: String?
        var uploadMbps: Double?
        var uploadBytes: Int
        var uploadSeconds: TimeInterval
        var uploadError: String?
        var downloadWave: [Double] = []
        var uploadWave: [Double] = []
    }

    /// 每过一整秒记一次这一秒的速度。测速最多 15 秒。
    struct SecondWave: Equatable {
        var rates: [Double] = []
        private var lastBytes = 0
        private var lastElapsed: TimeInterval = 0

        mutating func note(bytes: Int, elapsed: TimeInterval) -> Bool {
            let second = min(Int(sampleSeconds), Int(elapsed))
            guard second > rates.count else { return false }
            let deltaBytes = max(0, bytes - lastBytes)
            let deltaTime = max(0.05, elapsed - lastElapsed)
            let rate = mbps(bytes: deltaBytes, seconds: deltaTime)
            while rates.count < second {
                rates.append(rate)
            }
            lastBytes = bytes
            lastElapsed = elapsed
            return true
        }
    }

    static func waveLine(kind: String, rates: [Double]) -> String {
        let body = rates.map { String(format: "%.1f", $0) }.joined(separator: " ")
        return "电波\(kind)：\(body)"
    }

    static func parseWaves(_ text: String) -> (down: [Double], up: [Double]) {
        var down: [Double] = []
        var up: [Double] = []
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("电波下：") { down = waveValues(line) }
            if line.hasPrefix("电波上：") { up = waveValues(line) }
        }
        return (down, up)
    }

    private static func waveValues(_ line: String) -> [Double] {
        guard let split = line.firstIndex(of: "：") else { return [] }
        return line[line.index(after: split)...]
            .split(separator: " ")
            .compactMap { Double($0) }
    }

    private static let nodeArchive = "node-v20.18.1-darwin-arm64.tar.gz"
    private static let telecomUpload = URL(string: "https://speedtest1.online.sh.cn:8080/speedtest/upload.php")!
    private static let telecomDownload = URL(string: "https://speedtest1.online.sh.cn:8080/speedtest/random4000x4000.jpg")!

    static let lines: [Line] = [
        Line(id: "sh-telecom", name: "上海电信", downloadURL: telecomDownload, uploadName: "上海电信", uploadURL: telecomUpload, note: "上下行都走这条线路。"),
        mirror("tuna", "清华镜像", "https://mirrors.tuna.tsinghua.edu.cn/nodejs-release/v20.18.1/\(nodeArchive)"),
        mirror("npm", "npmmirror", "https://cdn.npmmirror.com/binaries/node/v20.18.1/\(nodeArchive)"),
        mirror("ustc", "中科大", "https://mirrors.ustc.edu.cn/node/v20.18.1/\(nodeArchive)"),
        mirror("tencent", "腾讯云", "https://mirrors.cloud.tencent.com/nodejs-release/v20.18.1/\(nodeArchive)"),
        mirror("huawei", "华为云", "https://mirrors.huaweicloud.com/nodejs/v20.18.1/\(nodeArchive)"),
        mirror("aliyun", "阿里云", "https://mirrors.aliyun.com/nodejs-release/v20.18.1/\(nodeArchive)")
    ]

    static func line(id: String) -> Line? {
        lines.first { $0.id == id }
    }

    /// shortcut: 镜像站不接收大体积上传，这些线路的上行固定走上海电信。镜像自己提供上传地址后再分开。
    private static func mirror(_ id: String, _ name: String, _ download: String) -> Line {
        Line(
            id: id, name: name, downloadURL: URL(string: download)!,
            uploadName: "上海电信", uploadURL: telecomUpload,
            note: "下行走\(name)。上行走上海电信，镜像站不接收大文件上传。"
        )
    }

    static let warmup: TimeInterval = 0.4
    /// 下载、上传各测这么久。单次文件或连接提前结束就再来一次，直到时间到。
    static let sampleSeconds: TimeInterval = 15
    /// 默认先开 5 条。速度还在涨就再加 5 条。上下行同一套。
    static let streamBatch = 5
    /// shortcut: 最多 32 条。到顶后这一秒仍比上一批快 8% 以上，说明线路更快，再把上限调高。
    static let streamCap = 32

    /// 这一轮正常结束但还没到点，就再测一次。失败或用户取消不再补，避免空转。
    static func shouldRepeatTransfer(elapsed: TimeInterval, stopping: Bool, status: Int, bytes: Int, failed: Bool) -> Bool {
        guard !stopping, !failed, elapsed < sampleSeconds else { return false }
        return (200...299).contains(status) || bytes >= 64 * 1024
    }

    /// 这一小段已经收到数据，又安静超过 1.5 秒，就重新请求。否则会干等到系统超时，后面的秒数是空的。
    static func shouldRotateDownload(quiet: TimeInterval, received: Int, elapsed: TimeInterval) -> Bool {
        elapsed < sampleSeconds && quiet >= 1.5 && received > 0
    }

    static func mbps(bytes: Int, seconds: TimeInterval) -> Double {
        guard bytes > 0, seconds > 0.05 else { return 0 }
        return Double(bytes) * 8 / seconds / 1_000_000
    }

    /// 样本超过 1.5 秒时丢掉启动段，避免握手把带宽拉低。
    static func paced(totalBytes: Int, elapsed: TimeInterval, warmupBytes: Int) -> (bytes: Int, seconds: TimeInterval) {
        guard elapsed > 1.5, warmupBytes > 0, totalBytes > warmupBytes else {
            return (totalBytes, elapsed)
        }
        return (totalBytes - warmupBytes, max(0.05, elapsed - warmup))
    }

    /// 再开一批之后，这一秒比加之前至少快 8%，才继续加。
    static func shouldAddStreams(baseline: Double, current: Double, open: Int, cap: Int = streamCap) -> Bool {
        guard open < cap, baseline > 1 else { return false }
        return current >= baseline * 1.08
    }

    /// 多条连接的字节加在一起，时间用最久的那条，启动段只扣一次。
    static func aggregate(bytes: [Int], seconds: [TimeInterval], warmupBytes: [Int]) -> (bytes: Int, seconds: TimeInterval) {
        paced(
            totalBytes: bytes.reduce(0, +),
            elapsed: seconds.max() ?? 0,
            warmupBytes: warmupBytes.reduce(0, +)
        )
    }

    static func parseRoute(_ text: String) -> (gateway: String, interfaceName: String)? {
        var gateway: String?
        var interfaceName: String?
        for line in text.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            if parts[0] == "gateway" { gateway = parts[1] }
            if parts[0] == "interface" { interfaceName = parts[1] }
        }
        guard let gateway, let interfaceName,
              isAddress(gateway), isInterfaceName(interfaceName) else { return nil }
        return (gateway, interfaceName)
    }

    static func parsePing(_ text: String) -> (averageMs: Double, loss: String, jitterMs: Double?)? {
        let loss = text.components(separatedBy: .newlines).first {
            $0.contains("packet loss") || $0.contains("packets received")
        }.map { line -> String in
            if let range = line.range(of: #"\d+(\.\d+)?%"#, options: .regularExpression) {
                return String(line[range])
            }
            return line.trimmingCharacters(in: .whitespaces)
        }
        guard let stats = text.components(separatedBy: .newlines).first(where: { $0.contains("min/avg/max") }),
              let avg = stats.split(separator: "=").last?
                .split(separator: "/")
                .dropFirst()
                .first
                .flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }) else { return nil }
        let samples = text.components(separatedBy: .newlines).compactMap { line -> Double? in
            guard let range = line.range(of: #"time=[0-9.]+"#, options: .regularExpression) else { return nil }
            return Double(line[range].dropFirst(5))
        }
        let stddev = stats.split(separator: "=").last?
            .split(separator: "/")
            .dropFirst(3)
            .first
            .flatMap { Double($0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ms", with: "")) }
        return (avg, loss ?? "未知", jitter(samples: samples) ?? stddev)
    }

    /// 相邻两次 Ping 的间隔平均值。样本不足时用 ping 自己的标准差。
    static func jitter(samples: [Double]) -> Double? {
        guard samples.count >= 2 else { return nil }
        let pairs = zip(samples, samples.dropFirst())
        let total = pairs.reduce(0.0) { $0 + abs($1.0 - $1.1) }
        return total / Double(samples.count - 1)
    }

    /// 把 ifconfig 的 media 行译成可读说法。网线没有无线信号强度。
    static func signalLabel(_ linkRate: String) -> String {
        let inner: String
        if let open = linkRate.firstIndex(of: "("),
           let close = linkRate.lastIndex(of: ")"),
           open < close {
            inner = String(linkRate[linkRate.index(after: open)..<close])
        } else {
            inner = linkRate
        }
        let folded = inner.lowercased()
        let speed: String? = {
            if folded.contains("10gbase") { return "有线 万兆" }
            if folded.contains("5gbase") || folded.contains("5000base") { return "有线 5 千兆" }
            if folded.contains("2.5gbase") || folded.contains("2500base") { return "有线 2.5 千兆" }
            if folded.contains("1000base") { return "有线 千兆" }
            if folded.contains("100base") { return "有线 百兆" }
            if folded.contains("10base") { return "有线 十兆" }
            return nil
        }()
        let duplex = folded.contains("full-duplex") ? "全双工" : folded.contains("half-duplex") ? "半双工" : nil
        let parts = [speed, duplex].compactMap { $0 }
        return parts.isEmpty ? "有线" : parts.joined(separator: " · ")
    }

    static func parseLinkRate(_ ifconfig: String) -> String? {
        guard let line = ifconfig.components(separatedBy: .newlines).first(where: { $0.contains("media:") }) else { return nil }
        let value = line.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return value.isEmpty ? nil : value
    }

    /// 兆就是 Mbps。下载速度用 MB/s，等于兆数除以 8：1000 兆 = 125 MB/s。
    static func byteRate(mbps: Double) -> Double { mbps / 8 }

    /// 达到该档的九成就算。900 Mbps 记成 1000 Mbps（千兆）。
    private static let bandwidthGrades: [(mbps: Int, name: String)] = [
        (100, "100 Mbps"),
        (200, "200 Mbps"),
        (300, "300 Mbps"),
        (500, "500 Mbps"),
        (1_000, "1000 Mbps（千兆）"),
        (2_000, "2000 Mbps（2G）"),
        (10_000, "10000 Mbps（万兆）"),
        (100_000, "100G")
    ]

    static func bandwidthLine(mbps: Double?) -> String {
        guard let mbps, mbps > 0 else { return "当前带宽：未能判断" }
        let name = bandwidthGrades.last { mbps >= Double($0.mbps) * 0.9 }?.name ?? "不足 100 Mbps"
        return "当前带宽：\(name)"
    }

    /// 下行电波在换成上行进度时还留着，两条线一起画。
    private final class WaveGate: @unchecked Sendable {
        private let lock = NSLock()
        private var down = ""
        private var up = ""

        func merge(_ text: String) -> String {
            lock.lock()
            defer { lock.unlock() }
            var body: [String] = []
            for line in text.components(separatedBy: "\n") {
                if line.hasPrefix("电波下：") { down = line }
                else if line.hasPrefix("电波上：") { up = line }
                else if !line.isEmpty { body.append(line) }
            }
            return ([down, up].filter { !$0.isEmpty } + body).joined(separator: "\n")
        }
    }

    static func run(lineID: String, onUpdate: (@Sendable (String) -> Void)? = nil) async -> Result<Report, Error> {
        guard let line = line(id: lineID) else {
            return .failure(URLError(.unsupportedURL, userInfo: [NSLocalizedDescriptionKey: "没有这条测速线路"]))
        }
        onUpdate?("正在检查本机网关…")
        let local = await localLink()
        let header = linkHeader(local)
        let reporting: (@Sendable (String) -> Void)?
        if let onUpdate {
            let gate = WaveGate()
            reporting = { text in
                let merged = gate.merge(text)
                onUpdate([header, merged].filter { !$0.isEmpty }.joined(separator: "\n"))
            }
        } else {
            reporting = nil
        }
        let configuration = directConfiguration()
        var report = Report(
            local: local, source: line.name,
            downloadMbps: nil, downloadBytes: 0, downloadSeconds: 0, downloadError: nil,
            uploadSource: line.uploadName, uploadMbps: nil, uploadBytes: 0, uploadSeconds: 0, uploadError: nil
        )
        let download = await transfer(kind: "下行", name: line.name, url: line.downloadURL, upload: false, configuration: configuration, onUpdate: reporting)
        report.downloadMbps = download.mbps
        report.downloadBytes = download.bytes
        report.downloadSeconds = download.seconds
        report.downloadError = download.error
        report.downloadWave = download.wave
        let upload = await transfer(kind: "上行", name: line.uploadName, url: line.uploadURL, upload: true, configuration: configuration, onUpdate: reporting)
        report.uploadMbps = upload.mbps
        report.uploadBytes = upload.bytes
        report.uploadSeconds = upload.seconds
        report.uploadError = upload.error
        report.uploadWave = upload.wave
        if report.downloadMbps == nil, report.uploadMbps == nil, local == nil {
            return .failure(URLError(.cannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: report.downloadError ?? report.uploadError ?? "测速失败"]))
        }
        return .success(report)
    }

    private struct Transfer {
        var mbps: Double?
        var bytes: Int
        var seconds: TimeInterval
        var error: String?
        var wave: [Double]
    }

    private struct Sample {
        var bytes: Int
        var seconds: TimeInterval
        var warmupBytes: Int
        var error: String?
    }

    /// 多条连接各自一个 URLSession。同一个 session 走 HTTP/2 时会并成一条 TCP，千兆填不满。
    private final class BytePump: @unchecked Sendable {
        let source: String
        let kind: String
        let onUpdate: (@Sendable (String) -> Void)?
        private let lock = NSLock()
        private var bytes = 0
        private var wave = SecondWave()
        private let started: Date
        private var lastPaint = Date.distantPast

        init(source: String, kind: String, onUpdate: (@Sendable (String) -> Void)?, started: Date) {
            self.source = source
            self.kind = kind
            self.onUpdate = onUpdate
            self.started = started
        }

        func add(_ count: Int) {
            guard count > 0 else { return }
            lock.lock()
            bytes += count
            let elapsed = Date().timeIntervalSince(started)
            let marked = wave.note(bytes: bytes, elapsed: elapsed)
            let paint = marked || Date().timeIntervalSince(lastPaint) > 0.3
            if paint { lastPaint = Date() }
            let rates = wave.rates
            let total = bytes
            lock.unlock()
            guard paint, let onUpdate else { return }
            onUpdate(LocalNetworkSpeedTest.liveProgress(source: source, kind: kind, bytes: total, elapsed: elapsed, rates: rates))
        }

        func latestRate() -> Double {
            lock.lock()
            defer { lock.unlock() }
            _ = wave.note(bytes: bytes, elapsed: Date().timeIntervalSince(started))
            return wave.rates.last ?? 0
        }

        func mark() -> [Double] {
            lock.lock()
            defer { lock.unlock() }
            _ = wave.note(bytes: bytes, elapsed: Date().timeIntervalSince(started))
            return wave.rates
        }
    }

    private static func liveProgress(source: String, kind: String, bytes: Int, elapsed: TimeInterval, rates: [Double]) -> String {
        let rate = byteRate(mbps: mbps(bytes: bytes, seconds: elapsed))
        var text = String(format: "测速中 · \(source)\n已传输 %@\n当前 %.1f MB/s",
                          ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file), rate)
        if !rates.isEmpty {
            text += "\n" + waveLine(kind: kind, rates: rates)
        }
        return text
    }

    private static func transfer(
        kind: String, name: String, url: URL, upload: Bool,
        configuration: URLSessionConfiguration, onUpdate: (@Sendable (String) -> Void)?
    ) async -> Transfer {
        onUpdate?("正在从\(name)测\(kind)…")
        let started = Date()
        let pump = BytePump(source: "\(name) · \(kind)", kind: upload ? "上" : "下", onUpdate: onUpdate, started: started)
        var parts: [Sample] = []
        await withTaskGroup(of: Sample.self) { group in
            var open = 0
            func launch(_ count: Int) {
                let n = min(count, streamCap - open)
                guard n > 0 else { return }
                for _ in 0..<n {
                    group.addTask {
                        await single(
                            upload: upload, url: url, configuration: configuration,
                            source: pump.source, started: started, onBytes: { pump.add($0) }
                        )
                    }
                }
                open += n
            }
            launch(streamBatch)
            var beforeAdd: Double?
            while Date().timeIntervalSince(started) < sampleSeconds - 1 {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }
                let current = pump.latestRate()
                guard current > 1 else { continue }
                if let beforeAdd, !shouldAddStreams(baseline: beforeAdd, current: current, open: open) { break }
                if open >= streamCap { break }
                launch(streamBatch)
                beforeAdd = current
            }
            for await part in group { parts.append(part) }
        }
        return combined(parts, wave: pump.mark())
    }

    private static func combined(_ parts: [Sample], wave: [Double]) -> Transfer {
        let usable = parts.filter { $0.error == nil && $0.bytes >= 64 * 1024 }
        guard !usable.isEmpty else {
            return Transfer(mbps: nil, bytes: parts.reduce(0) { $0 + $1.bytes }, seconds: 0, error: parts.compactMap(\.error).first ?? "没有数据", wave: [])
        }
        let sample = aggregate(bytes: usable.map(\.bytes), seconds: usable.map(\.seconds), warmupBytes: usable.map(\.warmupBytes))
        return Transfer(
            mbps: mbps(bytes: sample.bytes, seconds: sample.seconds),
            bytes: usable.reduce(0) { $0 + $1.bytes },
            seconds: usable.map(\.seconds).max() ?? 0,
            error: nil,
            wave: wave
        )
    }

    private static func single(
        upload: Bool, url: URL, configuration: URLSessionConfiguration, source: String,
        started: Date, onBytes: @escaping @Sendable (Int) -> Void
    ) async -> Sample {
        if upload {
            let meter = UploadMeter(onUpdate: nil, source: source, onBytes: onBytes, started: started)
            let session = URLSession(configuration: configuration, delegate: meter, delegateQueue: nil)
            do {
                let sample = try await meter.run(url: url, session: session)
                session.finishTasksAndInvalidate()
                return Sample(bytes: sample.bytes, seconds: sample.seconds, warmupBytes: sample.warmupBytes, error: nil)
            } catch {
                session.invalidateAndCancel()
                return Sample(bytes: 0, seconds: 0, warmupBytes: 0, error: error.localizedDescription)
            }
        }
        let meter = DownloadMeter(onUpdate: nil, source: source, onBytes: onBytes, started: started)
        let session = URLSession(configuration: configuration, delegate: meter, delegateQueue: nil)
        do {
            let sample = try await meter.run(url: url, session: session)
            session.finishTasksAndInvalidate()
            return Sample(bytes: sample.bytes, seconds: sample.seconds, warmupBytes: sample.warmupBytes, error: nil)
        } catch {
            session.invalidateAndCancel()
            return Sample(bytes: 0, seconds: 0, warmupBytes: 0, error: error.localizedDescription)
        }
    }

    static func byteText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// en0 这类名字是系统内部网口编号。结果里只区分有线还是无线。
    static func networkKind(signal: String?) -> String {
        guard let signal else { return "未知" }
        if signal.contains("dBm") { return "无线" }
        if signal.hasPrefix("有线") { return "有线" }
        return "当前网络"
    }

    static func speedText(_ mbps: Double?) -> String {
        guard let mbps else { return "—" }
        return String(format: "%.1f MB/s", byteRate(mbps: mbps))
    }

    static func summary(_ report: Report) -> String {
        var lines = ["线路：\(report.source ?? "未选择")"]
        if let local = report.local {
            lines.append("网络：\(networkKind(signal: local.signal)) · 网关 \(local.gateway)")
        }
        if let mbps = report.downloadMbps {
            lines.append("下载：\(speedText(mbps))")
        } else {
            lines.append("下载：失败（\(report.downloadError ?? "无结果")）")
        }
        lines.append("下载数据：\(byteText(report.downloadBytes))")
        if let mbps = report.uploadMbps {
            let title = report.uploadSource == report.source ? "上传" : "上传（\(report.uploadSource ?? "")）"
            lines.append("\(title)：\(speedText(mbps))")
        } else {
            lines.append("上传：失败（\(report.uploadError ?? "无结果")）")
        }
        lines.append("上传数据：\(byteText(report.uploadBytes))")
        lines.append(contentsOf: linkHeader(report.local).components(separatedBy: "\n"))
        lines.append(bandwidthLine(mbps: report.downloadMbps ?? report.uploadMbps))
        if !report.downloadWave.isEmpty { lines.append(waveLine(kind: "下", rates: report.downloadWave)) }
        if !report.uploadWave.isEmpty { lines.append(waveLine(kind: "上", rates: report.uploadWave)) }
        return lines.joined(separator: "\n")
    }

    private static func linkHeader(_ local: LocalLink?) -> String {
        let ping = local?.averageMs.map { String(format: "Ping：%.1f ms", $0) } ?? "Ping：无"
        let jitter = local?.jitterMs.map { String(format: "抖动：%.1f ms", $0) } ?? "抖动：无"
        let signal = "信号：\(local?.signal ?? "无")"
        let loss = "丢包：\(local?.loss ?? "无")"
        return [ping, jitter, signal, loss].joined(separator: "\n")
    }

    private static func localLink() async -> LocalLink? {
        guard let route = try? await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/sbin/route"),
            arguments: ["-n", "get", "default"],
            timeout: 3
        ), let parsed = parseRoute(String(decoding: route.output, as: UTF8.self)) else { return nil }
        let pingText: String
        if let ping = try? await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/sbin/ping"),
            arguments: ["-c", "4", "-W", "1000", parsed.gateway],
            timeout: 8
        ) {
            pingText = String(decoding: ping.output, as: UTF8.self)
        } else {
            pingText = ""
        }
        let stats = parsePing(pingText)
        let media = (try? await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/sbin/ifconfig"),
            arguments: [parsed.interfaceName],
            timeout: 3
        )).flatMap { parseLinkRate(String(decoding: $0.output, as: UTF8.self)) }
        let signal = wifiSignal(interface: parsed.interfaceName) ?? media.map(signalLabel)
        return LocalLink(
            interfaceName: parsed.interfaceName,
            gateway: parsed.gateway,
            averageMs: stats?.averageMs,
            jitterMs: stats?.jitterMs,
            loss: stats?.loss ?? "无响应",
            signal: signal
        )
    }

    private static func wifiSignal(interface: String) -> String? {
        guard let wifi = CWWiFiClient.shared().interface(withName: interface),
              wifi.interfaceName == interface else { return nil }
        let rssi = wifi.rssiValue()
        guard rssi != 0 else { return nil }
        return "\(rssi) dBm"
    }

    private static func isAddress(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isASCII && ($0.isHexDigit || $0 == "." || $0 == ":") }
    }

    private static func isInterfaceName(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 16 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    private static func directConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.connectionProxyDictionary = [
            "HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0, "ProxyAutoConfigEnable": 0
        ]
        return config
    }
}

struct SpeedSnapshot: Codable, Equatable, Sendable {
    var network: String
    var downloadMbps: Double?
    var uploadMbps: Double?
    var detail: String

    init(network: String, downloadMbps: Double?, uploadMbps: Double?, detail: String) {
        self.network = network
        self.downloadMbps = downloadMbps
        self.uploadMbps = uploadMbps
        self.detail = detail
    }

    init(_ report: LocalNetworkSpeedTest.Report) {
        self.init(
            network: report.source ?? "未选择",
            downloadMbps: report.downloadMbps,
            uploadMbps: report.uploadMbps,
            detail: LocalNetworkSpeedTest.summary(report)
        )
    }

    static func decode(_ text: String) -> SpeedSnapshot? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SpeedSnapshot.self, from: data)
    }

    func encoded() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return detail }
        return String(decoding: data, as: UTF8.self)
    }
}

struct SpeedRecord: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var at: Date
    var snapshot: SpeedSnapshot
}

enum SpeedHistory {
    static let defaultsKey = "networkTools.speedHistory"
    // shortcut: 只留最近 50 条，再早的记录挤掉。要全留就改这里。
    private static let limit = 50

    static func load(defaults: UserDefaults = .standard) -> [SpeedRecord] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([SpeedRecord].self, from: data)) ?? []
    }

    static func append(_ snapshot: SpeedSnapshot, at: Date = Date(), defaults: UserDefaults = .standard) {
        var items = load(defaults: defaults)
        items.insert(SpeedRecord(id: UUID(), at: at, snapshot: snapshot), at: 0)
        if items.count > limit { items = Array(items.prefix(limit)) }
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

struct LatencySnapshot: Codable, Equatable, Sendable {
    var target: String
    var averageMs: Double?
    var loss: String
    var detail: String

    static func make(from detail: String) -> LatencySnapshot? {
        let samples = LabUtilityProcess.latencySamples(in: detail)
        guard !samples.isEmpty else { return nil }
        let times = samples.compactMap { $0 }
        let average = times.isEmpty ? nil : times.reduce(0, +) / Double(times.count)
        return LatencySnapshot(
            target: labeled("目标", in: detail) ?? "时延",
            averageMs: average,
            loss: labeled("丢包", in: detail) ?? "—",
            detail: detail
        )
    }

    private static func labeled(_ key: String, in text: String) -> String? {
        let prefix = key + "："
        guard let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix(prefix) }) else { return nil }
        let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : String(value)
    }
}

struct LatencyRecord: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var at: Date
    var snapshot: LatencySnapshot
}

enum LatencyHistory {
    static let defaultsKey = "networkTools.latencyHistory"
    private static let limit = 50

    static func load(defaults: UserDefaults = .standard) -> [LatencyRecord] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([LatencyRecord].self, from: data)) ?? []
    }

    static func append(_ snapshot: LatencySnapshot, at: Date = Date(), defaults: UserDefaults = .standard) {
        var items = load(defaults: defaults)
        items.insert(LatencyRecord(id: UUID(), at: at, snapshot: snapshot), at: 0)
        if items.count > limit { items = Array(items.prefix(limit)) }
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

private final class DownloadMeter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Result {
        var bytes: Int
        var seconds: TimeInterval
        var warmupBytes: Int
        var latencyMs: Int
        var wave: [Double]
    }

    let onUpdate: (@Sendable (String) -> Void)?
    let onBytes: (@Sendable (Int) -> Void)?
    let source: String
    private let lock = NSLock()
    private let started: Date
    private var firstByte: Date?
    private var count = 0
    private var warmupBytes = 0
    private var warmed = false
    private var status = 0
    private var stopping = false
    private var rotating = false
    private var wave = LocalNetworkSpeedTest.SecondWave()
    private var lastPaint = Date.distantPast
    private var lastByteAt = Date()
    private var responseBytes = 0
    private var expectedBytes: Int64 = -1
    private var watchdog: DispatchSourceTimer?
    private var continuation: CheckedContinuation<Result, Error>?
    private var finished: Swift.Result<Result, Error>?
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var url: URL?

    init(onUpdate: (@Sendable (String) -> Void)?, source: String, onBytes: (@Sendable (Int) -> Void)? = nil, started: Date = Date()) {
        self.onUpdate = onUpdate
        self.onBytes = onBytes
        self.source = source
        self.started = started
    }

    func run(url: URL, session: URLSession) async throws -> Result {
        self.url = url
        self.session = session
        let task = makeTask()
        self.task = task
        startWatchdog()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let finished {
                    lock.unlock()
                    continuation.resume(with: finished)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                    task.resume()
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func makeTask() -> URLSessionDataTask {
        var request = URLRequest(url: url!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return session!.dataTask(with: request)
    }

    private func cancel() {
        lock.lock()
        stopping = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    /// 结束当前这一小段，不结束整次测速，好让后面的秒继续下载。
    private func rotate() {
        lock.lock()
        guard !stopping, !rotating else { lock.unlock(); return }
        rotating = true
        responseBytes = 0
        lastByteAt = Date()
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.tick() }
        watchdog = timer
        timer.resume()
    }

    private func tick() {
        lock.lock()
        let elapsed = Date().timeIntervalSince(started)
        let marked = wave.note(bytes: count, elapsed: elapsed)
        let quiet = Date().timeIntervalSince(lastByteAt)
        let received = responseBytes
        let bytes = count
        let stop = stopping
        lock.unlock()
        if stop { return }
        if marked { publish(bytes: bytes, elapsed: elapsed) }
        if elapsed >= LocalNetworkSpeedTest.sampleSeconds {
            cancel()
            return
        }
        if LocalNetworkSpeedTest.shouldRotateDownload(quiet: quiet, received: received, elapsed: elapsed) {
            rotate()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        lock.lock()
        responseBytes = 0
        expectedBytes = response.expectedContentLength
        lastByteAt = Date()
        lock.unlock()
        completionHandler((200...299).contains(status) ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if firstByte == nil { firstByte = Date() }
        let elapsed = Date().timeIntervalSince(started)
        lock.lock()
        count += data.count
        responseBytes += data.count
        lastByteAt = Date()
        if !warmed, elapsed >= LocalNetworkSpeedTest.warmup {
            warmupBytes = count
            warmed = true
        }
        let marked = wave.note(bytes: count, elapsed: elapsed)
        let finishedBody = expectedBytes > 0 && Int64(responseBytes) >= expectedBytes
        let bytes = count
        lock.unlock()
        if marked || Date().timeIntervalSince(lastPaint) > 0.3 {
            publish(bytes: bytes, elapsed: elapsed)
        }
        if elapsed >= LocalNetworkSpeedTest.sampleSeconds {
            cancel()
        } else if finishedBody {
            rotate()
        }
        onBytes?(data.count)
    }

    private func publish(bytes: Int, elapsed: TimeInterval) {
        lastPaint = Date()
        onUpdate?(progressText(kind: "下", bytes: bytes, elapsed: elapsed))
    }

    private func progressText(kind: String, bytes: Int, elapsed: TimeInterval) -> String {
        let rate = LocalNetworkSpeedTest.byteRate(mbps: LocalNetworkSpeedTest.mbps(bytes: bytes, seconds: elapsed))
        var text = String(format: "测速中 · \(source)\n已传输 %@\n当前 %.1f MB/s",
                          ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file), rate)
        if !wave.rates.isEmpty {
            text += "\n" + LocalNetworkSpeedTest.waveLine(kind: kind, rates: wave.rates)
        }
        return text
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let elapsed = Date().timeIntervalSince(started)
        lock.lock()
        _ = wave.note(bytes: count, elapsed: elapsed)
        let rotate = rotating
        rotating = false
        let again = LocalNetworkSpeedTest.shouldRepeatTransfer(
            elapsed: elapsed, stopping: stopping, status: status, bytes: count, failed: error != nil && !rotate
        )
        if again, let next = self.session == nil ? nil : makeTask() {
            self.task = next
            lock.unlock()
            next.resume()
            return
        }
        self.session = nil
        self.url = nil
        lock.unlock()
        watchdog?.cancel()
        watchdog = nil
        let outcome: Swift.Result<Result, Error>
        if !(200...299).contains(status) || count < 64 * 1024 {
            let detail = error?.localizedDescription ?? "HTTP \(status)"
            outcome = .failure(URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "\(source) 不可用（\(detail)）"]))
        } else {
            let latency = Int((firstByte ?? Date()).timeIntervalSince(started) * 1000)
            outcome = .success(Result(bytes: count, seconds: elapsed, warmupBytes: warmupBytes, latencyMs: max(1, latency), wave: wave.rates))
        }
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: outcome)
        } else {
            finished = outcome
            lock.unlock()
        }
    }
}

private final class UploadMeter: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate, @unchecked Sendable {
    struct Result {
        var bytes: Int
        var seconds: TimeInterval
        var warmupBytes: Int
        var wave: [Double]
    }

    let onUpdate: (@Sendable (String) -> Void)?
    let onBytes: (@Sendable (Int) -> Void)?
    let source: String
    private let lock = NSLock()
    private let started: Date
    private var count = 0
    private var sentBefore = 0
    private var warmupBytes = 0
    private var warmed = false
    private var status = 0
    private var stopping = false
    private var wave = LocalNetworkSpeedTest.SecondWave()
    private var lastPaint = Date.distantPast
    private var continuation: CheckedContinuation<Result, Error>?
    private var finished: Swift.Result<Result, Error>?
    private var task: URLSessionUploadTask?
    private var bodyOutput: OutputStream?
    private var session: URLSession?
    private var url: URL?

    init(onUpdate: (@Sendable (String) -> Void)?, source: String, onBytes: (@Sendable (Int) -> Void)? = nil, started: Date = Date()) {
        self.onUpdate = onUpdate
        self.onBytes = onBytes
        self.source = source
        self.started = started
    }

    func run(url: URL, session: URLSession) async throws -> Result {
        self.url = url
        self.session = session
        let task = makeTask()
        self.task = task
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let finished {
                    lock.unlock()
                    continuation.resume(with: finished)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                    task.resume()
                }
            }
        } onCancel: {
            cancel()
        }
    }

    private func makeTask() -> URLSessionUploadTask {
        var request = URLRequest(url: url!)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        return session!.uploadTask(withStreamedRequest: request)
    }

    private func cancel() {
        lock.lock()
        stopping = true
        let task = self.task
        let output = bodyOutput
        bodyOutput = nil
        lock.unlock()
        output?.close()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, needNewBodyStream completionHandler: @escaping (InputStream?) -> Void) {
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: 256 * 1024, inputStream: &input, outputStream: &output)
        guard let input, let output else {
            completionHandler(nil)
            return
        }
        bodyOutput = output
        output.open()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { output.close(); return }
            let chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                self.lock.lock()
                let stop = self.stopping || Date().timeIntervalSince(self.started) >= LocalNetworkSpeedTest.sampleSeconds
                self.lock.unlock()
                if stop {
                    self.cancel()
                    break
                }
                let count = chunk.withUnsafeBytes { raw -> Int in
                    output.write(raw.bindMemory(to: UInt8.self).baseAddress!, maxLength: chunk.count)
                }
                if count < 0 { break }
                if count == 0 { Thread.sleep(forTimeInterval: 0.01) }
            }
            output.close()
        }
        completionHandler(input)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if bytesSent > 0 { onBytes?(Int(bytesSent)) }
        count = sentBefore + Int(totalBytesSent)
        let elapsed = Date().timeIntervalSince(started)
        if !warmed, elapsed >= LocalNetworkSpeedTest.warmup {
            warmupBytes = count
            warmed = true
        }
        let marked = wave.note(bytes: count, elapsed: elapsed)
        if marked || Date().timeIntervalSince(lastPaint) > 0.3 {
            lastPaint = Date()
            let rate = LocalNetworkSpeedTest.byteRate(mbps: LocalNetworkSpeedTest.mbps(bytes: count, seconds: elapsed))
            var text = String(format: "测速中 · \(source)\n已传输 %@\n当前 %.1f MB/s",
                              ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file), rate)
            if !wave.rates.isEmpty {
                text += "\n" + LocalNetworkSpeedTest.waveLine(kind: "上", rates: wave.rates)
            }
            onUpdate?(text)
        }
        if elapsed >= LocalNetworkSpeedTest.sampleSeconds {
            cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let elapsed = Date().timeIntervalSince(started)
        _ = wave.note(bytes: count, elapsed: elapsed)
        lock.lock()
        let again = LocalNetworkSpeedTest.shouldRepeatTransfer(
            elapsed: elapsed, stopping: stopping, status: status, bytes: count, failed: error != nil
        )
        if again, let next = self.session == nil ? nil : makeTask() {
            sentBefore = count
            let output = bodyOutput
            bodyOutput = nil
            self.task = next
            lock.unlock()
            output?.close()
            next.resume()
            return
        }
        self.session = nil
        self.url = nil
        lock.unlock()
        let cancelledByUs = (error as NSError?)?.code == NSURLErrorCancelled && count >= 64 * 1024
        let accepted = (200...299).contains(status) && count >= 64 * 1024
        let outcome: Swift.Result<Result, Error>
        if accepted || cancelledByUs {
            outcome = .success(Result(bytes: count, seconds: elapsed, warmupBytes: warmupBytes, wave: wave.rates))
        } else {
            let detail = error?.localizedDescription ?? "HTTP \(status)"
            outcome = .failure(URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "\(source) 不可用（\(detail)）"]))
        }
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: outcome)
        } else {
            finished = outcome
            lock.unlock()
        }
    }

}
