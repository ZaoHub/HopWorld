import Foundation
import CryptoKit
import Combine

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
        let raw = connectionCanonicalParts(from: node).joined(separator: "|")
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
    static func redact(_ text: String) -> String {
        var result = text
        // UUID-like credentials
        if let regex = try? NSRegularExpression(pattern: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "••••••••"
            )
        }
        // scheme://secret@host
        if let regex = try? NSRegularExpression(pattern: #"(vless|vmess|trojan|ss)://[^@\s]+@"#) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1://••••••@"
            )
        }
        // query tokens
        if let regex = try? NSRegularExpression(pattern: #"(token|password|pwd|key)=([^&\s]+)"#, options: .caseInsensitive) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1=••••••"
            )
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
    private var saveTask: Task<Void, Never>?

    private init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("HopWorld", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        logFileURL = directory.appendingPathComponent("app-logs.json")

        if let data = try? Data(contentsOf: logFileURL),
           let saved = try? JSONDecoder.logDecoder.decode([LogEntry].self, from: data) {
            entries = Array(saved.suffix(maxEntries))
        } else {
            entries = []
        }
    }

    func log(_ level: AppLogLevel, category: LogCategory, _ message: String) {
        guard level.severityRank >= minimumLevel.severityRank else { return }
        let entry = LogEntry(level: level, category: category, message: LogRedactor.redact(message))
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
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
            "\(formatter.string(from: $0.date)) [\($0.level.displayName)][\($0.category.displayName)] \($0.message)"
        }.joined(separator: "\n")
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = entries
        let file = logFileURL
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) {
                do {
                    let data = try JSONEncoder.logEncoder.encode(snapshot)
                    try data.write(to: file, options: .atomic)
                } catch {
                    // Do not recursively log failures while persisting the log itself.
                }
            }.value
        }
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
