import Foundation
import Security
import CryptoKit
import LocalAuthentication

enum KeychainStore {
    private static let service = "com.hopworld.app.credentials"
    private static let libraryKeyAccount = "library-encryption-v1"

    private static func readLibraryKey(backend: LibraryKeyResolver.Backend) -> (OSStatus, Data?) {
        var query = backend == .dataProtection
            ? baseQuery(account: libraryKeyAccount)
            : legacyQuery(account: libraryKeyAccount)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item as? Data)
    }

    private static func addLibraryKey(backend: LibraryKeyResolver.Backend, key: Data) -> OSStatus {
        var query = backend == .dataProtection
            ? baseQuery(account: libraryKeyAccount)
            : legacyQuery(account: libraryKeyAccount)
        query[kSecValueData as String] = Data(key.base64EncodedString().utf8)
        if backend == .dataProtection {
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        return SecItemAdd(query as CFDictionary, nil)
    }

    static func libraryEncryptionKey(createIfMissing: Bool) throws -> Data {
        let keys = try libraryEncryptionKeyCandidates(createIfMissing: createIfMissing)
        guard let first = keys.first else {
            throw KeychainError.operationFailed(errSecItemNotFound)
        }
        return first
    }

    /// Every distinct 32-byte key stored in either Keychain backend (DP + login).
    static func libraryEncryptionKeyCandidates(createIfMissing: Bool) throws -> [Data] {
        var keys: [Data] = []
        var seen = Set<String>()
        func append(from backend: LibraryKeyResolver.Backend) {
            let (status, item) = readLibraryKey(backend: backend)
            guard status == errSecSuccess,
                  let data = item,
                  let key = try? LibraryKeyResolver.decodeStoredKey(data)
            else { return }
            let token = key.base64EncodedString()
            guard seen.insert(token).inserted else { return }
            keys.append(key)
        }
        append(from: .dataProtection)
        append(from: .login)
        if keys.isEmpty, createIfMissing {
            let created = try LibraryKeyResolver.resolve(
                createIfMissing: true,
                read: readLibraryKey,
                add: addLibraryKey
            )
            keys.append(created)
        }
        if keys.isEmpty {
            throw KeychainError.operationFailed(errSecItemNotFound)
        }
        return keys
    }

    static func save(account: String, secret: String) throws {
        let data = Data(secret.utf8)
        var query = baseQuery(account: account)

        // Prefer update so we don't churn ACLs / recreate items.
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus != errSecItemNotFound {
            // A locked/denied Keychain is not a missing item. Preserve the old secret.
            throw KeychainError.operationFailed(updateStatus)
        }

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.operationFailed(status)
        }
    }

    static func load(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess,
           let data = item as? Data,
           let string = String(data: data, encoding: .utf8) {
            return string
        }

        // One-shot migration from the legacy login keychain (the source of the prompt).
        if let legacy = loadLegacy(account: account) {
            do {
                try save(account: account, secret: legacy)
                deleteLegacyIfNeeded(account: account)
            } catch {
                // Keep the legacy copy until migration has actually succeeded.
            }
            return legacy
        }
        return nil
    }

    static func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        deleteLegacyIfNeeded(account: account)
    }

    static func storeNodeCredentials(_ node: inout ProxyNode) {
        if [.socks5, .http].contains(node.protocolType), node.username == nil, node.password == nil, node.httpHeaders == nil {
            node.credentialKey = nil
            return
        }
        let key = node.credentialKey ?? node.id.uuidString
        var payload: [String: String?] = [
            "uuid": node.uuid,
            "password": node.password,
            "username": node.username,
            "method": node.method,
            "publicKey": node.publicKey,
            "shortID": node.shortID
        ]
        if let headers = node.masqueHeaders, let data = try? JSONEncoder().encode(headers) {
            payload["masqueHeaders"] = String(data: data, encoding: .utf8)
        }
        if let options = node.wireGuardOptions, let data = try? JSONEncoder().encode(options) {
            payload["wireGuardOptions"] = String(decoding: data, as: UTF8.self)
        }
        if let headers = node.httpHeaders, let data = try? JSONEncoder().encode(headers) {
            payload["httpHeaders"] = String(decoding: data, as: UTF8.self)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload.compactMapValues { $0 }),
              let text = String(data: data, encoding: .utf8)
        else { return }

        do {
            try save(account: key, secret: text)
            node.credentialKey = key
        } catch {
            // The encrypted library retains the in-memory credentials. Never
            // create a dangling reference after an unsuccessful Keychain write.
        }
    }

    static func hydrateCredentials(_ node: inout ProxyNode,
                                   loadCredential: (String) -> String? = KeychainStore.load(account:)) {
        // V1 still keeps secrets on the node model; avoid Keychain I/O when already hydrated.
        if hasCredentials(node) { return }

        guard let key = node.credentialKey, let text = loadCredential(key),
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return }

        if node.uuid == nil { node.uuid = json["uuid"] }
        if node.password == nil { node.password = json["password"] }
        if node.username == nil { node.username = json["username"] }
        if let data = json["wireGuardOptions"]?.data(using: .utf8),
           let options = try? JSONDecoder().decode(WireGuardOptions.self, from: data) {
            if node.wireGuardOptions == nil { node.wireGuardOptions = options }
            else if node.wireGuardOptions?.privateKey == nil {
                node.wireGuardOptions?.privateKey = options.privateKey
                if node.wireGuardOptions?.preSharedKey == nil { node.wireGuardOptions?.preSharedKey = options.preSharedKey }
            }
        }
        if node.httpHeaders == nil, let data = json["httpHeaders"]?.data(using: .utf8) {
            node.httpHeaders = try? JSONDecoder().decode([String: String].self, from: data)
        }
        if node.masqueHeaders == nil, let data = json["masqueHeaders"]?.data(using: .utf8) {
            node.masqueHeaders = try? JSONDecoder().decode([String: String].self, from: data)
        }
        if node.method == nil { node.method = json["method"] }
        if (node.publicKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            node.publicKey = json["publicKey"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if node.shortID == nil { node.shortID = json["shortID"] }
    }

    private static func hasCredentials(_ node: ProxyNode) -> Bool {
        if node.security == .reality,
           (node.publicKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        switch node.protocolType {
        case .tuic:
            return node.uuid != nil && node.password != nil
        case .wireguard:
            return node.wireGuardOptions?.privateKey != nil
        case .socks5, .http:
            return node.username != nil || node.password != nil || node.httpHeaders != nil || node.credentialKey == nil
        case .masque:
            return node.username != nil || node.password != nil || node.masqueHeaders != nil || node.credentialKey == nil
        case .vless, .vmess:
            return !(node.uuid ?? "").isEmpty
        case .anytls, .trojan, .shadowsocks, .hysteria2:
            return !(node.password ?? "").isEmpty
        }
    }

    /// Data-protection keychain: same-app access does not show the login-keychain password dialog.
    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    private static func legacyQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func loadLegacy(account: String) -> String? {
        var query = legacyQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        // Silent migration only — never prompt for login-keychain password.
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    private static func deleteLegacyIfNeeded(account: String) {
        SecItemDelete(legacyQuery(account: account) as CFDictionary)
    }
}

enum KeychainError: LocalizedError {
    case operationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .operationFailed(let status):
            if status == errSecMissingEntitlement {
                return "当前签名缺少数据保护钥匙串权限，且登录钥匙串中没有可用的原密钥（-34018）；原文件已保留"
            }
            if status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == errSecUserCanceled {
                return "钥匙串未解锁或访问未获授权（\(status)）；请允许跃界访问后重新启动，原文件已保留"
            }
            return "Keychain 操作失败：\(status)"
        }
    }
}

