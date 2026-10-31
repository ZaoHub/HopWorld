import Foundation

@main
struct SubscriptionUpdateHistoryCheck {
    static func main() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = ISO8601DateFormatter().date(from: "2026-10-21T04:00:00Z")!
        let start = calendar.startOfDay(for: now)
        let subscriptionID = UUID()
        func log(_ date: Date, success: Bool) -> SubscriptionUpdateLog {
            SubscriptionUpdateLog(subscriptionID: subscriptionID, startedAt: date,
                                  requestedURL: "https://example.com", success: success)
        }
        let today = log(now, success: true)
        let midnight = log(start, success: false)
        let firstOf7 = log(calendar.date(byAdding: .day, value: -6, to: start)!, success: true)
        let before7 = log(firstOf7.startedAt.addingTimeInterval(-1), success: false)
        let firstOf30 = log(calendar.date(byAdding: .day, value: -29, to: start)!, success: true)
        let before30 = log(firstOf30.startedAt.addingTimeInterval(-1), success: false)
        let tomorrow = log(calendar.date(byAdding: .day, value: 1, to: start)!, success: true)
        let logs = [today, midnight, firstOf7, before7, firstOf30, before30, tomorrow]
        var filter = SubscriptionUpdateHistoryFilter()
        assert(!filter.isActive)
        assert(filter.apply(to: logs, now: now, calendar: calendar) == logs)
        assert(filter.apply(to: [], now: now, calendar: calendar).isEmpty)
        filter.result = .failure
        assert(filter.isActive)
        assert(filter.apply(to: logs, now: now, calendar: calendar) == [midnight, before7, before30])
        filter.period = .today
        assert(filter.apply(to: logs, now: now, calendar: calendar) == [midnight])
        filter.result = .success
        assert(filter.apply(to: logs, now: now, calendar: calendar) == [today])
        filter.result = .all
        filter.period = .last7Days
        assert(filter.apply(to: logs, now: now, calendar: calendar) == [today, midnight, firstOf7])
        filter.period = .last30Days
        assert(filter.apply(to: logs, now: now, calendar: calendar) == [today, midnight, firstOf7, before7, firstOf30])
        filter.result = .failure
        assert(filter.apply(to: [today, firstOf7, firstOf30], now: now, calendar: calendar).isEmpty)

        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let dstNow = ISO8601DateFormatter().date(from: "2026-03-09T19:00:00Z")!
        let dstStart = ISO8601DateFormatter().date(from: "2026-03-03T08:00:00Z")!
        let boundary = log(dstStart, success: false)
        let before = log(dstStart.addingTimeInterval(-1), success: false)
        filter.period = .last7Days
        assert(filter.apply(to: [boundary, before], now: dstNow, calendar: calendar) == [boundary])
        let reread = try JSONDecoder().decode([SubscriptionUpdateLog].self, from: JSONEncoder().encode(logs))
        assert(reread == logs)
        print("Subscription update history filter checks passed")
    }
}
