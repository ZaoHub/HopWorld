import Foundation

enum VMessParser {
    static func parse(_ link: String) throws -> ProxyNode {
        guard link.lowercased().hasPrefix("vmess://") else {
            throw ParserError.invalidURL(link)
        }

        let payload = String(link.dropFirst("vmess://".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ParserError.invalidBase64
        }

        let server = (json["add"] as? String) ?? (json["host"] as? String) ?? ""
        let portValue = json["port"]
        let port: Int
        if let intPort = portValue as? Int {
            port = intPort
        } else if let stringPort = portValue as? String, let parsed = Int(stringPort) {
            port = parsed
        } else {
            throw ParserError.missingField("port")
        }

        guard !server.isEmpty else { throw ParserError.missingField("server") }

        let uuid = (json["id"] as? String) ?? ""
        guard !uuid.isEmpty else { throw ParserError.missingField("uuid") }

        let name = (json["ps"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let network = ((json["net"] as? String) ?? "tcp").lowercased()
        let tls = ((json["tls"] as? String) ?? "").lowercased()
        let security: SecurityType = (tls == "tls" || tls == "reality") ? (tls == "reality" ? .reality : .tls) : .none

        let alterId: Int? = {
            if let value = json["aid"] as? Int { return value }
            if let value = json["aid"] as? String { return Int(value) }
            return nil
        }()

        return ProxyNode(
            name: (name?.isEmpty == false ? name! : "\(server):\(port)"),
            protocolType: .vmess,
            server: server,
            port: port,
            uuid: uuid,
            alterId: alterId,
            encryption: (json["scy"] as? String) ?? "auto",
            transport: mapTransport(network),
            security: security,
            sni: json["sni"] as? String,
            host: (json["host"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            path: json["path"] as? String,
            serviceName: json["path"] as? String,
            fingerprint: json["fp"] as? String,
            alpn: json["alpn"] as? String,
            finalMaskJSON: FinalMaskCodec.normalize(json["fm"] as? String)
        )
    }

    private static func mapTransport(_ value: String) -> TransportType {
        switch value {
        case "ws": return .ws
        case "grpc": return .grpc
        case "h2", "http": return .h2
        case "quic": return .quic
        case "httpupgrade": return .httpupgrade
        default: return .tcp
        }
    }
}
