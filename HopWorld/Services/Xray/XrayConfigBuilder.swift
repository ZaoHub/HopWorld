import Foundation
import Darwin

enum XrayConfigBuilder {
    struct LocalPorts: Sendable {
        var socksHost: String
        var socksPort: Int
        var httpHost: String
        var httpPort: Int
    }

    static func build(
        node: ProxyNode,
        ports: LocalPorts,
        routingMode: RoutingMode,
        routingRules: RoutingRules = RoutingRules(),
        probePort: Int? = nil,
        applicationProxy: (port: Int, password: String)? = nil,
        qualityProxy: (port: Int, password: String)? = nil
    ) throws -> [String: Any] {
        var hydrated = node
        KeychainStore.hydrateCredentials(&hydrated)

        let outbound = try buildOutbound(hydrated, tag: "proxy")
        let direct: [String: Any] = [
            "protocol": "freedom",
            "tag": "direct",
            "settings": [:] as [String: Any]
        ]
        let blocked: [String: Any] = [
            "protocol": "blackhole",
            "tag": "blocked",
            "settings": [:] as [String: Any]
        ]

        var inbounds: [[String: Any]] = [
            [
                "tag": "api",
                "listen": "127.0.0.1",
                "port": apiPort,
                "protocol": "dokodemo-door",
                "settings": [
                    "address": "127.0.0.1"
                ] as [String: Any]
            ],
            [
                "tag": "socks-in",
                "listen": ports.socksHost,
                "port": ports.socksPort,
                "protocol": "socks",
                "settings": [
                    "udp": true,
                    "auth": "noauth"
                ] as [String: Any],
                "sniffing": [
                    "enabled": true,
                    "routeOnly": true,
                    "destOverride": ["http", "tls", "quic"]
                ] as [String: Any]
            ],
            [
                "tag": "http-in",
                "listen": ports.httpHost,
                "port": ports.httpPort,
                "protocol": "http",
                "settings": [:] as [String: Any],
                "sniffing": [
                    "enabled": true,
                    "routeOnly": true,
                    "destOverride": ["http", "tls"]
                ] as [String: Any]
            ]
        ]

        var routing = try routing(for: routingMode, rules: routingRules)
        if let applicationProxy {
            inbounds.append([
                "tag": "application-in", "listen": "127.0.0.1", "port": applicationProxy.port,
                "protocol": "socks", "settings": ["udp": true, "auth": "password",
                    "accounts": [["user": "hopworld", "pass": applicationProxy.password]]]
            ])
            var rules = routing["rules"] as? [[String: Any]] ?? []
            rules.insert(["type": "field", "inboundTag": ["application-in"], "outboundTag": "proxy"], at: 0)
            routing["rules"] = rules
        }
        if let probePort {
            inbounds.append([
                "tag": "probe-in", "listen": "127.0.0.1", "port": probePort,
                "protocol": "http", "settings": [:] as [String: Any]
            ])
            var rules = routing["rules"] as? [[String: Any]] ?? []
            rules.insert([
                "type": "field", "inboundTag": ["probe-in"],
                "outboundTag": routingMode == .direct ? "direct" : "proxy"
            ], at: 0)
            routing["rules"] = rules
        }
        if let qualityProxy {
            inbounds.append([
                "tag": "quality-in", "listen": "127.0.0.1", "port": qualityProxy.port,
                "protocol": "socks", "settings": ["udp": true, "auth": "password",
                    "accounts": [["user": "hopworld", "pass": qualityProxy.password]]]
            ])
            var rules = routing["rules"] as? [[String: Any]] ?? []
            rules.insert(["type": "field", "inboundTag": ["quality-in"],
                          "outboundTag": routingMode == .direct ? "direct" : "proxy"], at: 0)
            routing["rules"] = rules
        }
        var dnsServers: [Any] = [
            "1.1.1.1", "8.8.8.8", "https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"
        ]
        if routingMode == .rules && routingRules.bypassChina {
            dnsServers.insert([
                "address": "223.5.5.5",
                "domains": ["geosite:cn"],
                "skipFallback": true,
                "tag": "dns-direct"
            ] as [String: Any], at: 0)
        }
        // Resolve the node before the tunnel exists. Never route its bootstrap
        // lookup through the very outbound that depends on that lookup.
        dnsServers.insert(bootstrapDNS(for: [node]), at: 0)

        var dnsRules = routing["rules"] as? [[String: Any]] ?? []
        dnsRules.insert(contentsOf: [
            ["type": "field", "inboundTag": ["dns-direct"], "outboundTag": "direct"],
            ["type": "field", "inboundTag": ["dns-remote"], "outboundTag": routingMode == .direct ? "direct" : "proxy"]
        ], at: min(1, dnsRules.count))
        routing["rules"] = dnsRules

        return [
            "log": [
                "loglevel": "warning"
            ],
            "stats": [:] as [String: Any],
            "api": [
                "tag": "api",
                "services": ["StatsService"]
            ] as [String: Any],
            "policy": [
                "levels": connectionPolicy,
                "system": [
                    "statsInboundUplink": true,
                    "statsInboundDownlink": true,
                    "statsOutboundUplink": true,
                    "statsOutboundDownlink": true
                ] as [String: Any]
            ] as [String: Any],
            "inbounds": inbounds,
            "outbounds": [outbound, direct, blocked],
            "routing": routing,
            // 国内域名优先使用国内 DNS；其它查询保留原有解析服务器。
            "dns": [
                "servers": dnsServers,
                "tag": "dns-remote",
                "queryStrategy": "UseIP"
            ] as [String: Any]
        ]
    }

