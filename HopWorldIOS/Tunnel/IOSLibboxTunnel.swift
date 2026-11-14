#if canImport(Libbox)
import Foundation
import Libbox
import Network
import NetworkExtension

/// sing-box 1.14 的平台接口。只接整机 TUN，不查找来源 App。
final class IOSLibboxTunnel: NSObject, LibboxPlatformInterfaceProtocol, LibboxCommandServerHandlerProtocol {
    private weak var provider: NEPacketTunnelProvider?
    private var server: LibboxCommandServer?
    private var pathMonitor: NWPathMonitor?

    func start(config: String, provider: NEPacketTunnelProvider) async throws {
        self.provider = provider
        let base = IOSAppGroup.containerURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let working = base.appendingPathComponent("sing-box-work", isDirectory: true)
        let temp = base.appendingPathComponent("sing-box-tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let setup = LibboxSetupOptions()
        setup.basePath = base.path
        setup.workingPath = working.path
        setup.tempPath = temp.path
        setup.commandServerListenPort = 2083
        setup.commandServerSecret = UUID().uuidString
        setup.logMaxLines = 200
        setup.crashReportSource = "HopWorldIOS"
        setup.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "5"
        setup.appMarketingVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0.0"
        var setupError: NSError?
        guard LibboxSetup(setup, &setupError) else {
            throw setupError ?? failure("sing-box 初始化失败")
        }
        var checkError: NSError?
        guard LibboxCheckConfig(config, &checkError) else {
            throw checkError ?? failure("sing-box 没有接受这条配置")
        }
        var serverError: NSError?
        guard let server = LibboxNewCommandServer(self, self, &serverError) else {
            throw serverError ?? failure("无法创建 sing-box")
        }
        try server.start()
        try server.startOrReloadService(config, options: LibboxOverrideOptions())
        self.server = server
    }

    func stop() {
        try? server?.closeService()
        server?.close()
        server = nil
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    func pause() { server?.pause() }
    func wake() { server?.wake() }

    func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        try blocking { try await self.apply(options, ret0_) }
    }

    func usePlatformAutoDetectControl() -> Bool { false }
    func autoDetectControl(_ fd: Int32) throws {}
    func underNetworkExtension() -> Bool { true }
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
        throw failure("iOS 隧道看不到流量来自哪个 App")
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
        return IOSInterfaceIterator(interfaces)
    }

    func send(_ notification: LibboxNotification?) throws {}
    func cancelNotification(_ identifier: String?, typeID: Int32) throws {}
    func startNeighborMonitor(_ listener: LibboxNeighborUpdateListenerProtocol?) throws {}
    func closeNeighborMonitor(_ listener: LibboxNeighborUpdateListenerProtocol?) throws {}
    func checkPlatformShell() throws { throw failure("iOS 不提供平台 shell") }
    func openShellSession(_ user: LibboxPlatformUser?, command: String?, environ: LibboxStringIteratorProtocol?, term: String?, rows: Int32, cols: Int32) throws -> LibboxShellSessionProtocol {
        throw failure("iOS 不提供平台 shell")
    }
    func lookupUser(_ username: String?) throws -> LibboxPlatformUser { throw failure("iOS 不提供用户查询") }
    func lookupSFTPServer(_ error: NSErrorPointer) -> String {
        error?.pointee = failure("iOS 不提供 SFTP")
        return ""
    }
    func readSystemSSHHostKey(_ error: NSErrorPointer) -> String {
        error?.pointee = failure("iOS 不提供 SSH 主机密钥")
        return ""
    }
    func createBridge(_ options: LibboxBridgeOptions?) throws -> LibboxBridgeSessionProtocol {
        throw failure("iOS 不创建网桥")
    }

    func serviceStop() throws { provider?.cancelTunnelWithError(nil) }
    func serviceReload() throws {
        let config = try IOSAppGroup.readConfig(options: nil)
        try server?.startOrReloadService(config, options: LibboxOverrideOptions())
    }
    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus { LibboxSystemProxyStatus() }
    func setSystemProxyEnabled(_ isEnabled: Bool) throws {}
    func triggerNativeCrash() throws { throw failure("不触发原生崩溃") }
    func connectSSHAgent(_ ret0_: UnsafeMutablePointer<Int32>?) throws {
        throw failure("iOS 不连接 SSH agent")
    }

