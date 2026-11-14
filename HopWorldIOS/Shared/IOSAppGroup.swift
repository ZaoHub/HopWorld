import Foundation

enum IOSTunnelError: LocalizedError {
    case missingConfig
    case coreNotLinked

    var errorDescription: String? {
        switch self {
        case .missingConfig:
            return "没有可连接的隧道配置"
        case .coreNotLinked:
            return "隧道扩展还没有链入 sing-box。将 Libbox.xcframework 放到 HopWorldIOS/Vendor 后重新编译。"
        }
    }
}

enum IOSAppGroup {
    static let identifierKey = "HopWorldIOSAppGroupIdentifier"
    static let tunnelBundleKey = "HopWorldIOSTunnelBundleIdentifier"
    static let configFileName = "tunnel-config.json"
    static let libraryFileName = "library.json"

    static var identifier: String {
        Bundle.main.object(forInfoDictionaryKey: identifierKey) as? String ?? "group.com.hopworld.ios"
    }

    static var tunnelBundleIdentifier: String {
        Bundle.main.object(forInfoDictionaryKey: tunnelBundleKey) as? String ?? "com.hopworld.ios.PacketTunnel"
    }

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static func libraryDirectory() -> URL {
        if let containerURL {
            return containerURL
        }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HopWorldIOS", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func writeConfig(_ text: String, directory: URL = libraryDirectory()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try text.write(to: directory.appendingPathComponent(configFileName), atomically: true, encoding: .utf8)
    }

    static func readConfig(options: [String: NSObject]?, directory: URL = libraryDirectory()) throws -> String {
        if let text = options?["configContent"] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        let url = directory.appendingPathComponent(configFileName)
        if let text = try? String(contentsOf: url, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        throw IOSTunnelError.missingConfig
    }
}