    /// Local Stats API port (dokodemo-door).
    static let apiPort = 10_885

    /// 512 KiB per request, bounded. In particular avoid the small ARM64
    /// default dropping UDP bursts when the internal queue is full.
    static let connectionPolicy: [String: Any] = [
        "0": ["bufferSize": 512, "connIdle": 3600]
    ]

    private static let nodeSocketOptions: [String: Any] = [
        "domainStrategy": "UseIPv4v6", "tcpKeepAliveIdle": 30, "tcpKeepAliveInterval": 15
    ]

    private static func bootstrapDNS(for nodes: [ProxyNode]) -> [String: Any] {
        [
            "address": "localhost",
            "domains": Array(Set(nodes.map { "full:" + $0.server.lowercased() })).sorted(),
            "skipFallback": true,
            "finalQuery": true
        ]
    }

    static func buildTestConfig(
        nodes: [(node: ProxyNode, localPort: Int)],
        routingMode: RoutingMode = .global
    ) throws -> [String: Any] {
        var inbounds: [[String: Any]] = []
        var outbounds: [[String: Any]] = [
            [
                "protocol": "freedom",
                "tag": "direct",
                "settings": [:] as [String: Any]
            ]
        ]
        var rules: [[String: Any]] = []

        for (index, item) in nodes.enumerated() {
            let tag = "proxy-\(index)"
            var hydrated = item.node
            KeychainStore.hydrateCredentials(&hydrated)
            let outbound = try buildOutbound(hydrated, tag: tag)
            outbounds.append(outbound)

            inbounds.append([
                "tag": "http-test-\(index)",
                "listen": "127.0.0.1",
                "port": item.localPort,
                "protocol": "http",
                "settings": [:] as [String: Any]
            ])

            rules.append([
                "type": "field",
                "inboundTag": ["http-test-\(index)"],
                "outboundTag": tag
            ])
        }

        return [
            "log": ["loglevel": "error"],
            "policy": ["levels": connectionPolicy],
            "dns": [
                "servers": [
                    bootstrapDNS(for: nodes.map(\.node)),
                    "1.1.1.1",
                    "8.8.8.8",
                    "localhost"
                ],
                "queryStrategy": "UseIP"
            ] as [String: Any],
            "inbounds": inbounds,
            "outbounds": outbounds,
            "routing": [
                "domainStrategy": "IPIfNonMatch",
                "rules": rules
            ]
        ]
    }

    /// This nonisolated async boundary keeps Keychain, encoding and disk I/O off MainActor.
    nonisolated static func writeTestConfig(
        nodes: [(node: ProxyNode, localPort: Int)], to file: URL, verbose: Bool = false
    ) async throws {
        try Task.checkCancellation()
        var config = try buildTestConfig(nodes: nodes)
        if verbose { config["log"] = ["loglevel": "info"] }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeJSON(config, to: file)
    }

