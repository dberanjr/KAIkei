import Foundation
import Testing
@testable import UsageCore

@Suite struct TrendTests {
    static let calendar = AccountTests.calendar
    static let now = AccountTests.now  // Sunday 2026-10-25 12:00 UTC

    static func day(_ daysAgo: Int) -> Date {
        calendar.startOfDay(for: now.addingTimeInterval(-Double(daysAgo) * 86_400))
    }
    static func point(_ daysAgo: Int, _ cost: Double, model: String = "claude-sonnet-5-5") -> DailyPoint {
        DailyPoint(day: day(daysAgo), model: model, cost: cost)
    }
    func summary(_ points: [DailyPoint]) -> TrendSummary {
        Trends.summary(daily: points, now: Self.now, calendar: Self.calendar)
    }

    @Test func peakDayIsTheCostliestDaySummedAcrossModels() throws {
        let s = summary([Self.point(0, 4), Self.point(0, 6, model: "claude-opus-5-5"), Self.point(3, 9)])
        let peak = try #require(s.peak)
        #expect(peak.day == Self.day(0))
        #expect(peak.cost == 10)
    }

    @Test func weekOverWeekComparesTheLastSevenDaysWithTheSevenBefore() throws {
        // last 7 days = Oct 19...25 (days ago 0...6); previous 7 = Oct 12...18 (days ago 7...13).
        let s = summary([Self.point(0, 10), Self.point(1, 2), Self.point(2, 3), Self.point(10, 5)])
        #expect(s.last7 == 15)
        #expect(s.previous7 == 5)
        #expect(abs(try #require(s.weekOverWeek) - 2.0) < 1e-9)  // +200%
    }

    @Test func weekOverWeekIsAbsentWhenThereWasNoSpendBefore() {
        #expect(summary([Self.point(0, 10)]).weekOverWeek == nil)
    }

    @Test func averageSpansFromTheFirstActiveDayThroughToday() {
        // First data 10 days ago, so the window is 11 days (both ends included).
        let s = summary([Self.point(10, 5), Self.point(0, 6)])
        #expect(abs(s.dailyAverage - 11.0 / 11.0) < 1e-9)
    }

    @Test func averageOnlyCountsTheLastThirtyDays() {
        // The 60-day-old $30 is outside the window, so the average is $30 over 30 days, not $60.
        let s = summary([Self.point(60, 30), Self.point(0, 30)])
        #expect(abs(s.dailyAverage - 30.0 / 30.0) < 1e-9)
    }

    @Test func emptyHistoryIsAllZeroAndNil() {
        let s = summary([])
        #expect(s.peak == nil && s.weekOverWeek == nil)
        #expect(s.dailyAverage == 0 && s.last7 == 0 && s.previous7 == 0)
    }

    @Test func cacheHitRateIsTheShareOfInputServedFromCache() {
        let u = TokenUsage(input: 100, output: 999, cacheWrite5m: 100, cacheWrite1h: 0, cacheRead: 800)
        #expect(abs((u.cacheHitRate ?? 0) - 0.8) < 1e-9)  // 800 / (100 + 100 + 800); output does not count
        #expect(TokenUsage().cacheHitRate == nil)
    }
}
