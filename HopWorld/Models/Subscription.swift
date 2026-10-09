import Foundation

enum SubscriptionInterval: String, Codable, CaseIterable, Sendable {
    case every6Hours
    case every12Hours
    case daily
    case every2Days
    case weekly
    case manual

    var displayName: String {
        switch self {
        case .every6Hours: return "每 6 小时"
        case .every12Hours: return "每 12 小时"
        case .daily: return "每天"
        case .every2Days: return "每 2 天"
        case .weekly: return "每周"
        case .manual: return "手动"
        }
    }

    var seconds: TimeInterval? {
        switch self {
        case .every6Hours: return 6 * 3600
        case .every12Hours: return 12 * 3600
        case .daily: return 24 * 3600
        case .every2Days: return 48 * 3600
        case .weekly: return 7 * 24 * 3600
        case .manual: return nil
        }
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
