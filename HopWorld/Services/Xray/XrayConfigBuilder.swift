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
        applicationProxy: (port: Int, password: String)? = nil
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
        var dnsServers: [Any] = [
            "1.1.1.1", "8.8.8.8", "https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query", "localhost"
        ]
        if routingMode == .rules && routingRules.bypassChina {
            dnsServers.insert([
                "address": "223.5.5.5",
                "domains": ["geosite:cn"],
                "skipFallback": true
            ] as [String: Any], at: 0)
        }
        // Resolve the node before the tunnel exists. Never route its bootstrap
        // lookup through the very outbound that depends on that lookup.
        dnsServers.insert(bootstrapDNS(for: [node]), at: 0)

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
                "queryStrategy": "UseIPv4"
            ] as [String: Any]
        ]
    }

    /// Local Stats API port (dokodemo-door).
    static let apiPort = 10_885

    /// 512 KiB per request, bounded. In particular avoid the small ARM64
    /// default dropping UDP bursts when the internal queue is full.
    static let connectionPolicy: [String: Any] = [
        "0": ["bufferSize": 512]
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
                "queryStrategy": "UseIPv4"
            ] as [String: Any],
            "inbounds": inbounds,
            "outbounds": outbounds,
            "routing": [
                "domainStrategy": "IPIfNonMatch",
                "rules": rules
            ]
        ]
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
        switch node.protocolType {
        case .vless:
            return try vlessOutbound(node, tag: tag)
        case .vmess:
            return try vmessOutbound(node, tag: tag)
        case .trojan:
            return try trojanOutbound(node, tag: tag)
        case .shadowsocks:
            return try shadowsocksOutbound(node, tag: tag)
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
        case .tcp:
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

        // Prefer IPv4 when dialing the node. Broken/partial IPv6 on the LAN
        // otherwise yields "all unavailable" while other IPv4-first clients work.
        stream["sockopt"] = [
            "domainStrategy": "UseIPv4"
        ] as [String: Any]

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
