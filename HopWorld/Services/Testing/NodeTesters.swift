import Foundation
import Darwin
import Network

enum TCPTester {
    /// DNS and dialing belong to one cancellable connection and one deadline.
    /// A timeout closes the actual connection, rather than abandoning a blocked
    /// getaddrinfo/connect worker on the global thread pool.
    static func measure(host: String, port: Int, timeout: TimeInterval = 3) async -> Int? {
        guard (1...65535).contains(port), timeout.isFinite, !Task.isCancelled else { return nil }
        let probe = TCPConnectionProbe()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                probe.start(host: host, port: UInt16(port), timeout: max(0.05, timeout), continuation: continuation)
            }
        } onCancel: {
            probe.cancel()
        }
    }
}

private final class TCPConnectionProbe: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "com.hopworld.tcp-probes", qos: .userInitiated)
    private var connection: NWConnection?
    private var completion: CheckedContinuation<Int?, Never>?
    private var timeoutWork: DispatchWorkItem?
    private var writable: DispatchSourceWrite?
    private var finished = false

    func start(host: String, port: UInt16, timeout: TimeInterval, continuation: CheckedContinuation<Int?, Never>) {
        Self.queue.async { [self] in
            guard !finished else { continuation.resume(returning: nil); return }
            completion = continuation
            let started = ProcessInfo.processInfo.systemUptime
            let work = DispatchWorkItem { [weak self] in self?.finish(nil) }
            timeoutWork = work
            Self.queue.asyncAfter(deadline: .now() + timeout, execute: work)
            if let address = Self.numericAddress(host: host, port: port) {
                startNumeric(address.data, family: address.family, started: started)
                return
            }
            let parameters = NWParameters.tcp
            // Probe the node itself even while the user's system proxy is on.
            parameters.preferNoProxies = true
            let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: parameters)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.finish(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))
                case .failed, .cancelled:
                    self?.finish(nil)
                case .waiting(let error):
                    // A refused port cannot benefit from waiting out the full
                    // budget. Other transient path states retain the deadline.
                    if case .posix(.ECONNREFUSED) = error { self?.finish(nil) }
                    if case .dns = error { self?.finish(nil) }
                default:
                    break // .waiting may recover; the deadline still applies.
                }
            }
            connection.start(queue: Self.queue)
        }
    }

    func cancel() { Self.queue.async { [self] in finish(nil) } }

    private func finish(_ latency: Int?) {
        guard !finished else { return }
        finished = true
        timeoutWork?.cancel()
        timeoutWork = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        writable?.cancel()
        writable = nil
        completion?.resume(returning: latency)
        completion = nil
    }

    private static func numericAddress(host: String, port: UInt16) -> (data: Data, family: Int32)? {
        var v4 = sockaddr_in()
        if inet_pton(AF_INET, host, &v4.sin_addr) == 1 {
            v4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            v4.sin_family = sa_family_t(AF_INET)
            v4.sin_port = port.bigEndian
            return (withUnsafeBytes(of: v4) { Data($0) }, AF_INET)
        }
        var v6 = sockaddr_in6()
        if inet_pton(AF_INET6, host, &v6.sin6_addr) == 1 {
            v6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            v6.sin6_family = sa_family_t(AF_INET6)
            v6.sin6_port = port.bigEndian
            return (withUnsafeBytes(of: v6) { Data($0) }, AF_INET6)
        }
        return nil
    }

    /// Numeric endpoints need no resolver: nonblocking connect reports refusal
    /// immediately instead of Network.framework's connection retry delay.
    private func startNumeric(_ address: Data, family: Int32, started: TimeInterval) {
        let fd = socket(family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { finish(nil); return }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { close(fd); finish(nil); return }
        let result = address.withUnsafeBytes { bytes in
            Darwin.connect(fd, bytes.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(address.count))
        }
        if result == 0 {
            close(fd)
            finish(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))
            return
        }
        guard errno == EINPROGRESS else { close(fd); finish(nil); return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: Self.queue)
        source.setEventHandler { [weak self] in
            guard let self, !finished else { return }
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            let success = getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0 && error == 0
            finish(success ? Int((ProcessInfo.processInfo.systemUptime - started) * 1000) : nil)
        }
        source.setCancelHandler { close(fd) }
        writable = source
        source.resume()
    }
}

