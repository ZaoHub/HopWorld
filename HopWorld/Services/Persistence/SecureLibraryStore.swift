import Foundation
import CryptoKit

struct LibrarySnapshot: Codable, Sendable {
    var nodes: [ProxyNode] = []
    var subscriptions: [Subscription] = []
    var updateLogs: [SubscriptionUpdateLog] = []
}

enum LibraryStoreError: LocalizedError {
    case locked
    case unreadable(String? = nil)
    case invalidKey
    var errorDescription: String? {
        switch self {
        case .locked: return "安全存储尚未成功读取，已阻止覆盖。请检查钥匙串权限后重新启动。"
        case .unreadable(let detail):
            var message = "数据无法读取，原文件已保留，已阻止覆盖。"
            if let detail, !detail.isEmpty {
                message += "（\(detail)）"
            }
            message += " 可尝试「重新读取」，或使用设置中的备份恢复。"
            return message
        case .invalidKey: return "安全存储密钥无效，未修改原数据。"
        }
    }
}

/// A single authenticated, encrypted commit for the entire subscription library.
/// The only encryption key lives in Keychain; no plaintext fallback is allowed.
/// Access is serialized even during startup and asynchronous saves.
final class SecureLibraryStore: @unchecked Sendable {
    private let directory: URL
    private let keyProvider: @Sendable (Bool) throws -> Data
    private let lock = NSLock()
    private var loaded = false
    private var cachedKey: SymmetricKey?
    private(set) var recoveredBackup = false
    private let legacyNames = ["nodes.json", "subscriptions.json", "subscription-logs.json"]

    init(directory: URL, keyProvider: @escaping @Sendable (Bool) throws -> Data = { try KeychainStore.libraryEncryptionKey(createIfMissing: $0) }) {
        self.directory = directory
        self.keyProvider = keyProvider
    }

    private var primary: URL { directory.appendingPathComponent("library.enc") }
    private var backup: URL { directory.appendingPathComponent("library.previous.enc") }

