import Foundation
import Darwin

enum TestStage: String, Codable, CaseIterable, Sendable {
    case config
    case dns
    case tcp
    case handshake
    case http
    case exitIP
    case throughput
    case udp

    var displayName: String {
        switch self {
        case .config: return "配置检查"
        case .dns: return "DNS"
        case .tcp: return "TCP"
        case .handshake: return "代理握手"
        case .http: return "HTTP 可用性"
        case .exitIP: return "出口 IP"
        case .throughput: return "下载速度"
        case .udp: return "UDP"
        }
    }
}

struct NodeTestResult: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var nodeID: UUID
    var startedAt: Date
    var finishedAt: Date

    var configValid: Bool
    var dnsLatency: Int?
    var tcpLatency: Int?
    var proxyLatency: Int?
    var downloadMbps: Double?
    var udpAvailable: Bool?

    var exitIP: String?
    var exitCountryCode: String?
    var exitCountryName: String?
    var asn: String?

    var success: Bool
    var failureStage: TestStage?
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        nodeID: UUID,
        startedAt: Date = Date(),
        finishedAt: Date = Date(),
        configValid: Bool = false,
        dnsLatency: Int? = nil,
        tcpLatency: Int? = nil,
        proxyLatency: Int? = nil,
        downloadMbps: Double? = nil,
        udpAvailable: Bool? = nil,
        exitIP: String? = nil,
        exitCountryCode: String? = nil,
        exitCountryName: String? = nil,
        asn: String? = nil,
        success: Bool = false,
        failureStage: TestStage? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.nodeID = nodeID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.configValid = configValid
        self.dnsLatency = dnsLatency
        self.tcpLatency = tcpLatency
        self.proxyLatency = proxyLatency
        self.downloadMbps = downloadMbps
        self.udpAvailable = udpAvailable
        self.exitIP = exitIP
        self.exitCountryCode = exitCountryCode
        self.exitCountryName = exitCountryName
        self.asn = asn
        self.success = success
        self.failureStage = failureStage
        self.errorMessage = errorMessage
    }

    var primaryLatency: Int? {
        proxyLatency ?? tcpLatency
    }

    /// 配置/客户端无法测（计入「失败」），与连通不通的「不可用」区分。
    var isConfigFailure: Bool {
        !success && (failureStage == .config || !configValid)
    }
}

struct CountryGroup: Identifiable, Hashable, Sendable {
    var id: String { code }
    var code: String
    var name: String
    var flag: String
    var nodes: [ProxyNode]

    var bestLatency: Int? {
        nodes
            .filter { $0.lastTestStatus.isUsable }
            .compactMap(\.lastLatency)
            .min()
    }

    var availableCount: Int {
        nodes.filter { $0.lastTestStatus.isUsable }.count
    }

    var hasUsableNode: Bool { availableCount > 0 }
}

enum ConnectionStatus: String, Codable, Sendable {
    case disconnected
    case connecting
    case connected
    case disconnecting
    case error

    var displayName: String {
        switch self {
        case .disconnected: return "未连接"
        case .connecting: return "连接中"
        case .connected: return "已连接"
        case .disconnecting: return "断开中"
        case .error: return "连接异常"
        }
    }
}

struct ConnectionState: Codable, Sendable {
    var status: ConnectionStatus = .disconnected
    var currentNodeID: UUID?
    var currentCountryCode: String?
    var currentCountryName: String?
    var protocolType: ProxyProtocolType?
    var latency: Int?
    var exitIP: String?
    var exitCountry: String?
    var downloadMbps: Double = 0
    var uploadMbps: Double = 0
    var sessionDownloadBytes: Int64 = 0
    var sessionUploadBytes: Int64 = 0
    var connectedAt: Date?
    var lastError: String?
    var autoSelectEnabled: Bool = true
}

/// Durable connection intent kept separately from the live connection state.
/// The live state is reset while cleaning up proxies on quit, but this record
/// lets the next launch distinguish a quit while connected from a manual disconnect.
struct StartupConnectionIntent: Codable, Sendable, Equatable {
    var lastConnectedNodeID: UUID?
    var reconnectOnNextLaunch = false
}

enum RoutingMode: String, Codable, CaseIterable, Sendable {
    case global
    case direct
    case rules

    var displayName: String {
        switch self {
        case .global: return "全局代理"
        case .direct: return "直连"
        case .rules: return "规则代理"
        }
    }

