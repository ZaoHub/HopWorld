import Foundation

enum ParserError: LocalizedError, Sendable {
    case unsupportedScheme(String)
    case invalidURL(String)
    case missingField(String)
    case invalidBase64
    case emptyContent
    case noValidNodes

    var errorDescription: String? {
        switch self {
        case .unsupportedScheme(let scheme): return "不支持的协议：\(scheme)"
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
}

enum NodeLinkParser {
    static func parse(_ raw: String) throws -> ProxyNode {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
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
        case "ss":
            return try ShadowsocksParser.parse(trimmed)
        default:
            throw ParserError.unsupportedScheme(scheme)
        }
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

    /// Pull ss/vless/vmess/trojan URIs out of messy pasted text (one per line or inline).
    static func extractShareLinks(from text: String) -> [String] {
        let pattern = #"(?i)\b((?:ss|vless|vmess|trojan)://[^\s<>"']+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var links: [String] = []
        var seen = Set<String>()
        for match in matches {
            guard match.numberOfRanges > 1 else { continue }
            var link = ns.substring(with: match.range(at: 1))
            // Trim trailing punctuation commonly copied from chats.
            while let last = link.last, ",.;)]}".contains(last) {
                link.removeLast()
            }
            guard !link.isEmpty, !seen.contains(link) else { continue }
            seen.insert(link)
            links.append(link)
        }
        return links
    }
}

enum Base64SubscriptionParser {
    static func parse(_ data: Data) throws -> ParseResult {
        guard !data.isEmpty else { throw ParserError.emptyContent }

        if let text = String(data: data, encoding: .utf8),
           text.contains("://") || text.contains("proxies:") {
            return try SubscriptionContentParser.parse(text: text, rawData: data)
        }

        let cleaned = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            ?? ""

        guard let decoded = Data(base64Encoded: cleaned, options: [.ignoreUnknownCharacters]),
              let decodedText = String(data: decoded, encoding: .utf8)
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

        // Clash YAML
        if trimmed.contains("proxies:") || trimmed.hasPrefix("port:") || trimmed.contains("\nproxies:") {
            let clash = try ClashYAMLParser.parse(trimmed)
            if !clash.validNodes.isEmpty { return clash }
        }

        // Share links
        if trimmed.contains("://") {
            let links = NodeLinkParser.parseLines(trimmed)
            if !links.validNodes.isEmpty { return links }
        }

        // Base64 body
        let base64 = try Base64SubscriptionParser.parse(rawData)
        if base64.validNodes.isEmpty { throw ParserError.noValidNodes }
        return base64
    }
}
