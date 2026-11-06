import Foundation

struct CodexResetNotificationRecipient: Codable, Equatable, Identifiable {
    var id: UUID
    var nickname: String
    var address: String
    var isSelected: Bool

    init(id: UUID = UUID(), nickname: String, address: String, isSelected: Bool = true) {
        self.id = id
        self.nickname = nickname
        self.address = address
        self.isSelected = isSelected
    }

    var deliveryAddress: String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("@") { return trimmed.lowercased() }
        let digits = trimmed.filter { "0123456789".contains($0) }
        return (trimmed.hasPrefix("+") ? "+" : "") + digits
    }

    var addressValidationError: String? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "请输入 iMessage 手机号或 Apple 账号邮箱。" }
        if trimmed.contains("@") {
            let parts = trimmed.components(separatedBy: "@")
            let localCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.!#$%&'*+-/=?^_`{|}~")
            let domainCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
            guard parts.count == 2, trimmed.utf8.count <= 254,
                  !parts[0].isEmpty, parts[0].utf8.count <= 64,
                  !parts[0].hasPrefix("."), !parts[0].hasSuffix("."), !parts[0].contains(".."),
                  parts[0].unicodeScalars.allSatisfy({ localCharacters.contains($0) }) else {
                return "请输入有效的 Apple 账号邮箱。"
            }
            let labels = parts[1].components(separatedBy: ".")
            guard labels.count >= 2, labels.allSatisfy({ label in
                !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                    && label.unicodeScalars.allSatisfy { domainCharacters.contains($0) }
            }) else { return "请输入有效的 Apple 账号邮箱。" }
            return nil
        }
        let phoneCharacters = CharacterSet(charactersIn: "+0123456789 ()-")
        let digits = trimmed.filter { "0123456789".contains($0) }
        guard trimmed.unicodeScalars.allSatisfy({ phoneCharacters.contains($0) }),
              trimmed.filter({ $0 == "+" }).count <= 1,
              !trimmed.contains("+") || trimmed.hasPrefix("+"),
              (7...15).contains(digits.count) else {
            return "请输入有效的手机号，国际号码请带国家或地区代码。"
        }
        return nil
    }
}

struct CodexResetNotificationSettings: Codable, Equatable {
    var enabled: Bool
    var recipients: [CodexResetNotificationRecipient]

    init(enabled: Bool = false, recipients: [CodexResetNotificationRecipient] = []) {
        self.enabled = enabled
        self.recipients = recipients
    }

    var selectedRecipients: [CodexResetNotificationRecipient] {
        var addresses = Set<String>()
        return recipients.filter { $0.isSelected && addresses.insert($0.deliveryAddress).inserted }
    }

    var validationError: String? {
        guard enabled else { return nil }
        guard !selectedRecipients.isEmpty else { return "请至少选择一位通知收件人。" }
        for recipient in recipients where recipient.isSelected {
            if let error = recipient.addressValidationError {
                let name = recipient.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? error : "\(name)：\(error)"
            }
        }
        return nil
    }
}

struct CodexResetNotificationObservation: Codable, Equatable {
    let accountID: String?
    let usedPercent: Double?
    let resetsAt: Double?
    let resetCount: Int
    let creditExpiresAt: Double?

    init(accountID: String?, usedPercent: Double?, resetsAt: Double?, resetCount: Int,
         creditExpiresAt: Double? = nil) {
        self.accountID = accountID
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.resetCount = resetCount
        self.creditExpiresAt = creditExpiresAt
    }

    static func make(accountID: String?, usedPercent: Double?, resetsAt: Double?,
                     resetCount: Int, creditExpiresAt: Double? = nil) -> Self? {
        guard resetCount >= 0 else { return nil }
        if let usedPercent {
            guard usedPercent.isFinite, (0...100).contains(usedPercent) else { return nil }
        }
        if let resetsAt {
            guard resetsAt.isFinite, resetsAt > 0 else { return nil }
        }
        let expiration = creditExpiresAt.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let account = accountID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(accountID: account.flatMap { $0.isEmpty ? nil : $0 },
                    usedPercent: usedPercent, resetsAt: resetsAt, resetCount: resetCount,
                    creditExpiresAt: expiration)
    }
}

struct CodexResetNotificationEvent: Equatable {
    let weeklyReset: Bool
    let giftedResetCount: Int
}

