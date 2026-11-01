import Foundation

/// Shared between the main app and Packet Tunnel extension (same source compiled into both).
enum HopWorldAppGroup {
    /// Injected via Info.plist from Configs/Signing.xcconfig so forks can use their own Team's IDs.
    static let identifier = infoString("HopWorldAppGroupIdentifier") ?? "group.com.hopworld.app"
    static let tunnelBundleIdentifier = infoString("HopWorldTunnelBundleIdentifier") ?? "com.hopworld.app.PacketTunnel"
    /// False for ad-hoc builds: they lack the Network Extension entitlement.
    static let isSystemVPNAvailable = infoString("HopWorldSystemVPNEnabled") == "YES"
    static let vpnDisplayName = "跃界"

    private static func infoString(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, !value.isEmpty else { return nil }
        return value
    }

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }

    enum Key {
        static let httpHost = "tunnel.httpHost"
        static let httpPort = "tunnel.httpPort"
        static let socksHost = "tunnel.socksHost"
        static let socksPort = "tunnel.socksPort"
        static let generation = "tunnel.generation"
    }

    struct TunnelEndpoints: Equatable, Sendable {
        var httpHost: String
        var httpPort: Int
        var socksHost: String
        var socksPort: Int
        var generation: Int
    }

    static func writeEndpoints(
        httpHost: String,
        httpPort: Int,
        socksHost: String,
        socksPort: Int,
        generation: Int
    ) {
        let d = defaults
        d.set(httpHost, forKey: Key.httpHost)
        d.set(httpPort, forKey: Key.httpPort)
        d.set(socksHost, forKey: Key.socksHost)
        d.set(socksPort, forKey: Key.socksPort)
        d.set(generation, forKey: Key.generation)
        d.synchronize()
    }

    static func readEndpoints() -> TunnelEndpoints {
        let d = defaults
        return TunnelEndpoints(
            httpHost: d.string(forKey: Key.httpHost) ?? "127.0.0.1",
            httpPort: d.object(forKey: Key.httpPort) as? Int ?? 10809,
            socksHost: d.string(forKey: Key.socksHost) ?? "127.0.0.1",
            socksPort: d.object(forKey: Key.socksPort) as? Int ?? 10808,
            generation: d.object(forKey: Key.generation) as? Int ?? 0
        )
    }
}
