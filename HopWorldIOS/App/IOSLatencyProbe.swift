import Foundation
import Network
#if canImport(Libbox)
import Libbox
#endif

enum IOSProbeOutcome: Equatable {
    case latency(Int)
    case unavailable
    case failed(String)
}

enum IOSLatencyProbe {
    /// 已连接时经系统隧道打开测试目标。未连接时经节点的本地 HTTP 代理打开它。
    static func measure(node: ProxyNode, throughTunnel: Bool, batch: Bool = false, urls: [String]? = nil) async -> (IOSProbeOutcome, IOSExitLookup.ExitIP?) {
        let urls = urls ?? IOSSettings.selectedTestURLs
        guard !urls.isEmpty else { return (.failed("请先在设置中选择测试目标"), nil) }
        if throughTunnel {
            return (await pages(urls: urls, session: .shared, timeout: TimeInterval(batch ? IOSSettings.batchTimeoutSeconds : IOSSettings.timeoutSeconds), attempts: 1), nil)
        }
        return await IOSExitProbe.measureHTTPS(node, urls: urls, batch: batch)
    }

    static func pages(urls: [String], session: URLSession, timeout: TimeInterval, attempts: Int) async -> IOSProbeOutcome {
        guard !urls.isEmpty else { return .failed("请先在设置中选择测试目标") }
        var results: [IOSProbeOutcome] = []
        for raw in urls {
            let outcome = await probe(IOSSettings.probeGroup(for: raw), session: session, timeout: timeout, attempts: attempts)
            if case .failed = outcome { return outcome }
            results.append(outcome)
        }
        return combined(results)
    }

    /// App 服务器有 HTTP 响应即算到达。官网目标仍要求 2xx/3xx。
    static func accepts(status: Int, anyHTTPStatus: Bool) -> Bool {
        if anyHTTPStatus { return (100...599).contains(status) }
        return (200...399).contains(status)
    }

    private static func probe(_ group: IOSSettings.ProbeGroup, session: URLSession, timeout: TimeInterval, attempts: Int) async -> IOSProbeOutcome {
        if group.matchAny {
            var outcome = IOSProbeOutcome.unavailable
            for request in group.requests {
                let one = await fetch(request, session: session, timeout: timeout, attempts: attempts)
                if case .failed = one { return one }
                if case .latency = one { return one }
                outcome = one
            }
            return outcome
        }
        var results: [IOSProbeOutcome] = []
        for request in group.requests {
            let one = await fetch(request, session: session, timeout: timeout, attempts: attempts)
            if case .failed = one { return one }
            results.append(one)
        }
        return combined(results)
    }

    private static func fetch(_ request: IOSSettings.ProbeRequest, session: URLSession, timeout: TimeInterval, attempts: Int) async -> IOSProbeOutcome {
        guard let url = URL(string: request.url) else { return .failed("测试地址无效") }
        var outcome = IOSProbeOutcome.unavailable
        for _ in 0..<attempts {
            if Task.isCancelled { return .failed("测试已取消") }
            var http = URLRequest(url: url)
            http.timeoutInterval = timeout
            let send = http
            let started = Date()
            do {
                let body = try await within(timeout) {
                    let (data, response) = try await IOSURL.load(send, session: session)
                    return TimedBody(data: data, status: (response as? HTTPURLResponse)?.statusCode ?? -1)
                }
                if accepts(status: body.status, anyHTTPStatus: request.anyHTTPStatus) {
                    outcome = .latency(max(1, Int(Date().timeIntervalSince(started) * 1000)))
                    break
                }
            } catch is CancellationError {
                return .failed("测试已取消")
            } catch { }
        }
        return outcome
    }

    static func combined(_ results: [IOSProbeOutcome]) -> IOSProbeOutcome {
        guard !results.isEmpty else { return .failed("请先在设置中选择测试目标") }
        var slowest = 0
        for result in results {
            switch result {
            case .latency(let milliseconds): slowest = max(slowest, milliseconds)
            case .unavailable: return .unavailable
            case .failed(let message): return .failed(message)
            }
        }
        return .latency(slowest)
    }

    /// URLSession does not reliably stop a proxied request at `timeoutInterval`.
    static func within<T: Sendable>(_ timeout: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw URLError(.timedOut) }
            return value
        }
    }

}

private struct TimedBody: Sendable {
    var data: Data
    var status: Int
}