enum DNSTester {
    static func resolve(host: String) async -> (latency: Int?, ipv4: String?, ipv6: String?) {
        // Skip DNS for literal IPs.
        if host.split(separator: ".").allSatisfy({ Int($0) != nil }) || host.contains(":") {
            return (0, host.contains(":") ? nil : host, host.contains(":") ? host : nil)
        }

        let start = Date()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo(
                    ai_flags: AI_ADDRCONFIG,
                    ai_family: AF_INET, // IPv4 first — faster for proxy latency probe
                    ai_socktype: SOCK_STREAM,
                    ai_protocol: 0,
                    ai_addrlen: 0,
                    ai_canonname: nil,
                    ai_addr: nil,
                    ai_next: nil
                )
                var resultPtr: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(host, nil, &hints, &resultPtr)
                defer { if let resultPtr { freeaddrinfo(resultPtr) } }

                guard status == 0, let first = resultPtr else {
                    continuation.resume(returning: (nil, nil, nil))
                    return
                }

                var ipv4: String?
                var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    first.pointee.ai_addr,
                    first.pointee.ai_addrlen,
                    &hostBuffer,
                    socklen_t(hostBuffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0 {
                    ipv4 = String(cString: hostBuffer)
                }

                let ms = Int(Date().timeIntervalSince(start) * 1000)
                continuation.resume(returning: (ms, ipv4, nil))
            }
        }
    }
}

enum ProxyHTTPTester {
    enum ProxyKind: Sendable {
        case http(host: String, port: Int)
        case socks5(host: String, port: Int)
    }

    /// Probe connectivity through the local inbound.
    /// - `strict`: require a real HTTPS response via curl (CONNECT-only is not enough to browse).
    /// - `singleURL`: only probe `testURL` (fast path for batch node tests). When false, try a few fallbacks.
    /// - `acceptAnyHTTPResponse`: 任意 HTTP 状态码（含 403）即算可达，适合应用连通探测。
    static func measure(
        proxyHost: String,
        proxyPort: Int,
        testURL: URL,
        timeout: TimeInterval = 4,
        socksPort: Int? = nil,
        strict: Bool = false,
        singleURL: Bool = false,
        acceptAnyHTTPResponse: Bool = false,
        userAgent: String? = nil
    ) async -> Int? {
        let checksChatGPTConnectivity = isChatGPTConnectivityURL(testURL)
        let probeURLs = (singleURL || checksChatGPTConnectivity)
            ? primaryHTTPURL(from: testURL).map { [$0] } ?? []
            : httpCandidates(from: testURL)
        guard !probeURLs.isEmpty else { return nil }

        // Real HTTPS through proxy — what browsers need.
        if let socksPort {
            for url in probeURLs {
                guard !Task.isCancelled else { return nil }
                if let ms = await curlHTTPS(
                    url: url,
                    socksHost: proxyHost,
                    socksPort: socksPort,
                    timeout: timeout,
                    acceptAnyHTTPResponse: acceptAnyHTTPResponse,
                    userAgent: userAgent
                ) {
                    return ms
                }
            }
        }
        for url in probeURLs {
            guard !Task.isCancelled else { return nil }
            if let ms = await curlHTTPS(
                url: url,
                httpProxyHost: proxyHost,
                httpProxyPort: proxyPort,
                timeout: timeout,
                acceptAnyHTTPResponse: acceptAnyHTTPResponse,
                userAgent: userAgent
            ) {
                return ms
            }
        }

        if strict || checksChatGPTConnectivity || Task.isCancelled {
            // Do not accept CONNECT-only: that caused "connected but Google/Cursor won't load".
            return nil
        }

        // Loose mode (node list probe): tunnel establishment as weak reachability signal.
        let target = tunnelTarget(from: testURL)
        if let socksPort {
            if let ms = await ProxyTunnelTester.socks5Connect(
                proxyHost: proxyHost,
                proxyPort: socksPort,
                targetHost: target.host,
                targetPort: target.port,
                timeout: min(timeout, 3)
            ) {
                return ms
            }
        }
        if let ms = await ProxyTunnelTester.httpConnect(
            proxyHost: proxyHost,
            proxyPort: proxyPort,
            targetHost: target.host,
            targetPort: target.port,
            timeout: min(timeout, 3)
        ) {
            return ms
        }
        return nil
    }

    static func primaryHTTPURL(from testURL: URL) -> URL? {
        AppSettings.validatedTestURL(testURL.absoluteString)
    }

    private static func httpCandidates(from testURL: URL) -> [URL] {
        var urls: [URL] = []
        func appendUnique(_ url: URL) {
            guard AppSettings.validatedTestURL(url.absoluteString) != nil else { return }
            guard !urls.contains(url) else { return }
            urls.append(url)
        }
        if let primary = primaryHTTPURL(from: testURL) {
            appendUnique(primary)
        }
        for raw in [
            "https://www.gstatic.com/generate_204",
            "https://www.google.com/generate_204",
            "https://captive.apple.com/hotspot-detect.html"
        ] {
            if let url = URL(string: raw) { appendUnique(url) }
        }
        return urls
    }

    private static func tunnelTarget(from url: URL) -> (host: String, port: Int) {
        let host = url.host ?? "www.gstatic.com"
        if let port = url.port { return (host, port) }
        switch url.scheme?.lowercased() {
        case "http": return (host, 80)
        default: return (host, 443)
        }
    }

