import Foundation

/// Parses share links even when query values contain `@` / `=` that break `URLComponents`.
enum ShareLinkComponents {
    struct Parts {
        var scheme: String
        var user: String?
        var host: String
        var port: Int
        var query: [String: String]
        var fragment: String?
    }

    static func parse(_ link: String) throws -> Parts {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        // Prefer Foundation when it works.
        if let comps = URLComponents(string: trimmed),
           let scheme = comps.scheme,
           let host = comps.host,
           let port = comps.port {
            var query: [String: String] = [:]
            for item in comps.queryItems ?? [] {
                query[item.name] = item.value
            }
            return Parts(
                scheme: scheme.lowercased(),
                user: comps.user.map { $0.removingPercentEncoding ?? $0 },
                host: host,
                port: port,
                query: query,
                fragment: comps.fragment.map { $0.removingPercentEncoding ?? $0 }
            )
        }
        return try parseLoose(trimmed)
    }

    private static func parseLoose(_ link: String) throws -> Parts {
        guard let schemeRange = link.range(of: "://") else {
            throw ParserError.invalidURL(link)
        }
        let scheme = String(link[..<schemeRange.lowerBound]).lowercased()
        var rest = String(link[schemeRange.upperBound...])

        var fragment: String?
        if let hash = rest.firstIndex(of: "#") {
            fragment = String(rest[rest.index(after: hash)...]).removingPercentEncoding
            rest = String(rest[..<hash])
        }

        var query: [String: String] = [:]
        if let q = rest.firstIndex(of: "?") {
            let queryString = String(rest[rest.index(after: q)...])
            rest = String(rest[..<q])
            query = parseQuery(queryString)
        }

        // userinfo@host:port  — split on the LAST @ before host (user may contain encoded chars)
        var user: String?
        var hostPort = rest
        if let at = rest.firstIndex(of: "@") {
            user = String(rest[..<at]).removingPercentEncoding
            hostPort = String(rest[rest.index(after: at)...])
        }

        let hp = hostPort.split(separator: ":", maxSplits: 1).map(String.init)
        guard hp.count == 2, let port = Int(hp[1].split(separator: "/").first.map(String.init) ?? hp[1]) else {
            throw ParserError.missingField("server/port")
        }
        let host = hp[0]
        guard !host.isEmpty else { throw ParserError.missingField("server") }

        return Parts(
            scheme: scheme,
            user: user,
            host: host,
            port: port,
            query: query,
            fragment: fragment
        )
    }

    static func parseQuery(_ queryString: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in queryString.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = parts.first, !key.isEmpty else { continue }
            let rawValue = parts.count > 1 ? parts[1] : ""
            result[key] = rawValue.removingPercentEncoding ?? rawValue
        }
        return result
    }
}