    var helpText: String {
        switch self {
        case .global:
            return "通过 TUN 接管所有 App 的网络流量，无需单独勾选应用；连接时需要管理员授权。"
        case .direct:
            return "全部流量不走节点，相当于未使用代理。"
        case .rules:
            return "按规则分流：自定义规则优先，国内域名和 IP 直连，其余走当前节点。"
        }
    }
}

/// How HopWorld captures traffic after Xray is up.
enum ConnectionCaptureMode: String, Codable, CaseIterable, Sendable {
    case systemProxy
    case systemVPN
    case applications
    case globalTun

    var usesTun: Bool { self == .applications || self == .globalTun }

    var displayName: String {
        switch self {
        case .systemProxy: return "系统代理"
        case .systemVPN: return "系统 VPN"
        case .globalTun: return "全局 TUN（所有应用）"
        case .applications: return "仅指定应用（TUN）"
        }
    }

    var helpText: String {
        switch self {
        case .systemProxy:
            return "通过 macOS 系统 HTTP/HTTPS/SOCKS 代理（现有方式）。部分 App 可能不遵循系统代理。"
        case .systemVPN:
            return "通过 Packet Tunnel 出现在「系统设置 → 网络」VPN 列表。需开启 Network Extension 签名权限；首次连接会请求 VPN 许可。"
        case .globalTun:
            return "所有 App 自动进入 TUN 并通过当前节点连接，无需应用白名单；需要管理员授权。"
        case .applications:
            return "需要管理员授权。选中的应用及应用包内辅助程序走节点，其他应用默认直连；局域网和系统 DNS 保持直连。不需要 Apple 开发者账号。"
        }
    }
}

/// 每行一个域名、精确域名（full:）或 IP/CIDR；禁止透传任意 Xray 表达式。
struct RoutingRules: Codable, Hashable, Sendable {
    var bypassChina = true
    var direct = ""
    var proxy = ""
    var blocked = ""

    func entries(_ text: String) throws -> (domains: [String], ips: [String]) {
        var domains: [String] = []
        var ips: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if value.isEmpty || value.hasPrefix("#") { continue }
            let parts = value.split(separator: "/", omittingEmptySubsequences: false)
            let address = String(parts[0])
            var v4 = in_addr()
            var v6 = in6_addr()
            let bits = inet_pton(AF_INET, address, &v4) == 1 ? 32 :
                (inet_pton(AF_INET6, address, &v6) == 1 ? 128 : 0)
            if bits > 0 {
                guard parts.count == 1 || (parts.count == 2 &&
                    parts[1].utf8.allSatisfy { (48...57).contains($0) } &&
                    Int(parts[1]).map { (0...bits).contains($0) } == true) else {
                    throw RoutingRuleError.invalid(value)
                }
                ips.append(value)
                continue
            }
            let prefix = value.hasPrefix("full:") ? "full:" : "domain:"
            let host = value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : value
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            guard host.count <= 253, !host.isEmpty,
                  labels.allSatisfy({ label in
                      !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" &&
                      label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
                  }), !host.allSatisfy({ $0.isNumber || $0 == "." }) else {
                throw RoutingRuleError.invalid(value)
            }
            domains.append(prefix + host)
        }
        return (domains, ips)
    }

    func validate() throws {
        for text in [blocked, proxy, direct] { _ = try entries(text) }
    }

    func xrayRouting() throws -> [String: Any] {
        var rules: [[String: Any]] = [
            ["type": "field", "inboundTag": ["api"], "outboundTag": "api"]
        ]
        // 按拦截、代理、直连排序；IPOnDemand 让自定义 IP 也能覆盖内置域名规则。
        for (tag, text) in [("blocked", blocked), ("proxy", proxy), ("direct", direct)] {
            let values = try entries(text)
            if !values.domains.isEmpty { rules.append(["type": "field", "domain": values.domains, "outboundTag": tag]) }
            if !values.ips.isEmpty { rules.append(["type": "field", "ip": values.ips, "outboundTag": tag]) }
        }
        rules.append(["type": "field", "domain": ["full:localhost", "domain:local"], "outboundTag": "direct"])
        if bypassChina {
            rules.append(["type": "field", "domain": ["geosite:cn"], "outboundTag": "direct"])
        }
        rules.append(["type": "field", "ip": ["geoip:private"], "outboundTag": "direct"])
        if bypassChina {
            rules.append(["type": "field", "ip": ["geoip:cn"], "outboundTag": "direct"])
        }
        // 未匹配使用第一个 outbound（proxy）。
        return ["domainStrategy": "IPOnDemand", "rules": rules]
    }
}

enum RoutingRuleError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let value): return "无效规则：\(value)。请输入域名、full:精确域名、IPv4/IPv6 或 CIDR；不要输入网址、端口或通配符。"
        }
    }
}