    /// curl is far more reliable than URLSession for TLS-over-local-proxy on macOS.
    /// - `acceptAnyHTTPResponse`: 收到任意 HTTP 状态码即视为可达（含 403/429，适合 ChatGPT 等反爬站点）。
    private static func curlHTTPS(
        url: URL, socksHost: String? = nil, socksPort: Int? = nil,
        httpProxyHost: String? = nil, httpProxyPort: Int? = nil,
        timeout: TimeInterval, acceptAnyHTTPResponse: Bool = false, userAgent: String? = nil
    ) async -> Int? {
        await diagnoseHTTPS(url: url, socksHost: socksHost, socksPort: socksPort,
                            httpProxyHost: httpProxyHost, httpProxyPort: httpProxyPort,
                            timeout: timeout, acceptAnyHTTPResponse: acceptAnyHTTPResponse, userAgent: userAgent).latency
    }

    struct HTTPSOutcome: Sendable {
        var latency: Int?
        var error: String?
        var statusCode: Int? = nil
        var warning: String? = nil
        var timedOut = false
    }

    static func diagnoseHTTPS(
        url: URL,
        socksHost: String? = nil,
        socksPort: Int? = nil,
        httpProxyHost: String? = nil,
        httpProxyPort: Int? = nil,
        timeout: TimeInterval,
        acceptAnyHTTPResponse: Bool = false,
        userAgent: String? = nil,
        followRedirects: Bool = true
    ) async -> HTTPSOutcome {
        let checksChatGPTConnectivity = isChatGPTConnectivityURL(url)
        var args = [
            "-sS",
            "--noproxy", "",
            "-o", "/dev/null",
            "-w", "\nHOPWORLD_RESULT %{http_code} %{time_total}",
            // connect-timeout 需覆盖整段 TLS（含 FinalMask fragment）；勿再硬压到 2.5s。
            "--connect-timeout", String(format: "%.1f", max(0.8, timeout)),
            "--max-time", String(format: "%.1f", max(1.0, timeout + 0.5)),
            "--http1.1",
            url.absoluteString
        ]
        if checksChatGPTConnectivity { args.insert("--head", at: 1) }
        if followRedirects && !checksChatGPTConnectivity { args.insert(contentsOf: ["-L", "--max-redirs", "5"], at: 1) }
        if let userAgent, !userAgent.isEmpty {
            args.insert(contentsOf: ["-A", userAgent], at: 1)
        }
        if let socksHost, let socksPort {
            args.insert(contentsOf: ["--socks5-hostname", "\(socksHost):\(socksPort)"], at: 1)
        } else if let httpProxyHost, let httpProxyPort {
            args.insert(contentsOf: ["-x", "http://\(httpProxyHost):\(httpProxyPort)"], at: 1)
        }
        let result: ProcessRunResult
        do {
            result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/curl"), arguments: args,
                                                 timeout: max(1, timeout + 0.5))
        } catch {
            return HTTPSOutcome(error: "无法启动 HTTPS 探测进程")
        }
        if result.cancelled { return HTTPSOutcome(error: "测试已取消") }
        if result.timedOut || result.status != 0 {
            return HTTPSOutcome(error: failureReason(status: result.status, timedOut: result.timedOut, timeout: timeout, diagnostic: String(decoding: result.output, as: UTF8.self)),
                                timedOut: result.timedOut || result.status == 28)
        }
        let text = String(decoding: result.output, as: UTF8.self)
        guard let line = text.components(separatedBy: .newlines).last(where: { $0.hasPrefix("HOPWORLD_RESULT ") }) else { return HTTPSOutcome(error: "HTTPS 探测未返回有效结果") }
        let parts = line.split(separator: " ").dropFirst()
        guard parts.count == 2, let code = parts.first, let status = Int(code),
              let seconds = Double(parts.last!), seconds.isFinite, seconds >= 0 else { return HTTPSOutcome(error: "HTTPS 探测结果格式无效") }
        return httpReachabilityOutcome(status: status, latency: Int(seconds * 1000),
                                       acceptAnyHTTPResponse: acceptAnyHTTPResponse || checksChatGPTConnectivity)
    }

    static func httpReachabilityOutcome(status: Int, latency: Int,
                                        acceptAnyHTTPResponse: Bool = false) -> HTTPSOutcome {
        let accepted = acceptAnyHTTPResponse
            ? (100...599).contains(status)
            : (200...399).contains(status)
        return accepted ? HTTPSOutcome(latency: latency, statusCode: status)
            : HTTPSOutcome(error: "测试网站返回 HTTP \(status)", statusCode: status)
    }

    private static func isChatGPTConnectivityURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host?.lowercased() == "chatgpt.com" else { return false }
        let path = url.path
        return path.isEmpty || path == "/" || path == "/generate_204"
            || path == "/backend-api/codex/responses"
    }

    static func failureReason(status: Int32, timedOut: Bool, timeout: TimeInterval, diagnostic: String = "") -> String {
        if timedOut || status == 28 { return "HTTPS 探测超时（\(Int(timeout)) 秒）" }
        switch status {
        case 5, 6: return "探测地址 DNS 解析失败"
        case 7: return "无法连接本地测试代理"
        case 35: return "HTTPS/TLS 握手失败"
        case 51, 60:
            let detail = diagnostic.lowercased()
            if detail.contains("no alternative certificate subject name matches") ||
                detail.contains("does not match target host") || detail.contains("not valid for name") {
                return "HTTPS 证书域名不匹配"
            }
            return "HTTPS 证书校验失败"
        case 52: return "连接关闭，未收到响应"
        case 55, 56: return "连接中断或被重置"
        default: return "HTTPS 探测失败（curl 错误码 \(status)）"
        }
    }

    static func measureOnce(
        url: URL,
        proxy: ProxyKind,
        timeout: TimeInterval
    ) async -> Int? {
        let config = URLSessionConfiguration.ephemeral
        var proxyDict = proxyDictionary(for: proxy)
        proxyDict["ProxyAutoConfigEnable"] = 0
        config.connectionProxyDictionary = proxyDict
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData

        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let start = Date()
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...399).contains(http.statusCode)
            else { return nil }
            return Int(Date().timeIntervalSince(start) * 1000)
        } catch {
            return nil
        }
    }

    private static func proxyDictionary(for proxy: ProxyKind) -> [AnyHashable: Any] {
        switch proxy {
        case .http(let host, let port):
            return [
                kCFNetworkProxiesHTTPEnable as String: true,
                kCFNetworkProxiesHTTPProxy as String: host,
                kCFNetworkProxiesHTTPPort as String: port,
                kCFNetworkProxiesHTTPSEnable as String: true,
                kCFNetworkProxiesHTTPSProxy as String: host,
                kCFNetworkProxiesHTTPSPort as String: port
            ]
        case .socks5(let host, let port):
            return [
                kCFStreamPropertySOCKSProxyHost as String: host,
                kCFStreamPropertySOCKSProxyPort as String: port,
                kCFStreamPropertySOCKSVersion as String: kCFStreamSocketSOCKSVersion5
            ]
        }
    }
}

