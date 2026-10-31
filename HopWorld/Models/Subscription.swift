import Foundation

enum SubscriptionInterval: Codable, Hashable, Sendable {
    enum Unit: String, Codable, CaseIterable, Sendable {
        case hours, days, weeks

        var displayName: String {
            switch self {
            case .hours: return "小时"
            case .days: return "天"
            case .weeks: return "周"
            }
        }
    }

    case hours(Int)
    case days(Int)
    case weeks(Int)
    case manual

    static let validCounts = 1...999
    static let hourly = Self.hours(1)
    static let every6Hours = Self.hours(6)
    static let every12Hours = Self.hours(12)
    static let daily = Self.days(1)
    static let every2Days = Self.days(2)
    static let weekly = Self.weeks(1)

    init(count: Int, unit: Unit) {
        switch unit {
        case .hours: self = .hours(count)
        case .days: self = .days(count)
        case .weeks: self = .weeks(count)
        }
    }

    var count: Int {
        switch self {
        case let .hours(count), let .days(count), let .weeks(count): return count
        case .manual: return 1
        }
    }

    var unit: Unit {
        switch self {
        case .hours: return .hours
        case .days, .manual: return .days
        case .weeks: return .weeks
        }
    }

    var displayName: String {
        self == .manual ? "手动" : "每 \(count) \(unit.displayName)"
    }

    var seconds: TimeInterval? {
        switch self {
        case let .hours(count): return Double(count) * 3600
        case let .days(count): return Double(count) * 24 * 3600
        case let .weeks(count): return Double(count) * 7 * 24 * 3600
        case .manual: return nil
        }
    }

    var usesTimeOfDay: Bool { self != .manual && unit != .hours }

    private enum CodingKeys: String, CodingKey { case count, unit }

    init(from decoder: Decoder) throws {
        // Existing subscription libraries store the former preset's name as a string.
        if let raw = try? decoder.singleValueContainer().decode(String.self) {
            switch raw {
            case "hourly": self = .hourly
            case "every6Hours": self = .every6Hours
            case "every12Hours": self = .every12Hours
            case "daily": self = .daily
            case "every2Days": self = .every2Days
            case "weekly": self = .weekly
            case "manual": self = .manual
            default:
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "未知的订阅更新周期"))
            }
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let count = try container.decode(Int.self, forKey: .count)
        guard Self.validCounts.contains(count) else {
            throw DecodingError.dataCorruptedError(forKey: .count, in: container, debugDescription: "更新周期必须为 1–999")
        }
        self.init(count: count, unit: try container.decode(Unit.self, forKey: .unit))
    }

    func encode(to encoder: Encoder) throws {
        if self == .manual {
            var container = encoder.singleValueContainer()
            try container.encode("manual")
            return
        }
        guard Self.validCounts.contains(count) else {
            throw EncodingError.invalidValue(count, .init(codingPath: encoder.codingPath, debugDescription: "更新周期必须为 1–999"))
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(count, forKey: .count)
        try container.encode(unit, forKey: .unit)
    }
}

enum SubscriptionUpdateMode: String, Codable, CaseIterable, Sendable {
    case overwrite
    case merge
    case smartMerge

    var displayName: String {
        switch self {
        case .overwrite: return "覆盖"
        case .merge: return "合并"
        case .smartMerge: return "智能合并"
        }
    }

    var helpText: String {
        switch self {
        case .overwrite:
            return "用本次拉取结果整体替换本地节点列表；本地多出的节点会删除，已有节点的收藏等个人设置会尽量保留。"
        case .merge:
            return "把新节点加入本地列表，已有节点保留不删；适合长期累积节点。"
        case .smartMerge:
            return "合并新节点；某节点连续多次更新未再出现时，才按设定次数删除，避免偶发缺席误删。"
        }
    }
}

enum SubscriptionURLMode: String, Codable, CaseIterable, Sendable {
    case fixed
    case dateTemplate

