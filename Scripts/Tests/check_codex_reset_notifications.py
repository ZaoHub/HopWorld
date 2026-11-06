#!/usr/bin/env python3
"""Exercise Codex reset notification decisions without accounts or Messages access."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
fixture = r'''
import Foundation

@main struct Checks {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        count += 1
        precondition(condition(), message)
    }
    static func sample(_ used: Double, at: Double = 2_000_000_000, resets: Int = 2,
                       account: String? = "account-a") -> CodexResetNotificationObservation {
        CodexResetNotificationObservation.make(accountID: account, usedPercent: used,
                                               resetsAt: at, resetCount: resets)!
    }
    static func main() throws {
        var state = CodexResetNotificationState()
        check(state.evaluate(sample(0), enabled: true) == nil, "First sample only establishes a baseline")
        check(state.evaluate(sample(0), enabled: true) == nil, "Identical samples never repeat notifications")
        check(state.evaluate(sample(10), enabled: true) == nil, "Spending quota is silent")
        check(state.evaluate(sample(0), enabled: true) == .init(weeklyReset: true, giftedResetCount: 0),
              "An off-schedule return to exactly 100% remaining is a weekly reset heuristic")
        check(state.evaluate(sample(0), enabled: true) == nil, "A weekly event is delivered once")
        check(state.evaluate(sample(0, at: 2_000_000_060), enabled: true) == nil,
              "A one-minute reset-time jitter at 100% remaining is the same weekly window")
        check(state.evaluate(sample(0, at: 2_000_000_000 + 7 * 24 * 3_600), enabled: true) == .init(weeklyReset: true, giftedResetCount: 0),
              "A week-sized reset-time move at 100% remaining detects an idle weekly reset")
        check(state.evaluate(sample(0, at: 2_000_000_000 + 7 * 24 * 3_600), enabled: true) == nil, "Changed-time event deduplicates")
        check(state.evaluate(sample(1, at: 2_000_000_002), enabled: true) == nil,
              "A changed reset timestamp below 100% remaining is insufficient")
        check(state.evaluate(sample(0.0001), enabled: true) == nil, "Nearly 100% must not round into a reset")
        check(state.evaluate(sample(0), enabled: true)?.weeklyReset == true, "Exactly zero used is required")

        _ = state.evaluate(sample(60, resets: 5), enabled: true)
        check(state.evaluate(sample(0, at: 2_000_000_100, resets: 4), enabled: true) == nil,
              "A consumed reset credit suppresses a manual reset even when time changes")
        check(state.evaluate(sample(0, at: 2_000_000_100, resets: 4), enabled: true) == nil,
              "Manual resets also advance the baseline")
        check(state.evaluate(sample(20, resets: 6), enabled: true) == .init(weeklyReset: false, giftedResetCount: 2),
              "Gifted resets notify independently of weekly remaining quota")
        check(state.evaluate(sample(0, resets: 8), enabled: true) == .init(weeklyReset: true, giftedResetCount: 2),
              "Coincident weekly resets and gifts are a single event")
        check(state.evaluate(sample(0, resets: 8), enabled: true) == nil, "A combined event deduplicates")

        _ = state.evaluate(sample(30), enabled: true)
        check(state.evaluate(sample(0), enabled: false) == nil && state.previous == nil,
              "Disabling clears the baseline")
        check(state.evaluate(sample(0, resets: 9), enabled: true) == nil, "Re-enabling does not report old events")
        _ = state.evaluate(sample(20, resets: 9), enabled: true)
        state.resetBaseline()
        check(state.evaluate(sample(0, resets: 10), enabled: true) == nil, "Explicit recipient changes can reset the baseline")
        check(state.evaluate(sample(0, resets: 12, account: "account-b"), enabled: true) == nil,
              "Account changes establish a new baseline")
        check(state.evaluate(sample(40, resets: 12, account: "account-b"), enabled: true) == nil, "The new account is scoped")
        check(state.evaluate(sample(0, resets: 12, account: "account-b"), enabled: true)?.weeklyReset == true,
              "Only changes within an identified account notify")
        check(state.evaluate(sample(20, resets: 12, account: nil), enabled: true) == nil, "Unknown account is silent")
        check(state.evaluate(sample(0, resets: 15, account: nil), enabled: true) == nil, "Unknown account never emits gifts")
        check(state.evaluate(sample(0, resets: 20, account: "account-a"), enabled: true) == nil,
              "Returning to a known account after unknown scope starts a baseline")

        var empty = CodexResetNotificationState()
        check(empty.evaluate(nil, enabled: true) == nil, "Missing initial data is silent")
        check(empty.evaluate(sample(0), enabled: true) == nil, "First valid observation after missing data is a baseline")
        check(empty.evaluate(nil, enabled: true) == nil && empty.previous == sample(0),
              "A failed refresh neither notifies nor replaces the last valid observation")
        var partial = CodexResetNotificationState()
        let countOnly = CodexResetNotificationObservation.make(accountID: "account-a", usedPercent: nil,
            resetsAt: nil, resetCount: 2)!
        let countGift = CodexResetNotificationObservation.make(accountID: "account-a", usedPercent: nil,
            resetsAt: nil, resetCount: 4)!
        check(partial.evaluate(countOnly, enabled: true) == nil, "Counts alone establish a gift baseline")
        check(partial.evaluate(countGift, enabled: true) == .init(weeklyReset: false, giftedResetCount: 2),
              "Gift notifications remain available without weekly quota or timestamp")
        check(partial.evaluate(sample(0, resets: 4), enabled: true) == nil,
              "Recovering complete weekly data establishes its own baseline")
        check(partial.evaluate(sample(0, at: 2_000_000_000 + 7 * 24 * 3_600, resets: 4), enabled: true)?.weeklyReset == true,
              "A later weekly window at 100% remaining is a weekly reset")
        _ = partial.evaluate(sample(40, resets: 4), enabled: true)
        let manualMissingTime = CodexResetNotificationObservation.make(accountID: "account-a", usedPercent: 0,
            resetsAt: nil, resetCount: 3)!
        check(partial.evaluate(manualMissingTime, enabled: true) == nil, "A manual reset without a timestamp is silent")
        check(partial.evaluate(sample(0, resets: 3), enabled: true) == nil,
              "A timestamp returning after a manual reset cannot fabricate a weekly event")
        let missingUsed = CodexResetNotificationObservation.make(accountID: "account-a", usedPercent: nil,
            resetsAt: 2_000_000_100, resetCount: 5)!
        check(partial.evaluate(missingUsed, enabled: true) == .init(weeklyReset: false, giftedResetCount: 2),
              "Gifts notify when only the weekly percentage is missing")
        check(partial.evaluate(sample(0, at: 2_000_000_100, resets: 5), enabled: true) == nil,
              "A percentage returning cannot infer a weekly transition across a partial sample")
        for used in [-1.0, 100.1, Double.nan, Double.infinity, -Double.infinity] {
            check(CodexResetNotificationObservation.make(accountID: "a", usedPercent: used, resetsAt: 1, resetCount: 0) == nil,
                  "Invalid percentages are rejected")
        }
        for resetTime in [0.0, -1, Double.nan, Double.infinity] {
            check(CodexResetNotificationObservation.make(accountID: "a", usedPercent: 0, resetsAt: resetTime, resetCount: 0) == nil,
                  "Invalid reset timestamps are rejected")
        }
        check(CodexResetNotificationObservation.make(accountID: "a", usedPercent: 0, resetsAt: 1, resetCount: -1) == nil,
              "Negative reset count is rejected")
        check(sample(0, account: " \n").accountID == nil, "Blank account identifiers stay unknown")
        check(sample(0, account: " account-a ").accountID == "account-a", "Account scope is trimmed")

        let encoded = try JSONEncoder().encode(state)
        var restored = try JSONDecoder().decode(CodexResetNotificationState.self, from: encoded)
        check(restored == state, "The account and previous observation survive persistence")
        check(restored.evaluate(sample(0, resets: 20), enabled: true) == nil, "Restart does not repeat the last event")
        check(restored.evaluate(sample(0, resets: 21), enabled: true)?.giftedResetCount == 1, "Persisted state sees the next gift")
        let corrupt = Data(#"{"wasEnabled":true,"previous":{"accountID":"account-a","usedPercent":10,"resetsAt":1,"resetCount":-9223372036854775808}}"#.utf8)
        var recovered = try JSONDecoder().decode(CodexResetNotificationState.self, from: corrupt)
        check(recovered.evaluate(sample(0), enabled: true) == nil, "Invalid persisted baselines cannot notify or overflow")
        let invalid = try JSONDecoder().decode(CodexResetNotificationObservation.self,
            from: Data(#"{"accountID":"account-a","usedPercent":-1,"resetsAt":1,"resetCount":2}"#.utf8))
        check(restored.evaluate(invalid, enabled: true) == nil, "Decoded observations are validated again at evaluation")

        let expires = 2_000_000_000.0
        var credits = CodexResetNotificationState()
        func remind(_ offset: TimeInterval, _ expected: Int?, _ message: String) {
            let lead = credits.pendingCreditReminder(expiration: expires, resetCount: 3,
                                                     now: Date(timeIntervalSince1970: expires - offset))
            check(lead == expected, message)
        }
        remind(86_400 + 60, nil, "More than a day before expiry stays quiet")
        remind(86_400, 86_400, "One day before expiry reminds once")
        credits.commitCreditReminder(86_400)
        remind(86_400 - 60, nil, "The one-day reminder does not repeat inside its window")
        remind(4 * 3_600, 18_000, "Five hours before expiry reminds without replaying the day reminder")
        credits.commitCreditReminder(18_000)
        remind(2 * 3_600, 10_800, "Three hours before expiry reminds")
        credits.commitCreditReminder(10_800)
        remind(20 * 60, 1_800, "Thirty minutes before expiry reminds")
        credits.commitCreditReminder(1_800)
        remind(4 * 60, 300, "Five minutes before expiry reminds")
        credits.commitCreditReminder(300)
        remind(60, nil, "A sent five-minute reminder does not repeat")
        remind(-1, nil, "After expiry there is no reminder")
        let shifted = credits.pendingCreditReminder(expiration: expires + 30, resetCount: 3,
                                                    now: Date(timeIntervalSince1970: expires - 4 * 60))
        check(shifted == nil, "A thirty-second expiry jitter is the same credit")
        check(credits.pendingCreditReminder(expiration: expires + 2 * 86_400, resetCount: 3,
                                            now: Date(timeIntervalSince1970: expires + 2 * 86_400 - 10_800)) == 10_800,
              "A new expiry starts its own reminder sequence")
        check(credits.pendingCreditReminder(expiration: expires, resetCount: 0,
                                            now: Date(timeIntervalSince1970: expires - 300)) == nil,
              "Zero remaining credits clear the expiry reminder")
        var late = CodexResetNotificationState()
        check(late.pendingCreditReminder(expiration: expires, resetCount: 2,
                                         now: Date(timeIntervalSince1970: expires - 4 * 3_600)) == 18_000,
              "A late first read sends only the closest due reminder")
        late.commitCreditReminder(18_000)
        check(late.pendingCreditReminder(expiration: expires, resetCount: 2,
                                         now: Date(timeIntervalSince1970: expires - 4 * 3_600)) == nil,
              "Catch-up marks the earlier day reminder as sent")
        check(late.pendingCreditReminder(expiration: nil, resetCount: 2,
                                         now: Date(timeIntervalSince1970: expires - 3 * 3_600)) == nil
              && late.creditExpiresAt == expires,
              "A read without an expiry keeps the saved reminder")
        check(late.pendingCreditReminder(expiration: expires, resetCount: 2,
                                         now: Date(timeIntervalSince1970: expires - 3 * 3_600)) == 10_800,
              "The next complete read still sends the three-hour reminder")

        let phone = CodexResetNotificationRecipient(nickname: "手机", address: " +86 (138) 0013-8000 ")
        let samePhone = CodexResetNotificationRecipient(nickname: "重复", address: "+8613800138000")
        let email = CodexResetNotificationRecipient(nickname: "邮箱", address: " Example+tag@iCloud.com ")
        let sameEmail = CodexResetNotificationRecipient(nickname: "重复邮箱", address: "example+tag@icloud.com")
        check(phone.addressValidationError == nil && phone.deliveryAddress == "+8613800138000", "Phone numbers normalize")
        check(email.addressValidationError == nil && email.deliveryAddress == "example+tag@icloud.com", "Emails normalize")
        for address in ["", " ", "abc", "123", "+1234567890123456", "123+456789", "++123456789", "1234567\n8",
                        "a@", "a@@b.com", "a b@c.com", "a@localhost", "a@.com", "a@-b.com", ".a@b.com", "a..b@c.com"] {
            check(CodexResetNotificationRecipient(nickname: "", address: address).addressValidationError != nil,
                  "Malformed recipient address must be rejected: \(address)")
        }
        var settings = CodexResetNotificationSettings(enabled: true, recipients: [phone, samePhone, email, sameEmail])
        check(settings.validationError == nil && settings.selectedRecipients.map(\.id) == [phone.id, email.id],
              "Selected recipients deduplicate normalized addresses in display order")
        settings.recipients[0].isSelected = false
        check(settings.selectedRecipients.first?.id == samePhone.id, "Unselected recipients do not suppress selected duplicates")
        settings.recipients.append(.init(nickname: "无效号码", address: "bad", isSelected: false))
        check(settings.validationError == nil, "Unselected incomplete drafts do not block sending")
        settings.recipients[4].isSelected = true
        check(settings.validationError?.contains("无效号码") == true, "Selected invalid recipients have an actionable named error")
        check(CodexResetNotificationSettings(enabled: true).validationError != nil, "Enabled notifications need a selected recipient")
        check(CodexResetNotificationSettings().validationError == nil, "Notifications default to disabled")
        let restoredSettings = try JSONDecoder().decode(CodexResetNotificationSettings.self, from: JSONEncoder().encode(settings))
        check(restoredSettings == settings, "Recipient identities, selections and settings persist")
        print("Codex reset notifications: \(count) checks, 0 failures; no real accounts or Messages access")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="hopworld-reset-notification-") as temporary:
    directory = Path(temporary)
    source = directory / "Checks.swift"
    source.write_text(fixture)
    binary = directory / "checks"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library",
                    str(root / "HopWorld/Models/CodexResetNotification.swift"), str(source),
                    "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