/// Establishes a TCP tunnel through local SOCKS5 / HTTP proxy without URLSession TLS.
enum ProxyTunnelTester {
    static func socks5Connect(
        proxyHost: String,
        proxyPort: Int,
        targetHost: String,
        targetPort: Int,
        timeout: TimeInterval
    ) async -> Int? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let start = Date()
                let ok = performSOCKS5(
                    proxyHost: proxyHost,
                    proxyPort: proxyPort,
                    targetHost: targetHost,
                    targetPort: targetPort,
                    timeout: timeout
                )
                continuation.resume(returning: ok ? Int(Date().timeIntervalSince(start) * 1000) : nil)
            }
        }
    }

    static func httpConnect(
        proxyHost: String,
        proxyPort: Int,
        targetHost: String,
        targetPort: Int,
        timeout: TimeInterval
    ) async -> Int? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let start = Date()
                let ok = performHTTPConnect(
                    proxyHost: proxyHost,
                    proxyPort: proxyPort,
                    targetHost: targetHost,
                    targetPort: targetPort,
                    timeout: timeout
                )
                continuation.resume(returning: ok ? Int(Date().timeIntervalSince(start) * 1000) : nil)
            }
        }
    }

    private static func performSOCKS5(
        proxyHost: String,
        proxyPort: Int,
        targetHost: String,
        targetPort: Int,
        timeout: TimeInterval
    ) -> Bool {
        guard let fd = connectTCP(host: proxyHost, port: proxyPort, timeout: timeout) else { return false }
        defer { close(fd) }

        // greeting: VER=5, NMETHODS=1, METHOD=0 (no auth)
        guard writeAll(fd, Data([0x05, 0x01, 0x00])) else { return false }
        guard let greet = readExact(fd, count: 2), greet.count == 2, greet[0] == 0x05, greet[1] == 0x00 else {
            return false
        }

        var request = Data([0x05, 0x01, 0x00, 0x03]) // CONNECT, domain
        let hostData = Data(targetHost.utf8)
        guard hostData.count <= 255 else { return false }
        request.append(UInt8(hostData.count))
        request.append(hostData)
        request.append(UInt8((targetPort >> 8) & 0xff))
        request.append(UInt8(targetPort & 0xff))
        guard writeAll(fd, request) else { return false }

        // reply: VER REP RSV ATYP ...
        guard let head = readExact(fd, count: 4), head.count == 4, head[0] == 0x05, head[1] == 0x00 else {
            return false
        }
        let skip: Int
        switch head[3] {
        case 0x01: skip = 4 + 2
        case 0x03:
            guard let lenData = readExact(fd, count: 1), let len = lenData.first else { return false }
            skip = Int(len) + 2
        case 0x04: skip = 16 + 2
        default: return false
        }
        guard readExact(fd, count: skip) != nil else { return false }
        return true
    }

    private static func performHTTPConnect(
        proxyHost: String,
        proxyPort: Int,
        targetHost: String,
        targetPort: Int,
        timeout: TimeInterval
    ) -> Bool {
        guard let fd = connectTCP(host: proxyHost, port: proxyPort, timeout: timeout) else { return false }
        defer { close(fd) }

        let request = "CONNECT \(targetHost):\(targetPort) HTTP/1.1\r\nHost: \(targetHost):\(targetPort)\r\nProxy-Connection: keep-alive\r\n\r\n"
        guard writeAll(fd, Data(request.utf8)) else { return false }

        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var chunk = [UInt8](repeating: 0, count: 1024)
            let n = chunk.withUnsafeMutableBytes { ptr in
                recv(fd, ptr.baseAddress, 1024, 0)
            }
            if n > 0 {
                buffer.append(contentsOf: chunk.prefix(n))
                if let text = String(data: buffer, encoding: .utf8),
                   text.contains("\r\n\r\n") {
                    let statusLine = text.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
                    return statusLine.contains(" 200")
                }
                if buffer.count > 8192 { return false }
            } else if n == 0 {
                return false
            } else if errno != EAGAIN && errno != EWOULDBLOCK {
                return false
            } else {
                usleep(20_000)
            }
        }
        return false
    }

    private static func connectTCP(host: String, port: Int, timeout: TimeInterval) -> Int32? {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let info = result else {
            return nil
        }
        defer { freeaddrinfo(info) }

        var cursor: UnsafeMutablePointer<addrinfo>? = info
        while let ai = cursor {
            let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if fd >= 0 {
                let seconds = Int(timeout)
                let usec = Int32(max(0, (timeout - TimeInterval(seconds)) * 1_000_000))
                var tv = timeval(tv_sec: seconds, tv_usec: usec)
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

                if Darwin.connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 {
                    return fd
                }
                close(fd)
            }
            cursor = ai.pointee.ai_next
        }
        return nil
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var sent = 0
            let total = raw.count
            let base = raw.bindMemory(to: UInt8.self).baseAddress
            while sent < total {
                let n = send(fd, base?.advanced(by: sent), total - sent, 0)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    private static func readExact(_ fd: Int32, count: Int) -> Data? {
        var data = Data()
        data.reserveCapacity(count)
        var buffer = [UInt8](repeating: 0, count: count)
        while data.count < count {
            let need = count - data.count
            let n = buffer.withUnsafeMutableBytes { ptr in
                recv(fd, ptr.baseAddress, need, 0)
            }
            if n <= 0 { return nil }
            data.append(contentsOf: buffer.prefix(n))
        }
        return data
    }
}

enum ExitIPTester {
    struct ExitInfo: Sendable {
        var ip: String?
        var countryCode: String?
        var countryName: String?
        var city: String?
        var asn: String?
        var networkType: ExitIPType?
        var networkOperator: String?
        var region: String?
        var latitude: Double?
        var longitude: Double?

        var nodeMetadata: NodeExitMetadata? {
            guard let ip else { return nil }
            return NodeExitMetadata(ip: ip, city: city, networkOperator: networkOperator, asn: asn, networkType: networkType,
                                   countryCode: countryCode, region: region, latitude: latitude, longitude: longitude)
        }
    }

    static func fetch(
        proxyHost: String,
        proxyPort: Int,
        timeout: TimeInterval = 5,
        socksPort: Int? = nil
    ) async -> ExitInfo {
        let endpoints = [
            "https://api.ipquery.io/?format=json",
            "https://api.ip.sb/geoip",
            "https://ipapi.co/json/",
            "https://ifconfig.co/json"
        ]

        // Prefer curl through SOCKS — more reliable than URLSession TLS-over-proxy.
        if let socksPort {
            for raw in endpoints {
                guard !Task.isCancelled else { return ExitInfo() }
                if let info = await fetchViaCurl(url: raw, socksHost: proxyHost, socksPort: socksPort, timeout: timeout) {
                    return await completingNetworkType(info) { ip in
                        await lookupExitInfo(ip: ip, proxyHost: proxyHost, proxyPort: proxyPort, socksPort: socksPort, timeout: timeout)
                    }
                }
            }
        }

        for raw in endpoints {
            guard !Task.isCancelled else { return ExitInfo() }
            guard let url = URL(string: raw) else { continue }
            if let info = await fetchOne(
                url: url,
                proxyHost: proxyHost,
                proxyPort: proxyPort,
                socksPort: socksPort,
                timeout: timeout
            ) {
                return await completingNetworkType(info) { ip in
                    await lookupExitInfo(ip: ip, proxyHost: proxyHost, proxyPort: proxyPort, socksPort: socksPort, timeout: timeout)
                }
            }
        }
        return ExitInfo()
    }

    /// A fallback geo provider may know the IP without knowing its network type.
    static func completingNetworkType(_ info: ExitInfo,
        lookup: (String) async -> ExitInfo?) async -> ExitInfo {
        guard !Task.isCancelled, info.networkType == nil, let ip = info.ip,
              IPv4Address(ip) != nil || IPv6Address(ip) != nil,
              let detail = await lookup(ip), !Task.isCancelled, detail.ip == ip else { return info }
        var result = info
        result.networkType = detail.networkType
        return result
    }

    static func lookupExitInfo(ip: String, proxyHost: String? = nil, proxyPort: Int? = nil,
                               socksPort: Int? = nil, timeout: TimeInterval = 5) async -> ExitInfo? {
        guard !Task.isCancelled, IPv4Address(ip) != nil || IPv6Address(ip) != nil,
              let url = URL(string: "https://api.ipquery.io/\(ip)?format=json") else { return nil }
        if let socksPort, let proxyHost,
           let info = await fetchViaCurl(url: url.absoluteString, socksHost: proxyHost, socksPort: socksPort, timeout: timeout) {
            return info.ip == ip ? info : nil
        }
        let info = await fetchOne(url: url, proxyHost: proxyHost, proxyPort: proxyPort, socksPort: socksPort, timeout: timeout)
        return info?.ip == ip ? info : nil
    }

    private static func fetchViaCurl(
        url: String,
        socksHost: String,
        socksPort: Int,
        timeout: TimeInterval
    ) async -> ExitInfo? {
        guard let result = try? await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/curl"),
            arguments: ["-sS", "--noproxy", "", "--connect-timeout", String(timeout),
                        "--max-time", String(timeout), "--socks5-hostname", "\(socksHost):\(socksPort)", url],
            timeout: timeout
        ), result.status == 0, !result.cancelled, !result.timedOut else { return nil }
        return parseGeoJSON(result.output)
    }

    private static func fetchOne(
        url: URL,
        proxyHost: String?,
        proxyPort: Int?,
        socksPort: Int?,
        timeout: TimeInterval
    ) async -> ExitInfo? {
        let config = URLSessionConfiguration.ephemeral
        if let socksPort, let proxyHost {
            config.connectionProxyDictionary = [
                kCFStreamPropertySOCKSProxyHost as String: proxyHost,
                kCFStreamPropertySOCKSProxyPort as String: socksPort,
                kCFStreamPropertySOCKSVersion as String: kCFStreamSocketSOCKSVersion5
            ]
        } else if let proxyHost, let proxyPort {
            config.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: true,
                kCFNetworkProxiesHTTPProxy as String: proxyHost,
                kCFNetworkProxiesHTTPPort as String: proxyPort,
                kCFNetworkProxiesHTTPSEnable as String: true,
                kCFNetworkProxiesHTTPSProxy as String: proxyHost,
                kCFNetworkProxiesHTTPSPort as String: proxyPort
            ]
        }
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false

        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            return parseGeoJSON(data)
        } catch {
            return nil
        }
    }

    static func parseGeoJSON(_ data: Data) -> ExitInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let location = json["location"] as? [String: Any] ?? [:]
        let isp = json["isp"] as? [String: Any] ?? [:]
        let ip = (json["ip"] as? String)
            ?? (json["query"] as? String)
            ?? (json["origin"] as? String)
        let code = (json["country_code"] as? String)
            ?? (json["countryCode"] as? String)
            ?? (json["country_iso"] as? String)
            ?? (location["country_code"] as? String)
        let name = (json["country_name"] as? String)
            ?? (json["country"] as? String)
            ?? (location["country"] as? String)
        let city = (json["city"] as? String) ?? (location["city"] as? String)
        let asn = (json["asn"] as? String)
            ?? (json["asn"] as? Int).map { "AS\($0)" }
            ?? (isp["asn"] as? String)
        let networkOperator = (isp["isp"] as? String)
            ?? (isp["org"] as? String)
            ?? (json["isp"] as? String)
            ?? (json["asn_organization"] as? String)
            ?? (json["asn_org"] as? String)
            ?? (json["organization"] as? String)
            ?? (json["org"] as? String)

        let normalizedCode: String? = {
            if let code, code.count == 2 { return code.uppercased() }
            if let name, let resolved = CountryResolver.resolve(fromName: name) {
                return resolved.code
            }
            return code?.uppercased()
        }()

        guard ip != nil || name != nil else { return nil }

        return ExitInfo(
            ip: ip,
            countryCode: normalizedCode,
            countryName: name,
            city: city,
            asn: asn,
            networkType: ip == nil ? nil : networkType(from: json["risk"] as? [String: Any]),
            networkOperator: networkOperator,
            region: (location["state"] as? String) ?? (json["region"] as? String) ?? (json["region_name"] as? String),
            latitude: (location["latitude"] as? Double) ?? (json["latitude"] as? Double) ?? (json["lat"] as? Double),
            longitude: (location["longitude"] as? Double) ?? (json["longitude"] as? Double) ?? (json["lon"] as? Double)
        )
    }

    private static func networkType(from risk: [String: Any]?) -> ExitIPType? {
        guard let risk else { return nil }
        if risk["is_tor"] as? Bool == true { return .tor }
        if risk["is_vpn"] as? Bool == true { return .vpn }
        if risk["is_proxy"] as? Bool == true { return .proxy }
        if risk["is_datacenter"] as? Bool == true { return .hosting }
        if risk["is_mobile"] as? Bool == true { return .mobile }
        // Absence of known flags only suggests residential use; it does not prove it.
        let flags = ["is_tor", "is_vpn", "is_proxy", "is_datacenter", "is_mobile"]
        return flags.allSatisfy { risk[$0] as? Bool == false } ? .residential : nil
    }
}