    var displayName: String {
        switch self {
        case .fixed: return "固定地址"
        case .dateTemplate: return "自动日期地址"
        }
    }
}

/// How nodes enter this subscription entry.
enum SubscriptionSourceKind: String, Codable, CaseIterable, Sendable {
    case remoteURL
    case shareLinks

    var displayName: String {
        switch self {
        case .remoteURL: return "订阅地址"
        case .shareLinks: return "节点分享链接"
        }
    }
}

enum SubscriptionUpdateState: Equatable, Sendable {
    case idle
    case resolvingURL
    case fetching
    case validating
    case parsing
    case deduplicating
    case merging
    case testing
    case completed
    case failed(String)

    var displayName: String {
        switch self {
        case .idle: return "空闲"
        case .resolvingURL: return "正在解析日期地址…"
        case .fetching: return "正在下载…"
        case .validating: return "正在验证…"
        case .parsing: return "正在解析节点…"
        case .deduplicating: return "正在去重…"
        case .merging: return "正在合并…"
        case .testing: return "正在测试…"
        case .completed: return "完成"
        case .failed(let message): return "失败：\(message)"
        }
    }
}

struct SubscriptionCleanupRecord: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var cleanedAt: Date
    var automatic: Bool
    var removedCount: Int
}

enum SubscriptionHistoryPeriod: String, CaseIterable {
    case all = "全部时间"
    case today = "今天"
    case last7Days = "最近 7 天"
    case last30Days = "最近 30 天"

    func dateInterval(now: Date, calendar: Calendar) -> DateInterval? {
        let days: Int
        switch self {
        case .all: return nil
        case .today: days = 1
        case .last7Days: days = 7
        case .last30Days: days = 30
        }
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: 1 - days, to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        return DateInterval(start: start, end: end)
    }
}

struct SubscriptionCleanupHistoryFilter {
    typealias Period = SubscriptionHistoryPeriod

    enum Source: String, CaseIterable {
        case all = "全部方式"
        case automatic = "自动"
        case manual = "手动"
    }

    var period: Period = .all
    var source: Source = .all
    var isActive: Bool { period != .all || source != .all }

    func apply(to records: [SubscriptionCleanupRecord], now: Date = Date(), calendar: Calendar = .current) -> [SubscriptionCleanupRecord] {
        let interval = period.dateInterval(now: now, calendar: calendar)
        return records.filter { record in
            let matchesSource = source == .all || record.automatic == (source == .automatic)
            let matchesDate = interval.map { record.cleanedAt >= $0.start && record.cleanedAt < $0.end } ?? true
            return matchesSource && matchesDate
        }
    }
}

struct SubscriptionUpdateHistoryFilter {
    enum Result: String, CaseIterable {
        case all = "全部结果"
        case success = "成功"
        case failure = "失败"
    }

    var period: SubscriptionHistoryPeriod = .all
    var result: Result = .all
    var isActive: Bool { period != .all || result != .all }

    func apply(to logs: [SubscriptionUpdateLog], now: Date = Date(), calendar: Calendar = .current) -> [SubscriptionUpdateLog] {
        let interval = period.dateInterval(now: now, calendar: calendar)
        return logs.filter { log in
            let matchesResult = result == .all || log.success == (result == .success)
            let matchesDate = interval.map { log.startedAt >= $0.start && log.startedAt < $0.end } ?? true
            return matchesResult && matchesDate
        }
    }
}

struct Subscription: Identifiable, Codable, Hashable, Sendable {
    let id: UUID

    var name: String
    var originalURL: String
    var urlTemplate: String?
    var resolvedURL: String?
    var urlMode: SubscriptionURLMode
    /// Optional for forward-compatible decode of older subscriptions.json.
    var sourceKindRaw: String?
    /// Pasted ss/vless/vmess/trojan lines when `sourceKind == .shareLinks`.
    var shareLinksText: String?

    var isEnabled: Bool
    var autoUpdate: Bool

    var updateHour: Int
    var updateMinute: Int
    var updateInterval: SubscriptionInterval
    var timeZoneID: String
    var urlDateTimeZoneID: String