    static func writeJSON(_ config: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    // MARK: - Outbound

    private static func buildOutbound(_ node: ProxyNode, tag: String) throws -> [String: Any] {
        guard node.transport != .masque || node.protocolType == .masque else {
            throw ParserError.unsupportedOption("masque 传输仅支持 MASQUE 协议")
        }
        if SingBoxConnectionConfig.requiresSingBox(node) {
            return ["tag": tag, "protocol": "socks", "settings": ["servers": [["address": "127.0.0.1", "port": 1]]],
                    SingBoxConnectionConfig.marker: try SingBoxConnectionConfig.outbound(node)]
        }
        switch node.protocolType {
        case .socks5, .http:
            try RemoteProtocolParser.validate(node)
            var server: [String: Any] = ["address": node.server, "port": node.port]
            if let user = node.username { server["users"] = [["user": user, "pass": node.password ?? ""]] }
            var settings: [String: Any] = ["servers": [server]]
            if let headers = node.httpHeaders, node.protocolType == .http { settings["headers"] = headers }
            var stream: [String: Any] = ["network": "tcp", "security": node.security.rawValue, "sockopt": nodeSocketOptions]
            if node.security == .tls {
                var tls: [String: Any] = ["serverName": node.sni ?? node.server, "alpn": ["http/1.1"]]
                if let pin = node.pinnedCertSHA256 { tls["pinnedPeerCertSha256"] = pin }
                stream["tlsSettings"] = tls
            }
            return ["tag": tag, "protocol": node.protocolType == .socks5 ? "socks" : "http", "settings": settings, "streamSettings": stream]
        case .wireguard:
            try RemoteProtocolParser.validate(node)
            let options = node.wireGuardOptions!
            let endpoint = node.server.contains(":") ? "[\(node.server)]:\(node.port)" : "\(node.server):\(node.port)"
            var peer: [String: Any] = ["endpoint": endpoint, "publicKey": options.peerPublicKey]
            if let psk = options.preSharedKey { peer["preSharedKey"] = psk }
            if let allowed = options.allowedIPs { peer["allowedIPs"] = allowed }
            if let keepalive = options.keepAlive { peer["keepAlive"] = keepalive }
            var settings: [String: Any] = ["secretKey": options.privateKey!, "address": options.addresses, "peers": [peer], "noKernelTun": true]
            if let mtu = options.mtu { settings["mtu"] = mtu }
            if let reserved = options.reserved { settings["reserved"] = reserved }
            if let dns = options.remoteDNS { settings["remoteDNS"] = dns }
            return ["tag": tag, "protocol": "wireguard", "settings": settings, "streamSettings": ["sockopt": nodeSocketOptions]]
        case .anytls, .tuic:
            throw ParserError.unsupportedOption("\(node.protocolType.displayName) 必须使用 sing-box 协议桥接")
        case .masque:
            try MasqueParser.validate(node)
            var settings: [String: Any] = ["address": node.server, "port": node.port]
            if let dns = node.masqueRemoteDNS, !dns.isEmpty { settings["remoteDNS"] = dns }
            var masque: [String: Any] = ["path": node.path ?? MasqueParser.defaultPath]
            if let host = node.host { masque["host"] = host }
            if let user = node.username { masque["user"] = user }
            if let password = node.password { masque["pass"] = password }
            if let headers = node.masqueHeaders { masque["headers"] = headers }
            var tls: [String: Any] = ["serverName": node.sni ?? node.server,
                                      "alpn": (node.alpn ?? "h3").components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }]
            if let fp = node.fingerprint { tls["fingerprint"] = fp }
            if let pin = node.pinnedCertSHA256 { tls["pinnedPeerCertSha256"] = pin }
            var stream: [String: Any] = ["network": "masque", "security": "tls", "masqueSettings": masque,
                                         "tlsSettings": tls, "sockopt": nodeSocketOptions]
            if let mask = FinalMaskCodec.jsonObject(from: node) { stream["finalmask"] = mask }
            return ["tag": tag, "protocol": "masque", "settings": settings, "streamSettings": stream]
        case .vless:
            return try vlessOutbound(node, tag: tag)
        case .vmess:
            return try vmessOutbound(node, tag: tag)
        case .trojan:
            return try trojanOutbound(node, tag: tag)
        case .shadowsocks:
            return try shadowsocksOutbound(node, tag: tag)
        case .hysteria2:
            guard let password = node.password, !password.isEmpty else { throw ParserError.missingField("password") }
            if node.allowInsecure == true, (node.pinnedCertSHA256 ?? "").isEmpty {
                throw ParserError.unsupportedOption("当前 Xray 不支持 Hysteria2 的 insecure=1，请使用有效证书或提供 pinSHA256")
            }
            var tls: [String: Any] = ["serverName": node.sni ?? node.server, "alpn": ["h3"]]
            if let pin = node.pinnedCertSHA256 { tls["pinnedPeerCertSha256"] = pin }
            if let alpn = node.alpn { tls["alpn"] = alpn.split(separator: ",").map(String.init) }
            return [
                "tag": tag, "protocol": "hysteria",
                "settings": ["version": 2, "address": node.server, "port": node.port],
                "streamSettings": [
                    "network": "hysteria", "security": "tls", "tlsSettings": tls,
                    "hysteriaSettings": ["version": 2, "auth": password]
                ]
            ]
        }
    }