/// 慢握手节点的测速/连通超时策略（REALITY、Vision、FinalMask）。
enum ProbePolicy {
    static func needsRelaxedTimeout(_ node: ProxyNode) -> Bool {
        if FinalMaskCodec.isPresent(on: node) { return true }
        if node.security == .reality { return true }
        if let flow = node.flow?.lowercased(), flow.contains("vision") { return true }
        return false
    }

    /// 批量默认可能只有 6s，REALITY 冷启动常要 8～12s；至少抬到单测超时，且不低于 12s。
    static func httpsTimeout(
        for node: ProxyNode,
        batchTimeout: TimeInterval,
        singleTimeout: TimeInterval
    ) -> TimeInterval {
        if needsRelaxedTimeout(node) {
            return max(batchTimeout, singleTimeout, 12)
        }
        return batchTimeout
    }
}

struct NodeConfigChecker {
    static func validate(_ node: ProxyNode,
                         loadCredential: (String) -> String? = KeychainStore.load(account:)) -> (Bool, String?) {
        guard !node.server.isEmpty else { return (false, "server 为空") }
        guard (1...65535).contains(node.port) else { return (false, "port 无效") }
        guard node.transport != .masque || node.protocolType == .masque else { return (false, "masque 传输仅支持 MASQUE 协议") }
        var node = node
        KeychainStore.hydrateCredentials(&node, loadCredential: loadCredential)

        switch node.protocolType {
        case .anytls, .tuic, .wireguard, .socks5, .http:
            do { try RemoteProtocolParser.validate(node) }
            catch { return (false, error.localizedDescription) }
        case .masque:
            do { try MasqueParser.validate(node) }
            catch { return (false, error.localizedDescription) }
        case .vless, .vmess:
            guard let uuid = node.uuid, !uuid.isEmpty else { return (false, "缺少 UUID") }
            // 公网明文 VLESS：Xray 禁止；sing-box 又不接受 FinalMask。提前标明，避免变成「Xray 启动失败」长日志。
            if node.protocolType == .vless,
               node.security == .none,
               !isLoopbackOrPrivateHost(node.server),
               FinalMaskCodec.isPresent(on: node) {
                return (false, "公网无 TLS 的 VLESS 无法使用 FinalMask（Xray 禁止明文，sing-box 不支持 FinalMask）")
            }
        case .hysteria2:
            guard !(node.password ?? "").isEmpty else { return (false, "缺少密码") }
        case .trojan:
            guard let password = node.password, !password.isEmpty else { return (false, "缺少密码") }
        case .shadowsocks:
            guard let method = node.method, !method.isEmpty,
                  let password = node.password, !password.isEmpty
            else { return (false, "缺少加密方式或密码") }
            // Xray 26.x 已移除流密码（cfb / rc4 等）；未知 method 会导致整份配置无法启动。
            let normalized = method.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard Self.supportedShadowsocksMethods.contains(normalized) || SingBoxConnectionConfig.requiresSingBox(node) else {
                return (false, "Xray 不支持的 Shadowsocks 加密：\(method)")
            }
        }

        if SingBoxConnectionConfig.requiresSingBox(node) {
            do { _ = try SingBoxConnectionConfig.outbound(node) }
            catch { return (false, error.localizedDescription) }
        }

        if node.security == .reality {
            guard let key = node.publicKey, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return (false, "REALITY 缺少 publicKey")
            }
        }

