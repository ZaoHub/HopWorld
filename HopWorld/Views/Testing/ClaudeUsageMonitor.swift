import Foundation
import Combine
import Security

struct ClaudeUsageSnapshot: Sendable {
    struct Window: Sendable {
        let usedPercent: Double
        let resetsAt: Date?
        var remaining: Double { min(100, max(0, 100 - usedPercent)) }
    }
    let fiveHour: Window?
    let sevenDay: Window?
    let sevenDayOpus: Window?
    let sevenDaySonnet: Window?
    var hasAnyWindow: Bool { fiveHour != nil || sevenDay != nil || sevenDayOpus != nil || sevenDaySonnet != nil }
}

/// Read the Claude Code login without writing, refreshing or persisting credentials.
/// The access token is used only for Anthropic's own read-only usage endpoint.
enum ClaudeUsageReader {
    struct Credentials: Sendable {
        let accessToken: String
        let expiresAt: Date?
    }

    private static let credentialsLock = NSLock()
    private static var cachedCredentials: Credentials?

    enum ReadError: LocalizedError {
        case missingLogin, loginExpired, unavailable, unsupported, unsupportedLogin
        case keychainAccess(OSStatus)
        case httpStatus(Int)
        var errorDescription: String? {
            switch self {
            case .missingLogin: return "未读取到 Claude Code 登录，请在终端运行 claude 并登录 Claude 账号后刷新。"
            case .loginExpired: return "Claude Code 登录已过期，请运行一次 claude 刷新登录后再点击刷新。"
            case .unavailable: return "Claude 用量读取失败，请稍后重试。"
            case .unsupported: return "Claude 未返回可显示的用量，请查看用量页面。"
            case .unsupportedLogin: return "无法识别 Claude Code 登录凭据，请重新登录 Claude Code 后重试。"
            case .keychainAccess: return "需要读取 Claude Code 登录，请点击刷新并允许访问“Claude Code-credentials”钥匙串。"
            case .httpStatus(403): return "Anthropic 拒绝访问用量接口（HTTP 403），可能是账号权限或当前出口地区不受支持。"
            case .httpStatus(429): return "Claude 用量接口请求过于频繁，请稍后重试。"
            case .httpStatus: return "Claude 用量读取失败，请稍后重试。"
            }
        }
    }

    static func decodeCredentials(_ data: Data) throws -> Credentials {
        guard data.count < 65_536,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { throw ReadError.unsupportedLogin }
        guard !token.isEmpty, token.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else { throw ReadError.unsupportedLogin }
        let expiresAt = (oauth["expiresAt"] as? Double).flatMap {
            $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil
        }
        return Credentials(accessToken: token, expiresAt: expiresAt)
    }

    /// Background refreshes use the credentials file or the login explicitly unlocked in this app session.
    static func readAccessToken(allowInteraction: Bool, now: Date = Date(),
                                loadFile: () -> Data? = readCredentialsFile,
                                loadKeychain: () throws -> Data = readKeychainCredentials) throws -> String {
        let credentials: Credentials
        if let file = loadFile() {
            credentials = try decodeCredentials(file)
        } else if allowInteraction {
            let data = try loadKeychain()
            guard !data.isEmpty else { throw ReadError.unsupportedLogin }
            credentials = try decodeCredentials(data)
            credentialsLock.withLock { cachedCredentials = credentials }
        } else {
            guard let cached = credentialsLock.withLock({ cachedCredentials }) else {
                throw ReadError.keychainAccess(errSecInteractionNotAllowed)
            }
            credentials = cached
        }
        if let expiresAt = credentials.expiresAt, expiresAt <= now { throw ReadError.loginExpired }
        return credentials.accessToken
    }

    static func readCredentialsFile() -> Data? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        return try? Data(contentsOf: url)
    }

    private static func readKeychainCredentials() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { throw ReadError.missingLogin }
        guard status == errSecSuccess else { throw ReadError.keychainAccess(status) }
        guard let data = item as? Data, !data.isEmpty else { throw ReadError.unsupportedLogin }
        return data
    }

    static func read(allowKeychainInteraction: Bool = false) async throws -> ClaudeUsageSnapshot {
        let token = try await Task.detached(priority: .utility) {
            try readAccessToken(allowInteraction: allowKeychainInteraction)
        }.value
        guard let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage") else { throw ReadError.unavailable }
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 25
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: ClaudeUsageRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ReadError.unavailable }
        return try decodeResponse(data, statusCode: response.statusCode)
    }

    static func decodeResponse(_ data: Data, statusCode: Int) throws -> ClaudeUsageSnapshot {
        if statusCode == 401 { throw ReadError.loginExpired }
        guard statusCode == 200 else { throw ReadError.httpStatus(statusCode) }
        guard data.count < 1_000_000,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ReadError.unsupported }
        let snapshot = ClaudeUsageSnapshot(
            fiveHour: window(object["five_hour"]),
            sevenDay: window(object["seven_day"]),
            sevenDayOpus: window(object["seven_day_opus"]),
            sevenDaySonnet: window(object["seven_day_sonnet"]))
        guard snapshot.hasAnyWindow else { throw ReadError.unsupported }
        return snapshot
    }

    private static func window(_ value: Any?) -> ClaudeUsageSnapshot.Window? {
        guard let value = value as? [String: Any],
              let used = value["utilization"] as? Double, used.isFinite else { return nil }
        return .init(usedPercent: used, resetsAt: (value["resets_at"] as? String).flatMap(parseDate))
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

private final class ClaudeUsageRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class ClaudeUsageMonitor: ObservableObject {
    @Published var snapshot: ClaudeUsageSnapshot?
    @Published var updatedAt: Date?
    @Published var message: String?
    @Published var isRefreshing = false
    /// When false, timers and callers skip refresh so unused faces do not touch Keychain or network.
    var isMonitoringEnabled = true
    private var refreshTimer: Timer?
    private let readSnapshot: @Sendable (Bool) async throws -> ClaudeUsageSnapshot
    init(refreshInterval: TimeInterval = 300,
         readSnapshot: @escaping @Sendable (Bool) async throws -> ClaudeUsageSnapshot = {
             try await ClaudeUsageReader.read(allowKeychainInteraction: $0)
         }) {
        self.readSnapshot = readSnapshot
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    deinit { refreshTimer?.invalidate() }
    func refresh(allowKeychainInteraction: Bool = false) async {
        guard isMonitoringEnabled, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            snapshot = try await readSnapshot(allowKeychainInteraction)
            updatedAt = Date()
            message = nil
        } catch {
            let detail: String
            if let readError = error as? ClaudeUsageReader.ReadError {
                detail = String(describing: readError)
            } else {
                let underlying = error as NSError
                detail = "domain=\(underlying.domain), code=\(underlying.code), message=\(CodexUsageReader.safeDetail(underlying.localizedDescription))"
            }
            AppLogger.shared.warning("[Claude 用量] 刷新失败；保留上次数据=\(snapshot != nil)；\(detail)")
            message = (error as? ClaudeUsageReader.ReadError)?.errorDescription ?? "Claude 用量读取失败，请稍后重试。"
        }
    }
}