    private static func vlessOutbound(_ node: ProxyNode, tag: String) throws -> [String: Any] {
        guard let uuid = node.uuid, !uuid.isEmpty else {
            throw ParserError.missingField("uuid")
        }

        var user: [String: Any] = [
            "id": uuid,
            "encryption": node.encryption ?? "none"
        ]
        if let flow = node.flow, !flow.isEmpty {
            user["flow"] = flow
        }

        let stream = streamSettings(for: node)
        return [
            "tag": tag,
            "protocol": "vless",
            "settings": [
                "vnext": [[
                    "address": node.server,
                    "port": node.port,
                    "users": [user]
                ]]
            ],
            "streamSettings": stream
        ]
    }

    private static func vmessOutbound(_ node: ProxyNode, tag: String) throws -> [String: Any] {
        guard let uuid = node.uuid, !uuid.isEmpty else {
            throw ParserError.missingField("uuid")
        }

        let stream = streamSettings(for: node)
        return [
            "tag": tag,
            "protocol": "vmess",
            "settings": [
                "vnext": [[
                    "address": node.server,
                    "port": node.port,
                    "users": [[
                        "id": uuid,
                        "alterId": node.alterId ?? 0,
                        "security": node.encryption ?? "auto"
                    ] as [String: Any]]
                ]]
            ],
            "streamSettings": stream
        ]
    }

    private static func trojanOutbound(_ node: ProxyNode, tag: String) throws -> [String: Any] {
        guard let password = node.password, !password.isEmpty else {
            throw ParserError.missingField("password")
        }

        var stream = streamSettings(for: node)
        if stream["security"] as? String == nil || stream["security"] as? String == "none" {
            stream["security"] = "tls"
        }
        return [
            "tag": tag,
            "protocol": "trojan",
            "settings": [
                "servers": [[
                    "address": node.server,
                    "port": node.port,
                    "password": password
                ] as [String: Any]]
            ],
            "streamSettings": stream
        ]
    }

    private static func shadowsocksOutbound(_ node: ProxyNode, tag: String) throws -> [String: Any] {
        guard let password = node.password, let method = node.method else {
            throw ParserError.missingField("method/password")
        }
        return [
            "tag": tag,
            "protocol": "shadowsocks",
            "streamSettings": ["sockopt": nodeSocketOptions],
            "settings": [
                "servers": [[
                    "address": node.server,
                    "port": node.port,
                    "method": method,
                    "password": password
                ] as [String: Any]]
            ]
        ]
    }

