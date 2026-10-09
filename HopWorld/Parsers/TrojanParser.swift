import Foundation

enum TrojanParser {
    static func parse(_ link: String) throws -> ProxyNode {
        let parts = try ShareLinkComponents.parse(link)
        guard parts.scheme == "trojan" else { throw ParserError.invalidURL(link) }

        let password = parts.user ?? ""
        guard !password.isEmpty else { throw ParserError.missingField("password") }

        let query = parts.query
        let name = parts.fragment ?? "\(parts.host):\(parts.port)"
        let transport = mapTransport(query["type"] ?? "tcp")
        let securityRaw = (query["security"] ?? "tls").lowercased()
        let security = SecurityType(rawValue: securityRaw) ?? .tls

        return ProxyNode(
            name: name,
            protocolType: .trojan,
            server: parts.host,
            port: parts.port,
            password: password,
            transport: transport,
            security: security,
            sni: query["sni"],
            host: query["host"] ?? query["Host"],
            path: query["path"],
            serviceName: query["serviceName"],
            fingerprint: query["fp"],
            alpn: query["alpn"],
            finalMaskJSON: FinalMaskCodec.normalize(query["fm"])
        )
    }

    private static func mapTransport(_ value: String) -> TransportType {
        switch value.lowercased() {
        case "ws": return .ws
        case "grpc": return .grpc
        case "httpupgrade": return .httpupgrade
        case "xhttp": return .xhttp
        default: return .tcp
        }
    }
}