        // Xray accepts an empty gRPC service name; only the server can reject a mismatch.
        return (true, nil)
    }

    /// AEAD / SS2022 only — matches Xray 26.x outbound shadowsocks.
    private static let supportedShadowsocksMethods: Set<String> = [
        "aes-128-gcm",
        "aes-256-gcm",
        "chacha20-ietf-poly1305",
        "chacha20-poly1305",
        "xchacha20-ietf-poly1305",
        "xchacha20-poly1305",
        "2022-blake3-aes-128-gcm",
        "2022-blake3-aes-256-gcm",
        "2022-blake3-chacha20-poly1305"
    ]

    static func isLoopbackOrPrivateHost(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if h == "localhost" || h.hasSuffix(".local") || h.hasSuffix(".localhost") {
            return true
        }
        if h == "::1" || h.hasPrefix("127.") { return true }
        if h.hasPrefix("10.") { return true }
        if h.hasPrefix("192.168.") { return true }
        if h.hasPrefix("172.") {
            let parts = h.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) {
                return true
            }
        }
        return false
    }
}

/// Off-main-actor probe helpers so concurrent tests don't serialize on UI thread.
enum NodeProbeEngine {
    /// TCP is optional metadata; only the actual proxy request proves usability.
    /// The core may resolve/dial differently from the direct TCP probe. Timeout is the
    /// user's budget, including slow protocols: no hidden 12s floor or retry.
    static func batchProxyProbe(node: ProxyNode, localPort: Int, testURL: URL?,
                                tcpTimeout: TimeInterval, httpsTimeout: TimeInterval) async -> NodeTestResult? {
        guard !Task.isCancelled else { return nil }
        let started = Date()
        async let tcp = node.usesUDPTransport ? nil : TCPTester.measure(host: node.server, port: node.port, timeout: tcpTimeout)
        var result = await httpsThroughProxy(nodeID: node.id, startedAt: started, localPort: localPort,
                                            testURL: testURL, timeout: httpsTimeout, tcpLatency: nil)
        result.tcpLatency = await tcp
        guard !Task.isCancelled else { return nil }
        if !result.success, !node.usesUDPTransport, result.tcpLatency == nil {
            result.failureStage = .tcp
            result.errorMessage = "TCP 连接失败或超时；\(result.errorMessage ?? "代理请求失败")"
        }
        result.finishedAt = Date()
        return result
    }
    /// Fast path: TCP only (optional DNS skipped). Used when xray is unavailable.
    static func tcpOnly(node: ProxyNode, timeout: TimeInterval) async -> NodeTestResult {
        let started = Date()
        let (valid, error) = NodeConfigChecker.validate(node)
        guard valid else {
            return NodeTestResult(
                nodeID: node.id,
                startedAt: started,
                finishedAt: Date(),
                configValid: false,
                success: false,
                failureStage: .config,
                errorMessage: error
            )
        }

        guard ![.anytls, .hysteria2, .masque, .tuic, .wireguard, .socks5, .http].contains(node.protocolType) else {
            return NodeTestResult(nodeID: node.id, startedAt: started, finishedAt: Date(), configValid: true,
                                  success: false, failureStage: .config, errorMessage: "\(node.protocolType.displayName) 需要 Xray 内核进行代理连通测试")
        }
        let tcp = await TCPTester.measure(host: node.server, port: node.port, timeout: timeout)
        return NodeTestResult(
            nodeID: node.id,
            startedAt: started,
            finishedAt: Date(),
            configValid: true,
            tcpLatency: tcp,
            success: tcp != nil,
            failureStage: tcp == nil ? .tcp : nil,
            errorMessage: tcp == nil ? "TCP 连接失败" : nil
        )
    }

