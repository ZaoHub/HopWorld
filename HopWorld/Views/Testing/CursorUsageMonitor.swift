import Foundation
import Combine
import SQLite3

struct CursorUsageSnapshot: Decodable, Sendable {
    struct PlanUsage: Decodable, Sendable {
        let autoPercentUsed: Double?
        let apiPercentUsed: Double?
        let totalPercentUsed: Double?
        let includedSpend: Double?
        let limit: Double?
        var totalRemaining: Double? {
            if let used = totalPercentUsed { return Self.remaining(used) }
            guard let used = includedSpend, let limit, limit > 0 else { return nil }
            return Self.remaining(used / limit * 100)
        }
        var cursorModelsRemaining: Double? { autoPercentUsed.flatMap(Self.remaining) }
        var otherModelsRemaining: Double? { apiPercentUsed.flatMap(Self.remaining) }
        private static func remaining(_ used: Double) -> Double? {
            guard used.isFinite else { return nil }
            return min(100, max(0, 100 - used))
        }
    }
    let planUsage: PlanUsage?
    let billingCycleEnd: Date?
    enum CodingKeys: String, CodingKey { case planUsage, billingCycleEnd }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        planUsage = try container.decodeIfPresent(PlanUsage.self, forKey: .planUsage)
        let milliseconds: Double?
        if let value = try? container.decode(String.self, forKey: .billingCycleEnd) {
            milliseconds = Double(value)
        } else { milliseconds = try container.decodeIfPresent(Double.self, forKey: .billingCycleEnd) }
        billingCycleEnd = milliseconds.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
    }
}

/// Read the Cursor-owned login database without writing or persisting credentials.
/// The access token is used only for Cursor's own read-only dashboard endpoint.
enum CursorUsageReader {
    enum ReadError: LocalizedError {
        case missingLogin, loginExpired, unavailable, unsupported
        case httpStatus(Int)
        var errorDescription: String? {
            switch self {
            case .missingLogin: return "未读取到 Cursor 登录，请在本机 Cursor 登录后刷新。"
            case .loginExpired: return "Cursor 登录已失效，请在 Cursor 重新登录后刷新。"
            case .unavailable: return "Cursor 用量读取失败，请稍后重试。"
            case .unsupported: return "Cursor 未返回可显示的用量，请查看用量页面。"
            case .httpStatus: return "Cursor 用量读取失败，请稍后重试。"
            }
        }
    }
    static func readAccessToken() throws -> String {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb").path
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw ReadError.missingLogin
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1", -1, &statement, nil) == SQLITE_OK else {
            throw ReadError.missingLogin
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_text(statement, 0) else { throw ReadError.missingLogin }
        let token = String(cString: bytes)
        guard !token.isEmpty, !token.contains("\n"), !token.contains("\r") else { throw ReadError.missingLogin }
        return token
    }
    static func read() async throws -> CursorUsageSnapshot {
        let token = try await Task.detached(priority: .utility) { try readAccessToken() }.value
        guard let endpoint = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage") else { throw ReadError.unavailable }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 25
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: CursorUsageRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ReadError.unavailable }
        if response.statusCode == 401 || response.statusCode == 403 { throw ReadError.loginExpired }
        guard response.statusCode == 200 else { throw ReadError.httpStatus(response.statusCode) }
        guard data.count < 1_000_000 else { throw ReadError.unavailable }
        let snapshot: CursorUsageSnapshot
        do { snapshot = try JSONDecoder().decode(CursorUsageSnapshot.self, from: data) }
        catch { throw ReadError.unsupported }
        guard let plan = snapshot.planUsage,
              plan.totalRemaining != nil || plan.cursorModelsRemaining != nil || plan.otherModelsRemaining != nil else {
            throw ReadError.unsupported
        }
        return snapshot
    }
}

private final class CursorUsageRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class CursorUsageMonitor: ObservableObject {
    @Published var snapshot: CursorUsageSnapshot?
    @Published var updatedAt: Date?
    @Published var message: String?
    @Published var isRefreshing = false
    private var refreshTimer: Timer?
    private let readSnapshot: @Sendable () async throws -> CursorUsageSnapshot
    init(refreshInterval: TimeInterval = 300,
         readSnapshot: @escaping @Sendable () async throws -> CursorUsageSnapshot = { try await CursorUsageReader.read() }) {
        self.readSnapshot = readSnapshot
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    deinit { refreshTimer?.invalidate() }
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            snapshot = try await readSnapshot()
            updatedAt = Date()
            message = nil
        } catch {
            let detail: String
            if let readError = error as? CursorUsageReader.ReadError {
                detail = String(describing: readError)
            } else {
                let underlying = error as NSError
                detail = "domain=\(underlying.domain), code=\(underlying.code), message=\(CodexUsageReader.safeDetail(underlying.localizedDescription))"
            }
            AppLogger.shared.warning("[Cursor 用量] 刷新失败；保留上次数据=\(snapshot != nil)；\(detail)")
            message = (error as? CursorUsageReader.ReadError)?.errorDescription ?? "Cursor 用量读取失败，请稍后重试。"
        }
    }
}
