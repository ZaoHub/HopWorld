import Foundation

enum IOSTheme: String, CaseIterable, Identifiable {
    case blackGold
    case xianxia

    var id: String { rawValue }
    var title: String { self == .blackGold ? "黑金奢华" : "国风仙侠" }
    var description: String { self == .blackGold ? "深黑、鎏金与金属质感" : "水墨云海、玉石与青金符纹" }
    var assetName: String { self == .blackGold ? "HomeReference" : "HomeXianxia" }
}

/// Phone test targets. Same addresses Mac uses for web and apps; desktop-only probes stay out.
enum IOSSettings {
    static let themeKey = "ios.theme"
    static let showSubscriptionNoticesKey = "ios.showSubscriptionNotices"
    static let customTargetsKey = "ios.customTestTargets"
    static let selectedTargetsKey = "ios.selectedTestTargets"

    struct Target: Identifiable, Hashable, Codable {
        var title: String
        var url: String
        var kind: String
        var id: String { url }
    }

    static let builtInTargets: [Target] = [
        Target(title: "网页连通", url: "https://www.gstatic.com/generate_204", kind: "网页"),
        Target(title: "谷歌", url: "https://www.google.com/generate_204", kind: "网页"),
        Target(title: "苹果", url: "https://www.apple.com/library/test/success.html", kind: "网页"),
        Target(title: "微软", url: "http://www.msftconnecttest.com/connecttest.txt", kind: "网页"),
        Target(title: "YouTube", url: "https://www.youtube.com/generate_204", kind: "App"),
        Target(title: "Telegram", url: "https://telegram.org/", kind: "App"),
        Target(title: "Instagram", url: "https://www.instagram.com/", kind: "App"),
        Target(title: "WhatsApp", url: "https://web.whatsapp.com/", kind: "App"),
        Target(title: "TikTok", url: "https://www.tiktok.com/", kind: "App"),
        Target(title: "X", url: "https://x.com/", kind: "App"),
        Target(title: "Discord", url: "https://discord.com/", kind: "App"),
        Target(title: "ChatGPT", url: "https://chatgpt.com/generate_204", kind: "App")
    ]

    static var customTargets: [Target] {
        get {
            guard let text = UserDefaults.standard.string(forKey: customTargetsKey),
                  let data = text.data(using: .utf8),
                  let items = try? JSONDecoder().decode([Target].self, from: data) else { return [] }
            return items
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue), let text = String(data: data, encoding: .utf8) else { return }
            UserDefaults.standard.set(text, forKey: customTargetsKey)
        }
    }

    static var targets: [Target] { builtInTargets + customTargets }

    static func customTarget(title: String, url: String, kind: String) -> Target? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, ["网页", "App"].contains(kind),
              let components = URLComponents(string: url),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty, components.url != nil,
              components.user == nil, components.password == nil else { return nil }
        return Target(title: title, url: url, kind: kind)
    }

    static let timeoutRange = 1...30

    static func selectedTestURLs(from text: String) -> [String] {
        if let data = text.data(using: .utf8),
           let selected = try? JSONDecoder().decode([String].self, from: data) {
            let allowed = Set(targets.map(\.url))
            return selected.filter { allowed.contains($0) }
        }
        let legacy = UserDefaults.standard.string(forKey: "ios.testURL")
        return [legacy.flatMap { url in targets.contains(where: { $0.url == url }) ? url : nil } ?? builtInTargets[0].url]
    }

    static func encodedTestURLs(_ urls: [String]) -> String {
        let allowed = Set(targets.map(\.url))
        var seen: Set<String> = []
        let selected = urls.filter { allowed.contains($0) && seen.insert($0).inserted }
        guard let data = try? JSONEncoder().encode(selected), let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    static var selectedTestURLs: [String] {
        get { selectedTestURLs(from: UserDefaults.standard.string(forKey: selectedTargetsKey) ?? "") }
        set { UserDefaults.standard.set(encodedTestURLs(newValue), forKey: selectedTargetsKey) }
    }

    static var timeoutSeconds: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: "ios.testTimeout")
            return timeoutRange.contains(stored) ? stored : 8
        }
        set { UserDefaults.standard.set(min(30, max(1, newValue)), forKey: "ios.testTimeout") }
    }

    static var batchTimeoutSeconds: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: "ios.batchTestTimeout")
            return timeoutRange.contains(stored) ? stored : 2
        }
        set { UserDefaults.standard.set(min(30, max(1, newValue)), forKey: "ios.batchTestTimeout") }
    }

    static func title(for url: String) -> String {
        targets.first { $0.url == url }?.title ?? "网页连通"
    }
}