    /// Quick probe through local xray HTTP inbound.
    /// Uses the same proxy-first decision as batch testing.
    static func quickProxyProbe(
        node: ProxyNode,
        localPort: Int,
        testURL: URL?,
        timeout: TimeInterval
    ) async -> NodeTestResult {
        let started = Date()
        let (valid, error) = NodeConfigChecker.validate(node)
        guard valid else {
            return NodeTestResult(
                nodeID: node.id,
                startedAt: started,
                finishedAt: Date(),
                configValid: false,
                success: false,
                failureStage: .config,
                errorMessage: error
            )
        }

        return await batchProxyProbe(node: node, localPort: localPort, testURL: testURL,
                                     tcpTimeout: min(timeout, 1), httpsTimeout: timeout)
            ?? NodeTestResult(nodeID: node.id, startedAt: started, finishedAt: Date(),
                              configValid: true, errorMessage: "测试已取消")
    }

    /// A real HTTP(S) response through the node's local proxy inbound.
    static func httpsThroughProxy(
        nodeID: UUID,
        startedAt: Date = Date(),
        localPort: Int,
        testURL: URL?,
        timeout: TimeInterval,
        tcpLatency: Int?
    ) async -> NodeTestResult {
        var outcome = ProxyHTTPTester.HTTPSOutcome(error: "未配置有效的 HTTP 或 HTTPS 测试地址")
        if let testURL, AppSettings.validatedTestURL(testURL.absoluteString) != nil {
            outcome = await ProxyHTTPTester.diagnoseHTTPS(url: testURL, httpProxyHost: "127.0.0.1",
                                                        httpProxyPort: localPort, timeout: timeout)
        }
        let proxyLatency = outcome.latency
        let success = proxyLatency != nil
        return NodeTestResult(
            nodeID: nodeID,
            startedAt: startedAt,
            finishedAt: Date(),
            configValid: true,
            dnsLatency: nil,
            tcpLatency: tcpLatency,
            proxyLatency: proxyLatency,
            success: success,
            failureStage: success ? nil : .http,
            errorMessage: success ? nil : outcome.error
        )
    }
}
