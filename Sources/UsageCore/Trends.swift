import Foundation

public struct TrendSummary: Equatable, Sendable {
    public struct Peak: Equatable, Sendable { public var day: Date; public var cost: Double }
    public var peak: Peak?
    /// Spend over the last 7 days (today and the 6 before) and over the 7 days before that.
    public var last7 = 0.0
    public var previous7 = 0.0
    /// Fractional change, +0.25 meaning 25% more than the previous week. Nil when there was no spend to compare with.
    public var weekOverWeek: Double? { previous7 > 0 ? (last7 - previous7) / previous7 : nil }
    /// Per day over the last 30 days, or since the first active day when that is more recent.
    public var dailyAverage = 0.0
    public init() {}
}

public enum Trends {
    public static func summary(daily: [DailyPoint], now: Date, calendar: Calendar) -> TrendSummary {
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today) ?? today }
        var perDay: [Date: Double] = [:]
        for p in daily { perDay[p.day, default: 0] += p.cost }

        var out = TrendSummary()
        out.peak = perDay.max { ($0.value, $1.key) < ($1.value, $0.key) }.map { .init(day: $0.key, cost: $0.value) }
        out.last7 = perDay.filter { $0.key >= day(-6) && $0.key <= today }.values.reduce(0, +)
        out.previous7 = perDay.filter { $0.key >= day(-13) && $0.key <= day(-7) }.values.reduce(0, +)

        // The window starts at the first day the user was ever active, capped at 30 days, so zero-spend days inside it
        // count as real zeros. Starting at the first active day *inside* the window would inflate the average.
        let windowStart = day(-29)
        if let first = perDay.keys.min() {
            let spanStart = max(first, windowStart)
            let days = (calendar.dateComponents([.day], from: spanStart, to: today).day ?? 0) + 1
            out.dailyAverage = perDay.filter { $0.key >= windowStart && $0.key <= today }.values.reduce(0, +) / Double(days)
        }
        return out
    }
}