enum IOSExitQuery: Equatable {
    case idle
    case looking
    case found(IOSExitLookup.ExitIP)
    case failed
}

enum IOSExitLookup {
    struct ExitIP: Equatable {
        var ip: String
        var countryCode: String?
        var countryName: String?
        var kind: String?
        var city: String? = nil
        var networkOperator: String? = nil
        var asn: String? = nil
    }

    /// Exit lookup through the local mixed proxy used by the tunnel and latency probe.
    static func fetch(timeout: TimeInterval = 12) async -> ExitIP? {
        await fetchThroughHTTPProxy(port: IOSSingBoxConfig.socksPort, timeout: timeout)
    }

    /// Selecting a node uses a separate local HTTP proxy.
    static func fetchThroughHTTPProxy(port: Int = IOSSingBoxConfig.httpPort, timeout: TimeInterval = 12) async -> ExitIP? {
        let session = httpProxySession(port: port, timeout: timeout)
        defer { session.invalidateAndCancel() }
        return await fetch(via: "http-proxy") { url in
            var request = URLRequest(url: url)
            request.timeoutInterval = timeout
            let send = request
            do {
                let body = try await IOSLatencyProbe.within(timeout) {
                    let (data, response) = try await IOSURL.load(send, session: session)
                    return TimedBody(data: data, status: (response as? HTTPURLResponse)?.statusCode ?? -1)
                }
                guard (200...299).contains(body.status) else {
                    probeLog("http-proxy status \(body.status)")
                    return nil
                }
                return body.data
            } catch {
                probeLog("http-proxy \(error.localizedDescription)")
                return nil
            }
        }
    }

    private static func fetch(via route: String, loader: @escaping (URL) async -> Data?) async -> ExitIP? {
        let endpoints = [
            "https://api.ipquery.io/?format=json",
            "https://api.ip.sb/geoip",
            "https://ipapi.co/json/",
            "https://ifconfig.co/json"
        ]
        for raw in endpoints {
            guard let url = URL(string: raw) else { continue }
            if let data = await loader(url), var exit = parse(data) {
                if exit.kind == nil { exit.kind = await attribute(forIP: exit.ip, loaders: [loader, loader, directAttribute]) }
                probeLog("ok \(route) \(raw) \(exit.countryCode ?? "-") \(exit.ip) \(exit.kind ?? "-")")
                return exit
            }
            probeLog("miss \(route) \(raw)")
        }
        return nil
    }

