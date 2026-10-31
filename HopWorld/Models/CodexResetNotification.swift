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

    static func make(accountID: String?, usedPercent: Double?, resetsAt: Double?,
                     resetCount: Int) -> Self? {
        guard resetCount >= 0 else { return nil }
        if let usedPercent {
            guard usedPercent.isFinite, (0...100).contains(usedPercent) else { return nil }
        }
        if let resetsAt {
            guard resetsAt.isFinite, resetsAt > 0 else { return nil }
        }
        let account = accountID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(accountID: account.flatMap { $0.isEmpty ? nil : $0 },
                    usedPercent: usedPercent, resetsAt: resetsAt, resetCount: resetCount)
    }
}

struct CodexResetNotificationEvent: Equatable {
    let weeklyReset: Bool
    let giftedResetCount: Int
}

struct CodexResetNotificationState: Codable, Equatable {
    private(set) var previous: CodexResetNotificationObservation?
    private var wasEnabled = false

    mutating func resetBaseline() {
        previous = nil
        wasEnabled = false
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
        let weekly: Bool
        if let previousUsed = previous.usedPercent, let previousReset = previous.resetsAt,
           let currentUsed = current.usedPercent, let currentReset = current.resetsAt {
            weekly = !manuallyReset && currentUsed == 0 && (previousUsed > 0 || currentReset != previousReset)
        } else {
            weekly = false
        }
        guard weekly || gifted > 0 else { return nil }
        return CodexResetNotificationEvent(weeklyReset: weekly, giftedResetCount: gifted)
    }
}
