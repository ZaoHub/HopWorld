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
    var exitMetadata: NodeExitMetadata? = nil

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

enum NodeTestStatistic: String, CaseIterable, Identifiable {
    case available, unavailable, failed, progress

    var id: String { rawValue }

    var title: String {
        switch self {
        case .available: return "可用 / 应用连通"
        case .unavailable: return "不可用"
        case .failed: return "失败"
        case .progress: return "测速进度"
        }
    }

    func sections(for nodes: [ProxyNode], remainingNodeIDs: Set<UUID> = []) -> [NodeTestStatisticSection] {
        switch self {
        case .available:
            let usable = nodes.filter { $0.lastTestStatus.isUsable }
            let speeds = Dictionary(grouping: usable) { $0.resolvedTestStatus.displayName }
                .mapValues { $0.count }
            let applications = Dictionary(grouping: nodes) { node in
                if node.hasAppProbeSuccess { return "应用已连通" }
                return node.lastAppProbeDate != nil ? "应用未通过" : "应用未测试"
            }.mapValues { $0.count }
            return [
                NodeTestStatisticSection(title: "可用节点速度档次", counts: speeds),
                NodeTestStatisticSection(title: "应用连通", counts: applications)
            ]
        case .unavailable, .failed:
            let status: NodeTestStatus = self == .failed ? .failed : .unavailable
            let counts = Dictionary(grouping: nodes.filter { $0.lastTestStatus == status }) { node in
                let reason = node.lastTestErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return reason.isEmpty || reason == "TCP_PASS"
                    ? "原因未记录（重新测速后可查看）" : reason
            }.mapValues { $0.count }
            return [NodeTestStatisticSection(title: "\(title)原因", counts: counts)]
        case .progress:
            let states = Dictionary(grouping: nodes) { $0.lastTestStatus.displayName }
                .mapValues { $0.count }
            let testing = nodes.filter { $0.lastTestStatus == .testing }.count
            let untested = nodes.filter { $0.lastTestStatus == .untested }.count
            var totals = [
                "范围节点": nodes.count,
                "已完成": nodes.count - testing - untested,
                "测试中": testing,
                "未测试": untested
            ]
            let remaining = remainingNodeIDs.intersection(Set(nodes.map(\.id))).count
            if remaining > 0 { totals["待继续"] = remaining }
            return [
                NodeTestStatisticSection(title: "测速状态", counts: states),
                NodeTestStatisticSection(title: "范围统计", counts: totals)
            ]
        }
    }
}

struct NodeTestStatisticSection: Identifiable {
    var title: String
    var counts: [String: Int]
    var id: String { title }

    var sortedCounts: [(key: String, value: Int)] {
        counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
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

    func retainingKnownDetails(from previous: Self?) -> Self {
        var result = self
        if previous?.ip == ip, result.networkType == nil { result.networkType = previous?.networkType }
        if result.localizedCity == nil, let previous, result.hasSameCityObservation(as: previous) {
            result.localizedCity = previous.localizedCity
        }
        return result
    }

    func hasSameCityObservation(as other: Self) -> Bool {
        ip == other.ip && city == other.city && countryCode == other.countryCode && region == other.region
            && latitude == other.latitude && longitude == other.longitude
    }
}

/// Display snapshot for the network health center: live connection exit first, then saved node metadata.
struct NetworkHealthExitInfo: Equatable, Sendable {
    var ip: String?
    var networkType: ExitIPType?
    var country: String?
    var rawCountry: String?
    var city: String
    var rawCity: String?
    var countryCode: String?
    var networkOperator: String
    var rawOperator: String?
    var asn: String?
    var isCurrentConnection: Bool
    var awaitingLive: Bool

