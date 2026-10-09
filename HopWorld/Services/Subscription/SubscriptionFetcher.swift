import Foundation

struct FetchResponse: Sendable {
    var url: URL
    var statusCode: Int
    var data: Data
    var etag: String?
    var lastModified: String?
    var notModified: Bool
}

enum SubscriptionFetcherError: LocalizedError, Sendable {
    case invalidURL(String)
    case httpError(Int)
    case emptyBody
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidURL(let value): return "无效 URL：\(value)"
        case .httpError(let code): return "HTTP \(code)"
        case .emptyBody: return "响应内容为空"
        case .timeout: return "请求超时"
        }
    }
}

actor SubscriptionFetcher {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 45
        config.httpMaximumConnectionsPerHost = 4
        config.waitsForConnectivity = false
        // Critical: do NOT inherit system HTTP/SOCKS proxy.
        // Otherwise updates fail whenever HopWorld (or a dead local proxy) owns system proxy.
        config.connectionProxyDictionary = [
            "HTTPEnable": 0,
            "HTTPSEnable": 0,
            "SOCKSEnable": 0,
            "ProxyAutoConfigEnable": 0
        ]
        self.session = URLSession(configuration: config)
    }

    func fetch(
        urlString: String,
        etag: String? = nil,
        lastModified: String? = nil
    ) async throws -> FetchResponse {
        guard let url = URL(string: urlString) else {
            throw SubscriptionFetcherError.invalidURL(urlString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) HopWorld/1.0",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/plain,*/*", forHTTPHeaderField: "Accept")
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw SubscriptionFetcherError.timeout
        }

        guard let http = response as? HTTPURLResponse else {
            throw SubscriptionFetcherError.httpError(-1)
        }

        if http.statusCode == 304 {
            return FetchResponse(
                url: url,
                statusCode: 304,
                data: Data(),
                etag: etag,
                lastModified: lastModified,
                notModified: true
            )
        }

        guard (200...299).contains(http.statusCode) else {
            throw SubscriptionFetcherError.httpError(http.statusCode)
        }

        guard !data.isEmpty else {
            throw SubscriptionFetcherError.emptyBody
        }

        return FetchResponse(
            url: url,
            statusCode: http.statusCode,
            data: data,
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
            notModified: false
        )
    }
}

enum SubscriptionPayloadValidator {
    static let minimumBytes = 16

    static func looksLikeHTML(_ data: Data) -> Bool {
        guard let text = String(data: data.prefix(256), encoding: .utf8)?.lowercased() else {
            return false
        }
        return text.contains("<html") || text.contains("<!doctype html") || text.contains("403 forbidden")
    }

    static func validateBasic(_ data: Data) -> Bool {
        guard data.count >= minimumBytes else { return false }
        guard !looksLikeHTML(data) else { return false }
        return true
    }
}
