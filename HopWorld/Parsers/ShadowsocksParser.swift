import Foundation

enum ShadowsocksParser {
    static func parse(_ link: String) throws -> ProxyNode {
        guard link.lowercased().hasPrefix("ss://") else {
            throw ParserError.invalidURL(link)
        }

        var remainder = String(link.dropFirst("ss://".count))
        var name = "Shadowsocks"
        if let hashIndex = remainder.firstIndex(of: "#") {
            name = String(remainder[remainder.index(after: hashIndex)...])
                .removingPercentEncoding ?? name
            remainder = String(remainder[..<hashIndex])
        }

        // ss://base64(method:password@host:port)
        // or ss://method:password@host:port
        // or ss://base64(method:password)@host:port

        if remainder.contains("@"), !isLikelyBase64Only(remainder) {
            return try parseSIP002(remainder, name: name)
        }

        guard let decoded = decodeBase64(remainder),
              let decodedText = String(data: decoded, encoding: .utf8)
        else {
            throw ParserError.invalidBase64
        }

        if decodedText.contains("@") {
            return try parseLegacy(decodedText, name: name)
        }

        throw ParserError.invalidURL(link)
    }

    private static func parseSIP002(_ remainder: String, name: String) throws -> ProxyNode {
        let parts = remainder.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw ParserError.invalidURL(remainder) }

        let userInfo: String
        if let decoded = decodeBase64(parts[0]), let text = String(data: decoded, encoding: .utf8) {
            userInfo = text
        } else {
            userInfo = parts[0].removingPercentEncoding ?? parts[0]
        }

        let methodPass = userInfo.split(separator: ":", maxSplits: 1).map(String.init)
        guard methodPass.count == 2 else { throw ParserError.missingField("method:password") }

        let hostPort = parts[1].split(separator: ":", maxSplits: 1).map(String.init)
        guard hostPort.count == 2, let port = Int(hostPort[1].split(separator: "/").first ?? Substring(hostPort[1])) else {
            throw ParserError.missingField("server:port")
        }

        return ProxyNode(
            name: name.isEmpty ? "\(hostPort[0]):\(port)" : name,
            protocolType: .shadowsocks,
            server: hostPort[0],
            port: port,
            password: methodPass[1],
            method: methodPass[0],
            transport: .tcp,
            security: .none
        )
    }

    private static func parseLegacy(_ text: String, name: String) throws -> ProxyNode {
        let parts = text.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw ParserError.invalidURL(text) }

        let methodPass = parts[0].split(separator: ":", maxSplits: 1).map(String.init)
        guard methodPass.count == 2 else { throw ParserError.missingField("method:password") }

        let hostPort = parts[1].split(separator: ":", maxSplits: 1).map(String.init)
        guard hostPort.count == 2, let port = Int(hostPort[1]) else {
            throw ParserError.missingField("server:port")
        }

        return ProxyNode(
            name: name.isEmpty ? "\(hostPort[0]):\(port)" : name,
            protocolType: .shadowsocks,
            server: hostPort[0],
            port: port,
            password: methodPass[1],
            method: methodPass[0],
            transport: .tcp,
            security: .none
        )
    }

    private static func decodeBase64(_ string: String) -> Data? {
        var padded = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = padded.count % 4
        if remainder > 0 {
            padded.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: padded, options: [.ignoreUnknownCharacters])
    }

    private static func isLikelyBase64Only(_ string: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/_-=\n\r")
        return string.unicodeScalars.allSatisfy { allowed.contains($0) } && !string.contains("@")
    }
}
