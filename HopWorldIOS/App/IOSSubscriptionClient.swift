import Foundation

enum IOSSubscriptionError: LocalizedError {
    case invalidURL(String)
    case http(Int)
    case empty
    case timeout
    case insecure

    var errorDescription: String? {
        switch self {
        case .invalidURL(let value): return "无效 URL：\(value)"
        case .http(let code): return "HTTP \(code)"
        case .empty: return "响应内容为空"
        case .timeout: return "请求超时"
        case .insecure: return "HTTP 订阅被系统安全策略拦截，当前仅支持 HTTPS 订阅。"
        }
    }

    var rejectsUserAgent: Bool {
        switch self {
        case .http(403), .http(415): return true
        default: return false
        }
    }
}

enum IOSSubscriptionClient {
    /// 面板常把 User-Agent 当白名单。顺序与 Mac 版一致。
    static let userAgents = [
        "HopWorld/1.0",
        "clash-meta/1.18.0",
        "clash/1.18.0",
        "v2rayN/6.45",
        "Shadowsocks/4.4.1.0",
        "Shadowrocket/1992",
        "sing-box/1.11.0",
        "Quantumult X/1.4.1",
        "Surge/5.0",
        "Stash/2.6.1",
        "Loon/3.3.0",
        "v2rayNG/1.9.34"
    ]

    static func fetch(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              url.host != nil else {
            throw IOSSubscriptionError.invalidURL(urlString)
        }
        var lastError: Error = IOSSubscriptionError.invalidURL(urlString)
        for agent in userAgents {
            do {
                return try await load(url, userAgent: agent)
            } catch let error as IOSSubscriptionError where error.rejectsUserAgent {
                lastError = error
                continue
            } catch {
                throw error
            }
        }
        throw lastError
    }

    private static func load(_ url: URL, userAgent: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/plain,*/*", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await IOSURL.load(request)
        } catch let error as URLError where error.code == .appTransportSecurityRequiresSecureConnection {
            throw IOSSubscriptionError.insecure
        } catch let error as URLError where error.code == .timedOut {
            throw IOSSubscriptionError.timeout
        }
        guard let http = response as? HTTPURLResponse else {
            throw IOSSubscriptionError.http(-1)
        }
        if http.statusCode == 403 || http.statusCode == 415 {
            throw IOSSubscriptionError.http(http.statusCode)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw IOSSubscriptionError.http(http.statusCode)
        }
        guard !data.isEmpty else { throw IOSSubscriptionError.empty }
        return data
    }
}

enum IOSURL {
    static func load(_ request: URLRequest, session: URLSession = .shared) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data, let response else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                continuation.resume(returning: (data, response))
            }
            task.resume()
        }
    }
}