    var dateOffset: Int
    var fallbackDays: Int

    var updateMode: SubscriptionUpdateMode

    var testAfterUpdate: Bool
    var removeUnavailableNodes: Bool
    var smartMergeMissingLimit: Int
    var autoCleanupUnavailableNodes: Bool?
    var unavailableCleanupDays: Int?
    var cleanupHistory: [SubscriptionCleanupRecord]?

    func automaticCleanupCountToday(now: Date = Date(), calendar: Calendar = .current) -> Int {
        (cleanupHistory ?? []).filter {
            $0.automatic && calendar.isDate($0.cleanedAt, inSameDayAs: now)
        }.reduce(0) { $0 + $1.removedCount }
    }

    mutating func removeCleanupHistory(recordIDs: Set<UUID>) -> Int {
        let previousCount = cleanupHistory?.count ?? 0
        cleanupHistory?.removeAll { recordIDs.contains($0.id) }
        return previousCount - (cleanupHistory?.count ?? 0)
    }

    var lastAttemptAt: Date?
    var lastSuccessAt: Date?
    var nextUpdateAt: Date?
    /// Consecutive failed update attempts (network / parse); drives 1/5/30 min retry.
    var updateFailureCount: Int = 0
    var nextRetryAt: Date?
    var lastResolvedDate: Date?
    var lastResolvedURL: String?

    var lastHTTPStatus: Int?
    var lastError: String?

    var etag: String?
    var lastModified: String?
    var contentHash: String?

    var nodeCount: Int
    var statusMessage: String?

    init(
        id: UUID = UUID(),
        name: String,
        originalURL: String,
        urlTemplate: String? = nil,
        resolvedURL: String? = nil,
        urlMode: SubscriptionURLMode = .fixed,
        sourceKind: SubscriptionSourceKind = .remoteURL,
        shareLinksText: String? = nil,
        isEnabled: Bool = true,
        autoUpdate: Bool = true,
        updateHour: Int = 8,
        updateMinute: Int = 30,
        updateInterval: SubscriptionInterval = .daily,
        timeZoneID: String = "Asia/Shanghai",
        urlDateTimeZoneID: String = "Asia/Shanghai",
        dateOffset: Int = 0,
        fallbackDays: Int = 3,
        updateMode: SubscriptionUpdateMode = .smartMerge,
        testAfterUpdate: Bool = true,
        removeUnavailableNodes: Bool = false,
        smartMergeMissingLimit: Int = 3,
        lastAttemptAt: Date? = nil,
        lastSuccessAt: Date? = nil,
        nextUpdateAt: Date? = nil,
        updateFailureCount: Int = 0,
        nextRetryAt: Date? = nil,
        lastResolvedDate: Date? = nil,
        lastResolvedURL: String? = nil,
        lastHTTPStatus: Int? = nil,
        lastError: String? = nil,
        etag: String? = nil,
        lastModified: String? = nil,
        contentHash: String? = nil,
        nodeCount: Int = 0,
        statusMessage: String? = nil
    ) {
        self.id = id
        self.name = name
        self.originalURL = originalURL
        self.urlTemplate = urlTemplate
        self.resolvedURL = resolvedURL
        self.urlMode = urlMode
        self.sourceKindRaw = sourceKind.rawValue
        self.shareLinksText = shareLinksText
        self.isEnabled = isEnabled
        self.autoUpdate = autoUpdate
        self.updateHour = updateHour
        self.updateMinute = updateMinute
        self.updateInterval = updateInterval
        self.timeZoneID = timeZoneID
        self.urlDateTimeZoneID = urlDateTimeZoneID
        self.dateOffset = dateOffset
        self.fallbackDays = fallbackDays
        self.updateMode = updateMode
        self.testAfterUpdate = testAfterUpdate
        self.removeUnavailableNodes = removeUnavailableNodes
        self.smartMergeMissingLimit = smartMergeMissingLimit
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessAt = lastSuccessAt
        self.nextUpdateAt = nextUpdateAt
        self.updateFailureCount = updateFailureCount
        self.nextRetryAt = nextRetryAt
        self.lastResolvedDate = lastResolvedDate
        self.lastResolvedURL = lastResolvedURL
        self.lastHTTPStatus = lastHTTPStatus
        self.lastError = lastError
        self.etag = etag
        self.lastModified = lastModified
        self.contentHash = contentHash
        self.nodeCount = nodeCount
        self.statusMessage = statusMessage
    }

