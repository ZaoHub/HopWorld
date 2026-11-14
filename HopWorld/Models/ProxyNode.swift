import Foundation

enum ProxyProtocolType: String, Codable, CaseIterable, Hashable, Sendable {
    case vless
    case vmess
    case trojan
    case shadowsocks
    case hysteria2
    case masque
    case tuic
    case anytls
    case wireguard
    case socks5
    case http

    var displayName: String {
        switch self {
        case .vless: return "VLESS"
        case .vmess: return "VMess"
        case .trojan: return "Trojan"
        case .shadowsocks: return "Shadowsocks"
        case .hysteria2: return "Hysteria2"
        case .masque: return "MASQUE"
        case .tuic: return "TUIC"
        case .anytls: return "AnyTLS"
        case .wireguard: return "WireGuard"
        case .socks5: return "SOCKS5"
        case .http: return "HTTP"
        }
    }
}

enum TransportType: String, Codable, CaseIterable, Hashable, Sendable {
    case tcp
    case ws
    case grpc
    case httpupgrade
    case xhttp
    case quic
    case h2
    case http
    case masque

    var displayName: String { rawValue.uppercased() }
}

enum SecurityType: String, Codable, CaseIterable, Hashable, Sendable {
    case none
    case tls
    case reality

    var displayName: String {
        switch self {
        case .none: return "None"
        case .tls: return "TLS"
        case .reality: return "REALITY"
        }
    }
}