    private static func streamSettings(for node: ProxyNode) -> [String: Any] {
        var stream: [String: Any] = [
            "network": networkName(node.transport)
        ]

        // CDN/WS nodes often require Host == SNI when `host` is omitted from the share link.
        let headerHost = firstNonEmpty(node.host, node.sni, node.server)

        switch node.transport {
        case .ws:
            var ws: [String: Any] = [:]
            if let path = node.path { ws["path"] = path }
            if let headerHost {
                // Xray 26.9+ prefers top-level `host`; `headers.Host` is deprecated.
                ws["host"] = headerHost
            }
            stream["wsSettings"] = ws
        case .grpc:
            var grpc: [String: Any] = [:]
            if let service = node.serviceName { grpc["serviceName"] = service }
            stream["grpcSettings"] = grpc
        case .httpupgrade:
            var upgrade: [String: Any] = [:]
            if let path = node.path { upgrade["path"] = path }
            if let headerHost { upgrade["host"] = headerHost }
            stream["httpupgradeSettings"] = upgrade
        case .xhttp, .h2, .http, .quic:
            // Xray 26.9+：HTTP/h2/QUIC 传输已移除，统一迁到 XHTTP。
            var xhttp: [String: Any] = [:]
            if let path = node.path { xhttp["path"] = path }
            if let headerHost { xhttp["host"] = headerHost }
            stream["xhttpSettings"] = xhttp
        case .tcp, .masque:
            break
        }

        switch node.security {
        case .tls where node.publicKey == nil || node.publicKey?.isEmpty == true:
            stream["security"] = "tls"
            var tls: [String: Any] = [:]
            if let sni = node.sni { tls["serverName"] = sni }
            if let fp = node.fingerprint { tls["fingerprint"] = fp }
            if let alpn = node.alpn {
                tls["alpn"] = alpn.split(separator: ",").map(String.init)
            }
            stream["tlsSettings"] = tls
        case .reality, .tls:
            // `.tls` with publicKey: share-link mislabel; treat as REALITY.
            stream["security"] = "reality"
            var reality: [String: Any] = [:]
            if let sni = node.sni { reality["serverName"] = sni }
            if let fp = node.fingerprint { reality["fingerprint"] = fp }
            if let pbk = node.publicKey { reality["publicKey"] = pbk }
            if let sid = node.shortID { reality["shortId"] = sid }
            if let spider = node.spiderX { reality["spiderX"] = spider }
            stream["realitySettings"] = reality
        case .none:
            stream["security"] = "none"
        }

        // Prefer IPv4 while retaining IPv6-only node support.
        stream["sockopt"] = nodeSocketOptions

        // FinalMask (share-link `fm=`): TCP fragment etc. Required under local DPI.
        if let finalmask = FinalMaskCodec.jsonObject(from: node) {
            stream["finalmask"] = finalmask
        }

        return stream
    }

    private static func networkName(_ transport: TransportType) -> String {
        switch transport {
        case .tcp: return "tcp"
        case .ws: return "ws"
        case .grpc: return "grpc"
        case .masque: return "masque"
        case .httpupgrade: return "httpupgrade"
        case .xhttp, .h2, .http, .quic:
            // Xray 26.9+ 已移除 h2/http/quic 传输。
            return "xhttp"
        }
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            guard let value else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func routing(for mode: RoutingMode, rules: RoutingRules) throws -> [String: Any] {
        let apiRule: [String: Any] = [
            "type": "field",
            "inboundTag": ["api"],
            "outboundTag": "api"
        ]

        switch mode {
        case .direct:
            return [
                "domainStrategy": "IPIfNonMatch",
                "rules": [
                    apiRule,
                    [
                        "type": "field",
                        "outboundTag": "direct",
                        "network": "tcp,udp"
                    ] as [String: Any]
                ]
            ]
        case .global:
            return [
                "domainStrategy": "IPIfNonMatch",
                "rules": [
                    apiRule,
                    [
                        "type": "field",
                        "outboundTag": "direct",
                        "ip": ["geoip:private"]
                    ] as [String: Any],
                    [
                        "type": "field",
                        "outboundTag": "proxy",
                        "network": "tcp,udp"
                    ] as [String: Any]
                ]
            ]
        case .rules:
            return try rules.xrayRouting()
        }
    }
}

enum XrayValidator {
    static func validateConfigFile(at url: URL, xrayURL: URL) async throws -> Bool {
        var environment = ProcessInfo.processInfo.environment
        if let assets = XrayInstaller.assetDirectory(for: xrayURL) {
            environment["XRAY_LOCATION_ASSET"] = assets.path
        }
        let result = try await ProcessRunner.run(executable: xrayURL,
            arguments: ["run", "-test", "-config", url.path], timeout: 15, environment: environment)
        return result.status == 0 && !result.timedOut && !result.cancelled
    }
}

/// Protocol fallback only: routing and statistics remain on the existing local core.
enum SingBoxConnectionConfig {
    static let marker = "hopworldSingBox"
    static let legacyShadowsocksMethods: Set<String> = ["rc4-md5", "aes-128-cfb", "aes-192-cfb", "aes-256-cfb"]

