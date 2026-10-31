import Foundation

@main
struct SubscriptionCleanupHistoryCheck {
    static func main() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = ISO8601DateFormatter().date(from: "2026-10-12T04:00:00Z")!
        let start = calendar.startOfDay(for: now)
        var sub = Subscription(name: "fixture", originalURL: "https://example.com")
        assert(sub.automaticCleanupCountToday(now: now, calendar: calendar) == 0)
        sub.cleanupHistory = [
            SubscriptionCleanupRecord(cleanedAt: start, automatic: true, removedCount: 3),
            SubscriptionCleanupRecord(cleanedAt: now, automatic: true, removedCount: 4),
            SubscriptionCleanupRecord(cleanedAt: now, automatic: false, removedCount: 20),
            SubscriptionCleanupRecord(cleanedAt: start.addingTimeInterval(-1), automatic: true, removedCount: 9),
            SubscriptionCleanupRecord(cleanedAt: start.addingTimeInterval(86400), automatic: true, removedCount: 8)
        ]
        assert(sub.automaticCleanupCountToday(now: now, calendar: calendar) == 7)
        let encoded = try JSONEncoder().encode(sub)
        let decoded = try JSONDecoder().decode(Subscription.self, from: encoded)
        assert(decoded.cleanupHistory == sub.cleanupHistory)
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "cleanupHistory")
        let old = try JSONDecoder().decode(Subscription.self, from: JSONSerialization.data(withJSONObject: legacy))
        assert(old.cleanupHistory == nil)

        let today = SubscriptionCleanupRecord(cleanedAt: now, automatic: true, removedCount: 2)
        let manual = SubscriptionCleanupRecord(cleanedAt: start, automatic: false, removedCount: 3)
        let firstOf7 = SubscriptionCleanupRecord(cleanedAt: calendar.date(byAdding: .day, value: -6, to: start)!, automatic: true, removedCount: 4)
        let before7 = SubscriptionCleanupRecord(cleanedAt: firstOf7.cleanedAt.addingTimeInterval(-1), automatic: false, removedCount: 5)
        let firstOf30 = SubscriptionCleanupRecord(cleanedAt: calendar.date(byAdding: .day, value: -29, to: start)!, automatic: true, removedCount: 6)
        let before30 = SubscriptionCleanupRecord(cleanedAt: firstOf30.cleanedAt.addingTimeInterval(-1), automatic: true, removedCount: 7)
        let tomorrow = SubscriptionCleanupRecord(cleanedAt: calendar.date(byAdding: .day, value: 1, to: start)!, automatic: true, removedCount: 8)
        let records = [today, manual, firstOf7, before7, firstOf30, before30, tomorrow]
        var filter = SubscriptionCleanupHistoryFilter()
        assert(filter.apply(to: records, now: now, calendar: calendar) == records)
        filter.period = .today
        assert(filter.apply(to: records, now: now, calendar: calendar) == [today, manual])
        filter.source = .manual
        assert(filter.apply(to: records, now: now, calendar: calendar) == [manual])
        filter.source = .automatic
        assert(filter.apply(to: records, now: now, calendar: calendar) == [today])
        filter.source = .all
        filter.period = .last7Days
        assert(filter.apply(to: records, now: now, calendar: calendar) == [today, manual, firstOf7])
        filter.period = .last30Days
        assert(filter.apply(to: records, now: now, calendar: calendar) == [today, manual, firstOf7, before7, firstOf30])

        // Calendar days span a daylight-saving change without shifting the first day's boundary.
        var dstCalendar = Calendar(identifier: .gregorian)
        dstCalendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let dstNow = ISO8601DateFormatter().date(from: "2026-03-09T19:00:00Z")!
        let dstStart = ISO8601DateFormatter().date(from: "2026-03-03T08:00:00Z")!
        let dstBoundary = SubscriptionCleanupRecord(cleanedAt: dstStart, automatic: true, removedCount: 1)
        let dstBefore = SubscriptionCleanupRecord(cleanedAt: dstStart.addingTimeInterval(-1), automatic: true, removedCount: 1)
        filter.period = .last7Days
        assert(filter.apply(to: [dstBoundary, dstBefore], now: dstNow, calendar: dstCalendar) == [dstBoundary])

        sub.cleanupHistory = records
        sub.autoCleanupUnavailableNodes = true
        sub.unavailableCleanupDays = 12
        let confirmedIDs = Set(filter.apply(to: records, now: now, calendar: calendar).map(\.id))
        let arrivedDuringConfirmation = SubscriptionCleanupRecord(cleanedAt: now, automatic: true, removedCount: 1)
        sub.cleanupHistory?.insert(arrivedDuringConfirmation, at: 0)
        assert(sub.removeCleanupHistory(recordIDs: confirmedIDs) == 3)
        assert(sub.cleanupHistory == [arrivedDuringConfirmation, before7, firstOf30, before30, tomorrow])
        assert(sub.autoCleanupUnavailableNodes == true && sub.unavailableCleanupDays == 12)
        assert(sub.removeCleanupHistory(recordIDs: confirmedIDs) == 0)
        assert(sub.removeCleanupHistory(recordIDs: [UUID()]) == 0)
        let reread = try JSONDecoder().decode(Subscription.self, from: JSONEncoder().encode(sub))
        assert(reread == sub)
        assert(sub.removeCleanupHistory(recordIDs: Set(sub.cleanupHistory!.map(\.id))) == 5)
        assert(sub.cleanupHistory?.isEmpty == true)
        var legacyEmpty = old
        assert(legacyEmpty.removeCleanupHistory(recordIDs: [UUID()]) == 0)
        assert(legacyEmpty.cleanupHistory == nil)
        print("Subscription cleanup history checks passed")
    }
}
