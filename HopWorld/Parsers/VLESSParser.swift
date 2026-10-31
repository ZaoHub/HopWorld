import Foundation

enum VLESSParser {
    static func parse(_ link: String) throws -> ProxyNode {
        let parts = try ShareLinkComponents.parse(link)
        guard parts.scheme == "vless" else { throw ParserError.invalidURL(link) }

        let uuid = parts.user ?? ""
        guard !uuid.isEmpty else { throw ParserError.missingField("uuid") }

        let query = parts.query
        let name = parts.fragment ?? "\(parts.host):\(parts.port)"

        var security = SecurityType(rawValue: (query["security"] ?? "none").lowercased()) ?? .none
        let keyFields = ["pbk", "publicKey", "publickey", "public-key", "public_key"]
            + (security == .reality ? ["password"] : [])
        let publicKey = keyFields.lazy.compactMap { query[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let shortID = query["sid"] ?? query["shortId"] ?? query["shortID"] ?? query["short-id"] ?? query["short_id"]
        if let publicKey, !publicKey.isEmpty {
            security = .reality
        }
        let transport = mapTransport(query["type"] ?? "tcp")

        return ProxyNode(
            name: name,
            protocolType: .vless,
            server: parts.host,
            port: parts.port,
            uuid: uuid,
            flow: query["flow"],
            encryption: query["encryption"] ?? "none",
            transport: transport,
            security: security,
            sni: query["sni"],
            host: query["host"] ?? query["Host"],
            path: query["path"],
            serviceName: query["serviceName"],
            publicKey: publicKey,
            shortID: shortID,
            fingerprint: query["fp"],
            spiderX: query["spx"],
            alpn: query["alpn"],
            finalMaskJSON: FinalMaskCodec.normalize(query["fm"])
        )
    }

    private static func mapTransport(_ value: String) -> TransportType {
        switch value.lowercased() {
        case "ws": return .ws
        case "grpc": return .grpc
        case "httpupgrade": return .httpupgrade
        case "xhttp", "splithttp": return .xhttp
        case "quic": return .quic
        case "h2", "http": return .h2
        default: return .tcp
        }
    }
}