    static func resolve(node: ProxyNode, connection: ConnectionState, showChinese: Bool = true,
                        catalog: ChineseCityCatalog? = nil) -> Self {
        let isCurrent = connection.status == .connected && connection.currentNodeID == node.id
        let metadata = node.exitMetadata
        let rawCity = isCurrent ? (connection.exitCity ?? metadata?.city) : metadata?.city
        let rawOperator = isCurrent ? (connection.exitOperator ?? metadata?.networkOperator) : metadata?.networkOperator
        let sameExitIP = isCurrent ? (connection.exitIP == nil || connection.exitIP == metadata?.ip) : true
        let liveCountry = connection.exitCountry?.trimmingCharacters(in: .whitespacesAndNewlines)
        let liveCountryCode = liveCountry.flatMap(ExitMetadataLocalization.countryCode(from:))
        let countryCode: String? = {
            if isCurrent {
                if sameExitIP {
                    return metadata?.countryCode ?? liveCountryCode ?? connection.currentCountryCode ?? node.countryCode
                }
                return liveCountryCode
            }
            return metadata?.countryCode ?? node.countryCode
        }()
        let rawCountry: String? = {
            if isCurrent, let liveCountry, !liveCountry.isEmpty { return liveCountry }
            if let code = countryCode, !code.isEmpty {
                return CountryResolver.displayName(for: code)
            }
            if !isCurrent {
                let resolved = CountryResolver.effectiveCountry(for: node)
                return resolved.code == "XX" ? nil : resolved.name
            }
            return nil
        }()
        let country = ExitMetadataLocalization.country(rawCountry, countryCode: countryCode, showChinese: showChinese)
        let localizedCity = (rawCity == nil || rawCity == metadata?.city) ? metadata?.localizedCity : nil
        let ip = isCurrent ? (connection.exitIP ?? metadata?.ip) : metadata?.ip
        return Self(
            ip: ip,
            networkType: isCurrent ? (connection.exitIPType ?? metadata?.networkType) : metadata?.networkType,
            country: country,
            rawCountry: rawCountry,
            city: ExitMetadataLocalization.city(rawCity, countryCode: countryCode,
                                                localizedCity: localizedCity,
                                                showChinese: showChinese, catalog: catalog),
            rawCity: rawCity,
            countryCode: countryCode,
            networkOperator: ExitMetadataLocalization.networkOperator(rawOperator, showChinese: showChinese),
            rawOperator: rawOperator,
            asn: isCurrent ? (connection.exitASN ?? metadata?.asn) : metadata?.asn,
            isCurrentConnection: isCurrent,
            awaitingLive: isCurrent && connection.exitIP == nil
        )
    }
}

enum ExitMetadataLocalization {
    static func city(_ value: String?, countryCode: String? = nil, localizedCity: String? = nil, showChinese: Bool = true, catalog: ChineseCityCatalog? = nil) -> String {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return "未知" }
        guard showChinese else { return value }
        return ChineseCityCatalog.chineseName(localizedCity)
            ?? (catalog ?? .shared).name(for: value, countryCode: countryCode) ?? value
    }