enum NodeTestStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case untested
    case testing
    case ultraFast
    case fast
    case fairlyFast
    case fairlySlow
    case slow
    case ultraSlow
    /// 连通探测已完成且节点不通（TCP/HTTPS 失败）。
    case unavailable
    /// 配置/客户端无法测（≠ 不可用）：如 Xray 不支持的加密、缺字段等。
    case failed

    /// 旧版「可用 / 较慢」持久化值兼容。
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "available": self = .fast
        case "degraded": self = .fairlySlow
        default:
            guard let value = NodeTestStatus(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unknown NodeTestStatus: \(raw)"
                )
            }
            self = value
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var displayName: String {
        switch self {
        case .untested: return "未测试"
        case .testing: return "测试中"
        case .ultraFast: return "特快"
        case .fast: return "快"
        case .fairlyFast: return "较快"
        case .fairlySlow: return "较慢"
        case .slow: return "慢"
        case .ultraSlow: return "特慢"
        case .unavailable: return "不可用"
        case .failed: return "失败"
        }
    }

    var symbolName: String {
        switch self {
        case .untested: return "circle"
        case .testing: return "arrow.triangle.2.circlepath"
        case .ultraFast, .fast, .fairlyFast:
            return "checkmark.circle.fill"
        case .fairlySlow, .slow:
            return "exclamationmark.circle.fill"
        case .ultraSlow:
            return "tortoise.fill"
        case .unavailable:
            return "xmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    /// 测速成功且可参与连接 /「可用」筛选。
    var isUsable: Bool {
        switch self {
        case .ultraFast, .fast, .fairlyFast, .fairlySlow, .slow, .ultraSlow:
            return true
        case .untested, .testing, .unavailable, .failed:
            return false
        }
    }

    /// 排序用：数字越小越优先。
    var sortRank: Int {
        switch self {
        case .ultraFast: return 0
        case .fast: return 1
        case .fairlyFast: return 2
        case .fairlySlow: return 3
        case .slow: return 4
        case .ultraSlow: return 5
        case .untested: return 6
        case .testing: return 7
        case .failed: return 8
        case .unavailable: return 9
        }
    }

    /// 按延迟毫秒划分档次（测速成功时使用）。
    static func from(latencyMs: Int) -> NodeTestStatus {
        switch latencyMs {
        case ..<500: return .ultraFast      // < 0.5 秒
        case ..<1000: return .fast         // < 1 秒
        case ..<2000: return .fairlyFast   // < 2 秒
        case ..<4000: return .fairlySlow   // < 4 秒
        case ..<8000: return .slow         // < 8 秒
        default: return .ultraSlow         // ≥ 8 秒
        }
    }

    var thresholdHelpText: String? {
        switch self {
        case .ultraFast: return "延迟小于 0.5 秒"
        case .fast: return "延迟 0.5～1 秒"
        case .fairlyFast: return "延迟 1～2 秒"
        case .fairlySlow: return "延迟 2～4 秒"
        case .slow: return "延迟 4～8 秒"
        case .ultraSlow: return "延迟 8 秒及以上"
        case .untested, .testing, .unavailable, .failed:
            return nil
        }
    }

    /// 「可用」各延迟档次说明（弹窗用）。
    static var latencyTierHelpMessage: String {
        let tiers = [ultraFast, fast, fairlyFast, fairlySlow, slow, ultraSlow]
            .compactMap { status -> String? in
                guard let tip = status.thresholdHelpText else { return nil }
                return "· \(status.displayName)\n\(tip)"
            }
            .joined(separator: "\n\n")
        return tiers
            + "\n\n「可用」筛选包含以上全部成功档次。"
            + "\n「不可用」= 已测通道路径但节点不通。"
            + "\n「失败」= 配置/客户端无法测（与不可用不同）。"
            + "\n未测试单独分类。"
    }
}

struct TuicOptions: Codable, Hashable, Sendable {
    var congestionControl: String?
    var udpRelayMode: String?
    var udpOverStream: Bool?
    var zeroRTTHandshake: Bool?
    var heartbeat: String?
    var certificate: String?
    var publicKeySHA256: [String]?
    var disableSNI: Bool?
}

struct WireGuardOptions: Codable, Hashable, Sendable {
    var privateKey: String?
    var addresses: [String]
    var peerPublicKey: String
    var preSharedKey: String?
    var allowedIPs: [String]?
    var reserved: [Int]?
    var mtu: Int?
    var keepAlive: Int?
    var remoteDNS: [String]?
}

struct ProxyNode: Identifiable, Codable, Hashable, Sendable {
    let id: UUID

    var name: String
    var protocolType: ProxyProtocolType

    var server: String
    var port: Int

    var credentialKey: String?

    var uuid: String?
    var password: String?
    var username: String?
    var masqueHeaders: [String: String]?
    var masqueRemoteDNS: [String]?
    var tuicOptions: TuicOptions?
    var wireGuardOptions: WireGuardOptions?
    var httpHeaders: [String: String]?
    var method: String?
    var alterId: Int?
    var flow: String?
    var encryption: String?

    var transport: TransportType
    var security: SecurityType

    var sni: String?
    var host: String?
    var path: String?
    var serviceName: String?
    var publicKey: String?
    var shortID: String?
    var fingerprint: String?
    var spiderX: String?
    var alpn: String?
    var allowInsecure: Bool?
    var pinnedCertSHA256: String?

    /// Xray FinalMask（分享链接 `fm=`），原始 JSON 字符串，写入 `streamSettings.finalmask`。
    var finalMaskJSON: String?

    var countryCode: String?
    var countryName: String?
    var city: String?
    var exitMetadata: NodeExitMetadata? = nil

    var subscriptionID: UUID?
    var sourceName: String?
    var nodeFingerprint: String?

    var lastLatency: Int?
    var lastTestDate: Date?
    var lastAvailableAt: Date?
    var unavailableSince: Date?
    var lastTestStatus: NodeTestStatus
    var lastTestErrorMessage: String? = nil

    /// 最近一次「应用连通」探测通过数；`nil` = 从未探测。
    var lastAppProbeOkCount: Int?
    /// 通过目标中的最佳延迟（ms）。
    var lastAppProbeLatency: Int?
    var lastAppProbeDate: Date?
    var lastAppProbePassedIDs: Set<String>? = nil

    var enabled: Bool
    var isFavorite: Bool
    var missingCount: Int
    var pendingRemoval: Bool
    /// Subscription refresh changed connection params while this node is connected.
    var pendingConfigUpdate = false
    var note: String?

    init(
        id: UUID = UUID(),
        name: String,
        protocolType: ProxyProtocolType,
        server: String,
        port: Int,
        credentialKey: String? = nil,
        uuid: String? = nil,
        password: String? = nil,
        username: String? = nil,
        masqueHeaders: [String: String]? = nil,
        masqueRemoteDNS: [String]? = nil,
        tuicOptions: TuicOptions? = nil,
        wireGuardOptions: WireGuardOptions? = nil,
        httpHeaders: [String: String]? = nil,
        method: String? = nil,
        alterId: Int? = nil,
        flow: String? = nil,
        encryption: String? = nil,
        transport: TransportType = .tcp,
        security: SecurityType = .none,
        sni: String? = nil,
        host: String? = nil,
        path: String? = nil,
        serviceName: String? = nil,
        publicKey: String? = nil,
        shortID: String? = nil,
        fingerprint: String? = nil,
        spiderX: String? = nil,
        alpn: String? = nil,
        allowInsecure: Bool? = nil,
        pinnedCertSHA256: String? = nil,
        finalMaskJSON: String? = nil,
        countryCode: String? = nil,
        countryName: String? = nil,
        city: String? = nil,
        subscriptionID: UUID? = nil,
        sourceName: String? = nil,
        nodeFingerprint: String? = nil,
        lastLatency: Int? = nil,
        lastAvailableAt: Date? = nil,
        unavailableSince: Date? = nil,
        lastTestDate: Date? = nil,
        lastTestStatus: NodeTestStatus = .untested,
        lastAppProbeOkCount: Int? = nil,
        lastAppProbeLatency: Int? = nil,
        lastAppProbeDate: Date? = nil,
        enabled: Bool = true,
        isFavorite: Bool = false,
        missingCount: Int = 0,
        pendingRemoval: Bool = false,
        pendingConfigUpdate: Bool = false,
        note: String? = nil
    ) {
        self.id = id
        self.name = name
        self.protocolType = protocolType
        self.server = server
        self.port = port
        self.credentialKey = credentialKey
        self.uuid = uuid
        self.password = password
        self.username = username
        self.masqueHeaders = masqueHeaders
        self.masqueRemoteDNS = masqueRemoteDNS
        self.tuicOptions = tuicOptions
        self.wireGuardOptions = wireGuardOptions
        self.httpHeaders = httpHeaders
        self.method = method
        self.alterId = alterId
        self.flow = flow
        self.encryption = encryption
        self.transport = transport
        self.security = security
        self.sni = sni
        self.host = host
        self.path = path
        self.serviceName = serviceName
        self.publicKey = publicKey
        self.shortID = shortID
        self.fingerprint = fingerprint
        self.spiderX = spiderX
        self.alpn = alpn
        self.allowInsecure = allowInsecure
        self.pinnedCertSHA256 = pinnedCertSHA256
        self.finalMaskJSON = finalMaskJSON
        self.countryCode = countryCode
        self.countryName = countryName
        self.city = city
        self.subscriptionID = subscriptionID
        self.sourceName = sourceName
        self.nodeFingerprint = nodeFingerprint
        self.lastLatency = lastLatency
        self.lastAvailableAt = lastAvailableAt
        self.unavailableSince = unavailableSince
        self.lastTestDate = lastTestDate
        self.lastTestStatus = lastTestStatus
        self.lastAppProbeOkCount = lastAppProbeOkCount
        self.lastAppProbeLatency = lastAppProbeLatency
        self.lastAppProbeDate = lastAppProbeDate
        self.enabled = enabled
        self.isFavorite = isFavorite
        self.missingCount = missingCount
        self.pendingRemoval = pendingRemoval
        self.pendingConfigUpdate = pendingConfigUpdate
        self.note = note
    }

    /// MASQUE uses HTTP/3 unless ALPN selects HTTP/2 without HTTP/3.
    var usesUDPTransport: Bool {
        if [.hysteria2, .tuic, .wireguard].contains(protocolType) { return true }
        guard protocolType == .masque else { return false }
        let protocols = (alpn ?? "h3").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return !protocols.contains("h2") || protocols.contains("h3")
    }

    var transportDisplayName: String {
        switch protocolType {
        case .tuic, .hysteria2: return "QUIC / UDP"
        case .wireguard: return "UDP"
        case .masque: return usesUDPTransport ? "MASQUE / HTTP/3" : "MASQUE / HTTP/2"
        default: return transport.displayName
        }
    }

    /// 应用连通至少有一个目标通过且有延迟。
    var hasAppProbeSuccess: Bool {
        (lastAppProbeOkCount ?? 0) > 0 && lastAppProbeLatency != nil
    }

    /// 应用连通通过数，供状态统计使用。
    var appProbePassTier: Int {
        let ok = lastAppProbeOkCount ?? 0
        guard ok > 0, lastAppProbeLatency != nil else { return 0 }
        // 保留实际通过数，不限制应用数量。
        return ok
    }

    /// 自动优选排序。
    /// - Parameter considerAppProbe: 为 false 时忽略应用连通分档，只按测速延迟。
    static func autoSelectLessThan(
        _ lhs: ProxyNode,
        _ rhs: ProxyNode,
        considerAppProbe: Bool,
        appOrder: [String] = [],
        preferFavorites: Bool = false,
        displayTitles: [UUID: String]? = nil
    ) -> Bool {
        if considerAppProbe {
            for id in appOrder {
                let leftPassed = lhs.lastAppProbePassedIDs?.contains(id) == true
                let rightPassed = rhs.lastAppProbePassedIDs?.contains(id) == true
                if leftPassed != rightPassed { return leftPassed }
            }
        }
        if preferFavorites, lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
        let leftLatency = lhs.lastLatency ?? Int.max
        let rightLatency = rhs.lastLatency ?? Int.max
        if leftLatency != rightLatency { return leftLatency < rightLatency }

        let leftTitle = displayTitles?[lhs.id] ?? lhs.displayTitle
        let rightTitle = displayTitles?[rhs.id] ?? rhs.displayTitle
        return leftTitle.localizedStandardCompare(rightTitle) == .orderedAscending
    }

    var displayCountry: String {
        countryName ?? countryCode ?? "未知"
    }

    /// 列表 / 菜单展示用名称（隐藏推广后缀，不改原始 `name`）。
    var displayTitle: String {
        Self.sanitizedDisplayName(name)
    }

    func groupName(subscriptions: [Subscription]) -> String {
        if let subscriptionID,
           let subscription = subscriptions.first(where: { $0.id == subscriptionID }),
           !subscription.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return subscription.name
        }
        if let sourceName, !sourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return sourceName
        }
        return subscriptionID == nil ? "手动导入" : "未知订阅"
    }

    private static let displayNameSuffixRegex = try? NSRegularExpression(
        pattern: #"""
        \s*(?:
            [+＋]\s*
            (?!(?:中转|直连|专线|落地|入口|出口|备用|备份|IPLC|IEPL|BGP|CN2|IPv[46]|VLESS|VMess|Trojan|Shadowsocks|SS|Hysteria2?|HY2|TUIC|REALITY|TCP|UDP|TLS|WS|gRPC)\s*节点)
            [\p{L}\p{N}._-]+\s*节点(?:分享|订阅)?(?=\s|[（(【\[+＋|｜]|$)
            | [+＋]\s*(?:https?://)?(?:[a-z0-9-]+\.)+[a-z]{2,}(?=\s|[（(【\[+＋|｜]|$)
            | [（(【\[]\s*(?:https?://)?(?:[\p{L}\p{N}._/-]+\s+)?[\p{L}\p{N}._-]*?
              (?:节点分享|订阅分享|免费节点|免费订阅|公益节点)\s*[）)】\]]
            | [|｜]\s*(?:[\p{L}\p{N}._-]*?(?:节点分享|订阅分享|免费节点|免费订阅|公益节点)|free[-\s]?nodes)
              (?=\s|[（(【\[+＋|｜]|$)
        )
        """#,
        options: [.caseInsensitive, .allowCommentsAndWhitespace]
    )

    private static let emptyDisplayNameDecorationRegex = try? NSRegularExpression(
        pattern: #"\s*(?:\(\s*\)|（\s*）|\[\s*\]|【\s*】)|\s*[+＋|｜·]+\s*$"#
    )

    static func sanitizedDisplayName(_ raw: String, customFilters: [String] = []) -> String {
        var result = raw
        if let regex = displayNameSuffixRegex {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }
        let filters = customFilters.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
        for filter in filters {
            result = result.replacingOccurrences(of: filter, with: "", options: .caseInsensitive)
        }
        if result != raw {
            if let regex = emptyDisplayNameDecorationRegex {
                let range = NSRange(result.startIndex..<result.endIndex, in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
            }
            result = result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? raw : trimmed
    }

    /// 有延迟且为可用档时，按当前阈值重算（避免改档后旧状态残留）。
    var resolvedTestStatus: NodeTestStatus {
        guard lastTestStatus.isUsable, let ms = lastLatency else {
            return lastTestStatus
        }
        return NodeTestStatus.from(latencyMs: ms)
    }

    var lastAvailableText: String {
        guard let date = lastAvailableAt else { return "暂无记录" }
        if #available(iOS 15.0, macOS 12.0, *) {
            return date.formatted(date: .numeric, time: .shortened)
        }
        return DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
    }

    var latencyText: String {
        guard let lastLatency else { return "—" }
        switch resolvedTestStatus {
        case .unavailable:
            // Failure often still has a TCP RTT; label it so it isn't read as "usable" delay.
            return "TCP \(LatencyFormat.display(lastLatency))"
        case .testing, .untested, .failed:
            return "—"
        case .ultraFast, .fast, .fairlyFast, .fairlySlow, .slow, .ultraSlow:
            return LatencyFormat.display(lastLatency)
        }
    }

    /// 将可用节点的档次与当前延迟阈值对齐；返回是否有变更。
    mutating func refreshLatencyTier() {
        guard lastTestStatus.isUsable else { return }
        lastTestErrorMessage = nil
        guard let ms = lastLatency else { return }
        lastTestStatus = NodeTestStatus.from(latencyMs: ms)
    }
}