    static func requiresSingBox(_ node: ProxyNode) -> Bool {
        [.anytls, .tuic].contains(node.protocolType)
            || ([ProxyProtocolType.vless, .vmess, .trojan].contains(node.protocolType) && [.h2, .http].contains(node.transport))
            || (node.protocolType == .vless && node.security == .none && !NodeConfigChecker.isLoopbackOrPrivateHost(node.server))
            || (node.protocolType == .hysteria2 && node.allowInsecure == true && (node.pinnedCertSHA256 ?? "").isEmpty)
            || (node.protocolType == .shadowsocks && legacyShadowsocksMethods.contains((node.method ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()))
    }

    static func outbound(_ node: ProxyNode) throws -> [String: Any] {
        guard !FinalMaskCodec.isPresent(on: node) else {
            throw ParserError.unsupportedOption("sing-box 连接暂不支持该节点的 FinalMask 参数")
        }
        var outbound: [String: Any] = ["type": node.protocolType.rawValue, "server": node.server, "server_port": node.port,
                                      "tcp_keep_alive": "30s", "tcp_keep_alive_interval": "15s"]
        switch node.protocolType {
        case .anytls:
            try RemoteProtocolParser.validate(node)
            outbound["password"] = node.password!
            var tls: [String: Any] = ["enabled": true, "server_name": node.sni ?? node.server,
                                     "insecure": node.allowInsecure ?? false]
            if let alpn = node.alpn { tls["alpn"] = alpn.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            if let fingerprint = node.fingerprint, !fingerprint.isEmpty {
                tls["utls"] = ["enabled": true, "fingerprint": fingerprint]
            }
            outbound["tls"] = tls
        case .tuic:
            try RemoteProtocolParser.validate(node)
            outbound["uuid"] = node.uuid!
            outbound["password"] = node.password!
            let options = node.tuicOptions
            if let congestion = options?.congestionControl { outbound["congestion_control"] = congestion }
            if let mode = options?.udpRelayMode { outbound["udp_relay_mode"] = mode }
            if let overStream = options?.udpOverStream { outbound["udp_over_stream"] = overStream }
            if let zeroRTT = options?.zeroRTTHandshake { outbound["zero_rtt_handshake"] = zeroRTT }
            if let heartbeat = options?.heartbeat { outbound["heartbeat"] = heartbeat }
            var tls: [String: Any] = ["enabled": true, "server_name": node.sni ?? node.server,
                                     "insecure": node.allowInsecure ?? false,
                                     "alpn": (node.alpn ?? "h3").components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }]
            if let cert = options?.certificate { tls["certificate"] = cert }
            if let pins = options?.publicKeySHA256 { tls["certificate_public_key_sha256"] = pins }
            if let disable = options?.disableSNI { tls["disable_sni"] = disable }
            outbound["tls"] = tls
        case .shadowsocks:
            let method = (node.method ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard legacyShadowsocksMethods.contains(method) else { throw ParserError.unsupportedOption("sing-box 旧版 Shadowsocks 桥接不支持：\(method)") }
            guard node.transport == .tcp, node.security == .none else {
                throw ParserError.unsupportedOption("\(method) 桥接仅支持原生 Shadowsocks，不支持额外传输或 TLS/REALITY")
            }
            guard let password = node.password, !password.isEmpty else { throw ParserError.missingField("password") }
            outbound["method"] = method
            outbound["password"] = password
        case .vless:
            guard let uuid = node.uuid, !uuid.isEmpty else { throw ParserError.missingField("uuid") }
            guard (node.encryption ?? "none") == "none" else { throw ParserError.unsupportedOption("sing-box 暂不支持 VLESS Encryption") }
            outbound["uuid"] = uuid
            if let flow = node.flow, !flow.isEmpty { outbound["flow"] = flow }
            switch node.transport {
            case .tcp: break
            case .ws:
                var transport: [String: Any] = ["type": "ws", "path": node.path ?? "/"]
                if let host = node.host ?? node.sni { transport["headers"] = ["Host": host] }
                outbound["transport"] = transport
            case .grpc:
                outbound["transport"] = ["type": "grpc", "service_name": node.serviceName ?? ""]
            case .httpupgrade:
                outbound["transport"] = ["type": "httpupgrade", "host": node.host ?? node.server, "path": node.path ?? "/"]
            case .h2, .http:
                try configureHTTPTransport(node, outbound: &outbound)
            default: throw ParserError.unsupportedOption("sing-box 不支持该 VLESS 传输：\(node.transport.displayName)")
            }
        case .vmess:
            guard let uuid = node.uuid, !uuid.isEmpty else { throw ParserError.missingField("uuid") }
            outbound["uuid"] = uuid
            outbound["security"] = node.encryption ?? "auto"
            outbound["alter_id"] = node.alterId ?? 0
            try configureHTTPTransport(node, outbound: &outbound)
        case .trojan:
            guard let password = node.password, !password.isEmpty else { throw ParserError.missingField("password") }
            outbound["password"] = password
            try configureHTTPTransport(node, outbound: &outbound)
        case .hysteria2:
            guard let password = node.password, !password.isEmpty else { throw ParserError.missingField("password") }
            outbound["password"] = password
            var tls: [String: Any] = ["enabled": true, "server_name": node.sni ?? node.server, "insecure": node.allowInsecure ?? false]
            if let alpn = node.alpn { tls["alpn"] = alpn.split(separator: ",").map(String.init) }
            outbound["tls"] = tls
        default: throw ParserError.unsupportedScheme(node.protocolType.rawValue)
        }
        return outbound
    }

    private static func configureHTTPTransport(_ node: ProxyNode, outbound: inout [String: Any]) throws {
        guard [.h2, .http].contains(node.transport) else { throw ParserError.unsupportedOption("该协议桥接仅支持旧 H2/HTTP 传输") }
        // sing-box 1.14 supports public-key pins, not the certificate digest stored by this model.
        guard (node.pinnedCertSHA256 ?? "").isEmpty else {
            throw ParserError.unsupportedOption("旧 H2/HTTP 桥接暂不支持证书 SHA-256 固定校验")
        }
        let realityKey = node.publicKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let useReality = node.security == .reality || !realityKey.isEmpty
        if useReality, realityKey.isEmpty {
            throw ParserError.unsupportedOption("REALITY 缺少 publicKey")
        }
        let spider = node.spiderX?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // shortcut: sing-box 1.14 reality 没有 spiderX，非默认路径会拒绝；内核补上该字段后再映射。
        if useReality, !spider.isEmpty, spider != "/" {
            throw ParserError.unsupportedOption("旧 H2/HTTP 桥接无法保留 REALITY spiderX")
        }
        var transport: [String: Any] = ["type": "http", "path": node.path ?? "/"]
        if let host = node.host, !host.isEmpty {
            transport["host"] = host.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        outbound["transport"] = transport
        if node.security == .tls || node.security == .reality || useReality || node.protocolType == .trojan {
            var tls: [String: Any] = ["enabled": true, "server_name": node.sni ?? node.server,
                                      "insecure": node.allowInsecure ?? false]
            if let alpn = node.alpn { tls["alpn"] = alpn.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            if let fingerprint = node.fingerprint, !fingerprint.isEmpty {
                tls["utls"] = ["enabled": true, "fingerprint": fingerprint]
            }
            if useReality {
                var reality: [String: Any] = ["enabled": true, "public_key": realityKey]
                if let sid = node.shortID?.trimmingCharacters(in: .whitespacesAndNewlines), !sid.isEmpty {
                    reality["short_id"] = sid
                }
                tls["reality"] = reality
                if tls["utls"] == nil {
                    // sing-box REALITY 客户端要求 uTLS。
                    tls["utls"] = ["enabled": true, "fingerprint": "chrome"]
                }
            }
            outbound["tls"] = tls
        }
    }
}
