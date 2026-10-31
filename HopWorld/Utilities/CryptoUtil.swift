import Foundation
import CryptoKit
import Combine
import Darwin

enum CryptoUtil {
    static func sha256Hex(_ string: String) -> String {
        sha256Hex(Data(string.utf8))
    }

    static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum NodeFingerprint {
    static func make(from node: ProxyNode) -> String {
        var raw = connectionCanonicalParts(from: node).joined(separator: "|")
        if node.protocolType == .anytls {
            raw += "|insecure=\(node.allowInsecure ?? false)|alpn=\(node.alpn ?? "")|fingerprint=\(node.fingerprint ?? "")"
        }
        if node.protocolType == .hysteria2 { raw += "|insecure=\(node.allowInsecure ?? false)|alpn=\(node.alpn ?? "")|pin=\(node.pinnedCertSHA256 ?? "")" }
        if node.protocolType == .masque {
            let options: [String: Any] = ["username": node.username ?? "", "headers": node.masqueHeaders ?? [:],
                                          "remoteDNS": node.masqueRemoteDNS ?? [], "alpn": node.alpn ?? "h3",
                                          "pin": node.pinnedCertSHA256 ?? "", "insecure": node.allowInsecure ?? false,
                                          "fingerprint": node.fingerprint ?? "", "finalMask": node.finalMaskJSON ?? ""]
            if let data = try? JSONSerialization.data(withJSONObject: options, options: [.sortedKeys]) {
                raw += "|masque=" + String(decoding: data, as: UTF8.self)
            }
        }
        if [.tuic, .wireguard, .socks5, .http].contains(node.protocolType) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let tuic = node.tuicOptions ?? TuicOptions()
            let options: [String: Any] = ["username": node.username ?? "", "headers": node.httpHeaders ?? [:],
                "alpn": node.alpn ?? (node.protocolType == .tuic ? "h3" : ""), "sni": node.sni ?? "",
                "pin": node.pinnedCertSHA256 ?? "", "insecure": node.allowInsecure ?? false,
                "tuic": String(decoding: (try? encoder.encode(tuic)) ?? Data(), as: UTF8.self),
                "wireguard": String(decoding: (try? encoder.encode(node.wireGuardOptions)) ?? Data(), as: UTF8.self)]
            if let data = try? JSONSerialization.data(withJSONObject: options, options: [.sortedKeys]) {
                raw += "|remote=" + String(decoding: data, as: UTF8.self)
            }
        }
        return CryptoUtil.sha256Hex(raw)
    }

    /// Stable key within a subscription when credentials or host change but the
    /// provider keeps the same display name (preserve favorites / notes).
    static func identityKey(from node: ProxyNode) -> String {
        let raw = [
            node.protocolType.rawValue.lowercased(),
            node.server.lowercased(),
            "\(node.port)",
            normalizedName(node.name)
        ].joined(separator: "|")
        return CryptoUtil.sha256Hex(raw)
    }

    private static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func connectionCanonicalParts(from node: ProxyNode) -> [String] {
        [
            node.protocolType.rawValue.lowercased(),
            node.server.lowercased(),
            "\(node.port)",
            node.uuid ?? "",
            node.password ?? "",
            node.method ?? "",
            node.transport.rawValue.lowercased(),
            node.security.rawValue.lowercased(),
            node.sni?.lowercased() ?? "",
            node.host?.lowercased() ?? "",
            node.path ?? "",
            node.serviceName ?? "",
            node.publicKey ?? "",
            node.shortID ?? ""
        ]
    }
}

enum LogCategory: String, Codable, CaseIterable, Sendable {
    case app
    case subscription
    case xray
    case network
    case test
    case systemProxy

    var displayName: String {
        switch self {
        case .app: return "App"
        case .subscription: return "Subscription"
        case .xray: return "Xray"
        case .network: return "Network"
        case .test: return "Test"
        case .systemProxy: return "SystemProxy"
        }
    }
}

struct LogEntry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let date: Date
    let level: AppLogLevel
    let category: LogCategory
    let message: String

    var isProblem: Bool { level == .warning || level == .error }

    var displayMessage: String {
        guard category == .test, message.hasPrefix("节点测试失败 · "),
              let nodeList = message.range(of: #" · [0-9]+ 个节点[：:]"#, options: .regularExpression) else {
            return message
        }
        return String(message[..<message.index(before: nodeList.upperBound)])
    }

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        level: AppLogLevel,
        category: LogCategory,
        message: String
    ) {
        self.id = id
        self.date = date
        self.level = level
        self.category = category
        self.message = message
    }
}

enum LogRedactor {
    private static let addressKey = SymmetricKey(size: .bits256)

