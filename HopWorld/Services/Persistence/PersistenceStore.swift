import Foundation
import CryptoKit

struct PersistenceStore: Sendable {
    private let directory: URL
    private let library: SecureLibraryStore
    /// Serial disk I/O — never block the main actor with encode/keychain/write.
    private let ioQueue = DispatchQueue(label: "com.hopworld.persistence", qos: .utility)

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("HopWorld", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.directory = base
        self.library = SecureLibraryStore(directory: base)
    }

    var recoveredLibraryBackup: Bool { library.recoveredBackup }

    /// Node credentials, subscription tokens and update URLs commit together.
    func loadLibrary() throws -> LibrarySnapshot {
        try library.load()
    }

    func reloadLibrary() throws -> LibrarySnapshot {
        try library.load()
    }

    func saveLibrary(_ snapshot: LibrarySnapshot, completion: @escaping @Sendable (String?) -> Void) {
        ioQueue.async {
            do {
                try library.save(snapshot)
                completion(nil)
            } catch {
                let detail = "节点与订阅保存失败：\(error)"
                Task { @MainActor in AppLogger.shared.error(detail) }
                let systemError = error as NSError
                if systemError.domain == NSCocoaErrorDomain &&
                    (systemError.code == CocoaError.fileReadNoPermission.rawValue ||
                     systemError.code == CocoaError.fileWriteNoPermission.rawValue) {
                    completion("系统拒绝访问本地数据。应用会自动重试，也会在解锁或返回应用时再次尝试保存。若持续失败，请检查应用的数据访问权限。保存成功前请保持应用打开。")
                } else {
                    completion("暂时无法保存节点和订阅。保存成功前请保持应用打开，以免丢失最近的修改。")
                }
            }
        }
    }