struct RoutingProfile: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var mode: RoutingMode
    var isDefault: Bool

    init(id: UUID = UUID(), name: String, mode: RoutingMode, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.mode = mode
        self.isDefault = isDefault
    }
}

struct OriginalProxySettings: Codable, Hashable, Sendable {
    var serviceName: String
    var httpEnabled: Bool
    var httpHost: String?
    var httpPort: Int?
    var httpsEnabled: Bool
    var httpsHost: String?
    var httpsPort: Int?
    var socksEnabled: Bool
    var socksHost: String?
    var socksPort: Int?
    var autoProxyEnabled: Bool
    var autoProxyURL: String?
    var bypassDomains: [String]? = nil
    var autoDiscoveryEnabled: Bool? = nil
}

struct AppSettings: Codable, Hashable, Sendable {
    var launchAtLogin: Bool = false
    var showMenuBar: Bool = true
    var connectOnLaunch: ConnectOnLaunch = .lastNode
    var disconnectOnScreenLock: Bool = true
    var screenLockDisconnectDelayMinutes: Int = 15

    var socksHost: String = "127.0.0.1"
    var socksPort: Int = 10808
    var httpHost: String = "127.0.0.1"
    var httpPort: Int = 10809

    var autoFailover: Bool = true
    /// 故障切换候选：前 N 个可用，或全部可用。
    var failoverPoolMode: FailoverPoolMode = .limited
    var maxFailoverAttempts: Int = 5
    /// 单次连接验证超时（秒）；超时后自动换下一个候选节点。
    var connectTimeoutSeconds: Int = 3

    var testURL: String = "https://www.gstatic.com/generate_204"
    var testConcurrency: Int = 16
    /// 单个节点测速超时（秒）；含 FinalMask 等慢握手节点可调高。
    var testTimeoutSeconds: Int = 8
    /// 批量测速 HTTPS 超时（秒）；默认较短以加快整批。
    var batchTestTimeoutSeconds: Int = 2
    /// 测试中心「应用连通」探测超时（秒）。
    var appProbeTimeoutSeconds: Int = 5
    /// 测速后 / 自动优选前，是否自动对「可用但未做应用连通」的节点补测。默认关闭。
    var autoAppProbeUsableNodes: Bool = false
    var appProbeSource: AppProbeSource? = nil
    var installedAppProbes: [InstalledAppProbe] = []
    var testResultTTLMinutes: Int = 30
    var throughputTestMB: Int = 5

    /// 定时测速（与订阅自动更新独立）。
    var scheduledTestEnabled: Bool = true
    /// 间隔（分钟），最少 5。
    var scheduledTestIntervalMinutes: Int = 30
    var scheduledTestScope: ScheduledTestNodeScope = .all
    /// `all` 或 `subscription:<uuid>`。
    var scheduledTestSubscriptionRaw: String = "all"
    var lastScheduledTestAt: Date? = nil

    var defaultUpdateHour: Int = 8
    var defaultUpdateMinute: Int = 30
    var defaultTimeZoneID: String = "Asia/Shanghai"
    var defaultUpdateMode: SubscriptionUpdateMode = .smartMerge
    var defaultFallbackDays: Int = 3

    var routingMode: RoutingMode = .rules
    var routingRules: RoutingRules = RoutingRules()
    /// 系统代理（默认）。系统 VPN（Network Extension）代码保留，设置页暂隐藏（需开发者账号）。
    var connectionCaptureMode: ConnectionCaptureMode = .systemProxy
    var proxyApplications: [ProxyApplication] = []
    var autoCountryResolve: Bool = true
    var favoritePreference: FavoritePreference = .preferFavorites
    /// Countries excluded from automatic selection. Manual node connections remain allowed.
    var autoSelectExcludedCountryCodes: Set<String> = []
    /// Whether automatic selection considers every non-excluded country or only an allowlist.
    var autoSelectCountryScope: AutoSelectCountryScope = .all
    /// Country allowlist used when `autoSelectCountryScope == .specified`.
    var autoSelectIncludedCountryCodes: Set<String> = []
    /// Slowest latency tier allowed to participate in automatic selection.
    var autoSelectMinimumSpeed: AutoSelectMinimumSpeed = .allUsable
    var autoSelectUnhealthySeconds: Int = 30

