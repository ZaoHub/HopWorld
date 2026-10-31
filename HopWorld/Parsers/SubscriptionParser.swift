import Foundation
import Darwin

enum ParserError: LocalizedError, Sendable {
    case unsupportedScheme(String)
    case unsupportedOption(String)
    case invalidURL(String)
    case missingField(String)
    case invalidBase64
    case emptyContent
    case noValidNodes

    var errorDescription: String? {
        switch self {
        case .unsupportedScheme(let scheme): return "不支持的协议：\(scheme)"
        case .unsupportedOption(let message): return message
        case .invalidURL(let value): return "无效链接：\(value)"
        case .missingField(let field): return "缺少字段：\(field)"
        case .invalidBase64: return "无效的 Base64 内容"
        case .emptyContent: return "内容为空"
        case .noValidNodes: return "未解析到有效节点"
        }
    }
}

struct ParseResult: Sendable {
    var validNodes: [ProxyNode]
    var invalidCount: Int
    var formatName: String

    var skippedLinksSummary: String {
        invalidCount > 0 ? "；跳过 \(invalidCount) 条无效或暂不支持的链接" : ""
    }
}

enum NodeLinkParser {
    static func parse(_ raw: String) throws -> ProxyNode {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if RemoteProtocolParser.isWireGuardConfig(trimmed) { return try RemoteProtocolParser.parseWireGuardConfig(trimmed) }
        guard let scheme = URL(string: trimmed)?.scheme?.lowercased()
                ?? trimmed.split(separator: ":", maxSplits: 1).first.map(String.init)?.lowercased()
        else {
            throw ParserError.invalidURL(trimmed)
        }

        switch scheme {
        case "vless":
            return try VLESSParser.parse(trimmed)
        case "vmess":
            return try VMessParser.parse(trimmed)
        case "trojan":
            return try TrojanParser.parse(trimmed)
        case "hysteria2", "hy2":
            return try parseHysteria2(trimmed)
        case "masque":
            return try MasqueParser.parse(trimmed)
        case "anytls", "tuic", "wireguard", "wg", "socks5", "socks", "http", "https":
            return try RemoteProtocolParser.parse(trimmed)
        case "ss":
            return try ShadowsocksParser.parse(trimmed)
        default:
            throw ParserError.unsupportedScheme(scheme)
        }
    }

    private static func parseHysteria2(_ link: String) throws -> ProxyNode {
        guard var components = URLComponents(string: link) else { throw ParserError.invalidURL(link) }
        if components.port == nil { components.port = 443 }
        let parts = try ShareLinkComponents.parse(components.string ?? link)
        let password = [parts.user, components.password].compactMap { $0 }.joined(separator: ":")
        guard !password.isEmpty else { throw ParserError.missingField("password") }
        guard (1...65535).contains(parts.port) else { throw ParserError.missingField("port") }
        // Reject options we cannot preserve rather than silently changing the connection.
        for key in ["obfs", "obfs-password", "mport"] where !(parts.query[key] ?? "").isEmpty {
            throw ParserError.unsupportedOption("暂不支持 Hysteria2 参数：\(key)")
        }
        return ProxyNode(
            name: parts.fragment ?? "\(parts.host):\(parts.port)",
            protocolType: .hysteria2, server: parts.host, port: parts.port,
            password: password, security: .tls, sni: parts.query["sni"],
            alpn: parts.query["alpn"],
            allowInsecure: ["1", "true"].contains((parts.query["insecure"] ?? parts.query["allowInsecure"] ?? "0").lowercased()),
            pinnedCertSHA256: parts.query["pinSHA256"]
        )
    }

    static func parseLines(_ text: String) -> ParseResult {
        let links = extractShareLinks(from: text)
        var nodes: [ProxyNode] = []
        var invalid = 0

        for line in links {
            do {
                var node = try parse(line)
                node.nodeFingerprint = NodeFingerprint.make(from: node)
                nodes.append(node)
            } catch {
                invalid += 1
            }
        }

        return ParseResult(validNodes: nodes, invalidCount: invalid, formatName: "Share Links")
    }