    var updateTimeComponents: DateComponents {
        var components = DateComponents()
        components.hour = updateHour
        components.minute = updateMinute
        return components
    }

    var isHealthy: Bool {
        lastError == nil && lastSuccessAt != nil
    }

    /// Human-readable backoff line for subscription detail / list (remote URL only).
    var updateRetryStatusLine: String? {
        guard !isShareLinksBundle else { return nil }
        guard updateFailureCount > 0 || nextRetryAt != nil else { return nil }
        var parts: [String] = []
        if updateFailureCount > 0 {
            parts.append("连续失败 \(updateFailureCount) 次")
        }
        if let nextRetryAt {
            parts.append("下次重试 \(nextRetryAt.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }

    var sourceKind: SubscriptionSourceKind {
        get {
            guard let raw = sourceKindRaw,
                  let kind = SubscriptionSourceKind(rawValue: raw)
            else { return .remoteURL }
            return kind
        }
        set { sourceKindRaw = newValue.rawValue }
    }

    var isShareLinksBundle: Bool { sourceKind == .shareLinks }

    /// Whether two records still refer to the same remote payload (URL / share text).
    /// Used when applying an in-flight download so schedule/name edits don't discard nodes.
    func hasSameFetchSource(as other: Subscription) -> Bool {
        sourceKind == other.sourceKind
            && originalURL == other.originalURL
            && urlMode == other.urlMode
            && urlTemplate == other.urlTemplate
            && dateOffset == other.dateOffset
            && urlDateTimeZoneID == other.urlDateTimeZoneID
            && fallbackDays == other.fallbackDays
            && shareLinksText == other.shareLinksText
    }
}

struct SubscriptionUpdateLog: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var subscriptionID: UUID
    var startedAt: Date
    var finishedAt: Date?
    var requestedURL: String
    var httpStatus: Int?
    var success: Bool
    var fetchedCount: Int
    var addedCount: Int
    var updatedCount: Int
    var removedCount: Int
    var duplicateCount: Int
    var invalidCount: Int
    var contentHash: String?
    var errorMessage: String?
    var usedFallbackDate: Bool
    var resolvedDateText: String?

    init(
        id: UUID = UUID(),
        subscriptionID: UUID,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        requestedURL: String,
        httpStatus: Int? = nil,
        success: Bool = false,
        fetchedCount: Int = 0,
        addedCount: Int = 0,
        updatedCount: Int = 0,
        removedCount: Int = 0,
        duplicateCount: Int = 0,
        invalidCount: Int = 0,
        contentHash: String? = nil,
        errorMessage: String? = nil,
        usedFallbackDate: Bool = false,
        resolvedDateText: String? = nil
    ) {
        self.id = id
        self.subscriptionID = subscriptionID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.requestedURL = requestedURL
        self.httpStatus = httpStatus
        self.success = success
        self.fetchedCount = fetchedCount
        self.addedCount = addedCount
        self.updatedCount = updatedCount
        self.removedCount = removedCount
        self.duplicateCount = duplicateCount
        self.invalidCount = invalidCount
        self.contentHash = contentHash
        self.errorMessage = errorMessage
        self.usedFallbackDate = usedFallbackDate
        self.resolvedDateText = resolvedDateText
    }
}


extension Subscription {
    func initialFetchOffsets(includeYesterday: Bool) -> [Int] {
        includeYesterday && urlMode == .dateTemplate ? [-1, 0] : [dateOffset]
    }
}