    var logLevel: AppLogLevel = .info
    /// One-shot: old tests used CONNECT-only and falsely marked free nodes available.
    var httpsProbeMigrated: Bool = false
    /// One-shot: raise concurrency / lower timeout after the "22 nodes took minutes" incident.
    var testSpeedTuned: Bool = false
    /// Last selected filters on the Nodes page: `scope@@source` (survives sidebar switches).
    var nodeListCategoryRaw: String = "all@@all"
}

enum AutoSelectCountryScope: String, Codable, CaseIterable, Sendable {
    case all
    case specified

    var displayName: String {
        switch self {
        case .all: return "全部国家"
        case .specified: return "指定国家"
        }
    }
}

enum AutoSelectMinimumSpeed: String, Codable, CaseIterable, Sendable {
    case allUsable
    case fairlyFast
    case fast
    case ultraFast

    var displayName: String {
        switch self {
        case .allUsable: return "全部可用"
        case .fairlyFast: return "较快及以上"
        case .fast: return "快及以上"
        case .ultraFast: return "仅特快"
        }
    }

    fileprivate var maximumSortRank: Int {
        switch self {
        case .allUsable: return NodeTestStatus.ultraSlow.sortRank
        case .fairlyFast: return NodeTestStatus.fairlyFast.sortRank
        case .fast: return NodeTestStatus.fast.sortRank
        case .ultraFast: return NodeTestStatus.ultraFast.sortRank
        }
    }
}

extension AppSettings {
    func allowsAutoSelectCountry(_ code: String?) -> Bool {
        let normalized = (code ?? "XX").uppercased()
        guard !autoSelectExcludedCountryCodes.contains(normalized) else { return false }
        switch autoSelectCountryScope {
        case .all:
            return true
        case .specified:
            return autoSelectIncludedCountryCodes.contains(normalized)
        }
    }

    func allowsAutoSelectNode(_ node: ProxyNode) -> Bool {
        guard allowsAutoSelectCountry(CountryResolver.effectiveCode(for: node)) else { return false }
        // A completed failed app probe disqualifies a node, including favorites.
        // Untested nodes remain eligible so automatic probing can evaluate them.
        if node.lastAppProbeDate != nil, !node.hasAppProbeSuccess { return false }
        let status = node.resolvedTestStatus
        return status.isUsable && status.sortRank <= autoSelectMinimumSpeed.maximumSortRank
    }
}

enum ConnectOnLaunch: String, Codable, CaseIterable, Sendable {
    case none
    case lastNode
    case fastest

    var displayName: String {
        switch self {
        case .none: return "不自动连接"
        case .lastNode: return "连接上次节点"
        case .fastest: return "自动连接最快节点"
        }
    }
}

enum FailoverPoolMode: String, Codable, CaseIterable, Sendable {
    case limited
    case allAvailable

    var displayName: String {
        switch self {
        case .limited: return "前 N 个可用"
        case .allAvailable: return "全部可用"
        }
    }
}

/// 定时测速的节点范围。
enum ScheduledTestNodeScope: String, Codable, CaseIterable, Sendable {
    case all
    case availableOnly
    case favoritesOnly

    var displayName: String {
        switch self {
        case .all: return "范围内全部节点"
        case .availableOnly: return "仅当前可用节点"
        case .favoritesOnly: return "仅收藏节点"
        }
    }

    var helpText: String {
        switch self {
        case .all:
            return "对当前订阅范围内的全部节点定时测速（含不可用）。"
        case .availableOnly:
            return "只对当前标记为可用（含各延迟档次）的节点定时测速，节省时间。"
        case .favoritesOnly:
            return "只对已收藏节点定时测速。"
        }
    }
}

enum FavoritePreference: String, Codable, CaseIterable, Sendable {
    case all
    case preferFavorites
    case favoritesOnly

    var displayName: String {
        switch self {
        case .all: return "所有节点"
        case .preferFavorites: return "优先收藏（不足再补其它可用）"
        case .favoritesOnly: return "仅收藏（失败不跨选其它可用）"
        }
    }

    var helpText: String {
        switch self {
        case .all:
            return "连接与故障切换时，从全部可用节点中选取，不优先收藏。"
        case .preferFavorites:
            return "优先使用已收藏的可用节点；收藏不够或失败时，再补充其它可用节点。"
        case .favoritesOnly:
            return "只在已收藏节点中连接与切换；收藏节点全部失败时，不会跨选其它可用节点。"
        }
    }
}

enum AppLogLevel: String, Codable, CaseIterable, Sendable {
    case debug
    case info
    case warning
    case error

    var displayName: String {
        switch self {
        case .debug: return "Debug"
        case .info: return "Info"
        case .warning: return "Warning"
        case .error: return "Error"
        }
    }
}
