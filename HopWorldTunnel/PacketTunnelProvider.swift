import NetworkExtension
import os.log

/// Packet Tunnel provider — registers as a system VPN and applies HTTP(S) proxy to local Xray.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = Logger(subsystem: "com.hopworld.app.PacketTunnel", category: "tunnel")

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let endpoints = HopWorldAppGroup.readEndpoints()
        log.info("startTunnel http=\(endpoints.httpPort) socks=\(endpoints.socksPort)")

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        // Proxy-only tunnel: no default route into the utun; OS still applies proxySettings
        // while this VPN is Connected (appears under System Settings → Network).
        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.254"])
        ipv4.includedRoutes = []
        ipv4.excludedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        let proxy = NEProxySettings()
        proxy.httpServer = NEProxyServer(address: endpoints.httpHost, port: endpoints.httpPort)
        proxy.httpsServer = NEProxyServer(address: endpoints.httpHost, port: endpoints.httpPort)
        proxy.httpEnabled = true
        proxy.httpsEnabled = true
        proxy.excludeSimpleHostnames = true
        proxy.matchDomains = [""] // apply broadly
        proxy.exceptionList = [
            "localhost",
            "127.0.0.1",
            "*.local",
            "169.254.0.0/16",
            "10.0.0.0/8",
            "172.16.0.0/12",
            "192.168.0.0/16"
        ]
        settings.proxySettings = proxy

        settings.dnsSettings = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
        settings.mtu = 1500

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error {
                self?.log.error("setTunnelNetworkSettings failed: \(error.localizedDescription)")
            } else {
                self?.log.info("tunnel network settings applied")
            }
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        log.info("stopTunnel reason=\(String(describing: reason))")
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        completionHandler?(messageData)
    }
}