    func load() throws -> LibrarySnapshot {
        lock.lock()
        defer { lock.unlock() }
        loaded = false
        let fm = FileManager.default
        let encryptedExists = fm.fileExists(atPath: primary.path) || fm.fileExists(atPath: backup.path)
        if encryptedExists {
            let keys = try KeychainStore.libraryEncryptionKeyCandidates(createIfMissing: false)
            var lastFailure: String?
            for keyData in keys {
                let sym = SymmetricKey(data: keyData)
                if fm.fileExists(atPath: primary.path) {
                    let blob = try Data(contentsOf: primary)
                    switch decodeSnapshot(blob, key: sym) {
                    case .success(let snapshot):
                        cachedKey = sym
                        loaded = true
                        return snapshot
                    case .failure(let error):
                        lastFailure = decodeFailureReason(error)
                    }
                }
                if let previous = try? Data(contentsOf: backup) {
                    switch decodeSnapshot(previous, key: sym) {
                    case .success(let snapshot):
                        if fm.fileExists(atPath: primary.path) {
                            let quarantine = directory.appendingPathComponent("library-unreadable-\(UUID().uuidString).enc")
                            try? fm.copyItem(at: primary, to: quarantine)
                        }
                        try protectedWrite(previous, to: primary)
                        cachedKey = sym
                        recoveredBackup = true
                        loaded = true
                        return snapshot
                    case .failure(let error):
                        lastFailure = decodeFailureReason(error)
                    }
                }
            }
            // Older quarantined copies from prior recovery attempts.
            let quarantined = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]))?
                .filter { $0.lastPathComponent.hasPrefix("library-unreadable-") }
                .sorted { lhs, rhs in
                    let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return l > r
                } ?? []
            for url in quarantined {
                guard let blob = try? Data(contentsOf: url) else { continue }
                for keyData in keys {
                    let key = SymmetricKey(data: keyData)
                    if let snapshot = try? decode(blob, key: key) {
                        try protectedWrite(blob, to: primary)
                        try protectedWrite(blob, to: backup)
                        cachedKey = key
                        recoveredBackup = true
                        loaded = true
                        return snapshot
                    }
                }
            }
            throw LibraryStoreError.unreadable(lastFailure)
        }
        let keyData = try keyProvider(true)
        guard keyData.count == 32 else { throw LibraryStoreError.invalidKey }
        let key = SymmetricKey(data: keyData)
        cachedKey = key
        // Missing legacy files are legitimate; malformed existing files must never
        // be interpreted as an empty library and subsequently overwritten.
        let snapshot = LibrarySnapshot(
            nodes: try readLegacy("nodes.json", default: [ProxyNode]()),
            subscriptions: try readLegacy("subscriptions.json", default: [Subscription]()),
            updateLogs: try readLegacy("subscription-logs.json", default: [SubscriptionUpdateLog]())
        )
        try commit(snapshot, key: key)
        loaded = true
        return snapshot
    }

    func save(_ snapshot: LibrarySnapshot) throws {
        lock.lock()
        defer { lock.unlock() }
        guard loaded, let key = cachedKey else { throw LibraryStoreError.locked }
        try commit(snapshot, key: key)
    }

    private func readLegacy<T: Decodable>(_ name: String, default empty: T) throws -> T {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return empty }
        do {
            return try decoder().decode(T.self, from: Data(contentsOf: url))
        } catch { throw LibraryStoreError.unreadable("旧版 \(name) 无法解析") }
    }

    private func decodeFailureReason(_ error: Error) -> String {
        if let decoding = error as? DecodingError {
            switch decoding {
            case .keyNotFound(let key, _):
                return "解密成功但数据格式过旧或损坏（缺少字段 \(key.stringValue)）"
            case .typeMismatch(let type, let context):
                let path = context.codingPath.map(\.stringValue).joined(separator: ".")
                return "解密成功但数据格式异常（\(path) 应为 \(type)）"
            case .dataCorrupted(let context):
                return "解密成功但 JSON 损坏：\(context.debugDescription)"
            default:
                return "解密成功但节点库 JSON 无法解析"
            }
        }
        return "解密失败（钥匙串密钥与加密文件不匹配）"
    }

    private func decodeSnapshot(_ data: Data, key: SymmetricKey) -> Result<LibrarySnapshot, Error> {
        Result { try decode(data, key: key) }
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func decode(_ data: Data, key: SymmetricKey) throws -> LibrarySnapshot {
        let box = try AES.GCM.SealedBox(combined: data)
        let plaintext = try AES.GCM.open(box, using: key)
        let patched = try LibrarySnapshotMigration.patchEncryptedLibraryJSON(plaintext)
        return try decoder().decode(LibrarySnapshot.self, from: patched)
    }

    private func commit(_ snapshot: LibrarySnapshot, key: SymmetricKey) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(snapshot)
        guard let encrypted = try AES.GCM.seal(plaintext, using: key).combined else {
            throw LibraryStoreError.invalidKey
        }
        // Verify before replacing anything. Only a readable primary may become backup.
        _ = try decode(encrypted, key: key)
        if FileManager.default.fileExists(atPath: primary.path) {
            let previous = try Data(contentsOf: primary)
            _ = try decode(previous, key: key)
            try protectedWrite(previous, to: backup)
        } else {
            try protectedWrite(encrypted, to: backup)
        }
        try protectedWrite(encrypted, to: primary)
        // Migration is complete only after both encrypted copies exist. If cleanup
        // fails, report it and retry on the next save; never silently claim success.
        // Old releases also left generated Xray configurations beside the JSON
        // library. They are reproducible and contain credentials, not user edits.
        for name in legacyNames + ["config.json", "test-single.json", "app-probe.json", "app-probe-auto.json"] {
            let legacy = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: legacy.path) {
                try FileManager.default.removeItem(at: legacy)
            }
        }
    }

    private func protectedWrite(_ data: Data, to url: URL) throws {
        // Background commits reopen the encrypted primary to validate and rotate its backup.
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