    /// Extract share links, including adjacent links with no separator.
    static func extractShareLinks(from text: String) -> [String] {
        let text = text.contains("://") ? text : (Base64SubscriptionParser.decodeText(text) ?? text)
        if RemoteProtocolParser.isWireGuardConfig(text) {
            guard let node = try? RemoteProtocolParser.parseWireGuardConfig(text), let link = RemoteProtocolParser.shareLink(node) else { return [text] }
            return [link]
        }
        let pattern = #"(?i)((?:anytls|ss|vless|vmess|trojan|hysteria2|hy2|masque|tuic|wireguard|wg|socks5|socks|https?)://[^\s<>"']+?)(?=(?:anytls|ss|vless|vmess|trojan|hysteria2|hy2|masque|tuic|wireguard|wg|socks5|socks|https?)://|[\s<>"']|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var links: [String] = []
        var previousEnd = -1
        var canAppend = false
        for match in matches {
            guard match.numberOfRanges > 1 else { continue }
            var link = ns.substring(with: match.range(at: 1))
            // Trim trailing punctuation commonly copied from chats.
            while let last = link.last, ",.;)]}".contains(last) {
                link.removeLast()
            }
            let adjacent = previousEnd == match.range.location
            previousEnd = NSMaxRange(match.range)
            guard !link.isEmpty else { canAppend = false; continue }
            if ["http", "https"].contains(URLComponents(string: link)?.scheme?.lowercased() ?? ""),
               !RemoteProtocolParser.isHTTPProxyLink(link) {
                // A website URL inside a node name/path is not a second proxy.
                if adjacent, canAppend, !links.isEmpty { links[links.count - 1] += link }
                else { canAppend = false }
                continue
            }
            links.append(link)
            canAppend = true
        }
        var seen = Set<String>()
        return links.filter { seen.insert($0).inserted }
    }
}

/// HopWorld's standard CONNECT-IP link format; WARP device enrollment is separate.
enum MasqueParser {
    static let defaultPath = "/.well-known/masque/ip/{target}/{ipproto}/"

    static func parse(_ link: String) throws -> ProxyNode {
        guard let components = URLComponents(string: link), components.scheme?.lowercased() == "masque",
              let host = components.host, !host.isEmpty else { throw ParserError.missingField("MASQUE server") }
        var query: [String: String] = [:]
        let supported: Set<String> = ["sni", "host", "path", "alpn", "headers", "remoteDNS", "pinSHA256", "security", "type", "insecure"]
        for item in components.queryItems ?? [] {
            guard supported.contains(item.name) else { throw ParserError.unsupportedOption("不支持的 MASQUE 参数：\(item.name)") }
            guard query[item.name] == nil, let value = item.value else { throw ParserError.unsupportedOption("MASQUE 参数重复或缺少值：\(item.name)") }
            query[item.name] = value
        }
        guard query["security"] == nil || query["security"] == "tls",
              query["type"] == nil || query["type"] == "masque",
              query["insecure"] == nil || ["0", "false"].contains(query["insecure"]!) else {
            throw ParserError.unsupportedOption("MASQUE 必须使用 TLS 并验证服务端证书")
        }
        var headers: [String: String]?
        if let value = query["headers"] {
            guard let data = value.data(using: .utf8), let parsed = try? JSONDecoder().decode([String: String].self, from: data) else {
                throw ParserError.unsupportedOption("MASQUE headers 必须是字符串键值 JSON 对象")
            }
            headers = parsed
        }
        let node = ProxyNode(name: components.fragment ?? "\(host):\(components.port ?? 443)", protocolType: .masque,
                             server: host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), port: components.port ?? 443,
                             password: components.password, username: components.user, masqueHeaders: headers,
                             masqueRemoteDNS: query["remoteDNS"].map { $0.components(separatedBy: ",") },
                             transport: .masque, security: .tls, sni: query["sni"], host: query["host"],
                             path: query["path"] ?? (components.path.isEmpty ? nil : components.path),
                             alpn: query["alpn"] ?? "h3", pinnedCertSHA256: query["pinSHA256"])
        try validate(node)
        return node
    }

    static func validate(_ node: ProxyNode) throws {
        guard !node.server.isEmpty, (1...65535).contains(node.port) else { throw ParserError.missingField("MASQUE server/port") }
        guard node.transport == .masque, node.security == .tls, node.allowInsecure != true, (node.publicKey ?? "").isEmpty else {
            throw ParserError.unsupportedOption("MASQUE 必须使用 masque 传输和 TLS 证书验证")
        }
        let protocols = (node.alpn ?? "h3").components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !protocols.isEmpty, protocols.allSatisfy({ $0 == "h2" || $0 == "h3" }) else {
            throw ParserError.unsupportedOption("MASQUE ALPN 仅支持 h2、h3")
        }
        guard !(node.username ?? "").contains(":") else { throw ParserError.unsupportedOption("MASQUE 用户名不能包含冒号") }
        var path = node.path.flatMap { $0.isEmpty ? nil : $0 } ?? defaultPath
        for template in ["{?target,ipproto}", "{?ipproto,target}", "{&target,ipproto}", "{&ipproto,target}", "{target}", "{ipproto}"] {
            path = path.replacingOccurrences(of: template, with: "*")
        }
        guard path.hasPrefix("/"), !path.contains(where: { "{}\r\n".contains($0) }) else {
            throw ParserError.unsupportedOption("MASQUE 路径必须以 / 开头，且仅支持 target、ipproto 模板变量")
        }
        if let host = node.host, !host.isEmpty {
            guard let authority = URLComponents(string: "https://" + host), authority.host != nil,
                  authority.user == nil, authority.password == nil, authority.path.isEmpty,
                  authority.query == nil, authority.fragment == nil,
                  authority.port == nil || (1...65535).contains(authority.port!) else {
                throw ParserError.unsupportedOption("MASQUE Host 必须是有效主机及可选端口")
            }
        }
        var names = Set<String>()
        let token = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        for (name, value) in node.masqueHeaders ?? [:] {
            let lower = name.lowercased()
            guard !name.isEmpty, name.unicodeScalars.allSatisfy({ token.contains($0) }),
                  value.unicodeScalars.allSatisfy({ $0.value == 9 || ($0.value >= 32 && $0.value != 127) }),
                  names.insert(lower).inserted, !["host", "capsule-protocol"].contains(lower),
                  lower != "authorization" || ((node.username ?? "").isEmpty && (node.password ?? "").isEmpty) else {
                throw ParserError.unsupportedOption("MASQUE 请求头无效、重复或与认证配置冲突")
            }
        }
        for address in node.masqueRemoteDNS ?? [] {
            var v4 = in_addr()
            var v6 = in6_addr()
            guard inet_pton(AF_INET, address, &v4) == 1 || inet_pton(AF_INET6, address, &v6) == 1 else {
                throw ParserError.unsupportedOption("MASQUE remoteDNS 必须是 IP 地址")
            }
        }
        if let pin = node.pinnedCertSHA256 {
            guard pin.count == 64, pin.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
                throw ParserError.unsupportedOption("MASQUE pinSHA256 必须是 64 位十六进制证书摘要")
            }
        }
    }
}