    static func httpProxySession(port: Int = IOSSingBoxConfig.httpPort, timeout: TimeInterval = 12) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        // iOS 忽略 connectionProxyDictionary，探测会直连测试地址，节点就全部不可用。
        if #available(iOS 17.0, *), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) {
            var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: nwPort))
            proxy.allowFailover = false
            config.proxyConfigurations = [proxy]
        } else {
            // shortcut: iOS 16 及更早没有 proxyConfigurations，旧字典仍会被系统忽略。
            config.connectionProxyDictionary = [
                "HTTPEnable": 1,
                "HTTPProxy": "127.0.0.1",
                "HTTPPort": port,
                "HTTPSEnable": 1,
                "HTTPSProxy": "127.0.0.1",
                "HTTPSPort": port
            ]
        }
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        return URLSession(configuration: config)
    }

    static func parse(_ data: Data) -> ExitIP? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let location = json["location"] as? [String: Any] ?? [:]
        let ip = (json["ip"] as? String) ?? (json["query"] as? String)
        guard let ip, !ip.isEmpty else { return nil }
        let code = (json["country_code"] as? String)
            ?? (json["countryCode"] as? String)
            ?? (location["country_code"] as? String)
        let name = (json["country"] as? String)
            ?? (json["country_name"] as? String)
            ?? (location["country"] as? String)
        let normalized: String? = {
            if let code, code.count == 2, code.allSatisfy({ $0.isASCII && $0.isLetter }) { return code.uppercased() }
            if let name, let resolved = CountryResolver.resolve(fromName: name)?.code { return resolved }
            return nil
        }()
        let isp = json["isp"] as? [String: Any] ?? [:]
        let city = (location["city"] as? String) ?? (json["city"] as? String)
        let networkOperator = (isp["org"] as? String) ?? (isp["isp"] as? String)
            ?? (json["org"] as? String) ?? (json["organization"] as? String) ?? (json["isp"] as? String)
        let rawASN = isp["asn"] ?? json["asn"] ?? json["as"]
        let rawASNText = (rawASN as? String) ?? (rawASN as? NSNumber)?.stringValue
        let asn = rawASNText.map { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && trimmed.allSatisfy(\.isNumber) ? "AS\(trimmed)" : trimmed
        }
        return ExitIP(ip: ip, countryCode: normalized, countryName: name, kind: attribute(in: json), city: city, networkOperator: networkOperator, asn: asn)
    }

    /// IPQuery `risk`，和 Mac 的出口 IP 属性同一套判断。
    private static func attribute(in json: [String: Any]) -> String? {
        guard let risk = json["risk"] as? [String: Any] else { return nil }
        if risk["is_tor"] as? Bool == true { return "Tor 出口" }
        if risk["is_vpn"] as? Bool == true { return "VPN 出口" }
        if risk["is_proxy"] as? Bool == true { return "公共代理" }
        if risk["is_datacenter"] as? Bool == true { return "机房托管" }
        if risk["is_mobile"] as? Bool == true { return "移动网络" }
        let flags = ["is_tor", "is_vpn", "is_proxy", "is_datacenter", "is_mobile"]
        return flags.allSatisfy { risk[$0] as? Bool == false } ? "家庭住宅·推测" : nil
    }

    /// The IP is already known, so a direct lookup still describes that exit, not the device.
    static func attribute(forIP ip: String, loaders: [(URL) async -> Data?]) async -> String? {
        guard ip.allSatisfy({ $0.isNumber || $0 == "." }),
              let url = URL(string: "https://api.ipquery.io/\(ip)?format=json") else { return nil }
        for loader in loaders {
            if let data = await loader(url), let extra = parse(data), extra.ip == ip, let kind = extra.kind {
                return kind
            }
        }
        return nil
    }

    private static func directAttribute(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        return (try? await IOSURL.load(request))?.0
    }

    /// Test all selected targets through the local proxy.
    static func proxyMilliseconds(urls: [String], timeout: TimeInterval, attempts: Int) async -> IOSProbeOutcome {
        let session = httpProxySession(timeout: timeout)
        defer { session.invalidateAndCancel() }
        return await IOSLatencyProbe.pages(urls: urls, session: session, timeout: timeout, attempts: attempts)
    }

}

enum IOSExitProbe {
    static func measure(_ node: ProxyNode) async -> (IOSExitLookup.ExitIP?, String?) {
        #if canImport(Libbox)
        let probe = IOSLibboxProbe()
        ProbeSlot.shared.begin(probe)
        let result = await probe.measure(node)
        ProbeSlot.shared.end(probe)
        return result
        #else
        return (nil, "没有链入 sing-box，无法穿过节点查询")
        #endif
    }

    /// HTTPS round trip through the node's HTTP proxy. Not a direct TCP connect.
    static func measureHTTPS(_ node: ProxyNode, urls: [String], batch: Bool = false) async -> (IOSProbeOutcome, IOSExitLookup.ExitIP?) {
        #if canImport(Libbox)
        let probe = IOSLibboxProbe()
        ProbeSlot.shared.begin(probe)
        let result = await probe.httpsMilliseconds(node, urls: urls, batch: batch)
        ProbeSlot.shared.end(probe)
        return result
        #else
        return (.failed("没有链入 sing-box，无法穿过节点查询"), nil)
        #endif
    }

    /// Uses a separate local proxy from node selection.
    static func measureLatency(_ node: ProxyNode) async -> (IOSExitLookup.ExitIP?, String?) {
        #if canImport(Libbox)
        let probe = IOSLibboxProbe()
        ProbeSlot.shared.begin(probe)
        let result = await probe.measureLatency(node)
        ProbeSlot.shared.end(probe)
        return result
        #else
        return (nil, "没有链入 sing-box，无法穿过节点查询")
        #endif
    }
}

#if canImport(Libbox)
private final class ProbeSlot {
    static let shared = ProbeSlot()
    private var current: IOSLibboxProbe?
    private let lock = NSLock()

    func begin(_ probe: IOSLibboxProbe) {
        lock.lock()
        let previous = current
        current = probe
        lock.unlock()
        previous?.stop()
    }

    func end(_ probe: IOSLibboxProbe) {
        lock.lock()
        let owns = current === probe
        if owns { current = nil }
        lock.unlock()
        if owns { probe.stop() }
    }
}
#endif

