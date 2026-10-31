import Foundation

struct FetchResponse: Sendable {
    var url: URL
    var statusCode: Int
    var data: Data
    var etag: String?
    var lastModified: String?
    var notModified: Bool
    var usedTemporaryProxy = false
}

enum SubscriptionFetcherError: LocalizedError, Sendable {
    case invalidURL(String)
    case httpError(Int)
    case emptyBody
    case timeout
    case insecureConnection
    case automaticRouteFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let value): return "无效 URL：\(value)"
        case .httpError(526): return "订阅源站证书校验失败（HTTP 526），需要订阅提供方修复或提供新的订阅地址"
        case .httpError(let code): return "HTTP \(code)"
        case .emptyBody: return "响应内容为空"
        case .timeout: return "请求超时"
        case .insecureConnection: return "HTTP 订阅被系统安全策略拦截，当前仅支持 HTTPS 订阅。请向订阅提供方获取 HTTPS 地址。"
        case .automaticRouteFailed(let detail): return "直连失败（\(detail)），已有节点的临时下载通道也不可用；已保留上次数据"
        }
    }
}

actor SubscriptionFetcher {
    private let session: URLSession

    init(session: URLSession? = nil) {
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
        self.session = session ?? URLSession(configuration: config)
    }

    func fetch(
        urlString: String,
        etag: String? = nil,
        lastModified: String? = nil,
        fallbackNodes: [ProxyNode] = []
    ) async throws -> FetchResponse {
        guard let url = URL(string: urlString),
              ["https", "http"].contains(url.scheme?.lowercased()), url.host != nil else {
            throw SubscriptionFetcherError.invalidURL(urlString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            "HopWorld/1.0",
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
        } catch let error as URLError where error.code == .appTransportSecurityRequiresSecureConnection {
            throw SubscriptionFetcherError.insecureConnection
        } catch {
            try Task.checkCancellation()
            guard Self.shouldTryTemporaryProxy(error), !fallbackNodes.isEmpty else {
                if (error as? URLError)?.code == .timedOut { throw SubscriptionFetcherError.timeout }
                throw error
            }
            return try await fetchThroughTemporaryProxy(request, nodes: fallbackNodes, directError: error)
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

    static func shouldTryTemporaryProxy(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .secureConnectionFailed, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
             .networkConnectionLost, .timedOut, .notConnectedToInternet:
            return true
        default: return false
        }
    }

    static func temporaryProxyCandidates(_ nodes: [ProxyNode]) -> [ProxyNode] {
        Array(nodes.filter { $0.enabled && !$0.pendingRemoval }.sorted {
            if $0.lastTestStatus.sortRank != $1.lastTestStatus.sortRank {
                return $0.lastTestStatus.sortRank < $1.lastTestStatus.sortRank
            }
            return ($0.lastLatency ?? Int.max) < ($1.lastLatency ?? Int.max)
        }.prefix(3))
    }

    private func fetchThroughTemporaryProxy(
        _ request: URLRequest, nodes: [ProxyNode], directError: Error
    ) async throws -> FetchResponse {
        // A separate core owns only this download; never touch ConnectionManager or system routing.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HopWorld-subscription-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let core = XrayProcessManager()
        for node in Self.temporaryProxyCandidates(nodes) {
            do {
                try Task.checkCancellation()
                let reservation = try LocalTestPorts(count: 1)
                let port = reservation.ports[0]
                let file = directory.appendingPathComponent("config.json")
                try await XrayConfigBuilder.writeTestConfig(nodes: [(node, port)], to: file)
                reservation.release()
                try await core.start(configURL: file)
                let response = try await fetchUsingCurl(request, port: port, directory: directory)
                await core.stop()
                return response
            } catch {
                await core.stop()
                try Task.checkCancellation()
            }
        }
        throw SubscriptionFetcherError.automaticRouteFailed(directError.localizedDescription)
    }

    private func fetchUsingCurl(_ request: URLRequest, port: Int, directory: URL) async throws -> FetchResponse {
        let url = request.url!
        let body = directory.appendingPathComponent("body")
        let headers = directory.appendingPathComponent("headers")
        var arguments = ["--disable", "--silent", "--show-error", "--globoff", "--location", "--max-redirs", "5",
                         "--noproxy", "", "--proxy", "http://127.0.0.1:\(port)",
                         "--connect-timeout", "8", "--max-time", "20", "--compressed",
                         "--proto", "=http,https", "--proto-redir", url.scheme?.lowercased() == "https" ? "=https" : "=http,https",
                         "--output", body.path, "--dump-header", headers.path, "--write-out", "%{http_code}"]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            arguments += ["--header", "\(name): \(value)"]
        }
        arguments += ["--url", url.absoluteString]
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/curl"),
                                                 arguments: arguments, timeout: 22)
        if result.cancelled { throw CancellationError() }
        if result.timedOut || result.status == 28 { throw SubscriptionFetcherError.timeout }
        guard result.status == 0 else { throw URLError(.cannotConnectToHost) }
        let rawHeaders = try String(contentsOf: headers, encoding: .utf8)
        let responseHeaders = rawHeaders.components(separatedBy: "\r\n\r\n").last { $0.hasPrefix("HTTP/") } ?? ""
        let lines = responseHeaders.components(separatedBy: "\r\n")
        let status = Int(lines.first?.split(separator: " ").dropFirst().first ?? "") ?? -1
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard status == 304 || (200...299).contains(status) else { throw SubscriptionFetcherError.httpError(status) }
        let data = status == 304 ? Data() : try Data(contentsOf: body)
        guard status == 304 || !data.isEmpty else { throw SubscriptionFetcherError.emptyBody }
        return FetchResponse(url: url, statusCode: status, data: data,
                             etag: status == 304 ? request.value(forHTTPHeaderField: "If-None-Match") : fields["etag"],
                             lastModified: status == 304 ? request.value(forHTTPHeaderField: "If-Modified-Since") : fields["last-modified"],
                             notModified: status == 304, usedTemporaryProxy: true)
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