    private func apply(_ options: LibboxTunOptionsProtocol?, _ ret0_: UnsafeMutablePointer<Int32>?) async throws {
        guard let options else { throw failure("缺少 tun 参数") }
        guard let ret0_ else { throw failure("缺少 tun 返回值") }
        guard let provider else { throw failure("隧道已释放") }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = NSNumber(value: options.getMTU())

        let ipv4 = prefixes(options.getInet4Address())
        if !ipv4.isEmpty {
            let ipv4Settings = NEIPv4Settings(addresses: ipv4.map(\.address), subnetMasks: ipv4.map(\.mask))
            var included = prefixes(options.getInet4RouteAddress()).map {
                NEIPv4Route(destinationAddress: $0.address, subnetMask: $0.mask)
            }
            if included.isEmpty, options.getAutoRoute() { included = [NEIPv4Route.default()] }
            ipv4Settings.includedRoutes = included
            ipv4Settings.excludedRoutes = prefixes(options.getInet4RouteExcludeAddress()).map {
                NEIPv4Route(destinationAddress: $0.address, subnetMask: $0.mask)
            }
            settings.ipv4Settings = ipv4Settings
        }

        let ipv6 = prefixes(options.getInet6Address())
        if !ipv6.isEmpty {
            let ipv6Settings = NEIPv6Settings(
                addresses: ipv6.map(\.address),
                networkPrefixLengths: ipv6.map { NSNumber(value: $0.prefix) }
            )
            var included = prefixes(options.getInet6RouteAddress()).map {
                NEIPv6Route(destinationAddress: $0.address, networkPrefixLength: NSNumber(value: $0.prefix))
            }
            if included.isEmpty, options.getAutoRoute() { included = [NEIPv6Route.default()] }
            ipv6Settings.includedRoutes = included
            ipv6Settings.excludedRoutes = prefixes(options.getInet6RouteExcludeAddress()).map {
                NEIPv6Route(destinationAddress: $0.address, networkPrefixLength: NSNumber(value: $0.prefix))
            }
            settings.ipv6Settings = ipv6Settings
        }

        if options.getDNSMode()?.value != LibboxDNSModeDisabled {
            var servers = strings(try? options.getDNSServerAddress())
            if servers.isEmpty { servers = ["1.1.1.1", "8.8.8.8"] }
            settings.dnsSettings = NEDNSSettings(servers: servers)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            provider.setTunnelNetworkSettings(settings) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        let fd = LibboxGetTunnelFileDescriptor()
        guard fd != -1 else { throw failure("系统没有返回隧道文件描述符") }
        ret0_.pointee = fd
    }

    private func publish(_ path: Network.NWPath, to listener: LibboxInterfaceUpdateListenerProtocol) {
        guard path.status == .satisfied, let interface = path.availableInterfaces.first else {
            listener.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
            return
        }
        listener.updateDefaultInterface(
            interface.name,
            interfaceIndex: Int32(interface.index),
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }

    private func prefixes(_ iterator: LibboxRoutePrefixIteratorProtocol?) -> [(address: String, mask: String, prefix: Int32)] {
        guard let iterator else { return [] }
        var values: [(address: String, mask: String, prefix: Int32)] = []
        while iterator.hasNext() {
            guard let prefix = iterator.next() else { continue }
            values.append((prefix.address(), prefix.mask(), prefix.prefix()))
        }
        return values
    }

    private func strings(_ iterator: LibboxStringIteratorProtocol?) -> [String] {
        guard let iterator else { return [] }
        var values: [String] = []
        while iterator.hasNext() { values.append(iterator.next()) }
        return values
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "HopWorldIOS", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private final class IOSInterfaceIterator: NSObject, LibboxNetworkInterfaceIteratorProtocol {
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

private func blocking(_ work: @escaping () async throws -> Void) throws {
    let box = ErrorBox()
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do { try await work() } catch { box.error = error }
        semaphore.signal()
    }
    semaphore.wait()
    if let error = box.error { throw error }
}

private final class ErrorBox: @unchecked Sendable {
    var error: Error?
}
#endif
