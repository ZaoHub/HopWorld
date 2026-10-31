import Foundation
import Darwin

/// Remote proxy nodes; subscription URLs continue to use the remote-URL import entry.
enum RemoteProtocolParser {
    static func parse(_ text: String) throws -> ProxyNode {
        guard let url = URLComponents(string: text), let scheme = url.scheme?.lowercased(),
              let host = url.host, !host.isEmpty else { throw ParserError.missingField("server") }
        let type: ProxyProtocolType
        switch scheme {
        case "anytls": type = .anytls
        case "tuic": type = .tuic
        case "wireguard", "wg": type = .wireguard
        case "socks5", "socks": type = .socks5
        case "http", "https": type = .http
        default: throw ParserError.unsupportedScheme(scheme)
        }
        guard url.path.isEmpty || url.path == "/" else {
            throw ParserError.unsupportedOption("远程代理节点链接不能包含网站或订阅路径，请使用订阅 URL 入口")
        }
        let aliases = ["publickey": "public-key", "presharedkey": "pre-shared-key", "address": "addresses",
                       "ip": "addresses", "allow-insecure": "insecure", "skip-cert-verify": "insecure",
                       "servername": "sni", "server-name": "sni", "reduce-rtt": "zero-rtt-handshake",
                       "allowInsecure": "insecure", "headerType": "header-type"]
        var query: [String: String] = [:]
        for item in url.queryItems ?? [] {
            let name = item.name.replacingOccurrences(of: "_", with: "-")
            let key = aliases[name] ?? name
            guard query[key] == nil, let value = item.value else {
                throw ParserError.unsupportedOption("远程节点参数重复或缺少值：\(key)")
            }
            query[key] = value
        }
        let allowed: Set<String>
        switch type {
        case .anytls:
            allowed = ["sni", "alpn", "insecure", "fp", "security", "type", "header-type"]
        case .tuic:
            allowed = ["sni", "alpn", "insecure", "congestion-control", "udp-relay-mode", "udp-over-stream",
                       "zero-rtt-handshake", "heartbeat", "certificate", "public-key-sha256", "disable-sni"]
        case .wireguard:
            allowed = ["public-key", "pre-shared-key", "addresses", "allowed-ips", "reserved", "mtu", "keepalive", "remote-dns"]
        case .socks5: allowed = []
        case .http: allowed = ["sni", "headers", "pinSHA256", "alpn"]
        default: throw ParserError.unsupportedScheme(scheme)
        }
        for key in query.keys where !allowed.contains(key) {
            throw ParserError.unsupportedOption("不支持的 \(type.displayName) 参数：\(key)")
        }
        let port = url.port ?? (type == .wireguard ? 51820 : type == .socks5 ? 1080 : scheme == "http" ? 80 : 443)
        var node = ProxyNode(name: url.fragment ?? "\(type.displayName) \(host):\(port)", protocolType: type,
                             server: host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), port: port,
                             password: url.password, username: url.user,
                             security: [.anytls, .tuic].contains(type) || scheme == "https" ? .tls : .none,
                             sni: query["sni"], alpn: query["alpn"], pinnedCertSHA256: query["pinSHA256"])
        if type == .socks5 {
            if let encoded = url.user, url.password == nil {
                guard let decoded = Base64SubscriptionParser.decodeText(encoded), let colon = decoded.firstIndex(of: ":") else {
                    throw ParserError.missingField("SOCKS5 username:password")
                }
                node.username = String(decoded[..<colon])
                node.password = String(decoded[decoded.index(after: colon)...])
            }
            if node.username == "", node.password == "" {
                node.username = nil
                node.password = nil
            }
        }
        if type == .anytls {
            guard query["security"] == nil || query["security"] == "tls",
                  query["type"] == nil || query["type"] == "tcp",
                  query["header-type"] == nil || query["header-type"] == "none" else {
                throw ParserError.unsupportedOption("AnyTLS 仅支持原生 TLS/TCP，不支持额外传输或伪装头")
            }
            node.password = [url.user, url.password].compactMap { $0 }.joined(separator: ":")
            node.username = nil
            node.allowInsecure = try boolean(query["insecure"])
            node.fingerprint = query["fp"]
        } else if type == .tuic {
            node.uuid = url.user
            node.username = nil
            node.alpn = query["alpn"] ?? "h3"
            node.allowInsecure = try boolean(query["insecure"])
            node.tuicOptions = TuicOptions(congestionControl: query["congestion-control"], udpRelayMode: query["udp-relay-mode"],
                udpOverStream: try boolean(query["udp-over-stream"]), zeroRTTHandshake: try boolean(query["zero-rtt-handshake"]),
                heartbeat: query["heartbeat"], certificate: query["certificate"], publicKeySHA256: list(query["public-key-sha256"]),
                disableSNI: try boolean(query["disable-sni"]))
        } else if type == .wireguard {
            node.username = nil
            node.password = nil
            node.wireGuardOptions = WireGuardOptions(privateKey: url.user, addresses: list(query["addresses"]) ?? [],
                peerPublicKey: query["public-key"] ?? "", preSharedKey: query["pre-shared-key"],
                allowedIPs: list(query["allowed-ips"]), reserved: try integers(query["reserved"]),
                mtu: try integer(query["mtu"]), keepAlive: try integer(query["keepalive"]), remoteDNS: list(query["remote-dns"]))
            guard url.password == nil else { throw ParserError.unsupportedOption("WireGuard 链接不使用用户名密码认证") }
        } else if let headers = query["headers"] {
            guard let data = headers.data(using: .utf8), let parsed = try? JSONDecoder().decode([String: String].self, from: data) else {
                throw ParserError.unsupportedOption("HTTP headers 必须是字符串键值 JSON 对象")
            }
            node.httpHeaders = parsed
        }
        try validate(node)
        return node
    }

    static func isWireGuardConfig(_ text: String) -> Bool {
        text.components(separatedBy: .newlines).contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == "[interface]" }
    }

    static func parseClash(_ fields: [String: String]) throws -> ProxyNode {
        let type = fields["type"] ?? ""
        let scheme = type == "http" && fields["tls"]?.lowercased() == "true" ? "https" : type
        var common: Set<String> = ["name", "type", "server", "port", "tls", "udp"]
        if type == "tuic" || type == "anytls" { common.insert("password") }
        else if type == "socks5" || type == "http" { common.formUnion(["username", "password"]) }
        let specifics: Set<String>
        switch type {
        case "anytls": specifics = ["sni", "servername", "alpn", "skip-cert-verify", "client-fingerprint"]
        case "tuic": specifics = ["uuid", "sni", "servername", "alpn", "skip-cert-verify", "congestion-controller", "congestion-control", "udp-relay-mode", "udp-over-stream", "reduce-rtt", "zero-rtt-handshake", "heartbeat-interval", "heartbeat", "certificate", "public-key-sha256", "disable-sni"]
        case "wireguard": specifics = ["private-key", "public-key", "pre-shared-key", "ip", "ipv6", "addresses", "allowed-ips", "reserved", "mtu", "persistent-keepalive", "remote-dns", "dns"]
        case "socks5": specifics = []
        case "http": specifics = ["sni", "servername", "alpn", "pin-sha256", "skip-cert-verify"]
        default: throw ParserError.unsupportedScheme(type)
        }
        for key in fields.keys where !common.contains(key) && !specifics.contains(key) && !(type == "http" && key.hasPrefix("headers.")) {
            throw ParserError.unsupportedOption("不支持的 \(type) YAML 参数：\(key)")
        }
        if let tls = try boolean(fields["tls"]), type != "http", tls != (type == "tuic" || type == "anytls") {
            throw ParserError.unsupportedOption("节点 TLS 设置与协议不匹配")
        }
        if let udp = try boolean(fields["udp"]), udp != (type != "http") {
            throw ParserError.unsupportedOption("此协议的 UDP 开关未接入该取值")
        }
        var url = URLComponents()
        url.scheme = scheme
        let host = fields["server"] ?? ""
        url.host = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        guard let port = Int(fields["port"] ?? ""), (1...65535).contains(port) else { throw ParserError.missingField("port") }
        url.port = port
        url.fragment = fields["name"]
        url.user = type == "tuic" ? fields["uuid"] : type == "wireguard" ? fields["private-key"] : fields["username"]
        if type != "wireguard" { url.password = fields["password"] }
        if type == "anytls" { url.user = fields["password"]; url.password = nil }
        var query: [String: String] = [:]
        if ["anytls", "tuic", "http"].contains(type) {
            query["sni"] = fields["sni"] ?? fields["servername"]
            query["alpn"] = fields["alpn"]
            let insecure = try boolean(fields["skip-cert-verify"])
            if type == "tuic" || type == "anytls" { query["insecure"] = insecure.map(String.init) }
            else if insecure == true { throw ParserError.unsupportedOption("HTTPS CONNECT 必须验证服务端证书") }
        }
        if type == "anytls" {
            query["fp"] = fields["client-fingerprint"]
        } else if type == "tuic" {
            for key in ["udp-relay-mode", "udp-over-stream", "heartbeat", "certificate", "public-key-sha256", "disable-sni"] { query[key] = fields[key] }
            query["congestion-control"] = fields["congestion-control"] ?? fields["congestion-controller"]
            query["zero-rtt-handshake"] = fields["zero-rtt-handshake"] ?? fields["reduce-rtt"]
            query["heartbeat"] = fields["heartbeat"]
            if query["heartbeat"] == nil, let interval = try integer(fields["heartbeat-interval"]) {
                guard interval >= 0 else { throw ParserError.unsupportedOption("TUIC heartbeat-interval 不能为负数") }
                query["heartbeat"] = "\(interval)ms"
            }
        } else if type == "wireguard" {
            for key in ["public-key", "pre-shared-key", "allowed-ips", "reserved", "mtu"] { query[key] = fields[key] }
            query["addresses"] = fields["addresses"] ?? [fields["ip"], fields["ipv6"]].compactMap { $0 }.joined(separator: ",")
            query["keepalive"] = fields["persistent-keepalive"]
            query["remote-dns"] = fields["remote-dns"] ?? fields["dns"]
        } else if type == "http" {
            query["pinSHA256"] = fields["pin-sha256"]
            var headers: [String: String] = [:]
            for (key, value) in fields where key.hasPrefix("headers.") { headers[String(key.dropFirst(8))] = value }
            if !headers.isEmpty { query["headers"] = String(decoding: try JSONEncoder().encode(headers), as: UTF8.self) }
        }
        url.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let link = url.string else { throw ParserError.missingField("node URL") }
        return try parse(link)
    }

    static func isHTTPProxyLink(_ text: String) -> Bool {
        guard let url = URLComponents(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.port != nil || url.user != nil else { return false }
        return (try? parse(text)) != nil
    }

    static func shareLink(_ node: ProxyNode) -> String? {
        guard (try? validate(node)) != nil else { return nil }
        var url = URLComponents()
        url.scheme = node.protocolType == .http && node.security == .tls ? "https" : node.protocolType.rawValue
        url.host = node.server.contains(":") ? "[\(node.server)]" : node.server
        url.port = node.port
        url.fragment = node.name
        url.user = node.protocolType == .tuic ? node.uuid : node.username
        url.password = node.password
        if node.protocolType == .anytls { url.user = node.password; url.password = nil }
        var query: [String: String] = [:]
        if let sni = node.sni { query["sni"] = sni }
        if let alpn = node.alpn { query["alpn"] = alpn }
        if [.anytls, .tuic].contains(node.protocolType) { query["insecure"] = node.allowInsecure.map { $0 ? "1" : "0" } }
        if node.protocolType == .anytls { query["fp"] = node.fingerprint }
        if node.protocolType == .tuic, let options = node.tuicOptions {
            query["congestion-control"] = options.congestionControl
            query["udp-relay-mode"] = options.udpRelayMode
            query["udp-over-stream"] = options.udpOverStream.map(String.init)
            query["zero-rtt-handshake"] = options.zeroRTTHandshake.map(String.init)
            query["disable-sni"] = options.disableSNI.map(String.init)
            query["heartbeat"] = options.heartbeat
            query["certificate"] = options.certificate
            query["public-key-sha256"] = options.publicKeySHA256?.joined(separator: ",")
        } else if node.protocolType == .wireguard, let options = node.wireGuardOptions {
            url.user = options.privateKey
            url.password = nil
            query["public-key"] = options.peerPublicKey
            query["pre-shared-key"] = options.preSharedKey
            query["addresses"] = options.addresses.joined(separator: ",")
            query["allowed-ips"] = options.allowedIPs?.joined(separator: ",")
            query["remote-dns"] = options.remoteDNS?.joined(separator: ",")
            query["reserved"] = options.reserved?.map(String.init).joined(separator: ",")
            query["mtu"] = options.mtu.map(String.init)
            query["keepalive"] = options.keepAlive.map(String.init)
        } else if node.protocolType == .http {
            query["pinSHA256"] = node.pinnedCertSHA256
            if let headers = node.httpHeaders, !headers.isEmpty,
               let data = try? JSONEncoder().encode(headers) { query["headers"] = String(decoding: data, as: UTF8.self) }
        }
        if !query.isEmpty { url.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return url.string
    }

    static func parseWireGuardConfig(_ text: String) throws -> ProxyNode {
        var section = ""
        var peers = 0
        var fields: [String: String] = [:]
        let allowed = ["interface": Set(["privatekey", "address", "dns", "mtu"]),
                       "peer": Set(["publickey", "presharedkey", "allowedips", "endpoint", "persistentkeepalive"])]
        for raw in text.components(separatedBy: .newlines) {
            let line = String(raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.first == "[" {
                section = line.lowercased()
                guard section == "[interface]" || section == "[peer]" else { throw ParserError.unsupportedOption("不支持的 WireGuard 配置段") }
                section = section.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                if section == "peer" { peers += 1 }
                guard peers <= 1 else { throw ParserError.unsupportedOption("目前仅支持单 Peer WireGuard 客户端配置") }
                continue
            }
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { throw ParserError.unsupportedOption("WireGuard 配置行必须是字段=值") }
            let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            guard allowed[section]?.contains(key) == true, fields[section + "." + key] == nil else {
                throw ParserError.unsupportedOption("WireGuard 字段不支持、重复或所在段无效：\(key)")
            }
            fields[section + "." + key] = pair[1].trimmingCharacters(in: .whitespaces)
        }
        guard peers == 1, let endpoint = fields["peer.endpoint"], let url = URLComponents(string: "wireguard://" + endpoint),
              let host = url.host, let port = url.port, url.user == nil, url.query == nil, url.fragment == nil, url.path.isEmpty else {
            throw ParserError.missingField("WireGuard Peer Endpoint")
        }
        let options = WireGuardOptions(privateKey: fields["interface.privatekey"], addresses: list(fields["interface.address"]) ?? [],
            peerPublicKey: fields["peer.publickey"] ?? "", preSharedKey: fields["peer.presharedkey"],
            allowedIPs: list(fields["peer.allowedips"]), mtu: try integer(fields["interface.mtu"]),
            keepAlive: try integer(fields["peer.persistentkeepalive"]), remoteDNS: list(fields["interface.dns"]))
        let node = ProxyNode(name: "WireGuard \(host):\(port)", protocolType: .wireguard,
                             server: host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), port: port, wireGuardOptions: options)
        try validate(node)
        return node
    }

    static func validate(_ node: ProxyNode) throws {
        guard !node.server.isEmpty, (1...65535).contains(node.port), node.transport == .tcp,
              !FinalMaskCodec.isPresent(on: node) else { throw ParserError.unsupportedOption("远程节点地址、端口或传输参数不支持") }
        switch node.protocolType {
        case .anytls:
            guard !(node.password ?? "").isEmpty, node.security == .tls, node.username == nil else {
                throw ParserError.missingField("AnyTLS password/TLS")
            }
            guard node.pinnedCertSHA256 == nil, (node.publicKey ?? "").isEmpty else {
                throw ParserError.unsupportedOption("AnyTLS 暂不支持证书固定摘要或 REALITY")
            }
            if let alpn = node.alpn {
                guard alpn.components(separatedBy: ",").allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
                    throw ParserError.unsupportedOption("AnyTLS ALPN 不能为空")
                }
            }
        case .tuic:
            guard let uuid = node.uuid, UUID(uuidString: uuid) != nil, node.password != nil, node.security == .tls else {
                throw ParserError.missingField("TUIC v5 UUID/password/TLS")
            }
            guard node.pinnedCertSHA256 == nil else { throw ParserError.unsupportedOption("TUIC 使用 public-key-sha256 固定公钥，不使用证书 pinSHA256") }
            if let options = node.tuicOptions {
                guard options.congestionControl == nil || ["cubic", "new_reno", "bbr"].contains(options.congestionControl!),
                      options.udpRelayMode == nil || ["native", "quic"].contains(options.udpRelayMode!),
                      options.udpOverStream != true || options.udpRelayMode == nil else {
                    throw ParserError.unsupportedOption("TUIC 拥塞控制或 UDP 转发选项无效/冲突")
                }
                if let heartbeat = options.heartbeat, heartbeat.range(of: #"^\d+(?:\.\d+)?(?:ms|s|m|h)$"#, options: .regularExpression) == nil {
                    throw ParserError.unsupportedOption("TUIC heartbeat 必须是带单位的时长")
                }
                for pin in options.publicKeySHA256 ?? [] {
                    guard Data(base64Encoded: pin)?.count == 32 else { throw ParserError.unsupportedOption("TUIC 公钥摘要必须是 Base64 SHA-256") }
                }
                if let cert = options.certificate, !cert.contains("-----BEGIN CERTIFICATE-----") {
                    throw ParserError.unsupportedOption("TUIC certificate 必须是 PEM 证书")
                }
            }
            guard (node.alpn ?? "h3").components(separatedBy: ",").allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
                throw ParserError.unsupportedOption("TUIC ALPN 不能为空")
            }
        case .wireguard:
            guard node.security == .none, let options = node.wireGuardOptions else { throw ParserError.missingField("WireGuard 配置") }
            guard validKey(options.privateKey), validKey(options.peerPublicKey), options.preSharedKey == nil || validKey(options.preSharedKey) else {
                throw ParserError.unsupportedOption("WireGuard 密钥必须为 32 字节 Base64 或 64 位十六进制")
            }
            guard !options.addresses.isEmpty, options.addresses.allSatisfy({ validIP($0, cidr: true) }),
                  options.allowedIPs == nil || (!options.allowedIPs!.isEmpty && options.allowedIPs!.allSatisfy({ validIP($0, cidr: true, requirePrefix: true) })),
                  options.remoteDNS == nil || options.remoteDNS!.allSatisfy({ validIP($0) }) else {
                throw ParserError.unsupportedOption("WireGuard 本地地址、AllowedIPs 或 DNS 无效")
            }
            guard options.reserved == nil || (options.reserved!.count == 3 && options.reserved!.allSatisfy({ (0...255).contains($0) })),
                  options.mtu == nil || (576...65535).contains(options.mtu!),
                  options.keepAlive == nil || (0...65535).contains(options.keepAlive!) else {
                throw ParserError.unsupportedOption("WireGuard reserved、MTU 或 keepalive 无效")
            }
            if let mtu = options.mtu, mtu < 1280, options.addresses.contains(where: { $0.contains(":") }) {
                throw ParserError.unsupportedOption("WireGuard 包含 IPv6 地址时 MTU 不能小于 1280")
            }
        case .socks5, .http:
            guard node.security == .none || (node.protocolType == .http && node.security == .tls), node.allowInsecure != true else {
                throw ParserError.unsupportedOption("SOCKS5 仅支持原生传输；HTTPS 必须验证证书")
            }
            if node.username != nil || node.password != nil {
                guard let user = node.username, !user.isEmpty, node.protocolType != .http || !user.contains(":"),
                      node.protocolType != .socks5 || (user.utf8.count <= 255 && !(node.password ?? "").isEmpty && (node.password ?? "").utf8.count <= 255) else {
                    throw ParserError.unsupportedOption("代理用户名/密码无效或超过 SOCKS5 长度限制")
                }
            }
            if node.protocolType == .http {
                guard node.alpn == nil || node.alpn == "http/1.1" else { throw ParserError.unsupportedOption("HTTP CONNECT 当前使用 HTTP/1.1") }
                try validateHeaders(node.httpHeaders ?? [:], basic: node.username != nil)
                if let pin = node.pinnedCertSHA256 {
                    guard node.security == .tls, pin.count == 64, pin.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
                        throw ParserError.unsupportedOption("HTTPS pinSHA256 必须为 64 位十六进制证书摘要")
                    }
                }
                guard node.security == .tls || node.sni == nil else { throw ParserError.unsupportedOption("明文 HTTP 不使用 TLS SNI") }
            }
        default: throw ParserError.unsupportedScheme(node.protocolType.rawValue)
        }
    }

    static func validateHeaders(_ headers: [String: String], basic: Bool) throws {
        var seen = Set<String>()
        let token = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        for (key, value) in headers {
            let name = key.lowercased()
            guard !key.isEmpty, key.unicodeScalars.allSatisfy({ token.contains($0) }), seen.insert(name).inserted,
                  value.unicodeScalars.allSatisfy({ $0.value == 9 || ($0.value >= 32 && $0.value != 127) }),
                  !["host", "content-length", "transfer-encoding", "connection", "proxy-connection"].contains(name),
                  name != "proxy-authorization" || !basic else {
                throw ParserError.unsupportedOption("HTTP 代理请求头无效、重复或与认证配置冲突")
            }
        }
    }

    static func validIP(_ value: String, cidr: Bool = false, requirePrefix: Bool = false) -> Bool {
        let parts = value.components(separatedBy: "/")
        guard parts.count <= (cidr ? 2 : 1), !requirePrefix || parts.count == 2 else { return false }
        var v4 = in_addr()
        var v6 = in6_addr()
        let bits = inet_pton(AF_INET, parts[0], &v4) == 1 ? 32 : inet_pton(AF_INET6, parts[0], &v6) == 1 ? 128 : 0
        guard bits > 0 else { return false }
        if parts.count == 2 { return Int(parts[1]).map { (0...bits).contains($0) } ?? false }
        return true
    }

    static func validKey(_ value: String?) -> Bool {
        guard let value else { return false }
        return Data(base64Encoded: value)?.count == 32 || (value.count == 64 && value.allSatisfy({ $0.isASCII && $0.isHexDigit }))
    }

    static func list(_ value: String?) -> [String]? { value.map { $0.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) } } }
    static func boolean(_ value: String?) throws -> Bool? {
        guard let value else { return nil }
        switch value.lowercased() {
        case "1", "true": return true
        case "0", "false": return false
        default: throw ParserError.unsupportedOption("布尔参数必须为 true/false 或 1/0")
        }
    }
    static func integer(_ value: String?) throws -> Int? {
        guard let value else { return nil }
        guard let result = Int(value) else { throw ParserError.unsupportedOption("数字参数格式无效") }
        return result
    }
    static func integers(_ value: String?) throws -> [Int]? {
        try list(value).map { try $0.map { text in
            guard let number = Int(text) else { throw ParserError.unsupportedOption("整数列表格式无效") }
            return number
        } }
    }
}