    func loadSettings() -> AppSettings {
        let file = url(for: "settings.json")
        guard let data = try? Data(contentsOf: file) else { return AppSettings() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            if let seconds = try? value.decode(Double.self) {
                return Date(timeIntervalSinceReferenceDate: seconds)
            }
            let raw = try value.decode(String.self)
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: raw) { return date }
            formatter.formatOptions.insert(.withFractionalSeconds)
            if let date = formatter.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid settings date")
        }
        // 兼容旧版 settings.json：缺少新字段时补默认值再解码，避免整份设置被重置。
        if var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let previous = obj["testURL"] as? String,
               ["https://chatgpt.com/cdn-cgi/trace", "https://chatgpt.com/", "https://chatgpt.com"].contains(previous) {
                obj["testURL"] = AppSettings.chatGPTConnectivityTestURL
                if var names = obj["customTestURLNames"] as? [String: String],
                   let name = names[previous], names[AppSettings.chatGPTConnectivityTestURL] == nil {
                    names[AppSettings.chatGPTConnectivityTestURL] = name
                    obj["customTestURLNames"] = names
                }
            }
            // Fill every missing field from defaults; adding a new setting must
            // not invalidate the user's entire saved configuration.
            if let defaultsData = try? JSONEncoder().encode(AppSettings()),
               let defaults = try? JSONSerialization.jsonObject(with: defaultsData) as? [String: Any] {
                for (key, value) in defaults where obj[key] == nil {
                    obj[key] = value
                }
            }
            if obj["proxyApplications"] == nil { obj["proxyApplications"] = [] }
            if obj["routingRules"] == nil {
                obj["routingRules"] = ["bypassChina": true, "direct": "", "proxy": "", "blocked": ""]
            }
            if obj["disconnectOnScreenLock"] == nil {
                obj["disconnectOnScreenLock"] = true
            }
            if obj["appProbeTimeoutSeconds"] == nil {
                obj["appProbeTimeoutSeconds"] = 5
            }
            if obj["autoAppProbeUsableNodes"] == nil {
                obj["autoAppProbeUsableNodes"] = false
            }
            if obj["autoSelectExcludedCountryCodes"] == nil {
                obj["autoSelectExcludedCountryCodes"] = []
            }
            if obj["autoSelectCountryScope"] == nil {
                obj["autoSelectCountryScope"] = "all"
            }
            if obj["autoSelectIncludedCountryCodes"] == nil {
                obj["autoSelectIncludedCountryCodes"] = []
            }
            if obj["autoSelectMinimumSpeed"] == nil {
                obj["autoSelectMinimumSpeed"] = "allUsable"
            }
            if obj["autoSelectUnhealthySeconds"] == nil {
                obj["autoSelectUnhealthySeconds"] = 30
            }
            if obj["scheduledTestEnabled"] == nil {
                obj["scheduledTestEnabled"] = true
            }
            if obj["scheduledTestIntervalMinutes"] == nil {
                obj["scheduledTestIntervalMinutes"] = 30
            }
            // 批量超时曾用 Double（默认 1.5）；统一为 Int 秒，兼容旧值。
            if let existing = obj["batchTestTimeoutSeconds"] {
                if let d = existing as? Double {
                    obj["batchTestTimeoutSeconds"] = max(1, Int(d.rounded()))
                } else if let i = existing as? Int {
                    obj["batchTestTimeoutSeconds"] = max(1, i)
                } else if let n = existing as? NSNumber {
                    obj["batchTestTimeoutSeconds"] = max(1, n.intValue)
                }
            } else {
                obj["batchTestTimeoutSeconds"] = 2
            }
            if let patched = try? JSONSerialization.data(withJSONObject: obj),
               var settings = try? decoder.decode(AppSettings.self, from: patched) {
                settings.normalizeApplicationProxyMode()
                settings.connectTimeoutSeconds = min(99, max(1, settings.connectTimeoutSeconds))
                settings.scheduledTestIntervalMinutes = min(1440, max(5, settings.scheduledTestIntervalMinutes))
                return settings
            }
        }
        if var settings = try? decoder.decode(AppSettings.self, from: data) {
            settings.normalizeApplicationProxyMode()
            settings.connectTimeoutSeconds = min(99, max(1, settings.connectTimeoutSeconds))
            settings.scheduledTestIntervalMinutes = min(1440, max(5, settings.scheduledTestIntervalMinutes))
            return settings
        }
        // Preserve the exact original before subsequent startup saves can write
        // defaults. Use a unique name so repeated failures retain every copy.
        let backup = directory.appendingPathComponent("settings-unreadable-\(UUID().uuidString).json")
        do {
            try data.write(to: backup, options: .atomic)
            Task { @MainActor in
                AppLogger.shared.error("设置解析失败，原配置已备份至 \(backup.lastPathComponent)")
            }
        } catch {
            Task { @MainActor in
                AppLogger.shared.error("设置解析失败且备份失败：\(error.localizedDescription)")
            }
        }
        var settings = AppSettings()
        settings.normalizeApplicationProxyMode()
        return settings
    }

    func saveSettings(_ settings: AppSettings) {
        save(settings, filename: "settings.json")
    }

    func loadConnectionState() -> ConnectionState {
        load(filename: "connection.json", as: ConnectionState.self) ?? ConnectionState()
    }

    func saveConnectionState(_ state: ConnectionState) {
        save(state, filename: "connection.json")
    }

    func loadStartupConnectionIntent() -> StartupConnectionIntent {
        load(filename: "startup-connection.json", as: StartupConnectionIntent.self) ?? StartupConnectionIntent()
    }

    func saveStartupConnectionIntent(_ intent: StartupConnectionIntent) {
        save(intent, filename: "startup-connection.json")
    }

    func loadPinnedNodeIDs() -> [UUID] {
        load(filename: "pinned-nodes.json", as: [UUID].self) ?? []
    }

    func savePinnedNodeIDs(_ ids: [UUID]) {
        save(ids, filename: "pinned-nodes.json")
    }

    func loadDailyUsage() -> DailyUsageStats {
        load(filename: "daily-usage.json", as: DailyUsageStats.self) ?? DailyUsageStats()
    }

    func saveDailyUsage(_ usage: DailyUsageStats) {
        save(usage, filename: "daily-usage.json")
    }

    /// Wait for queued records before replying to the app's termination request.
    func flush() async {
        await withCheckedContinuation { continuation in
            ioQueue.async { continuation.resume() }
        }
    }

    private func url(for filename: String) -> URL {
        directory.appendingPathComponent(filename)
    }

    private func load<T: Decodable>(filename: String, as type: T.Type) -> T? {
        let file = url(for: filename)
        // Startup-only; keep sync so AppState.load() stays simple.
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    private func save<T: Encodable & Sendable>(_ value: T, filename: String) {
        let file = url(for: filename)
        ioQueue.async {
            Self.writeJSON(value, to: file)
        }
    }

    private static func writeJSON<T: Encodable>(_ value: T, to file: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(value)
            try data.write(to: file, options: .atomic)
        } catch {
            Task { @MainActor in
                AppLogger.shared.error("保存 \(file.lastPathComponent) 失败：\(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Portable backup (passphrase, not Keychain)

enum LibraryBackupError: LocalizedError, Equatable {
    case invalidFile
    case wrongPassphrase
    case emptyExport
    case requiresReplaceConfirmation

    var errorDescription: String? {
        switch self {
        case .invalidFile: return "不是有效的跃界备份文件"
        case .wrongPassphrase: return "备份密码不正确"
        case .emptyExport: return "请至少选择一个订阅组、手动节点或应用配置"
        case .requiresReplaceConfirmation: return "当前已有节点数据，请确认覆盖后再导入"
        }
    }
}

/// Decrypted portable backup. Older files omit `settings`.
struct LibraryBackupContents: Sendable {
    var snapshot: LibrarySnapshot
    var settings: AppSettings?
}

enum LibraryBackup {
    private static let magic = Data("HOPWBACKUP1".utf8)

    /// Portable document: same library fields as `LibrarySnapshot`, plus optional app settings.
    private struct Document: Codable {
        var nodes: [ProxyNode] = []
        var subscriptions: [Subscription] = []
        var updateLogs: [SubscriptionUpdateLog] = []
        var settings: AppSettings?
    }

    /// - Parameters:
    ///   - subscriptionIDs: `nil` = all subscriptions; otherwise only listed IDs.
    ///   - includeManualNodes: nodes with no `subscriptionID`.
    ///   - settings: when non-nil, written into the backup file.
    static func export(
        snapshot: LibrarySnapshot,
        passphrase: String,
        includeCredentials: Bool,
        subscriptionIDs: Set<UUID>? = nil,
        includeManualNodes: Bool = true,
        settings: AppSettings? = nil
    ) throws -> Data {
        let filtered = filter(snapshot: snapshot, subscriptionIDs: subscriptionIDs, includeManualNodes: includeManualNodes)
        guard !filtered.nodes.isEmpty || !filtered.subscriptions.isEmpty || settings != nil else {
            throw LibraryBackupError.emptyExport
        }
        var document = Document(
            nodes: filtered.nodes,
            subscriptions: filtered.subscriptions,
            updateLogs: filtered.updateLogs,
            settings: settings
        )
        if !includeCredentials {
            document.nodes = document.nodes.map(redactForExport)
            document.subscriptions = document.subscriptions.map { subscription in
                var copy = subscription
                copy.shareLinksText = nil
                return copy
            }
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(document)
        let key = try deriveKey(passphrase: passphrase)
        guard let sealed = try AES.GCM.seal(json, using: key).combined else {
            throw LibraryBackupError.invalidFile
        }
        return magic + sealed
    }

    static func importBackup(from data: Data, passphrase: String) throws -> LibraryBackupContents {
        guard data.count > magic.count, data.prefix(magic.count) == magic else {
            throw LibraryBackupError.invalidFile
        }
        let key = try deriveKey(passphrase: passphrase)
        let box = try AES.GCM.SealedBox(combined: data.dropFirst(magic.count))
        let json: Data
        do {
            json = try AES.GCM.open(box, using: key)
        } catch {
            throw LibraryBackupError.wrongPassphrase
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let patched = try LibrarySnapshotMigration.patchEncryptedLibraryJSON(json)
        let document = try decoder.decode(Document.self, from: patched)
        return LibraryBackupContents(
            snapshot: LibrarySnapshot(
                nodes: document.nodes,
                subscriptions: document.subscriptions,
                updateLogs: document.updateLogs
            ),
            settings: document.settings
        )
    }

    static func filter(
        snapshot: LibrarySnapshot,
        subscriptionIDs: Set<UUID>?,
        includeManualNodes: Bool
    ) -> LibrarySnapshot {
        let subscriptions: [Subscription]
        if let subscriptionIDs {
            subscriptions = snapshot.subscriptions.filter { subscriptionIDs.contains($0.id) }
        } else {
            subscriptions = snapshot.subscriptions
        }
        let selectedIDs = Set(subscriptions.map(\.id))
        let nodes = snapshot.nodes.filter { node in
            if let id = node.subscriptionID {
                return subscriptionIDs == nil ? true : selectedIDs.contains(id)
            }
            return includeManualNodes
        }
        let updateLogs = snapshot.updateLogs.filter { selectedIDs.contains($0.subscriptionID) }
        return LibrarySnapshot(nodes: nodes, subscriptions: subscriptions, updateLogs: updateLogs)
    }

    private static func redactForExport(_ node: ProxyNode) -> ProxyNode {
        var copy = node
        copy.uuid = nil
        copy.password = nil
        copy.username = nil
        copy.masqueHeaders = nil
        copy.httpHeaders = nil
        copy.wireGuardOptions?.privateKey = nil
        copy.wireGuardOptions?.preSharedKey = nil
        copy.credentialKey = nil
        return copy
    }

    private static func deriveKey(passphrase: String) throws -> SymmetricKey {
        let salt = Data("HopWorld.LibraryBackup.v1".utf8)
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(passphrase.utf8)),
            salt: salt,
            info: Data("library-backup".utf8),
            outputByteCount: 32
        )
        return key
    }
}