/// Resolve both macOS Keychain implementations before creating a master key.
/// A signing change must not rotate the key of an existing encrypted library.
enum LibraryKeyResolver {
    enum Backend { case dataProtection, login }

    static func resolve(createIfMissing: Bool,
                        read: (Backend) -> (OSStatus, Data?),
                        add: (Backend, Data) -> OSStatus) throws -> Data {
        let protected = read(.dataProtection)
        if protected.0 == errSecSuccess { return try decode(protected.1) }
        guard protected.0 == errSecItemNotFound || protected.0 == errSecMissingEntitlement else {
            throw KeychainError.operationFailed(protected.0)
        }
        let login = read(.login)
        if login.0 == errSecSuccess { return try decode(login.1) }
        guard login.0 == errSecItemNotFound else { throw KeychainError.operationFailed(login.0) }
        guard createIfMissing else {
            throw KeychainError.operationFailed(protected.0 == errSecMissingEntitlement
                                               ? errSecMissingEntitlement : errSecItemNotFound)
        }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var backend: Backend = protected.0 == errSecMissingEntitlement ? .login : .dataProtection
        var status = add(backend, key)
        if backend == .dataProtection, status == errSecMissingEntitlement {
            // Some environments permit the lookup but reject the insertion.
            backend = .login
            let existing = read(.login)
            if existing.0 == errSecSuccess { return try decode(existing.1) }
            guard existing.0 == errSecItemNotFound else { throw KeychainError.operationFailed(existing.0) }
            status = add(.login, key)
        }
        if status == errSecDuplicateItem {
            let winner = read(backend)
            guard winner.0 == errSecSuccess else { throw KeychainError.operationFailed(winner.0) }
            return try decode(winner.1)
        }
        guard status == errSecSuccess else { throw KeychainError.operationFailed(status) }
        return key
    }

    static func decodeStoredKey(_ encoded: Data) throws -> Data {
        try decode(encoded)
    }

    private static func decode(_ encoded: Data?) throws -> Data {
        guard let encoded, let text = String(data: encoded, encoding: .utf8),
              let key = Data(base64Encoded: text), key.count == 32 else {
            throw KeychainError.operationFailed(errSecDecode)
        }
        return key
    }
}
