import Foundation

// ConnectionState.swift 留在 Mac。这里只补上被引用文件要编译的类型，字段与 Mac 一致。

enum ExitIPType: String, Codable, Hashable, Sendable {
    case residential, mobile, hosting, vpn, proxy, tor
}

struct NodeExitMetadata: Codable, Hashable, Sendable {
    var ip: String
    var city: String?
    var networkOperator: String?
    var asn: String?
    var networkType: ExitIPType?
    var countryCode: String?
    var region: String?
    var latitude: Double?
    var longitude: Double?
    var localizedCity: String?
}

struct CountryGroup: Identifiable, Hashable, Sendable {
    var id: String { code }
    var code: String
    var name: String
    var flag: String
    var nodes: [ProxyNode]
}

enum AppLogLevel: String, Codable, CaseIterable, Sendable {
    case debug, info, warning, error

    var displayName: String {
        switch self {
        case .debug: return "Debug"
        case .info: return "Info"
        case .warning: return "Warning"
        case .error: return "Error"
        }
    }
}
