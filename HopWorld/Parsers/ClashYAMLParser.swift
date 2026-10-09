import Foundation

/// Lightweight Clash proxy list parser (proxies section) without external YAML deps.
enum ClashYAMLParser {
    static func parse(_ text: String) throws -> ParseResult {
        let proxies = try extractProxyMaps(from: text)
        guard !proxies.isEmpty else {
            let fallback = NodeLinkParser.parseLines(text)
            if fallback.validNodes.isEmpty {
                throw ParserError.noValidNodes
            }
            return ParseResult(
                validNodes: fallback.validNodes,
                invalidCount: fallback.invalidCount,
                formatName: "Clash YAML (fallback)"
            )
        }

        var nodes: [ProxyNode] = []
        var invalid = 0

        for proxy in proxies {
            do {
                var node = try mapProxy(proxy)
                node.nodeFingerprint = NodeFingerprint.make(from: node)
                nodes.append(node)
            } catch {
                invalid += 1
            }
        }

        if nodes.isEmpty {
            throw ParserError.noValidNodes
        }

        return ParseResult(validNodes: nodes, invalidCount: invalid, formatName: "Clash YAML")
    }

    // MARK: - Mapping

    private static func mapProxy(_ proxy: [String: String]) throws -> ProxyNode {
        let proxy = Dictionary(proxy.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        let type = (proxy["type"] ?? "").lowercased()
        let name = proxy["name"] ?? "Clash Node"
        let server = proxy["server"] ?? ""
        let port = Int(proxy["port"] ?? "") ?? 0
        guard !server.isEmpty, (1...65535).contains(port) else { throw ParserError.missingField("server/port") }

        let network = (proxy["network"] ?? "tcp").lowercased()
        guard let transport = mapNetwork(network) else { throw ParserError.unsupportedScheme("Clash network") }
        if type == "vless" || type == "vmess" {
            guard let uuid = proxy["uuid"], UUID(uuidString: uuid) != nil else { throw ParserError.missingField("uuid") }
        } else {
            guard !(proxy["password"] ?? "").isEmpty else { throw ParserError.missingField("password") }
        }
        if type == "ss" || type == "shadowsocks" {
            guard !(proxy["cipher"] ?? "").isEmpty else { throw ParserError.missingField("cipher") }
        }
        let host = proxy["ws-opts.headers.host"] ?? proxy["http-opts.headers.host"] ?? proxy["host"]
        let path = proxy["ws-opts.path"] ?? proxy["http-opts.path"] ?? proxy["path"]
        let serviceName = proxy["grpc-opts.grpc-service-name"] ?? proxy["grpc-service-name"] ?? proxy["servicename"]
        let security: SecurityType = {
            if proxy.keys.contains(where: { $0.hasPrefix("reality") || $0.contains("public-key") }) {
                return .reality
            }
            if (proxy["tls"] ?? "").lowercased() == "true" {
                return .tls
            }
            return .none
        }()

        switch type {
        case "vless":
            return ProxyNode(
                name: name,
                protocolType: .vless,
                server: server,
                port: port,
                uuid: proxy["uuid"],
                flow: proxy["flow"],
                encryption: proxy["encryption"] ?? "none",
                transport: transport,
                security: security,
                sni: proxy["servername"] ?? proxy["sni"],
                host: host,
                path: path,
                serviceName: serviceName,
                publicKey: proxy["reality-opts.public-key"] ?? proxy["public-key"] ?? proxy["publickey"],
                shortID: proxy["reality-opts.short-id"] ?? proxy["short-id"] ?? proxy["shortid"],
                fingerprint: proxy["client-fingerprint"] ?? proxy["fingerprint"],
                alpn: proxy["alpn"]
            )
        case "vmess":
            return ProxyNode(
                name: name,
                protocolType: .vmess,
                server: server,
                port: port,
                uuid: proxy["uuid"],
                alterId: Int(proxy["alterId"] ?? proxy["alterid"] ?? ""),
                encryption: proxy["cipher"] ?? "auto",
                transport: transport,
                security: security,
                sni: proxy["servername"] ?? proxy["sni"],
                host: host,
                path: path,
                serviceName: serviceName,
                fingerprint: proxy["client-fingerprint"] ?? proxy["fingerprint"],
                alpn: proxy["alpn"]
            )
        case "trojan":
            return ProxyNode(
                name: name,
                protocolType: .trojan,
                server: server,
                port: port,
                password: proxy["password"],
                transport: transport,
                security: .tls,
                sni: proxy["sni"] ?? proxy["servername"],
                host: host,
                path: path,
                serviceName: serviceName,
                fingerprint: proxy["client-fingerprint"] ?? proxy["fingerprint"],
                alpn: proxy["alpn"]
            )
        case "ss", "shadowsocks":
            return ProxyNode(
                name: name,
                protocolType: .shadowsocks,
                server: server,
                port: port,
                password: proxy["password"],
                method: proxy["cipher"],
                transport: .tcp,
                security: .none
            )
        default:
            throw ParserError.unsupportedScheme(type)
        }
    }

    private static func mapNetwork(_ value: String) -> TransportType? {
        switch value {
        case "ws": return .ws
        case "grpc": return .grpc
        case "h2", "http": return .h2
        case "httpupgrade": return .httpupgrade
        case "tcp": return .tcp
        case "xhttp": return .xhttp
        default: return nil
        }
    }

    // MARK: - YAML proxy subset

    /// Preserve nested key paths rather than flattening unrelated leaf names.
    /// Unsupported YAML constructs fail closed instead of producing a wrong node.
    private static func extractProxyMaps(from text: String) throws -> [[String: String]] {
        let lines = text.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("proxies:") }) else { return [] }
        let header = stripComment(lines[start]).trimmingCharacters(in: .whitespaces)
        let headerValue = String(header.dropFirst("proxies:".count)).trimmingCharacters(in: .whitespaces)
        if !headerValue.isEmpty {
            guard headerValue.hasPrefix("["), headerValue.hasSuffix("]") else { throw ParserError.noValidNodes }
            return try splitTopLevel(String(headerValue.dropFirst().dropLast())).map { try flowMap($0) }
        }
        let sectionIndent = lines[start].prefix(while: { $0 == " " }).count
        var result: [[String: String]] = []
        var current: [String: String] = [:]
        var parents: [(indent: Int, key: String)] = []
        var itemIndent: Int?
        for raw in lines.dropFirst(start + 1) {
            let line = stripComment(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard !line.contains("\t") else { throw ParserError.noValidNodes }
            let indent = line.prefix(while: { $0 == " " }).count
            let isItem = trimmed.hasPrefix("- ") || trimmed == "-"
            if indent <= sectionIndent && !isItem { break }
            if isItem && (itemIndent == nil || indent == itemIndent) {
                if !current.isEmpty { result.append(current) }
                current = [:]
                parents = []
                itemIndent = indent
                let body = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                if body.hasPrefix("{") {
                    current = try flowMap(body)
                } else if !body.isEmpty {
                    let pair = try parsePair(body)
                    try addValue(pair.value, key: pair.key, into: &current)
                    if pair.value.isEmpty { parents.append((indent + 2, pair.key)) }
                }
                continue
            }
            guard let base = itemIndent, indent > base else { throw ParserError.noValidNodes }
            if isItem {
                guard let parent = parents.last, indent >= parent.indent else { throw ParserError.noValidNodes }
                let key = parents.map(\.key).joined(separator: ".")
                guard ["alpn", "http-opts.path", "http-opts.headers.Host", "http-opts.headers.host"].contains(key) else { throw ParserError.noValidNodes }
                let value = try scalar(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                current[key] = current[key].map { $0 + "," + value } ?? value
                continue
            }
            while let parent = parents.last, parent.indent >= indent { parents.removeLast() }
            let pair = try parsePair(trimmed)
            let key = (parents.map(\.key) + [pair.key]).joined(separator: ".")
            try addValue(pair.value, key: key, into: &current)
            if pair.value.isEmpty { parents.append((indent, pair.key)) }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func addValue(_ value: String, key: String, into result: inout [String: String]) throws {
        guard key != "<<", !value.hasPrefix("&"), !value.hasPrefix("*"), !value.hasPrefix("!"),
              value != "|", value != ">" else { throw ParserError.noValidNodes }
        if value.hasPrefix("{") {
            for (child, scalar) in try flowMap(value) { result[key + "." + child] = scalar }
        } else if value.hasPrefix("[") {
            guard value.hasSuffix("]") else { throw ParserError.noValidNodes }
            result[key] = try splitTopLevel(String(value.dropFirst().dropLast())).map { try scalar($0) }.joined(separator: ",")
        } else if !value.isEmpty {
            result[key] = try scalar(value)
        }
    }

    private static func flowMap(_ value: String) throws -> [String: String] {
        let value = value.trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("{"), value.hasSuffix("}") else { throw ParserError.noValidNodes }
        var result: [String: String] = [:]
        for part in try splitTopLevel(String(value.dropFirst().dropLast())) {
            let pair = try parsePair(part)
            try addValue(pair.value, key: pair.key, into: &result)
        }
        return result
    }

    private static func parsePair(_ value: String) throws -> (key: String, value: String) {
        let parts = try splitTopLevel(value, separator: ":", firstOnly: true)
        guard parts.count == 2 else { throw ParserError.noValidNodes }
        let key = try scalar(parts[0])
        guard !key.isEmpty else { throw ParserError.noValidNodes }
        return (key, parts[1])
    }

    private static func scalar(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\"") {
            guard let data = value.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(String.self, from: data) else { throw ParserError.noValidNodes }
            return decoded
        }
        if value.hasPrefix("'") {
            guard value.count >= 2, value.hasSuffix("'") else { throw ParserError.noValidNodes }
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return value
    }

    private static func splitTopLevel(_ text: String, separator: Character = ",", firstOnly: Bool = false) throws -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var depth = 0
        for char in text {
            if let q = quote {
                current.append(char)
                if escaped { escaped = false }
                else if char == "\\", q == "\"" { escaped = true }
                else if char == q { quote = nil }
                continue
            }
            if char == "\"" || char == "'" { quote = char }
            else if char == "{" || char == "[" { depth += 1 }
            else if char == "}" || char == "]" { depth -= 1 }
            guard depth >= 0 else { throw ParserError.noValidNodes }
            if char == separator, depth == 0, (!firstOnly || parts.isEmpty) {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else { current.append(char) }
        }
        guard quote == nil, depth == 0 else { throw ParserError.noValidNodes }
        if !current.isEmpty || !parts.isEmpty { parts.append(current.trimmingCharacters(in: .whitespaces)) }
        return parts
    }

    private static func stripComment(_ text: String) -> String {
        var quote: Character?
        var escaped = false
        var previous: Character?
        for index in text.indices {
            let char = text[index]
            if let q = quote {
                if escaped { escaped = false }
                else if char == "\\", q == "\"" { escaped = true }
                else if char == q { quote = nil }
            } else if char == "\"" || char == "'" { quote = char }
            else if char == "#", previous == nil || previous?.isWhitespace == true {
                return String(text[..<index])
            }
            previous = char
        }
        return text
    }
}