enum Base64SubscriptionParser {
    static func decodeText(_ text: String) -> String? {
        var encoded = text.filter { !$0.isWhitespace }
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = encoded.utf8.count % 4
        if remainder > 0 { encoded += String(repeating: "=", count: 4 - remainder) }
        guard let decoded = Data(base64Encoded: encoded) else { return nil }
        return String(data: decoded, encoding: .utf8)
    }

    static func parse(_ data: Data) throws -> ParseResult {
        guard !data.isEmpty else { throw ParserError.emptyContent }

        if let text = String(data: data, encoding: .utf8),
           text.contains("://") || text.contains("proxies:") {
            return try SubscriptionContentParser.parse(text: text, rawData: data)
        }

        guard let text = String(data: data, encoding: .utf8),
              let decodedText = decodeText(text)
        else {
            // Maybe already plain text share links
            if let text = String(data: data, encoding: .utf8) {
                let result = NodeLinkParser.parseLines(text)
                if result.validNodes.isEmpty { throw ParserError.invalidBase64 }
                return ParseResult(validNodes: result.validNodes, invalidCount: result.invalidCount, formatName: "Plain Text")
            }
            throw ParserError.invalidBase64
        }

        let result = NodeLinkParser.parseLines(decodedText)
        return ParseResult(validNodes: result.validNodes, invalidCount: result.invalidCount, formatName: "Base64 Subscription")
    }
}

enum SubscriptionContentParser {
    static func parse(data: Data) throws -> ParseResult {
        guard !data.isEmpty else { throw ParserError.emptyContent }
        if let text = String(data: data, encoding: .utf8) {
            return try parse(text: text, rawData: data)
        }
        if let text = String(data: data, encoding: .isoLatin1) {
            return try parse(text: text, rawData: data)
        }
        throw ParserError.emptyContent
    }

    static func parse(text: String, rawData: Data) throws -> ParseResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParserError.emptyContent }

        if RemoteProtocolParser.isWireGuardConfig(trimmed) {
            var node = try RemoteProtocolParser.parseWireGuardConfig(trimmed)
            node.nodeFingerprint = NodeFingerprint.make(from: node)
            return ParseResult(validNodes: [node], invalidCount: 0, formatName: "WireGuard")
        }

        // Clash YAML
        if trimmed.contains("proxies:") || trimmed.hasPrefix("port:") || trimmed.contains("\nproxies:") {
            let clash = try ClashYAMLParser.parse(trimmed)
            if !clash.validNodes.isEmpty { return clash }
        }

        // Share links
        if trimmed.contains("://") {
            let links = NodeLinkParser.parseLines(trimmed)
            if !links.validNodes.isEmpty { return links }
            throw ParserError.noValidNodes
        }

        // Base64 body
        let base64 = try Base64SubscriptionParser.parse(rawData)
        if base64.validNodes.isEmpty { throw ParserError.noValidNodes }
        return base64
    }
}
