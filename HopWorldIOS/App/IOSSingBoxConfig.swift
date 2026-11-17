import Foundation

/// sing-box 1.14 整机隧道配置。只在 iOS 使用，不调用 Mac 的 `XrayConfigBuilder`。
enum IOSSingBoxConfig {
    static let coreVersion = "1.14.4"
    /// Latency lookup uses this mixed inbound. Select does not.
    static let socksPort = 2080
    /// Select uses this HTTP proxy, the same way the Mac dashboard asks for an exit IP.
    static let httpPort = 2081

    static func json(for node: ProxyNode) throws -> String {
        var copy = node
        KeychainStore.hydrateCredentials(&copy)
        let object = try document(for: copy)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw ParserError.unsupportedOption("无法生成隧道配置")
        }
        return text
    }

    /// HTTP proxy only. Selecting a node asks for the exit the way Mac does.
    static func probeJSON(for node: ProxyNode) throws -> String {
        var object = try document(for: node)
        object["inbounds"] = [httpInbound]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw ParserError.unsupportedOption("无法生成出口探测配置")
        }
        return text
    }

    /// Separate mixed proxy for latency exit lookup.
    static func latencyJSON(for node: ProxyNode) throws -> String {
        var object = try document(for: node)
        object["inbounds"] = [socksInbound]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw ParserError.unsupportedOption("无法生成测延迟的出口配置")
        }
        return text
    }

    /// 1.1.1.1 对部分节点域名返回 SERVFAIL。测试前改用系统 DNS 解析，TLS 仍用原来的 SNI。
    static var resolveServer: (String) -> String? = IOSSystemDNS.resolve

    static func usingResolvedServer(_ node: ProxyNode) -> ProxyNode {
        let host = node.server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !IOSSystemDNS.isAddress(host),
              let address = resolveServer(host), IOSSystemDNS.isAddress(address) else { return node }
        var copy = node
        if (copy.sni ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.sni = host
        }
        copy.server = address
        return copy
    }

    static func document(for node: ProxyNode) throws -> [String: Any] {
        let node = usingResolvedServer(node)
        guard !FinalMaskCodec.isPresent(on: node) else {
            throw ParserError.unsupportedOption("sing-box 1.14 不支持这条节点的 FinalMask")
        }
        let endpoint = try wireGuardEndpoint(node)
        let proxy = try endpoint == nil ? proxyOutbound(node) : nil
        var outbounds: [[String: Any]] = [["type": "direct", "tag": "direct"]]
        if let proxy {
            outbounds.insert(proxy, at: 0)
        }
        var document: [String: Any] = [
            "log": ["level": "warn"],
            "dns": dns,
            "inbounds": [tunInbound, socksInbound],
            "outbounds": outbounds,
            "route": route
        ]
        if let endpoint {
            document["endpoints"] = [endpoint]
        }
        return document
    }

    private static let tunInbound: [String: Any] = [
        "type": "tun",
        "tag": "tun-in",
        "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
        "mtu": 1500,
        "auto_route": true,
        "strict_route": true,
        "stack": "mixed"
    ]

    private static let socksInbound: [String: Any] = [
        "type": "mixed",
        "tag": "socks-in",
        "listen": "127.0.0.1",
        "listen_port": socksPort
    ]

    private static let httpInbound: [String: Any] = [
        "type": "http",
        "tag": "http-in",
        "listen": "127.0.0.1",
        "listen_port": httpPort
    ]

    private static let dns: [String: Any] = [
        "servers": [
            ["type": "udp", "tag": "remote", "server": "1.1.1.1", "detour": "proxy"],
            ["type": "udp", "tag": "direct-dns", "server": "1.1.1.1"]
        ],
        "final": "remote"
    ]

    private static let route: [String: Any] = [
        "rules": [
            ["action": "sniff"],
            ["protocol": "dns", "action": "hijack-dns"],
            ["ip_is_private": true, "action": "route", "outbound": "direct"]
        ],
        "final": "proxy",
        "auto_detect_interface": true,
        "default_domain_resolver": "direct-dns"
    ]

    private static func wireGuardEndpoint(_ node: ProxyNode) throws -> [String: Any]? {
        guard node.protocolType == .wireguard else { return nil }
        try RemoteProtocolParser.validate(node)
        guard let options = node.wireGuardOptions else { throw ParserError.missingField("WireGuard 配置") }
        guard let privateKey = options.privateKey, !privateKey.isEmpty else {
            throw ParserError.missingField("WireGuard privateKey")
        }
        guard !options.peerPublicKey.isEmpty else { throw ParserError.missingField("WireGuard publicKey") }
        var peer: [String: Any] = [
            "address": node.server,
            "port": node.port,
            "public_key": options.peerPublicKey,
            "allowed_ips": options.allowedIPs ?? ["0.0.0.0/0", "::/0"]
        ]
        if let key = options.preSharedKey, !key.isEmpty { peer["pre_shared_key"] = key }
        if let keepAlive = options.keepAlive { peer["persistent_keepalive_interval"] = keepAlive }
        if let reserved = options.reserved, reserved.count == 3 { peer["reserved"] = reserved }
        var endpoint: [String: Any] = [
            "type": "wireguard",
            "tag": "proxy",
            "private_key": privateKey,
            "address": options.addresses,
            "peers": [peer]
        ]
        if let mtu = options.mtu { endpoint["mtu"] = mtu }
        return endpoint
    }

    private static func proxyOutbound(_ node: ProxyNode) throws -> [String: Any] {
        switch node.protocolType {
        case .masque:
            // shortcut: sing-box 1.14 没有 MASQUE 出站，导入仍保留字段，连接时拒绝。
            throw ParserError.unsupportedOption("sing-box 1.14 没有 MASQUE 出站，这条节点只能导入，不能连接")
        case .wireguard:
            throw ParserError.unsupportedOption("WireGuard 应写成 endpoint")
        case .vless:
            return try vless(node)
        case .vmess:
            return try vmess(node)
        case .trojan:
            return try trojan(node)
        case .shadowsocks:
            return try shadowsocks(node)
        case .hysteria2:
            return try hysteria2(node)
        case .tuic:
            return try tuic(node)
        case .anytls:
            return try anytls(node)
        case .socks5:
            return try socks(node)
        case .http:
            return try http(node)
        }
    }

    private static func vless(_ node: ProxyNode) throws -> [String: Any] {
        guard let uuid = node.uuid, !uuid.isEmpty else { throw ParserError.missingField("uuid") }
        guard (node.encryption ?? "none") == "none" else {
            throw ParserError.unsupportedOption("sing-box 1.14 不支持 VLESS Encryption")
        }
        var outbound = base("vless", node)
        outbound["uuid"] = uuid
        if let flow = node.flow, !flow.isEmpty { outbound["flow"] = flow }
        try applyTransport(node, to: &outbound)
        if node.security == .tls || node.security == .reality {
            outbound["tls"] = try tls(for: node, reality: node.security == .reality)
        }
        return outbound
    }

    private static func vmess(_ node: ProxyNode) throws -> [String: Any] {
        guard let uuid = node.uuid, !uuid.isEmpty else { throw ParserError.missingField("uuid") }
        var outbound = base("vmess", node)
        outbound["uuid"] = uuid
        outbound["security"] = node.encryption ?? "auto"
        outbound["alter_id"] = node.alterId ?? 0
        try applyTransport(node, to: &outbound)
        if node.security == .tls || node.security == .reality {
            outbound["tls"] = try tls(for: node, reality: node.security == .reality)
        }
        return outbound
    }

    private static func trojan(_ node: ProxyNode) throws -> [String: Any] {
        guard let password = node.password, !password.isEmpty else { throw ParserError.missingField("password") }
        var outbound = base("trojan", node)
        outbound["password"] = password
        try applyTransport(node, to: &outbound)
        outbound["tls"] = try tls(for: node, reality: node.security == .reality)
        return outbound
    }

    private static func shadowsocks(_ node: ProxyNode) throws -> [String: Any] {
        let method = (node.method ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !method.isEmpty else { throw ParserError.missingField("method") }
        guard let password = node.password, !password.isEmpty else { throw ParserError.missingField("password") }
        guard node.transport == .tcp, node.security == .none else {
            throw ParserError.unsupportedOption("sing-box 1.14 这条 Shadowsocks 只支持原生 TCP，不支持额外传输或 TLS")
        }
        var outbound = base("shadowsocks", node)
        outbound["method"] = method
        outbound["password"] = password
        return outbound
    }

    private static func hysteria2(_ node: ProxyNode) throws -> [String: Any] {
        guard let password = node.password, !password.isEmpty else { throw ParserError.missingField("password") }
        var outbound = base("hysteria2", node)
        outbound["password"] = password
        outbound["tls"] = try tls(for: node, reality: false)
        return outbound
    }

    private static func tuic(_ node: ProxyNode) throws -> [String: Any] {
        try RemoteProtocolParser.validate(node)
        var outbound = base("tuic", node)
        outbound["uuid"] = node.uuid!
        outbound["password"] = node.password!
        let options = node.tuicOptions
        if let value = options?.congestionControl { outbound["congestion_control"] = value }
        if let value = options?.udpRelayMode { outbound["udp_relay_mode"] = value }
        if let value = options?.udpOverStream { outbound["udp_over_stream"] = value }
        if let value = options?.zeroRTTHandshake { outbound["zero_rtt_handshake"] = value }
        if let value = options?.heartbeat { outbound["heartbeat"] = value }
        var tls = try tls(for: node, reality: false)
        if tls["alpn"] == nil { tls["alpn"] = ["h3"] }
        if let cert = options?.certificate { tls["certificate"] = cert }
        if let pins = options?.publicKeySHA256 { tls["certificate_public_key_sha256"] = pins }
        if let disable = options?.disableSNI { tls["disable_sni"] = disable }
        outbound["tls"] = tls
        return outbound
    }

    private static func anytls(_ node: ProxyNode) throws -> [String: Any] {
        try RemoteProtocolParser.validate(node)
        var outbound = base("anytls", node)
        outbound["password"] = node.password!
        outbound["tls"] = try tls(for: node, reality: false)
        return outbound
    }

    private static func socks(_ node: ProxyNode) throws -> [String: Any] {
        try RemoteProtocolParser.validate(node)
        var outbound = base("socks", node)
        outbound["version"] = "5"
        if let username = node.username, !username.isEmpty { outbound["username"] = username }
        if let password = node.password, !password.isEmpty { outbound["password"] = password }
        if node.security == .tls { outbound["tls"] = try tls(for: node, reality: false) }
        return outbound
    }

    private static func http(_ node: ProxyNode) throws -> [String: Any] {
        try RemoteProtocolParser.validate(node)
        var outbound = base("http", node)
        if let username = node.username, !username.isEmpty { outbound["username"] = username }
        if let password = node.password, !password.isEmpty { outbound["password"] = password }
        if let headers = node.httpHeaders, !headers.isEmpty { outbound["headers"] = headers }
        if node.security == .tls { outbound["tls"] = try tls(for: node, reality: false) }
        return outbound
    }

    private static func base(_ type: String, _ node: ProxyNode) -> [String: Any] {
        ["type": type, "tag": "proxy", "server": node.server, "server_port": node.port]
    }

    private static func applyTransport(_ node: ProxyNode, to outbound: inout [String: Any]) throws {
        switch node.transport {
        case .tcp:
            return
        case .ws:
            var transport: [String: Any] = ["type": "ws", "path": node.path ?? "/"]
            if let host = node.host ?? node.sni, !host.isEmpty {
                transport["headers"] = ["Host": host]
            }
            outbound["transport"] = transport
        case .grpc:
            outbound["transport"] = ["type": "grpc", "service_name": node.serviceName ?? ""]
        case .httpupgrade:
            outbound["transport"] = [
                "type": "httpupgrade",
                "host": node.host ?? node.server,
                "path": node.path ?? "/"
            ]
        case .h2, .http:
            var transport: [String: Any] = ["type": "http", "path": node.path ?? "/"]
            if let host = node.host, !host.isEmpty {
                transport["host"] = host.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }
            outbound["transport"] = transport
        case .xhttp, .quic, .masque:
            throw ParserError.unsupportedOption("sing-box 1.14 不支持该传输：\(node.transport.displayName)")
        }
    }

    private static func tls(for node: ProxyNode, reality: Bool) throws -> [String: Any] {
        let spider = node.spiderX?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // shortcut: sing-box 1.14 的 REALITY 没有 spiderX，非默认路径会和节点不一致，所以直接拒绝。
        if reality, !spider.isEmpty, spider != "/" {
            throw ParserError.unsupportedOption("sing-box 1.14 不能保留 REALITY spiderX")
        }
        if let pin = node.pinnedCertSHA256, !pin.isEmpty {
            throw ParserError.unsupportedOption("sing-box 1.14 不能按证书 SHA-256 固定校验这条节点")
        }
        var tls: [String: Any] = [
            "enabled": true,
            "server_name": node.sni ?? node.server,
            "insecure": node.allowInsecure ?? false
        ]
        if let alpn = node.alpn, !alpn.isEmpty {
            tls["alpn"] = alpn.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let fingerprint = node.fingerprint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if reality {
            // shortcut: sing-box 1.14 的 utls 只有 chrome 带 X25519MLKEM768，safari/firefox 会被 Xray 26.9.8+ 拒绝。utls 补上后再按节点指纹发。
            tls["utls"] = ["enabled": true, "fingerprint": "chrome"]
        } else if !fingerprint.isEmpty {
            tls["utls"] = ["enabled": true, "fingerprint": fingerprint]
        }
        if reality {
            let key = node.publicKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !key.isEmpty else { throw ParserError.unsupportedOption("REALITY 缺少 publicKey") }
            var realityBlock: [String: Any] = ["enabled": true, "public_key": key]
            if let sid = node.shortID?.trimmingCharacters(in: .whitespacesAndNewlines), !sid.isEmpty {
                realityBlock["short_id"] = sid
            }
            tls["reality"] = realityBlock
        }
        return tls
    }
}

enum IOSSystemDNS {
    static func isAddress(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return host.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }

    static func resolve(_ host: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &info) == 0, let info else { return nil }
        defer { freeaddrinfo(info) }
        var ipv4: String?
        var ipv6: String?
        var cursor: UnsafeMutablePointer<addrinfo>? = info
        while let item = cursor {
            if item.pointee.ai_family == AF_INET, let addr = item.pointee.ai_addr {
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                if inet_ntop(AF_INET, &sin, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                    ipv4 = String(cString: buffer)
                    break
                }
            } else if ipv6 == nil, item.pointee.ai_family == AF_INET6, let addr = item.pointee.ai_addr {
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                var sin = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                if inet_ntop(AF_INET6, &sin, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil {
                    ipv6 = String(cString: buffer)
                }
            }
            cursor = item.pointee.ai_next
        }
        return ipv4 ?? ipv6
    }
}
