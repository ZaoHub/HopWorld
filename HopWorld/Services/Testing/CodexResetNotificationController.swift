import Foundation
import Combine

@MainActor
final class CodexResetNotificationController: ObservableObject {
    private struct Saved: Codable {
        var settings: CodexResetNotificationSettings
        var state: CodexResetNotificationState
        var deliveryStatus: String?
    }
    @Published private(set) var settings: CodexResetNotificationSettings
    @Published private(set) var status: String
    @Published private(set) var isSending = false
    @Published private(set) var monitoringStatus = "等待成功读取用量"
    private var state: CodexResetNotificationState
    private let defaults: UserDefaults
    private let send: @Sendable (String, String) async throws -> Void
    private var sendingTask: Task<Void, Never>?
    private var generation = UUID()
    private var latestBatchID: UUID?
    private static let storageKey = "usageCard.codexResetNotifications.v1"

    init(defaults: UserDefaults = .standard,
         send: @escaping @Sendable (String, String) async throws -> Void = {
             try await IMessageSender.send(to: $0, message: $1)
         }) {
        self.defaults = defaults
        self.send = send
        let saved = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        settings = saved?.settings ?? .init()
        state = saved?.state ?? .init()
        status = saved?.deliveryStatus ?? "尚未发送通知"
        if status.hasPrefix("发送中：") {
            status = "上次发送未完成确认，可能已提交；请在“信息”中检查，未自动重试。"
        }
    }

    func apply(_ updated: CodexResetNotificationSettings) {
        guard updated.validationError == nil, updated != settings else { return }
        let deliveryChanged = updated.enabled != settings.enabled
            || Set(updated.selectedRecipients.map(\.deliveryAddress)) != Set(settings.selectedRecipients.map(\.deliveryAddress))
        if deliveryChanged {
            sendingTask?.cancel()
            generation = UUID()
            sendingTask = nil
            latestBatchID = nil
            isSending = false
        }
        if updated.enabled != settings.enabled {
            state = .init()
            status = updated.enabled ? "等待下一次成功读取，建立基线后监测变化" : "通知已关闭"
            monitoringStatus = updated.enabled ? "等待成功读取用量" : "通知已关闭"
        } else if deliveryChanged, status.hasPrefix("发送中：") {
            status = "收件人已更新；尚未提交的消息已取消，请在“信息”中检查已提交的消息。"
        }
        settings = updated
        persist()
    }

    func sendTest(using draft: CodexResetNotificationSettings) {
        guard sendingTask == nil else { return }
        var validated = draft
        validated.enabled = true
        if let error = validated.validationError {
            status = "测试发送失败：" + error
            persist()
            return
        }
        let message = "跃界 · Codex 通知测试\n这是一条手动测试 iMessage，用于检查通知发送配置。\n发送时间："
            + Date().formatted(date: .abbreviated, time: .shortened)
        enqueue(recipients: validated.selectedRecipients, message: message, isTest: true)
    }

    func observe(_ snapshot: CodexUsageSnapshot) {
        let weekly = snapshot.window(minutes: 10_080)
        let observation = snapshot.rateLimitResetCredits.flatMap { credits in
            CodexResetNotificationObservation.make(accountID: snapshot.accountID,
                usedPercent: weekly?.usedPercent, resetsAt: weekly?.resetsAt, resetCount: credits.availableCount)
        }
        observe(observation)
    }

    // Called only for successful reads; stale card data never enters the detector.
    func observe(_ observation: CodexResetNotificationObservation?) {
        let observation = observation.flatMap {
            CodexResetNotificationObservation.make(accountID: $0.accountID, usedPercent: $0.usedPercent,
                resetsAt: $0.resetsAt, resetCount: $0.resetCount)
        }
        if let previousAccount = state.previous?.accountID, let observation,
           previousAccount != observation.accountID {
            sendingTask?.cancel()
            sendingTask = nil
            latestBatchID = nil
            generation = UUID()
            isSending = false
            if status.hasPrefix("发送中：") { status = "账号已变化，尚未提交的消息已取消。" }
        }
        let event = state.evaluate(observation, enabled: settings.enabled)
        guard settings.enabled else { monitoringStatus = "通知已关闭"; persist(); return }
        guard let observation, observation.accountID != nil else {
            monitoringStatus = "等待有效的账号和可用重置次数数据"
            persist()
            return
        }
        monitoringStatus = observation.usedPercent != nil && observation.resetsAt != nil
            ? "基线已记录，正在等待下一次额度变化" : "周用量暂未获取，继续监测可用重置次数"
        guard let event else { persist(); return }
        guard settings.validationError == nil else {
            status = "请在通知设置中选择有效收件人"
            persist()
            return
        }
        enqueue(recipients: settings.selectedRecipients,
                message: Self.message(event: event, observation: observation))
    }

    private func enqueue(recipients: [CodexResetNotificationRecipient], message: String, isTest: Bool = false) {
        let sendingStatus = "发送中：" + (isTest ? "测试消息，" : "")
            + "向 \(recipients.count) 位收件人提交 iMessage"
        // Persist the transition before delivery; testing only updates delivery status.
        status = sendingStatus
        isSending = true
        persist()
        let previousTask = sendingTask
        let batchGeneration = generation
        let batchID = UUID()
        latestBatchID = batchID
        sendingTask = Task { [weak self] in
            // Serialize batches so status and Messages automation cannot race.
            await withTaskCancellationHandler {
                await previousTask?.value
            } onCancel: {
                previousTask?.cancel()
            }
            guard let self, !Task.isCancelled, self.generation == batchGeneration else { return }
            self.isSending = true
            self.status = sendingStatus
            var succeeded = 0
            var failures: [String] = []
            for recipient in recipients {
                guard !Task.isCancelled, self.generation == batchGeneration else { return }
                do {
                    try await self.send(recipient.deliveryAddress, message)
                    succeeded += 1
                } catch {
                    guard !Task.isCancelled, self.generation == batchGeneration else { return }
                    let name = recipient.nickname.isEmpty ? "未命名收件人" : recipient.nickname
                    failures.append(name + "：" + error.localizedDescription)
                }
            }
            guard !Task.isCancelled, self.generation == batchGeneration else { return }
            let time = Date().formatted(date: .abbreviated, time: .shortened)
            self.status = (isTest ? "测试发送 · " : "")
                + "\(time)：已交给“信息” \(succeeded)/\(recipients.count) 位；不代表已送达。"
            if !failures.isEmpty { self.status += "\n" + failures.joined(separator: "\n") + "\n未自动重试，请在“信息”中检查。" }
            if self.latestBatchID == batchID {
                self.sendingTask = nil
                self.isSending = false
            }
            self.persist()
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Saved(settings: settings, state: state, deliveryStatus: status)) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    private static func message(event: CodexResetNotificationEvent,
                                observation: CodexResetNotificationObservation) -> String {
        var lines = ["跃界 · Codex 用量提醒"]
        if event.weeklyReset {
            lines.append("按规则判断为官方周额度重置，周余量已恢复至 100%。")
            if let resetsAt = observation.resetsAt {
                let reset = Date(timeIntervalSince1970: resetsAt)
                lines.append("下次周重置：" + reset.formatted(date: .abbreviated, time: .shortened))
            }
        }
        if event.giftedResetCount > 0 { lines.append("按规则判断为官方赠送 \(event.giftedResetCount) 次重置。") }
        lines.append("当前可用重置：\(observation.resetCount) 次。")
        lines.append("依据相邻成功读取的数据判断；重置次数减少按手动重置处理。")
        return lines.joined(separator: "\n")
    }
}
