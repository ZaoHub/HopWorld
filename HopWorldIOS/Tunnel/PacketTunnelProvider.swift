import NetworkExtension

// 内嵌核心是 sing-box 1.14 Libbox。xcframework 不进仓库；链入 HopWorldIOS/Vendor/Libbox.xcframework 后才会转发。
final class PacketTunnelProvider: NEPacketTunnelProvider {
    #if canImport(Libbox)
    private var core: IOSLibboxTunnel?
    #endif

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        Task {
            do {
                let config = try IOSAppGroup.readConfig(options: options)
                #if canImport(Libbox)
                let core = IOSLibboxTunnel()
                self.core = core
                try await core.start(config: config, provider: self)
                completionHandler(nil)
                #else
                throw IOSTunnelError.coreNotLinked
                #endif
            } catch {
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        #if canImport(Libbox)
        core?.stop()
        core = nil
        #endif
        completionHandler()
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        #if canImport(Libbox)
        core?.pause()
        #endif
        completionHandler()
    }

    override func wake() {
        #if canImport(Libbox)
        core?.wake()
        #endif
    }
}