#if canImport(Libbox)
private final class IOSLibboxProbe: NSObject, LibboxPlatformInterfaceProtocol, LibboxCommandServerHandlerProtocol {
    private var server: LibboxCommandServer?
    private var pathMonitor: NWPathMonitor?

    func httpsMilliseconds(_ node: ProxyNode, urls: [String], batch: Bool) async -> (IOSProbeOutcome, IOSExitLookup.ExitIP?) {
        do {
            try start(IOSSingBoxConfig.probeJSON(for: node))
            await waitUntilListening(UInt16(IOSSingBoxConfig.httpPort))
            let timeout = TimeInterval(batch ? IOSSettings.batchTimeoutSeconds : IOSSettings.timeoutSeconds)
            let outcome = await IOSExitLookup.proxyMilliseconds(urls: urls, timeout: timeout, attempts: batch ? 1 : 2)
            guard case .latency = outcome else { return (outcome, nil) }
            return (outcome, await IOSExitLookup.fetchThroughHTTPProxy(timeout: timeout))
        } catch {
            return (.failed(error.localizedDescription), nil)
        }
    }

    func measure(_ node: ProxyNode) async -> (IOSExitLookup.ExitIP?, String?) {
        do {
            try start(IOSSingBoxConfig.probeJSON(for: node))
            await waitUntilListening(UInt16(IOSSingBoxConfig.httpPort))
            let result = await IOSExitLookup.fetchThroughHTTPProxy()
            if result == nil { return (nil, "穿过节点后没有拿到出口国家") }
            return (result, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    func measureLatency(_ node: ProxyNode) async -> (IOSExitLookup.ExitIP?, String?) {
        do {
            try start(IOSSingBoxConfig.latencyJSON(for: node))
            await waitUntilListening(UInt16(IOSSingBoxConfig.socksPort))
            let result = await IOSExitLookup.fetch(timeout: TimeInterval(IOSSettings.timeoutSeconds))
            if result == nil { return (nil, "测延迟时没有拿到出口国家") }
            return (result, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    private func waitUntilListening(_ port: UInt16) async {
        for _ in 0..<30 {
            if portAccepts(port) { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func portAccepts(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private func start(_ config: String) throws {
        #if targetEnvironment(simulator)
        // Simulator container paths can exceed the Unix socket path limit.
        let base = URL(fileURLWithPath: "/tmp/hw-ios-probe", isDirectory: true)
        #else
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("hw", isDirectory: true)
        #endif
        let working = base.appendingPathComponent("work", isDirectory: true)
        let temp = base.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let setup = LibboxSetupOptions()
        setup.basePath = base.path
        setup.workingPath = working.path
        setup.tempPath = temp.path
        setup.commandServerListenPort = 2082
        setup.commandServerSecret = UUID().uuidString
        setup.logMaxLines = 50
        setup.crashReportSource = "HopWorldIOSProbe"
        setup.appVersion = "6"
        setup.appMarketingVersion = "1.0.1"
        var setupError: NSError?
        guard LibboxSetup(setup, &setupError) else { throw setupError ?? probeFailure("sing-box 初始化失败") }
        var checkError: NSError?
        guard LibboxCheckConfig(config, &checkError) else { throw checkError ?? probeFailure("sing-box 没有接受探测配置") }
        var serverError: NSError?
        guard let server = LibboxNewCommandServer(self, self, &serverError) else {
            throw serverError ?? probeFailure("无法创建 sing-box")
        }
        try server.start()
        try server.startOrReloadService(config, options: LibboxOverrideOptions())
        self.server = server
    }

    fileprivate func stop() {
        try? server?.closeService()
        server?.close()
        server = nil
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        throw probeFailure("出口探测不使用系统隧道")
    }
    func usePlatformAutoDetectControl() -> Bool { false }
    func autoDetectControl(_ fd: Int32) throws {}
    func underNetworkExtension() -> Bool { false }
    func includeAllNetworks() -> Bool { false }
    func usePlatformShell() -> Bool { false }
    func usePlatformBridge() -> Bool { false }
    func tailscaleHostname() -> String { "" }
    func clearDNSCache() {}
    func writeDebugMessage(_ message: String?) {}
    func registerMyInterface(_ name: String?) {}
    func readWIFIState() -> LibboxWIFIState? { nil }
    func localDNSTransport() -> LibboxLocalDNSTransportProtocol? { nil }
    func findConnectionOwner(_ ipProtocol: Int32, sourceAddress: String?, sourcePort: Int32, destinationAddress: String?, destinationPort: Int32) throws -> LibboxConnectionOwner {
        throw probeFailure("出口探测不查找来源 App")
    }
    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        guard let listener else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        let semaphore = DispatchSemaphore(value: 0)
        monitor.pathUpdateHandler = { [weak self] path in
            self?.publish(path, to: listener)
            semaphore.signal()
            monitor.pathUpdateHandler = { [weak self] path in
                self?.publish(path, to: listener)
            }
        }
        monitor.start(queue: .global())
        semaphore.wait()
    }
    func closeDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        pathMonitor?.cancel()
        pathMonitor = nil
    }
    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        let interfaces = pathMonitor?.currentPath.availableInterfaces.map { item -> LibboxNetworkInterface in
            let face = LibboxNetworkInterface()
            face.name = item.name
            face.index = Int32(item.index)
            switch item.type {
            case .wifi: face.type = LibboxInterfaceTypeWIFI
            case .cellular: face.type = LibboxInterfaceTypeCellular
            case .wiredEthernet: face.type = LibboxInterfaceTypeEthernet
            default: face.type = LibboxInterfaceTypeOther
            }
            return face
        } ?? []
        return IOSProbeInterfaceIterator(interfaces)
    }
    func send(_ notification: LibboxNotification?) throws {}
    func cancelNotification(_ identifier: String?, typeID: Int32) throws {}
    func startNeighborMonitor(_ listener: LibboxNeighborUpdateListenerProtocol?) throws {}
    func closeNeighborMonitor(_ listener: LibboxNeighborUpdateListenerProtocol?) throws {}
    func checkPlatformShell() throws { throw probeFailure("iOS 不提供平台 shell") }
    func openShellSession(_ user: LibboxPlatformUser?, command: String?, environ: LibboxStringIteratorProtocol?, term: String?, rows: Int32, cols: Int32) throws -> LibboxShellSessionProtocol {
        throw probeFailure("iOS 不提供平台 shell")
    }
    func lookupUser(_ username: String?) throws -> LibboxPlatformUser { throw probeFailure("iOS 不提供用户查询") }
    func lookupSFTPServer(_ error: NSErrorPointer) -> String {
        error?.pointee = probeFailure("iOS 不提供 SFTP")
        return ""
    }
    func readSystemSSHHostKey(_ error: NSErrorPointer) -> String {
        error?.pointee = probeFailure("iOS 不提供 SSH 主机密钥")
        return ""
    }
    func createBridge(_ options: LibboxBridgeOptions?) throws -> LibboxBridgeSessionProtocol {
        throw probeFailure("iOS 不创建网桥")
    }
    func serviceStop() throws {}
    func serviceReload() throws {}
    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus { LibboxSystemProxyStatus() }
    func setSystemProxyEnabled(_ isEnabled: Bool) throws {}
    func triggerNativeCrash() throws { throw probeFailure("不触发原生崩溃") }
    func connectSSHAgent(_ ret0_: UnsafeMutablePointer<Int32>?) throws {
        throw probeFailure("iOS 不连接 SSH agent")
    }

    private func publish(_ path: Network.NWPath, to listener: LibboxInterfaceUpdateListenerProtocol) {
        guard path.status == .satisfied, let interface = path.availableInterfaces.first else {
            listener.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
            return
        }
        listener.updateDefaultInterface(interface.name, interfaceIndex: Int32(interface.index), isExpensive: path.isExpensive, isConstrained: path.isConstrained)
    }
}

private final class IOSProbeInterfaceIterator: NSObject, LibboxNetworkInterfaceIteratorProtocol {
    private let items: [LibboxNetworkInterface]
    private var index = 0
    init(_ items: [LibboxNetworkInterface]) { self.items = items }
    func hasNext() -> Bool { index < items.count }
    func next() -> LibboxNetworkInterface? {
        guard index < items.count else { return nil }
        defer { index += 1 }
        return items[index]
    }
}

private func probeLog(_ line: String) {
    let url = URL(fileURLWithPath: "/tmp/hw-ios-probe/probe.log")
    let text = line + "\n"
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try? handle.close()
    } else {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.data(using: .utf8)?.write(to: url)
    }
}

private func probeFailure(_ message: String) -> NSError {
    NSError(domain: "HopWorldIOS", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}
#endif