    /// Keep the English country label, and append Chinese in parentheses when available.
    static func country(_ value: String?, countryCode code: String? = nil, showChinese: Bool = true) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedCode = resolvedCountryCode(code) ?? resolvedCountryCode(trimmed)
        let english = englishCountryName(raw: trimmed, code: resolvedCode)
        guard showChinese else { return english }
        guard let english else { return nil }
        let chinese = resolvedCode.map(CountryResolver.displayName(for:))
            ?? trimmed.flatMap { CountryResolver.resolve(fromName: $0)?.name }
        guard let chinese, chinese != english,
              chinese.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) else {
            return english
        }
        return "\(english)（\(chinese)）"
    }

    static func countryCode(from value: String?) -> String? {
        resolvedCountryCode(value)
    }

    private static func resolvedCountryCode(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count == 2, trimmed.allSatisfy({ $0.isASCII && $0.isLetter }) {
            return trimmed.uppercased()
        }
        return CountryResolver.resolve(fromName: trimmed)?.code
    }

    private static func englishCountryName(raw: String?, code: String?) -> String? {
        if let raw, !raw.isEmpty {
            let hasChinese = raw.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) })
            let isISOCode = raw.count == 2 && raw.allSatisfy({ $0.isASCII && $0.isLetter })
            if !hasChinese && !isISOCode { return raw }
        }
        if let code, code.count == 2,
           let english = Locale(identifier: "en_US").localizedString(forRegionCode: code), !english.isEmpty {
            return english
        }
        if let raw, !raw.isEmpty {
            let isISOCode = raw.count == 2 && raw.allSatisfy({ $0.isASCII && $0.isLetter })
            if !isISOCode { return raw }
        }
        return code
    }

    static func networkOperator(_ value: String?, showChinese: Bool = true) -> String {
        localized(value, names: showChinese ? operators : [:])
    }

    static func help(raw: String?, displayed: String, showChinese: Bool) -> String {
        let original = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pending = showChinese && !original.isEmpty && displayed == original
            && ChineseCityCatalog.chineseName(displayed) == nil
        return "\(displayed)（\(original.isEmpty ? "未知" : original)）" + (pending ? "\n中文名待补充" : "")
    }

    private static func localized(_ value: String?, names: [String: String]) -> String {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return "未知" }
        return names[normalizedKey(value)] ?? value
    }

    private static func normalizedKey(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    private static let operators = [
        "ovh": "OVH 云服务", "ovh sas": "OVH 云服务", "ovh s.a.s.": "OVH 云服务",
        "ovhcloud": "OVH 云服务", "ovh hosting, inc.": "OVH 云服务",
        "google": "谷歌", "google llc": "谷歌", "google cloud": "谷歌云",
        "microsoft corporation": "微软", "microsoft": "微软",
        "amazon.com, inc.": "亚马逊", "amazon technologies inc.": "亚马逊科技",
        "amazon data services": "亚马逊数据服务", "amazon web services": "亚马逊云科技",
        "alibaba (us) technology co., ltd.": "阿里巴巴（美国）", "alibaba cloud": "阿里云",
        "tencent cloud": "腾讯云", "tencent cloud computing (beijing) co., ltd": "腾讯云",
        "huawei cloud": "华为云", "huawei clouds": "华为云",
        "china telecom": "中国电信", "chinanet": "中国电信", "china unicom": "中国联通",
        "china mobile": "中国移动", "china mobile communications corporation": "中国移动",
        "oracle corporation": "甲骨文", "akamai technologies, inc.": "阿卡迈科技",
        "digitalocean, llc": "数字海洋", "ntt communications corporation": "NTT 通信",
        "deutsche telekom ag": "德国电信", "france telecom": "法国电信"
    ]
}

enum ExitIPType: String, Codable, Sendable {
    case residential, mobile, hosting, vpn, proxy, tor

