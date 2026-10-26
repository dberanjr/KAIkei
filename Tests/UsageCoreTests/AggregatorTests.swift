import Foundation
import Testing
@testable import UsageCore

func rec(
    _ id: String, session: String = "s1", model: String = "claude-sonnet-5-5", at ts: Date,
    input: Int = 0, output: Int = 0, read: Int = 0, write5m: Int = 0,
    skill: String? = nil, plugin: String? = nil, tools: [String: String] = [:], cwd: String? = "/work/alpha"
) -> UsageRecord {
    UsageRecord(
        messageID: id, sessionID: session, timestamp: ts, model: model,
        usage: TokenUsage(input: input, output: output, cacheWrite5m: write5m, cacheWrite1h: 0, cacheRead: read),
        skill: skill, plugin: plugin, tools: tools, cwd: cwd, isSidechain: false)
}

@Suite struct AggregatorTests {
    // Fixed clock: Sunday 2026-10-25 12:00 UTC, evaluated in UTC so day boundaries are deterministic.
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()
    static let now = Date(timeIntervalSince1970: 1_792_929_600)
    static func hoursAgo(_ h: Double) -> Date { now.addingTimeInterval(-h * 3600) }
    func snap(_ records: [UsageRecord], _ range: TimeRange = .all) -> Snapshot {
        Aggregator.snapshot(records: records, range: range, now: Self.now, calendar: Self.calendar)
    }

    @Test func totalsSumCostAndTokens() {
        let s = snap([
            rec("a", at: Self.hoursAgo(1), input: 1_000_000),               // $2.00
            rec("b", at: Self.hoursAgo(2), output: 1_000_000),              // $10.00
        ])
        #expect(abs(s.totalCost - 12.0) < 1e-9)
        #expect(s.messageCount == 2)
        #expect(s.totalUsage.input == 1_000_000 && s.totalUsage.output == 1_000_000)
    }

    @Test func billingModeChangesTotalsConsistentlyAcrossBreakdowns() {
        var r = rec("a", at: Self.hoursAgo(1))
        r.usage.cacheWrite1h = 1_000_000 // sonnet 5.5: $2/MTok input
        let cc = Aggregator.snapshot(records: [r], range: .all, now: Self.now, calendar: Self.calendar, billing: .flatWriteRate)
        let api = Aggregator.snapshot(records: [r], range: .all, now: Self.now, calendar: Self.calendar, billing: .listPrice)
        #expect(abs(cc.totalCost - 2.5) < 1e-9 && abs(cc.byModel[0].cost - 2.5) < 1e-9)
        #expect(abs(api.totalCost - 4.0) < 1e-9 && abs(api.byModel[0].cost - 4.0) < 1e-9)
    }

    @Test func snapshotCarriesCostByTokenKind() {
        let s = snap([rec("a", at: Self.hoursAgo(1), input: 1_000_000, output: 1_000_000)]) // sonnet 5.5
        #expect(abs(s.costParts.input - 2.0) < 1e-9 && abs(s.costParts.output - 10.0) < 1e-9)
        #expect(abs(s.costParts.total - s.totalCost) < 1e-9)
    }

    @Test func rangeTodayExcludesYesterday() {
        let s = snap([rec("a", at: Self.hoursAgo(1), output: 1_000), rec("b", at: Self.hoursAgo(20), output: 1_000)], .today)
        #expect(s.messageCount == 1) // "now" is 12:00 UTC, so 20h ago is yesterday
    }

    @Test func rangeWeekIsRollingSevenDays() {
        let s = snap([rec("a", at: Self.hoursAgo(24 * 6), output: 1), rec("b", at: Self.hoursAgo(24 * 8), output: 1)], .week)
        #expect(s.messageCount == 1)
    }

    @Test func byModelIsSortedByCostDescending() {
        let s = snap([
            rec("a", model: "claude-haiku-5-5", at: Self.hoursAgo(1), output: 1_000_000),
            rec("b", model: "claude-opus-5-5", at: Self.hoursAgo(1), output: 1_000_000),
        ])
        #expect(s.byModel.map(\.key) == ["claude-opus-5-5", "claude-haiku-5-5"])
    }

    @Test func skillBreakdownBucketsUnattributedMessages() {
        let s = snap([
            rec("a", at: Self.hoursAgo(1), output: 1_000_000, skill: "dtctl"),
            rec("b", at: Self.hoursAgo(1), output: 1_000_000),
        ])
        #expect(Set(s.bySkill.map(\.key)) == ["dtctl", Snapshot.noSkill])
    }

    @Test func toolCostIsSplitEvenlyAcrossToolCallsInAMessage() {
        // One $10 message that called Read once and Bash once -> $5 attributed to each, 1 call each.
        let s = snap([rec("a", at: Self.hoursAgo(1), output: 1_000_000, tools: ["t1": "Read", "t2": "Bash"])])
        let read = s.byTool.first { $0.key == "Read" }
        #expect(read?.count == 1)
        #expect(abs((read?.cost ?? 0) - 5.0) < 1e-9)
        #expect(s.byTool.count == 2)
    }

    @Test func projectsAreNamedByDirectoryBasename() {
        let s = snap([rec("a", at: Self.hoursAgo(1), output: 10, cwd: "/Users/x/work/alpha")])
        #expect(s.byProject.first?.key == "alpha")
    }

    @Test func dailySeriesSplitsByDayAndModel() {
        let s = snap([
            rec("a", model: "claude-sonnet-5-5", at: Self.hoursAgo(1), output: 1_000_000),
            rec("b", model: "claude-opus-5-5", at: Self.hoursAgo(1), output: 1_000_000),
            rec("c", model: "claude-sonnet-5-5", at: Self.hoursAgo(30), output: 1_000_000),
        ])
        #expect(s.daily.count == 3)
        let days = Set(s.daily.map(\.day))
        #expect(days.count == 2)
    }

    @Test func sessionSummaryReportsLatestContextOccupancy() {
        let recs = [
            rec("a", at: Self.hoursAgo(3), input: 5, read: 10_000, write5m: 1_000),
            rec("b", at: Self.hoursAgo(1), input: 7, read: 90_000, write5m: 3_000),
            rec("z", session: "other", at: Self.hoursAgo(2), input: 1),
        ]
        let sessions = Aggregator.sessions(records: recs)
        let s = sessions["s1"]
        #expect(s?.messageCount == 2)
        #expect(s?.contextTokens == 7 + 90_000 + 3_000) // from the most recent message only
        #expect(s?.lastModel == "claude-sonnet-5-5")
        #expect(sessions["other"]?.messageCount == 1)
    }
}