    static func addressIdentifier(_ address: String) -> String {
        let digest = HMAC<SHA256>.authenticationCode(for: Data(address.lowercased().utf8), using: addressKey)
        return "ip#" + digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    static func redact(_ text: String) -> String {
        var result = text
        // Drop URL paths/queries, share links, auth headers and structured secrets.
        let secrets: [(String, String)] = [
            (#"(?i)\b(?:https?|wss?|socks(?:4a?|5h?)?|anytls|vless|vmess|trojan|ss|hysteria2|hy2|masque|tuic|wireguard|wg)://[^\s<>\"'，；）]+"#, "[URL 已脱敏]"),
            (#"(?im)\b(?:authorization|proxy-authorization|cookie|set-cookie)\s*[:=][^\r\n]+"#, "[认证信息已脱敏]"),
            (#"(?i)\bbearer\s+[^\s,;]+"#, "Bearer ••••••"),
            (#"(?i)(\"?(?:access_token|refresh_token|api[_-]?key|token|password|passwd|pwd|secret|private[_-]?key|pre[_-]?shared[_-]?key|authorization|proxy-authorization|cookie|set-cookie)\"?\s*[:=]\s*)(?:\"(?:\\.|[^\"\\])*\"|'[^']*'|[^&\s,;}]+)"#, "$1••••••"),
            (#"\bsk-[A-Za-z0-9_-]+"#, "••••••"),
            (#"/Users/[^/\s]+"#, "/Users/[用户]")
        ]
        for (pattern, replacement) in secrets {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        // UUID-like credentials
        if let regex = try? NSRegularExpression(pattern: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "••••••••"
            )
        }
        // Replace only valid literals, preserving error codes, ports and timings.
        let pattern = #"(?<![\w.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![\w.])|(?<!\w)[0-9a-fA-F:]*:[0-9a-fA-F:.]*:[0-9a-fA-F:.]+(?:%[\w]+)?"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                let literal = String(result[range])
                let address = literal.components(separatedBy: "%")[0]
                var v4 = in_addr()
                var v6 = in6_addr()
                if inet_pton(AF_INET, address, &v4) == 1 || inet_pton(AF_INET6, address, &v6) == 1 {
                    result.replaceSubrange(range, with: addressIdentifier(address))
                }
            }
        }
        return result
    }
}

@MainActor
final class AppLogger: ObservableObject {
    static let shared = AppLogger()

    @Published private(set) var entries: [LogEntry]
    var minimumLevel: AppLogLevel = .info

    private let maxEntries = 2000
    private let logFileURL: URL
    private let historicalEntryIDs: Set<UUID>
    private var saveTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?

    init(logFileURL: URL? = nil) {
        let directory = logFileURL?.deletingLastPathComponent()
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("HopWorld", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.logFileURL = logFileURL ?? directory.appendingPathComponent("app-logs.json")

        let savedEntries: [LogEntry]
        if let data = try? Data(contentsOf: self.logFileURL),
           let saved = try? JSONDecoder.logDecoder.decode([LogEntry].self, from: data) {
            savedEntries = saved.suffix(maxEntries).map {
                LogEntry(id: $0.id, date: $0.date, level: $0.level, category: $0.category,
                         message: LogRedactor.redact($0.message))
            }
        } else {
            savedEntries = []
        }
        entries = savedEntries
        historicalEntryIDs = Set(savedEntries.map(\.id))
    }

    func log(_ level: AppLogLevel, category: LogCategory, _ message: String) {
        guard level.severityRank >= minimumLevel.severityRank else { return }
        let entry = LogEntry(level: level, category: category, message: LogRedactor.redact(message))
        entries.append(entry)
        if entries.count > maxEntries {
            // Keep recent context, including manual disconnects, alongside older problems.
            let oldestRoutine = entries.prefix(entries.count - 100).firstIndex { !$0.isProblem }
            entries.remove(at: oldestRoutine ?? entries.startIndex)
        }
        scheduleSave()
        #if DEBUG
        print("[\(level.displayName)][\(category.displayName)] \(entry.message)")
        #endif
    }

    func debug(_ message: String, category: LogCategory = .app) {
        log(.debug, category: category, message)
    }

    func info(_ message: String, category: LogCategory = .app) {
        log(.info, category: category, message)
    }

    func warning(_ message: String, category: LogCategory = .app) {
        log(.warning, category: category, message)
    }

    func error(_ message: String, category: LogCategory = .app) {
        log(.error, category: category, message)
    }

    func clear() {
        entries.removeAll()
        scheduleSave()
    }

    func exportText(_ selectedEntries: [LogEntry]? = nil) -> String {
        let formatter = ISO8601DateFormatter()
        return (selectedEntries ?? entries).map {
            "\(formatter.string(from: $0.date)) [\($0.level.displayName)][\($0.category.displayName)] \(LogRedactor.redact($0.displayMessage))"
        }.joined(separator: "\n")
    }

    var hasCurrentSessionProblems: Bool {
        entries.contains { $0.isProblem && !historicalEntryIDs.contains($0.id) }
    }

    var hasHistoricalEntries: Bool {
        entries.contains { historicalEntryIDs.contains($0.id) }
    }

    func recentEntries(problemsOnly: Bool, includeHistory: Bool = true, limit: Int = 100) -> [LogEntry] {
        Array(entries.reversed().lazy
            .filter { includeHistory || !self.historicalEntryIDs.contains($0.id) }
            .filter { !problemsOnly || $0.isProblem }
            .prefix(max(0, limit)))
    }

    func flush() async {
        saveTask?.cancel()
        saveTask = nil
        await enqueueWrite(entries).value
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = entries
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await enqueueWrite(snapshot).value
        }
    }

    private func enqueueWrite(_ snapshot: [LogEntry]) -> Task<Void, Never> {
        let previous = writeTask
        let file = logFileURL
        // Cancelling a debounce cannot cancel a write already in progress.
        let task = Task.detached(priority: .utility) {
            await previous?.value
            do {
                let data = try JSONEncoder.logEncoder.encode(snapshot)
                let temporary = file.deletingLastPathComponent().appendingPathComponent(".log-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                                     attributes: [.posixPermissions: 0o600]) else { return }
                guard rename(temporary.path, file.path) == 0 else { return }
            } catch {
                // Do not recursively log failures while persisting the log itself.
            }
        }
        writeTask = task
        return task
    }
}

private extension JSONEncoder {
    static var logEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var logDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension AppLogLevel {
    var severityRank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }
}
