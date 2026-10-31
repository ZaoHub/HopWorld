import Foundation

/// 将 `ProxyNode` 还原为可分享的 ss / vless / vmess / trojan 链接。
enum ShareLinkExporter {
    static func makeShareLink(from node: ProxyNode) -> String? {
        var copy = node
        KeychainStore.hydrateCredentials(&copy)
        switch copy.protocolType {
        case .anytls, .tuic, .wireguard, .socks5, .http:
            return RemoteProtocolParser.shareLink(copy)
        case .vless:
            return encodeVLESS(copy)
        case .vmess:
            return encodeVMess(copy)
        case .trojan:
            return encodeTrojan(copy)
        case .shadowsocks:
            return encodeShadowsocks(copy)
        case .hysteria2:
            guard let password = copy.password, !password.isEmpty else { return nil }
            var components = URLComponents()
            components.scheme = "hysteria2"
            components.host = copy.server
            components.port = copy.port
            components.user = password
            components.fragment = copy.name
            var query = [URLQueryItem(name: "insecure", value: copy.allowInsecure == true ? "1" : "0")]
            if let sni = copy.sni { query.append(URLQueryItem(name: "sni", value: sni)) }
            if let alpn = copy.alpn { query.append(URLQueryItem(name: "alpn", value: alpn)) }
            if let pin = copy.pinnedCertSHA256 { query.append(URLQueryItem(name: "pinSHA256", value: pin)) }
            components.queryItems = query
            return components.string
        case .masque:
            guard (try? MasqueParser.validate(copy)) != nil else { return nil }
            var components = URLComponents()
            components.scheme = "masque"
            components.host = copy.server.contains(":") ? "[\(copy.server)]" : copy.server
            components.port = copy.port
            components.user = copy.username
            components.password = copy.password
            components.fragment = copy.name
            var query: [String: String] = ["alpn": copy.alpn ?? "h3"]
            put(&query, "sni", copy.sni)
            put(&query, "host", copy.host)
            put(&query, "path", copy.path)
            put(&query, "pinSHA256", copy.pinnedCertSHA256)
            if let dns = copy.masqueRemoteDNS, !dns.isEmpty { query["remoteDNS"] = dns.joined(separator: ",") }
            if let headers = copy.masqueHeaders, !headers.isEmpty,
               let data = try? JSONSerialization.data(withJSONObject: headers, options: [.sortedKeys]) {
                query["headers"] = String(data: data, encoding: .utf8)
            }
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            return components.string
        }
    }

    private static func encodeVLESS(_ node: ProxyNode) -> String? {
        guard let uuid = node.uuid, !uuid.isEmpty else { return nil }
        var query: [String: String] = [
            "encryption": node.encryption ?? "none",
            "security": securityRaw(node.security),
            "type": transportRaw(node.transport)
        ]
        put(&query, "flow", node.flow)
        put(&query, "sni", node.sni)
        put(&query, "host", node.host)
        put(&query, "path", node.path)
        put(&query, "serviceName", node.serviceName)
        put(&query, "pbk", node.publicKey)
        put(&query, "sid", node.shortID)
        put(&query, "fp", node.fingerprint)
        put(&query, "spx", node.spiderX)
        put(&query, "alpn", node.alpn)
        put(&query, "fm", FinalMaskCodec.normalize(node.finalMaskJSON))

        let fragment = percentEncode(node.name)
        return "vless://\(uuid)@\(node.server):\(node.port)?\(queryString(query))#\(fragment)"
    }

    private static func encodeTrojan(_ node: ProxyNode) -> String? {
        guard let password = node.password, !password.isEmpty else { return nil }
        var query: [String: String] = [
            "security": securityRaw(node.security == .none ? .tls : node.security),
            "type": transportRaw(node.transport)
        ]
        put(&query, "sni", node.sni)
        put(&query, "host", node.host)
        put(&query, "path", node.path)
        put(&query, "serviceName", node.serviceName)
        put(&query, "fp", node.fingerprint)
        put(&query, "alpn", node.alpn)
        put(&query, "fm", FinalMaskCodec.normalize(node.finalMaskJSON))

        let user = percentEncode(password)
        let fragment = percentEncode(node.name)
        return "trojan://\(user)@\(node.server):\(node.port)?\(queryString(query))#\(fragment)"
    }

    private static func encodeVMess(_ node: ProxyNode) -> String? {
        guard let uuid = node.uuid, !uuid.isEmpty else { return nil }
        var json: [String: Any] = [
            "v": "2",
            "ps": node.name,
            "add": node.server,
            "port": node.port,
            "id": uuid,
            "aid": node.alterId ?? 0,
            "scy": node.encryption ?? "auto",
            "net": transportRaw(node.transport),
            "type": "none",
            "tls": node.security == .none ? "" : securityRaw(node.security)
        ]
        if let host = node.host { json["host"] = host }
        if let path = node.path { json["path"] = path }
        if let sni = node.sni { json["sni"] = sni }
        if let fp = node.fingerprint { json["fp"] = fp }
        if let alpn = node.alpn { json["alpn"] = alpn }
        if let fm = FinalMaskCodec.normalize(node.finalMaskJSON) { json["fm"] = fm }

        guard let data = try? JSONSerialization.data(withJSONObject: json, options: []),
              let encoded = data.base64EncodedString().nilIfEmpty
        else { return nil }
        return "vmess://\(encoded)"
    }

    private static func encodeShadowsocks(_ node: ProxyNode) -> String? {
        guard let method = node.method, !method.isEmpty,
              let password = node.password, !password.isEmpty
        else { return nil }
        let userInfo = "\(method):\(password)"
        let userData = Data(userInfo.utf8).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let fragment = percentEncode(node.name)
        return "ss://\(userData)@\(node.server):\(node.port)#\(fragment)"
    }

    private static func securityRaw(_ security: SecurityType) -> String {
        switch security {
        case .none: return "none"
        case .tls: return "tls"
        case .reality: return "reality"
        }
    }

    private static func transportRaw(_ transport: TransportType) -> String {
        switch transport {
        case .tcp: return "tcp"
        case .ws: return "ws"
        case .grpc: return "grpc"
        case .httpupgrade: return "httpupgrade"
        case .xhttp: return "xhttp"
        case .quic: return "quic"
        case .h2, .http: return "h2"
        case .masque: return "masque"
        }
    }

    private static func put(_ query: inout [String: String], _ key: String, _ value: String?) {
        guard let value, !value.isEmpty else { return }
        query[key] = value
    }

    private static func queryString(_ query: [String: String]) -> String {
        query
            .sorted { $0.key < $1.key }
            .map { "\(percentEncode($0.key))=\(percentEncode($0.value))" }
            .joined(separator: "&")
    }

    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":/?#[]@!$&'()*+,;=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