    var displayName: String {
        switch self {
        case .residential: return "家庭住宅·推测"
        case .mobile: return "移动网络"
        case .hosting: return "机房托管"
        case .vpn: return "VPN 出口"
        case .proxy: return "公共代理"
        case .tor: return "Tor 出口"
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
    var lastSuccessfulLatency: Int?
    var exitIP: String?
    var exitIPType: ExitIPType?
    var exitCountry: String?
    var exitCity: String?
    var exitOperator: String?
    var exitASN: String?
    var downloadMbps: Double = 0
    var uploadMbps: Double = 0
    var sessionDownloadBytes: Int64 = 0
    var sessionUploadBytes: Int64 = 0
    var connectedAt: Date?
    var lastError: String?
    var autoSelectEnabled: Bool = true

    mutating func recordExitIP(_ ip: String?, type: ExitIPType?) {
        let sameExit = ip != nil && ip == exitIP
        exitIPType = type ?? (sameExit ? exitIPType : nil)
        exitIP = ip
    }

    mutating func recordLatency(_ milliseconds: Int?) {
        latency = milliseconds
        if let milliseconds { lastSuccessfulLatency = milliseconds }
    }

    mutating func resetLatency() {
        latency = nil
        lastSuccessfulLatency = nil
    }

    func dashboardLatencyText(lastTestLatency: Int?) -> String {
        if status == .connected {
            if let latency { return LatencyFormat.display(latency) }
            if let previous = lastSuccessfulLatency ?? lastTestLatency {
                return "\(LatencyFormat.display(previous))（上次）"
            }
            return "暂不可测"
        }
        if status == .connecting {
            return lastSuccessfulLatency.map { LatencyFormat.display($0) }
                ?? lastTestLatency.map { LatencyFormat.display($0) }
                ?? "连接中"
        }
        return lastTestLatency.map { LatencyFormat.display($0) } ?? "未测速"
    }
}

/// Connection history survives quit cleanup; settings.connectOnLaunch controls the next launch.
struct StartupConnectionIntent: Codable, Sendable, Equatable {
    var lastConnectedNodeID: UUID?
    /// Records a recoverable session without overriding the startup setting.
    var reconnectOnNextLaunch = false
    /// Legacy manual-stop record; it does not override the next launch's setting.
    var stayDisconnectedUntilConnect = false
}

extension StartupConnectionIntent {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        lastConnectedNodeID = try values.decodeIfPresent(UUID.self, forKey: .lastConnectedNodeID)
        reconnectOnNextLaunch = try values.decodeIfPresent(Bool.self, forKey: .reconnectOnNextLaunch) ?? false
        stayDisconnectedUntilConnect = try values.decodeIfPresent(Bool.self, forKey: .stayDisconnectedUntilConnect) ?? false
    }
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
            return "默认用系统代理按域名/IP 分流（遵循系统代理的 App 都会进入节点）。若只要指定 App 走代理，请在下方启用「按应用代理」。"
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
            return "通过 Packet Tunnel 接管全部应用，并出现在「系统设置 → 网络」VPN 列表，不依赖应用是否遵循系统代理。仅自行签名、带 Network Extension 权限的构建可用；首次连接会请求添加 VPN 配置。"
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

enum AppTheme: String, Codable, CaseIterable, Sendable {
    case system, light, dark

    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}

struct AppSettings: Codable, Hashable, Sendable {
    func shouldResolveChineseCity(for node: ProxyNode) -> Bool {
        showChineseNodeMetadata && node.resolvedTestStatus.isUsable && node.enabled && !node.pendingRemoval
    }

    var theme: AppTheme = .system
    var launchAtLogin: Bool = false
    var showChineseNodeMetadata: Bool = true
    var filterNodeNameAds: Bool = true
    var nodeNameAdFilterText: String = ""
    var connectOnLaunch: ConnectOnLaunch = .lastNode
    var disconnectOnScreenLock: Bool = true
    var screenLockDisconnectDelayMinutes: Int = 15

    var socksHost: String = "127.0.0.1"
    var socksPort: Int = 10808
    var httpHost: String = "127.0.0.1"
    var httpPort: Int = 10809

    var autoFailover: Bool = true
    var codexSmartFailover: Bool = false
    /// 故障切换候选：前 N 个可用，或全部可用。
    var failoverPoolMode: FailoverPoolMode = .limited
    var maxFailoverAttempts: Int = 5
    /// 初次连接验证的等待时间（秒）；慢连接会延长等待后再决定是否切换。
    var connectTimeoutSeconds: Int = 15

    static let chatGPTConnectivityTestURL = "https://chatgpt.com/generate_204"
    static let codexConnectivityTestURL = "https://chatgpt.com/backend-api/codex/responses"
    static let presetTestURLs = [
        "https://www.google.com/generate_204",
        "https://www.youtube.com/generate_204",
        "https://www.googlevideo.com/generate_204",
        "https://www.gstatic.com/generate_204",
        "https://www.apple.com/library/test/success.html",
        "http://www.msftconnecttest.com/connecttest.txt",
        chatGPTConnectivityTestURL,
        codexConnectivityTestURL
    ]
    static func testURLTitle(_ url: String) -> String {
        switch url {
        case presetTestURLs[0]: return "谷歌连通性检测"
        case presetTestURLs[1]: return "优兔连通性检测"
        case presetTestURLs[2]: return "谷歌视频连通性检测"
        case presetTestURLs[3]: return "谷歌静态资源连通性检测（默认）"
        case presetTestURLs[4]: return "苹果网络连通性检测"
        case presetTestURLs[5]: return "微软网络连通性检测"
        case presetTestURLs[6]: return "ChatGPT 连通性检测"
        case presetTestURLs[7]: return "Codex连通性检测"
        default: return "自定义测试地址"
        }
    }
    var customTestURLs: [String]? = nil
    var customTestURLNames: [String: String]? = nil
    func testURLDisplayTitle(_ url: String) -> String {
        if let name = customTestURLNames?[url]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if Self.presetTestURLs.contains(url) { return Self.testURLTitle(url) }
        return URL(string: url)?.host ?? Self.testURLTitle(url)
    }
    var availableTestURLs: [String] {
        var urls = Self.presetTestURLs
        for url in (customTestURLs ?? []) + [testURL] where !urls.contains(url) {
            urls.append(url)
        }
        return urls
    }
    static func validatedTestURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
    static func testURLForAddition(_ raw: String, useGenerate204: Bool) -> URL? {
        guard let url = validatedTestURL(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        guard useGenerate204 else { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/generate_204"
        components.query = nil
        components.fragment = nil
        return components.url
    }
    var testURL: String = "https://www.gstatic.com/generate_204"
    var testConcurrency: Int = 16
    /// 单个节点测速超时（秒）；含 FinalMask 等慢握手节点可调高。
    var testTimeoutSeconds: Int = 8
    /// 批量测速 HTTPS 超时（秒）；默认较短以加快整批。
    var batchTestTimeoutSeconds: Int = 2
    /// 测试中心「应用连通」探测超时（秒）。
    var appProbeTimeoutSeconds: Int = 5
    /// 开启后，手动与后台测速结束都会对可用节点补测应用连通（手动会强制复测）。默认关闭。
    var autoAppProbeUsableNodes: Bool = false
    var appProbeOrder: [String: [String]] = [:]
    /// 概览「应用代理」中停用的目标：不参与应用连通测试与自动优选排序。
    var appProbeDisabledTargetIDs: Set<String> = []
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
    var defaultTimeZoneID: String = TimeZone.current.identifier
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
    var temporarilyBlockedNodeIDs: Set<UUID>? = nil
    var autoSelectMinimumSpeed: AutoSelectMinimumSpeed = .allUsable
    var autoSelectUnhealthySeconds: Int = 30

    var logLevel: AppLogLevel = .info
    /// One-shot: old tests used CONNECT-only and falsely marked free nodes available.
    var httpsProbeMigrated: Bool = false
    /// One-shot: raise concurrency / lower timeout after the "22 nodes took minutes" incident.
    var testSpeedTuned: Bool = false
    /// Last selected filters on the Nodes page: `scope@@source` (survives sidebar switches).
    var nodeListCategoryRaw: String = "all@@all"

    func nodeDisplayTitle(_ node: ProxyNode) -> String {
        nodeDisplayName(node.name)
    }

    func nodeCountryLabel(_ node: ProxyNode, displayedCity: String? = nil) -> String? {
        let country = CountryResolver.displayName(for: CountryResolver.effectiveCode(for: node))
        return nodeDisplayTitle(node).contains(country) || displayedCity == country ? nil : country
    }

    func nodeDisplayName(_ raw: String) -> String {
        filterNodeNameAds
            ? ProxyNode.sanitizedDisplayName(raw, customFilters: nodeNameAdFilterText.components(separatedBy: .newlines))
            : raw
    }
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

    func isTemporarilyBlocked(_ id: UUID) -> Bool {
        temporarilyBlockedNodeIDs?.contains(id) == true
    }

    func allowsAutoSelectNode(_ node: ProxyNode, includingTemporarilyBlocked: Bool = false) -> Bool {
        if !includingTemporarilyBlocked, isTemporarilyBlocked(node.id) { return false }
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
            return "只对当前可用节点定时测速。不可用和失败节点不测；没有新的相同状态结果时顺延计时，已超过设定天数且天数内仍是同一状态则立即删除。"
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

/// 按自然日累计的代理流量（跨连接会话累加，用于概览「今日流量」卡片）。
struct DailyUsageStats: Codable, Sendable, Equatable {
    /// yyyy-MM-dd（本地时区）。
    var day: String
    var uploadBytes: Int64 = 0
    var downloadBytes: Int64 = 0

    init(day: String = DailyUsageStats.todayString(), uploadBytes: Int64 = 0, downloadBytes: Int64 = 0) {
        self.day = day
        self.uploadBytes = uploadBytes
        self.downloadBytes = downloadBytes
    }

    var totalBytes: Int64 { uploadBytes + downloadBytes }

    static func todayString(_ date: Date = Date()) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
                      components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    /// 跨自然日后从零重新累计。
    func rolledForwardToToday() -> DailyUsageStats {
        let today = Self.todayString()
        guard day != today else { return self }
        return DailyUsageStats(day: today)
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


extension AppSettings {
    /// Apply only user edits, preserving scheduler timestamps and unrelated concurrent settings.
    func applyingSettingsEdits(from draft: Self, comparedTo baseline: Self) -> Self {
        var updated = self
        func merge<Value: Equatable>(_ keyPath: WritableKeyPath<Self, Value>) {
            if draft[keyPath: keyPath] != baseline[keyPath: keyPath] {
                updated[keyPath: keyPath] = draft[keyPath: keyPath]
            }
        }
        merge(\.appProbeTimeoutSeconds)
        merge(\.autoAppProbeUsableNodes)
        merge(\.autoFailover)
        merge(\.codexSmartFailover)
        merge(\.autoSelectCountryScope)
        merge(\.autoSelectExcludedCountryCodes)
        merge(\.autoSelectIncludedCountryCodes)
        merge(\.temporarilyBlockedNodeIDs)
        merge(\.autoSelectMinimumSpeed)
        merge(\.autoSelectUnhealthySeconds)
        merge(\.batchTestTimeoutSeconds)
        merge(\.connectOnLaunch)
        merge(\.connectTimeoutSeconds)
        merge(\.defaultFallbackDays)
        merge(\.defaultTimeZoneID)
        merge(\.defaultUpdateHour)
        merge(\.defaultUpdateMinute)
        merge(\.defaultUpdateMode)
        merge(\.disconnectOnScreenLock)
        merge(\.failoverPoolMode)
        merge(\.favoritePreference)
        merge(\.showChineseNodeMetadata)
        merge(\.filterNodeNameAds)
        merge(\.nodeNameAdFilterText)
        merge(\.launchAtLogin)
        merge(\.logLevel)
        merge(\.maxFailoverAttempts)
        merge(\.scheduledTestEnabled)
        merge(\.scheduledTestIntervalMinutes)
        merge(\.scheduledTestScope)
        merge(\.scheduledTestSubscriptionRaw)
        merge(\.screenLockDisconnectDelayMinutes)
        merge(\.theme)
        merge(\.testConcurrency)
        merge(\.testResultTTLMinutes)
        merge(\.testTimeoutSeconds)
        merge(\.testURL)
        merge(\.customTestURLs)
        merge(\.customTestURLNames)
        merge(\.installedAppProbes)
        merge(\.appProbeSource)
        merge(\.appProbeOrder)
        merge(\.socksHost)
        merge(\.socksPort)
        merge(\.httpHost)
        merge(\.httpPort)
        return updated
    }
}

extension AppSettings {
    static func connectionCandidatesGuidance(blockedCount: Int, hasNodes: Bool) -> String {
        guard hasNodes else { return "还没有可连接的节点。请先添加订阅，再到测试页面完成测速和应用连通测试。" }
        let blocked = blockedCount > 0
            ? "当前有 \(blockedCount) 个节点被临时屏蔽，不会参与自动连接。可在快速切换中右键节点，选择“关闭临时屏蔽”。\n\n"
            : ""
        return blocked + "目前没有符合优选条件的可用节点。请前往测试页面重新测速和测试应用连通，并检查国家范围、最低速度及收藏限制。临时屏蔽不会自动解除。"
    }

}

extension AppSettings {
    func quickSwitchCounts(for nodes: [ProxyNode]) -> (available: Int, filtered: Int, blocked: Int) {
        var counts = (available: 0, filtered: 0, blocked: 0)
        for node in nodes where !node.pendingRemoval {
            if isTemporarilyBlocked(node.id) {
                counts.blocked += 1
            } else if node.enabled && allowsAutoSelectNode(node)
                        && (favoritePreference != .favoritesOnly || node.isFavorite) {
                counts.available += 1
            } else if node.resolvedTestStatus.isUsable || node.hasAppProbeSuccess {
                counts.filtered += 1
            }
        }
        return counts
    }
}