struct CodexResetNotificationState: Codable, Equatable {
    /// Seconds before the soonest available reset credit expires. Each lead is sent once.
    static let creditReminderLeads = [86_400, 18_000, 10_800, 1_800, 300]
    private(set) var previous: CodexResetNotificationObservation?
    private var wasEnabled = false
    private(set) var creditExpiresAt: Double?
    private(set) var sentCreditReminderLeads: [Int] = []

    mutating func resetBaseline() {
        previous = nil
        wasEnabled = false
        creditExpiresAt = nil
        sentCreditReminderLeads = []
    }

    mutating func clearCreditReminder() {
        creditExpiresAt = nil
        sentCreditReminderLeads = []
    }

    /// The closest reminder whose time has arrived and has not been sent.
    /// Earlier missed leads are left unsent until `commitCreditReminder`; a later call still returns only the closest.
    /// Expirations within a minute are the same credit, so a small timestamp change does not restart the sequence.
    /// A missing expiry leaves the saved schedule alone; zero remaining credits clear it.
    mutating func pendingCreditReminder(expiration: Double?, resetCount: Int, now: Date) -> Int? {
        guard resetCount > 0 else {
            clearCreditReminder()
            return nil
        }
        guard let expiration, expiration.isFinite, expiration > 0 else { return nil }
        if creditExpiresAt.map({ abs($0 - expiration) < 60 }) != true {
            creditExpiresAt = expiration
            sentCreditReminderLeads = []
        }
        guard let stored = creditExpiresAt else { return nil }
        let nowTS = now.timeIntervalSince1970
        guard nowTS < stored else { return nil }
        let sent = Set(sentCreditReminderLeads)
        return Self.creditReminderLeads.filter { nowTS + 1 >= stored - Double($0) && !sent.contains($0) }.min()
    }

    mutating func commitCreditReminder(_ lead: Int) {
        let sent = Set(sentCreditReminderLeads)
        sentCreditReminderLeads = Self.creditReminderLeads.filter { $0 >= lead || sent.contains($0) }
    }

    enum CodingKeys: String, CodingKey {
        case previous, wasEnabled, creditExpiresAt, sentCreditReminderLeads
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        previous = try container.decodeIfPresent(CodexResetNotificationObservation.self, forKey: .previous)
        wasEnabled = try container.decodeIfPresent(Bool.self, forKey: .wasEnabled) ?? false
        creditExpiresAt = try container.decodeIfPresent(Double.self, forKey: .creditExpiresAt)
        sentCreditReminderLeads = try container.decodeIfPresent([Int].self, forKey: .sentCreditReminderLeads) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(previous, forKey: .previous)
        try container.encode(wasEnabled, forKey: .wasEnabled)
        try container.encodeIfPresent(creditExpiresAt, forKey: .creditExpiresAt)
        try container.encode(sentCreditReminderLeads, forKey: .sentCreditReminderLeads)
    }

    mutating func evaluate(_ observation: CodexResetNotificationObservation?,
                           enabled: Bool) -> CodexResetNotificationEvent? {
        guard enabled else {
            resetBaseline()
            return nil
        }
        let current = observation.flatMap {
            CodexResetNotificationObservation.make(accountID: $0.accountID, usedPercent: $0.usedPercent,
                                                    resetsAt: $0.resetsAt, resetCount: $0.resetCount)
        }
        guard wasEnabled else {
            wasEnabled = true
            previous = current
            return nil
        }
        guard let current else { return nil }
        defer { previous = current }
        guard let previous = previous.flatMap({
            CodexResetNotificationObservation.make(accountID: $0.accountID, usedPercent: $0.usedPercent,
                                                    resetsAt: $0.resetsAt, resetCount: $0.resetCount)
        }), let accountID = current.accountID,
              previous.accountID == accountID else { return nil }
        let gifted = max(0, current.resetCount - previous.resetCount)
        let manuallyReset = current.resetCount < previous.resetCount
        // 周额度归零与重置次数变化仅作启发式判断，购买的 credits 不参与。
        // 同一窗口的重置时间常有分钟级跳动，不足 1 小时不视为新的官方周重置。
        let weekly: Bool
        if let previousUsed = previous.usedPercent, let previousReset = previous.resetsAt,
           let currentUsed = current.usedPercent, let currentReset = current.resetsAt {
            let windowMoved = abs(currentReset - previousReset) >= 3_600
            weekly = !manuallyReset && currentUsed == 0 && (previousUsed > 0 || windowMoved)
        } else {
            weekly = false
        }
        guard weekly || gifted > 0 else { return nil }
        return CodexResetNotificationEvent(weeklyReset: weekly, giftedResetCount: gifted)
    }
}