enum IOSNodeSort {
    static func byLatency(_ nodes: [ProxyNode]) -> [ProxyNode] {
        nodes.sorted { lhs, rhs in
            let left = bucket(lhs), right = bucket(rhs)
            if left != right { return left < right }
            let leftLatency = lhs.lastLatency ?? Int.max
            let rightLatency = rhs.lastLatency ?? Int.max
            if leftLatency != rightLatency { return leftLatency < rightLatency }
            let order = lhs.displayTitle.localizedStandardCompare(rhs.displayTitle)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private static func bucket(_ node: ProxyNode) -> Int {
        switch node.resolvedTestStatus {
        case .ultraFast, .fast, .fairlyFast, .fairlySlow, .slow, .ultraSlow: return 0
        case .testing: return 1
        case .untested: return 2
        case .failed: return 3
        case .unavailable: return node.lastLatency == nil ? 5 : 4
        }
    }
}

struct IOSNodeTally: Equatable {
    var total = 0
    var available = 0
    var unavailable = 0
    var failed = 0

    static func make(_ nodes: [ProxyNode]) -> IOSNodeTally {
        var tally = IOSNodeTally(total: nodes.count)
        for node in nodes {
            switch node.resolvedTestStatus {
            case .unavailable: tally.unavailable += 1
            case .failed: tally.failed += 1
            default:
                if node.resolvedTestStatus.isUsable { tally.available += 1 }
            }
        }
        return tally
    }

    var line: String { "总 \(total) · 可用 \(available) · 不可用 \(unavailable) · 失败 \(failed)" }
}

enum IOSNodeScope: String, CaseIterable, Identifiable {
    case all
    case available
    case unavailable
    case failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .available: return "可用"
        case .unavailable: return "不可用"
        case .failed: return "失败"
        }
    }

    func matches(_ node: ProxyNode) -> Bool {
        switch self {
        case .all: return true
        case .available: return node.resolvedTestStatus.isUsable
        case .unavailable: return node.resolvedTestStatus == .unavailable
        case .failed: return node.resolvedTestStatus == .failed
        }
    }
}

enum IOSNodeIdentity {
    static func key(_ node: ProxyNode) -> String {
        [
            node.protocolType.rawValue,
            node.server.lowercased(),
            String(node.port),
            node.uuid ?? "",
            node.password ?? "",
            node.transport.rawValue
        ].joined(separator: "\n")
    }

    /// Keep the previous id and test result when the refreshed link is the same node.
    static func keepingResults(existing: [ProxyNode], proposed: [ProxyNode], subscriptionID: UUID, sourceName: String) -> [ProxyNode] {
        var pool: [String: [ProxyNode]] = [:]
        for node in existing {
            pool[key(node), default: []].append(node)
        }
        return proposed.map { node in
            var copy = node
            copy.subscriptionID = subscriptionID
            copy.sourceName = sourceName
            CountryResolver.applyNameHeuristics(to: &copy)
            guard var matches = pool[key(copy)], !matches.isEmpty else { return copy }
            var kept = matches.removeFirst()
            pool[key(copy)] = matches
            kept.name = copy.name
            kept.protocolType = copy.protocolType
            kept.server = copy.server
            kept.port = copy.port
            kept.uuid = copy.uuid
            kept.password = copy.password
            kept.username = copy.username
            kept.method = copy.method
            kept.alterId = copy.alterId
            kept.flow = copy.flow
            kept.encryption = copy.encryption
            kept.transport = copy.transport
            kept.security = copy.security
            kept.sni = copy.sni
            kept.host = copy.host
            kept.path = copy.path
            kept.serviceName = copy.serviceName
            kept.publicKey = copy.publicKey
            kept.shortID = copy.shortID
            kept.fingerprint = copy.fingerprint
            kept.spiderX = copy.spiderX
            kept.alpn = copy.alpn
            kept.allowInsecure = copy.allowInsecure
            kept.countryCode = copy.countryCode
            kept.countryName = copy.countryName
            kept.subscriptionID = subscriptionID
            kept.sourceName = sourceName
            CountryResolver.applyNameHeuristics(to: &kept)
            return kept
        }
    }
}
