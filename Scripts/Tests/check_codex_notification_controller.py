#!/usr/bin/env python3
"""Exercise the production controller using local snapshots and a mock sender."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
card = (root / "HopWorld/Views/Testing/CodexUsageCard.swift").read_text()
snapshot_source = card[:card.index("/// Uses the local Codex login")]
fixture = r'''
import Foundation

struct FixtureFailure: LocalizedError {
    var errorDescription: String? { "本地模拟失败" }
}

actor Deliveries {
    var values: [(String, String)] = []
    var fail = false
    var blockFirst = false
    var cancellations = 0
    private var releaseFirst: CheckedContinuation<Void, Never>?
    var count: Int { values.count }
    init(fail: Bool = false, blockFirst: Bool = false) {
        self.fail = fail
        self.blockFirst = blockFirst
    }
    func send(_ address: String, _ message: String) async throws {
        values.append((address, message))
        if blockFirst && values.count == 1 {
            await withTaskCancellationHandler {
                await withCheckedContinuation { releaseFirst = $0 }
            } onCancel: {
                Task { await self.recordCancellation() }
            }
        }
        if fail { throw FixtureFailure() }
    }
    func release() { releaseFirst?.resume(); releaseFirst = nil }
    private func recordCancellation() { cancellations += 1 }
}

@main struct Checks {
    @MainActor static var checks = 0
    @MainActor static func check(_ value: Bool, _ message: String) {
        checks += 1
        precondition(value, message)
    }
    @MainActor static func wait(_ condition: () async -> Bool) async {
        for _ in 0..<500 {
            if await condition() { return }
            try! await Task.sleep(nanoseconds: 2_000_000)
        }
        preconditionFailure("Timed out waiting for local controller fixture")
    }
    @MainActor static func pause() async { try! await Task.sleep(nanoseconds: 30_000_000) }

    static func sample(_ used: Double, reset: Double = 2_000_000_000,
                       count: Int? = 1, account: String? = "account-a",
                       weeklyMinutes: Int = 10_080) -> CodexUsageSnapshot {
        var object: [String: Any] = ["rateLimits": ["secondary": [
            "usedPercent": used, "windowDurationMins": weeklyMinutes, "resetsAt": reset
        ]]]
        if let count { object["rateLimitResetCredits"] = ["availableCount": count] }
        if let account { object["accountID"] = account }
        return try! JSONDecoder().decode(CodexUsageSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object))
    }

    static func settings(enabled: Bool = true) -> CodexResetNotificationSettings {
        .init(enabled: enabled, recipients: [
            .init(nickname: "主账号", address: "fixture@example.com"),
            .init(nickname: "相同账号", address: "FIXTURE@EXAMPLE.COM"),
            .init(nickname: "另一个账号", address: "+86 138-0013-8000"),
            .init(nickname: "未选账号", address: "unused@example.com", isSelected: false)
        ])
    }

    @MainActor static func batches(_ defaults: UserDefaults) async {
        let deliveries = Deliveries()
        let controller = CodexResetNotificationController(defaults: defaults,
            send: { try await deliveries.send($0, $1) })
        controller.apply(.init(enabled: true))
        check(!controller.settings.enabled, "Invalid settings must not replace saved configuration")
        controller.apply(settings())
        controller.observe(sample(0))
        await pause()
        let baselineCount = await deliveries.count
        check(baselineCount == 0, "First enabled sample at 100% only establishes a baseline")
        controller.observe(sample(40))
        controller.observe(sample(40, count: 3))
        await wait { !controller.isSending && controller.status.contains("2/2") }
        let gifts = await deliveries.values
        check(gifts.count == 2, "Selected normalized recipient addresses are sent once each")
        check(gifts.map(\.0) == ["fixture@example.com", "+8613800138000"], "Unselected and duplicate recipients are excluded")
        check(gifts[0].1.contains("赠送 2 次") && !gifts[0].1.contains("周余量已恢复"), "A gift is independent from weekly recovery")
        check(controller.status.contains("不代表已送达"), "Result must describe Messages acceptance rather than delivery")
        controller.observe(sample(40, count: 3))
        await pause()
        let duplicateCount = await deliveries.count
        check(duplicateCount == 2, "Repeated successful snapshots do not resend gifts")
        controller.observe(sample(0, count: 3))
        await wait { await deliveries.count == 4 }
        await wait { !controller.isSending }
        let weekly = await deliveries.values
        check(weekly[2].1.contains("周余量已恢复至 100%"), "Weekly recovery at an unchanged reset timestamp is sent")
        controller.observe(sample(10, count: 3))
        controller.observe(sample(0, reset: 2_000_604_800, count: 4))
        await wait { await deliveries.count == 6 }
        await wait { !controller.isSending }
        let combined = await deliveries.values
        check(combined[4].1.contains("赠送 1 次") && combined[4].1.contains("周余量已恢复"), "Simultaneous gift and weekly reset form one batch")
        controller.observe(sample(0, reset: 2_000_000_002, count: 3))
        await pause()
        let manualCount = await deliveries.count
        check(manualCount == 6, "A decreasing reset count suppresses weekly notifications")

        let restored = CodexResetNotificationController(defaults: defaults,
            send: { try await deliveries.send($0, $1) })
        check(restored.settings == controller.settings, "Recipient nicknames and selections persist")
        restored.observe(sample(0, reset: 2_000_000_002, count: 3))
        await pause()
        let restoredCount = await deliveries.count
        check(restoredCount == 6, "Reconstructing from defaults does not resend a consumed transition")
        restored.observe(sample(0, reset: 2_000_604_802, count: 3))
        await wait { await deliveries.count == 8 }
        await wait { !restored.isSending }
        check(restored.status.contains("2/2"), "A changed reset timestamp at 100% sends after restoration")
    }

    @MainActor static func failures(_ defaults: UserDefaults) async {
        let deliveries = Deliveries(fail: true)
        let controller = CodexResetNotificationController(defaults: defaults,
            send: { try await deliveries.send($0, $1) })
        controller.apply(settings())
        controller.observe(sample(30))
        controller.observe(sample(0))
        await wait { controller.status.contains("未自动重试") }
        check(controller.status.contains("0/2") && controller.status.contains("本地模拟失败"), "Per-recipient failures are visible in status")
        controller.observe(sample(0))
        await pause()
        let count = await deliveries.count
        check(count == 2, "Failed sends have no automatic retry")
        let restored = CodexResetNotificationController(defaults: defaults,
            send: { try await deliveries.send($0, $1) })
        check(restored.status == controller.status, "Last delivery result persists")
        restored.observe(sample(0))
        await pause()
        let restoredCount = await deliveries.count
        check(restoredCount == 2, "A failed transition stays consumed after reconstruction")
    }

    @MainActor static func baselines(_ defaults: UserDefaults) async {
        let deliveries = Deliveries()
        let controller = CodexResetNotificationController(defaults: defaults,
            send: { try await deliveries.send($0, $1) })
        controller.apply(settings())
        controller.observe(sample(25))
        controller.observe(sample(0, count: nil))
        controller.observe(CodexResetNotificationObservation(accountID: "account-a", usedPercent: -1,
            resetsAt: 2_000_000_000, resetCount: 10))
        await pause()
        let invalidCount = await deliveries.count
        check(invalidCount == 0, "Missing or invalid successful fields never send")
        controller.observe(sample(0))
        await wait { await deliveries.count == 2 }
        await wait { !controller.isSending }
        check(controller.status.contains("2/2"), "Invalid samples preserve the last valid baseline")
        var disabled = controller.settings
        disabled.enabled = false
        controller.apply(disabled)
        controller.observe(sample(20, count: 3))
        var enabled = disabled
        enabled.enabled = true
        controller.apply(enabled)
        controller.observe(sample(0, reset: 2_000_000_100, count: 5))
        await pause()
        let reenabledCount = await deliveries.count
        check(reenabledCount == 2, "Re-enabling waits for a fresh baseline instead of replaying disabled changes")
        controller.observe(sample(0, reset: 2_000_000_101, count: 5, account: "account-b"))
        await pause()
        let switchedCount = await deliveries.count
        check(switchedCount == 2, "Switching accounts establishes a separate baseline")
        controller.observe(sample(0, reset: 2_000_604_800, count: 5, account: "account-b"))
        await wait { await deliveries.count == 4 }
        await wait { !controller.isSending }
        controller.observe(sample(0, reset: 2_000_000_103, count: 7, account: nil))
        await pause()
        let missingAccountCount = await deliveries.count
        check(missingAccountCount == 4, "Unknown account identity cannot send")
    }

    @MainActor static func cancellation(_ defaults: UserDefaults) async {
        let deliveries = Deliveries(blockFirst: true)
        let controller = CodexResetNotificationController(defaults: defaults,
            send: { try await deliveries.send($0, $1) })
        controller.apply(settings())
        controller.observe(sample(20))
        controller.observe(sample(0))
        await wait { await deliveries.count == 1 }
        check(controller.isSending, "An active batch exposes busy state")
        var disabled = controller.settings
        disabled.enabled = false
        controller.apply(disabled)
        await deliveries.release()
        await pause()
        let cancelledCount = await deliveries.count
        check(cancelledCount == 1, "Disabling stops remaining recipients after the in-flight submission")
        check(!controller.isSending && controller.status == "通知已关闭", "A stale cancelled batch cannot overwrite disabled status")
        var enabled = disabled
        enabled.enabled = true
        controller.apply(enabled)
        controller.observe(sample(0))
        controller.observe(sample(0, count: 2))
        await wait { await deliveries.count == 3 }
        await wait { !controller.isSending }
        check(controller.status.contains("2/2"), "A new generation can send after cancellation")
    }

    @MainActor static func queuedCancellation(_ defaults: UserDefaults) async {
        let deliveries = Deliveries(blockFirst: true)
        let controller = CodexResetNotificationController(defaults: defaults,
            send: { try await deliveries.send($0, $1) })
        controller.apply(settings())
        controller.observe(sample(20))
        controller.observe(sample(0))
        await wait { await deliveries.count == 1 }
        // Batch B waits for blocked A; cancelling B must propagate to A.
        controller.observe(sample(0, reset: 2_000_000_001, count: 2))
        var disabled = controller.settings
        disabled.enabled = false
        controller.apply(disabled)
        await wait { await deliveries.cancellations == 1 }
        let countBeforeRelease = await deliveries.count
        check(countBeforeRelease == 1, "Cancelling a queued batch also cancels the active sender")
        await deliveries.release()
        await pause()
        let countAfterRelease = await deliveries.count
        check(countAfterRelease == 1, "Neither queued nor active batch submits remaining recipients after disable")
        check(!controller.isSending && controller.status == "通知已关闭", "Queued cancellation cannot overwrite the closed status")
    }

    @MainActor static func renameDuringSend(_ defaults: UserDefaults) async {
        let deliveries = Deliveries(blockFirst: true)
        let controller = CodexResetNotificationController(defaults: defaults,
            send: { try await deliveries.send($0, $1) })
        controller.apply(settings())
        controller.observe(sample(20))
        controller.observe(sample(0))
        await wait { await deliveries.count == 1 }
        var renamed = controller.settings
        renamed.recipients[0].nickname = "新昵称"
        controller.apply(renamed)
        await pause()
        let cancellations = await deliveries.cancellations
        check(cancellations == 0 && controller.isSending, "A nickname edit leaves the active batch running")
        await deliveries.release()
        await wait { await deliveries.count == 2 }
        await wait { !controller.isSending }
        check(controller.settings.recipients[0].nickname == "新昵称" && controller.status.contains("2/2"), "Nickname edits persist while the original batch completes")
    }

    @MainActor static func giftsWithoutWeekly(_ defaults: UserDefaults) async {
        let deliveries = Deliveries()
        let controller = CodexResetNotificationController(defaults: defaults,
            send: { try await deliveries.send($0, $1) })
        controller.apply(settings())
        controller.observe(sample(20, weeklyMinutes: 300))
        controller.observe(sample(0, count: 3, weeklyMinutes: 300))
        await wait { await deliveries.count == 2 }
        await wait { !controller.isSending }
        let values = await deliveries.values
        check(values[0].1.contains("赠送 2 次") && !values[0].1.contains("周余量已恢复"), "Gift notifications need no weekly window fields")
        check(controller.monitoringStatus.contains("周用量暂未获取"), "Missing weekly data leaves reset-count monitoring active")
        controller.observe(sample(0, count: 3))
        await pause()
        let count = await deliveries.count
        check(count == 2, "Restored weekly fields establish their baseline without replaying the gift")
    }

    @MainActor static func testSendingDraft(_ defaults: UserDefaults) async {
        let deliveries = Deliveries()
        let controller = CodexResetNotificationController(defaults: defaults,
            send: { try await deliveries.send($0, $1) })
        let saved = CodexResetNotificationSettings(enabled: false, recipients: [
            .init(nickname: "已保存", address: "saved@example.com")
        ])
        controller.apply(saved)
        let draft = settings(enabled: false)
        controller.sendTest(using: draft)
        await wait { await deliveries.count == 2 }
        await wait { !controller.isSending }
        let tested = await deliveries.values
        check(tested.map(\.0) == ["fixture@example.com", "+8613800138000"], "A disabled unsaved draft can test selected normalized unique recipients")
        check(tested.allSatisfy { $0.1.contains("测试") }, "Every manual test message is explicitly labelled as a test")
        check(controller.settings == saved && !controller.settings.enabled, "Testing neither enables automation nor saves the draft")
        let restored = CodexResetNotificationController(defaults: defaults,
            send: { try await deliveries.send($0, $1) })
        check(restored.settings == saved && restored.settings.recipients[0].address == "saved@example.com", "Persisted settings keep the saved recipients after a draft test")

        var enabled = saved
        enabled.enabled = true
        controller.apply(enabled)
        controller.sendTest(using: draft)
        await wait { await deliveries.count == 4 }
        await wait { !controller.isSending }
        controller.observe(sample(0))
        await pause()
        let firstObservationCount = await deliveries.count
        check(firstObservationCount == 4, "Testing before the first observation does not create or consume a monitoring baseline")
        controller.observe(sample(25))
        controller.sendTest(using: draft)
        await wait { await deliveries.count == 6 }
        await wait { !controller.isSending }
        controller.observe(sample(0, count: 2))
        await wait { await deliveries.count == 7 }
        await wait { !controller.isSending }
        let actual = await deliveries.values
        check(actual[6].0 == "saved@example.com" && actual[6].1.contains("周余量已恢复") && !actual[6].1.contains("测试"), "Testing between observations leaves real events and saved delivery targets intact")
    }

    @MainActor static func invalidTestDrafts(_ defaults: UserDefaults) async {
        let deliveries = Deliveries()
        let controller = CodexResetNotificationController(defaults: defaults,
            send: { try await deliveries.send($0, $1) })
        controller.sendTest(using: .init(enabled: false))
        await pause()
        let emptyCount = await deliveries.count
        check(emptyCount == 0 && controller.status.contains("收件人"), "Manual tests reject an empty selection even with automation disabled")
        let invalid = CodexResetNotificationSettings(enabled: false, recipients: [
            .init(nickname: "错误账号", address: "bad@")
        ])
        controller.sendTest(using: invalid)
        await pause()
        let invalidCount = await deliveries.count
        check(invalidCount == 0 && controller.status.contains("邮箱"), "Manual tests validate selected draft addresses before calling the sender")
        check(controller.settings == .init(), "Rejected test drafts never alter saved configuration")
    }

    @MainActor static func repeatedTestClick(_ defaults: UserDefaults) async {
        let deliveries = Deliveries(blockFirst: true)
        let controller = CodexResetNotificationController(defaults: defaults,
            send: { try await deliveries.send($0, $1) })
        let draft = settings(enabled: false)
        controller.sendTest(using: draft)
        controller.sendTest(using: draft)
        await wait { await deliveries.count == 1 }
        controller.sendTest(using: draft)
        await pause()
        let blockedCount = await deliveries.count
        check(blockedCount == 1 && controller.isSending, "Rapid repeated test clicks cannot queue additional batches")
        await deliveries.release()
        await wait { await deliveries.count == 2 }
        await wait { !controller.isSending }
        await pause()
        let completedCount = await deliveries.count
        check(completedCount == 2 && controller.status.contains("2/2"), "Only one test batch completes after duplicate clicks")
    }

    @MainActor static func failedTestSend(_ defaults: UserDefaults) async {
        let deliveries = Deliveries(fail: true)
        let controller = CodexResetNotificationController(defaults: defaults,
            send: { try await deliveries.send($0, $1) })
        controller.sendTest(using: settings(enabled: false))
        await wait { controller.status.contains("未自动重试") }
        let failedCount = await deliveries.count
        check(failedCount == 2 && controller.status.contains("0/2") && controller.status.contains("本地模拟失败"), "Manual test failures show per-recipient results without retrying")
        check(controller.settings == .init(), "Failed test delivery also leaves saved settings unchanged")
    }

    @MainActor static func observingDuringTest(_ defaults: UserDefaults) async {
        let deliveries = Deliveries(blockFirst: true)
        let controller = CodexResetNotificationController(defaults: defaults,
            send: { try await deliveries.send($0, $1) })
        let draft = settings(enabled: false)
        controller.sendTest(using: draft)
        await wait { await deliveries.count == 1 }
        controller.observe(sample(0, count: 3))
        await pause()
        let cancelled = await deliveries.cancellations
        check(cancelled == 0 && controller.isSending, "A first fresh observation while automation is disabled does not cancel a manual test")
        await deliveries.release()
        await wait { await deliveries.count == 2 }
        await wait { !controller.isSending }
        controller.sendTest(using: draft)
        await wait { await deliveries.count == 4 }
        await wait { !controller.isSending }
        check(controller.status.contains("测试发送") && controller.settings == .init(), "The completed test clears its task and allows another unsaved draft test")
        let data = defaults.data(forKey: "usageCard.codexResetNotifications.v1")!
        let saved = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let state = saved["state"] as! [String: Any]
        check(state["previous"] == nil && state["wasEnabled"] as? Bool == false, "Observations and tests while automation is disabled leave monitoring without a baseline")
    }

    @MainActor static func accountSwitchDuringTest(_ defaults: UserDefaults) async {
        let deliveries = Deliveries(blockFirst: true)
        let controller = CodexResetNotificationController(defaults: defaults,
            send: { try await deliveries.send($0, $1) })
        controller.apply(settings())
        controller.observe(sample(25))
        controller.sendTest(using: settings(enabled: false))
        await wait { await deliveries.count == 1 }
        controller.observe(sample(0, count: 3, account: "account-b"))
        await wait { await deliveries.cancellations == 1 }
        check(!controller.isSending, "A known account change cancels an active test batch")
        controller.sendTest(using: settings(enabled: false))
        await wait { await deliveries.count == 3 }
        await wait { !controller.isSending }
        check(controller.status.contains("测试发送"), "Account-switch cancellation clears the task pointer so a new manual test can start")
        await deliveries.release()
        await pause()
        let completedCount = await deliveries.count
        check(completedCount == 3 && controller.status.contains("2/2"), "The cancelled test submits no remaining recipients and cannot overwrite its successor")
    }

    @MainActor static func main() async {
        let suite = "HopWorldNotificationControllerChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        await batches(defaults)
        defaults.removePersistentDomain(forName: suite)
        await failures(defaults)
        defaults.removePersistentDomain(forName: suite)
        await baselines(defaults)
        defaults.removePersistentDomain(forName: suite)
        await cancellation(defaults)
        defaults.removePersistentDomain(forName: suite)
        await queuedCancellation(defaults)
        defaults.removePersistentDomain(forName: suite)
        await renameDuringSend(defaults)
        defaults.removePersistentDomain(forName: suite)
        await giftsWithoutWeekly(defaults)
        defaults.removePersistentDomain(forName: suite)
        await testSendingDraft(defaults)
        defaults.removePersistentDomain(forName: suite)
        await invalidTestDrafts(defaults)
        defaults.removePersistentDomain(forName: suite)
        await repeatedTestClick(defaults)
        defaults.removePersistentDomain(forName: suite)
        await failedTestSend(defaults)
        defaults.removePersistentDomain(forName: suite)
        await observingDuringTest(defaults)
        defaults.removePersistentDomain(forName: suite)
        await accountSwitchDuringTest(defaults)
        print("Codex notification controller: \(checks) checks, 0 failures; mock sends only")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="hopworld-notification-controller-") as directory:
    path = Path(directory)
    snapshot = path / "Snapshot.swift"
    snapshot.write_text(snapshot_source)
    source = path / "Check.swift"
    source.write_text(fixture)
    binary = path / "check"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", str(snapshot),
        str(root / "HopWorld/Models/CodexResetNotification.swift"),
        str(root / "HopWorld/Services/Testing/CodexResetNotificationController.swift"),
        str(root / "HopWorld/Services/System/IMessageSender.swift"),
        str(root / "HopWorld/Utilities/ProcessRunner.swift"), str(source), "-o", str(binary)
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
