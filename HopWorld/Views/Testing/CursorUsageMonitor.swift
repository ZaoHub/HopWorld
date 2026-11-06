import Foundation
import Combine
import SQLite3
import Security
import CommonCrypto

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
    private static let passwordLock = NSLock()
    private static var cachedSafeStoragePassword: Data?

    enum ReadError: LocalizedError {
        case missingLogin, loginExpired, unavailable, unsupported, unsupportedLogin
        case keychainAccess(OSStatus)
        case httpStatus(Int)
        var errorDescription: String? {
            switch self {
            case .missingLogin: return "未读取到 Cursor 登录，请在本机 Cursor 登录后刷新。"
            case .loginExpired: return "Cursor 登录已失效，请在 Cursor 重新登录后刷新。"
            case .unavailable: return "Cursor 用量读取失败，请稍后重试。"
            case .unsupported: return "Cursor 未返回可显示的用量，请查看用量页面。"
            case .unsupportedLogin: return "无法解密 Cursor 登录凭据，请打开 Cursor 确认登录状态后重试。"
            case .keychainAccess: return "无法读取 Cursor 加密登录，请点击刷新并允许访问“Cursor Safe Storage”钥匙串。"
            case .httpStatus(403): return "Cursor 拒绝访问用量接口（HTTP 403），请检查账号权限或网络后重试。"
            case .httpStatus: return "Cursor 用量读取失败，请稍后重试。"
            }
        }
    }
    static func readAccessToken(allowKeychainInteraction: Bool = false) throws -> String {
        let storedValue = try readStoredAccessToken()
        do {
            return try decodeAccessToken(storedValue) {
                try readSafeStoragePassword(allowInteraction: allowKeychainInteraction)
            }
        } catch ReadError.unsupportedLogin where storedValue.hasPrefix("cursor-safe-storage:") && allowKeychainInteraction {
            // shortcut: 记住的钥匙解不开时丢掉再问一次。Cursor 没换钥匙就不会再弹窗。
            forgetSafeStoragePassword()
            let token = try decodeAccessToken(storedValue) {
                try readSafeStoragePassword(allowInteraction: true, loadPassword: readCursorKeychainPassword)
            }
            if let cached = passwordLock.withLock({ cachedSafeStoragePassword }) {
                rememberPassword(cached, in: supportDirectory)
            }
            return token
        }
    }

    private static func readStoredAccessToken() throws -> String {
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
        return String(cString: bytes)
    }

    static func readSafeStoragePassword(allowInteraction: Bool,
                                        loadPassword: () throws -> Data = readKeychainPassword) throws -> Data {
        // 允许过一次就用记下的钥匙。再点更新用量不再读 Cursor 的钥匙串。
        if let cached = passwordLock.withLock({ cachedSafeStoragePassword }) {
            return cached
        }
        guard allowInteraction else {
            throw ReadError.keychainAccess(errSecInteractionNotAllowed)
        }
        let data = try loadPassword()
        guard !data.isEmpty else { throw ReadError.unsupportedLogin }
        passwordLock.withLock { cachedSafeStoragePassword = data }
        return data
    }

    private static func readKeychainPassword() throws -> Data {
        if let stored = rememberedPassword(in: supportDirectory) {
            return stored
        }
        let data = try readCursorKeychainPassword()
        rememberPassword(data, in: supportDirectory)
        return data
    }

    private static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HopWorld", isDirectory: true)
    }

    private static func forgetSafeStoragePassword() {
        passwordLock.withLock { cachedSafeStoragePassword = nil }
        forgetPassword(in: supportDirectory)
    }

    private static func passwordFileURL(in directory: URL) -> URL {
        directory.appendingPathComponent("cursor-safe-storage.key")
    }

    static func rememberedPassword(in directory: URL) -> Data? {
        guard let data = try? Data(contentsOf: passwordFileURL(in: directory)), !data.isEmpty else { return nil }
        return data
    }

    static func rememberPassword(_ data: Data, in directory: URL) {
        guard !data.isEmpty else { return }
        let url = passwordFileURL(in: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func forgetPassword(in directory: URL) {
        try? FileManager.default.removeItem(at: passwordFileURL(in: directory))
    }

    private static func readCursorKeychainPassword() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Cursor Safe Storage",
            kSecAttrAccount as String: "Cursor Key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { throw ReadError.keychainAccess(status) }
        guard let data = item as? Data, !data.isEmpty else { throw ReadError.unsupportedLogin }
        return data
    }

    static func decodeAccessToken(_ storedValue: String, password: () throws -> Data) throws -> String {
        guard storedValue.utf8.count < 65_536 else { throw ReadError.unsupportedLogin }
        var token = storedValue
        if storedValue.hasPrefix("cursor-safe-storage:") {
            let prefix = "cursor-safe-storage:v1:"
            guard storedValue.hasPrefix(prefix),
                  let encrypted = Data(base64Encoded: String(storedValue.dropFirst(prefix.count))),
                  encrypted.starts(with: Data("v10".utf8)),
                  encrypted.count > 3, (encrypted.count - 3) % kCCBlockSizeAES128 == 0 else {
                throw ReadError.unsupportedLogin
            }
            let secret = try password()
            guard !secret.isEmpty else { throw ReadError.unsupportedLogin }
            // Chromium macOS OSCrypt v10: PBKDF2-SHA1 and AES-128-CBC/PKCS7.
            let salt = Array("saltysalt".utf8)
            var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
            let derived = secret.withUnsafeBytes { bytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), bytes.bindMemory(to: CChar.self).baseAddress,
                                      secret.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                                      1003, &key, key.count)
            }
            guard derived == kCCSuccess else { throw ReadError.unsupportedLogin }
            let ciphertext = Data(encrypted.dropFirst(3))
            let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
            var plaintext = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
            let capacity = plaintext.count
            var written = 0
            let decrypted = ciphertext.withUnsafeBytes { bytes in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        key, key.count, iv, bytes.baseAddress, ciphertext.count, &plaintext, capacity, &written)
            }
            guard decrypted == kCCSuccess,
                  let decoded = String(bytes: plaintext.prefix(written), encoding: .utf8) else {
                throw ReadError.unsupportedLogin
            }
            token = decoded
        }
        guard !token.isEmpty, token.utf8.allSatisfy({ (0x21...0x7e).contains($0) }),
              !token.hasPrefix("cursor-safe-storage:") else { throw ReadError.missingLogin }
        return token
    }
    /// Cursor 从服务端获取并缓存的可用模型名；出口地区不支持 Claude 时列表中没有 `claude-*`。
    static func readAvailableModelNames() -> [String]? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb").path
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1000)
        var statement: OpaquePointer?
        let key = "src.vs.platform.reactivestorage.browser.reactiveStorageServiceImpl.persistentStorage.applicationUser"
        guard sqlite3_prepare_v2(database, "SELECT value FROM ItemTable WHERE key = '\(key)' LIMIT 1", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["availableDefaultModels2"] as? [[String: Any]] else { return nil }
        return models.compactMap { $0["name"] as? String }
    }

    static func read(allowKeychainInteraction: Bool = false) async throws -> CursorUsageSnapshot {
        let token = try await Task.detached(priority: .utility) {
            try readAccessToken(allowKeychainInteraction: allowKeychainInteraction)
        }.value
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
        return try decodeResponse(data, statusCode: response.statusCode)
    }

    static func decodeResponse(_ data: Data, statusCode: Int) throws -> CursorUsageSnapshot {
        if statusCode == 401 { throw ReadError.loginExpired }
        guard statusCode == 200 else { throw ReadError.httpStatus(statusCode) }
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
    /// When false, timers and callers skip refresh so unused faces do not touch Keychain or network.
    var isMonitoringEnabled = true
    private var refreshTimer: Timer?
    private let readSnapshot: @Sendable (Bool) async throws -> CursorUsageSnapshot
    init(refreshInterval: TimeInterval = 300,
         readSnapshot: @escaping @Sendable (Bool) async throws -> CursorUsageSnapshot = {
             try await CursorUsageReader.read(allowKeychainInteraction: $0)
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
        guard await LabUtilityProcess.allowInternet(userInitiated: allowKeychainInteraction) else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            snapshot = try await readSnapshot(allowKeychainInteraction)
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
