import Foundation
import Testing
@testable import UsageCore

@Suite struct DrilldownTests {
    static let calendar = AccountTests.calendar
    static let now = AccountTests.now  // Sunday 2026-10-25 12:00 UTC
    static func hoursAgo(_ h: Double) -> Date { now.addingTimeInterval(-h * 3600) }

    // alpha/sonnet/brainstorming/Read ($2.00), alpha/opus/no skill ($4.00 = 1M input at Opus 5.5's $4), beta/sonnet/Bash+Read ($10.00),
    // and an old sonnet message 3 days ago in beta ($2.00).
    static let records: [UsageRecord] = [
        rec("a", session: "s1", at: hoursAgo(1), input: 1_000_000, skill: "brainstorming", plugin: "superpowers",
            tools: ["t1": "Read"], cwd: "/work/alpha"),
        rec("b", session: "s1", model: "claude-opus-5-5", at: hoursAgo(2), input: 1_000_000, cwd: "/work/alpha"),
        rec("c", session: "s2", at: hoursAgo(3), output: 1_000_000, tools: ["t2": "Bash", "t3": "Read"], cwd: "/work/beta"),
        rec("d", session: "s2", at: hoursAgo(72), input: 1_000_000, cwd: "/work/beta"),
    ]

    func detail(_ target: DrillTarget, range: TimeRange = .all, records: [UsageRecord] = DrilldownTests.records) -> DrillDetail {
        Drilldown.detail(records: records, target: target, range: range, now: Self.now, calendar: Self.calendar)
    }

    @Test func modelTargetKeepsOnlyThatModel() {
        let d = detail(.model("claude-opus-5-5"))
        #expect(d.snapshot.messageCount == 1)
        #expect(abs(d.snapshot.totalCost - 4) < 1e-9)
    }

    @Test func modelTargetMatchesAcrossDateSuffixedIDs() {
        let r = rec("x", model: "claude-sonnet-5-5-20260101", at: Self.hoursAgo(1), input: 1_000_000)
        #expect(detail(.model("claude-sonnet-5-5"), records: [r]).snapshot.messageCount == 1)
    }

    @Test func skillTargetIncludingTheNoSkillBucket() {
        #expect(detail(.skill("brainstorming")).snapshot.messageCount == 1)
        #expect(detail(.skill(Snapshot.noSkill)).snapshot.messageCount == 3)
    }

    @Test func pluginProjectAndSessionTargets() {
        #expect(detail(.plugin("superpowers")).snapshot.messageCount == 1)
        #expect(detail(.project("alpha")).snapshot.messageCount == 2)
        #expect(detail(.session("s2")).snapshot.messageCount == 2)
    }

    @Test func toolTargetIsEveryResponseThatCalledTheTool() {
        let d = detail(.tool("Read"))
        #expect(d.snapshot.messageCount == 2)                    // messages a and c
        #expect(abs(d.snapshot.totalCost - 12) < 1e-9)           // full message cost, not the per-call share
    }

    @Test func totalTargetIsEverythingInRange() {
        #expect(detail(.total).snapshot.messageCount == 4)
        #expect(detail(.total, range: .today).snapshot.messageCount == 3)
    }

    @Test func dayTargetIgnoresTheSelectedRangeAndCoversThatDayOnly() {
        let threeDaysAgo = Self.calendar.startOfDay(for: Self.hoursAgo(72))
        let d = detail(.day(threeDaysAgo), range: .today)
        #expect(d.snapshot.messageCount == 1)
        #expect(abs(d.snapshot.totalCost - 2) < 1e-9)
    }

    @Test func rangeLimitsTheSnapshotButTheTrendAlwaysSpansThirtyDays() {
        let d = detail(.project("beta"), range: .today)
        #expect(d.snapshot.messageCount == 1)                    // only message c is today
        #expect(Set(d.trend.map(\.day)).count == 2)              // today and 3 days ago both appear
    }

    @Test func topMessagesAreRankedByCostAndCapped() {
        let many = (0..<15).map { rec("m\($0)", at: Self.hoursAgo(Double($0) + 1), input: ($0 + 1) * 1000) }
        let d = detail(.total, records: many)
        #expect(d.topMessages.count == 10)
        #expect(d.topMessages.first?.messageID == "m14")
        #expect(d.topMessages.map(\.cost) == d.topMessages.map(\.cost).sorted(by: >))
    }

    @Test func topMessagesCarryWhatIsNeededToExplainThem() throws {
        let m = try #require(detail(.skill("brainstorming")).topMessages.first)
        #expect(m.tools == ["Read"] && m.skill == "brainstorming")
        #expect(m.model == "claude-sonnet-5-5" && m.usage.input == 1_000_000)
    }

    @Test func topSessionsAreGroupedAndRankedByCost() {
        let d = detail(.total)
        #expect(d.topSessions.map(\.sessionID) == ["s2", "s1"])  // s2 = $12, s1 = $6
        #expect(d.topSessions[0].messageCount == 2)
        #expect(d.topSessions[0].project == "beta")
        #expect(abs(d.topSessions[0].cost - 12) < 1e-9)
    }

    @Test func hourlyProfileBucketsCostByHourOfDay() {
        // 12:00 UTC now: a = 11:00, b = 10:00, c = 09:00 ($10), d = 12:00 three days ago.
        let h = detail(.total).hourly
        #expect(h.count == 24)
        #expect(abs(h[9] - 10) < 1e-9)
        #expect(abs(h[10] - 4) < 1e-9)
        #expect(abs(h[11] - 2) < 1e-9)
        #expect(abs(h[12] - 2) < 1e-9)
        #expect(abs(h.reduce(0, +) - 18) < 1e-9)
    }

    @Test func sessionTargetExposesContextGrowthInTimeOrder() {
        let rs = [
            rec("late", session: "s9", at: Self.hoursAgo(1), input: 300_000),
            rec("early", session: "s9", at: Self.hoursAgo(5), input: 100_000, read: 50_000),
        ]
        let d = detail(.session("s9"), records: rs)
        #expect(d.contextTimeline.map(\.tokens) == [150_000, 300_000])
        #expect(d.contextTimeline[0].time < d.contextTimeline[1].time)
    }

    @Test func aSessionTargetCoversItsWholeLifeWhateverRangeIsSelected() {
        // The terminal row shows a session's all-time cost, so its detail must match even when "Today" is selected.
        let rs = [
            rec("old", session: "s9", at: Self.hoursAgo(24 * 10), input: 1_000_000),
            rec("new", session: "s9", at: Self.hoursAgo(1), input: 1_000_000),
        ]
        let d = detail(.session("s9"), range: .today, records: rs)
        #expect(d.snapshot.messageCount == 2)
        #expect(abs(d.snapshot.totalCost - 4) < 1e-9)
        #expect(d.contextTimeline.count == 2)
    }

    @Test func aSessionDetailCarriesItsTimelineOtherTargetsDoNot() throws {
        let events = [tevent("p", minute: -5, .prompt(preview: "go"), session: "s1")]
        let d = Drilldown.detail(records: Self.records, events: events, target: .session("s1"), range: .today, now: Self.now, calendar: Self.calendar)
        let t = try #require(d.timeline)
        #expect(t.calls.count == 2 && t.markers.count == 1)
        #expect(Drilldown.detail(records: Self.records, events: events, target: .model("claude-opus-5-5"), range: .all, now: Self.now, calendar: Self.calendar).timeline == nil)
    }

    @Test func firstAndLastSeenSpanTheMatchingMessages() {
        let d = detail(.project("beta"))
        #expect(d.firstSeen == Self.hoursAgo(72))
        #expect(d.lastSeen == Self.hoursAgo(3))
    }

    @Test func aTargetWithNoMatchesIsEmptyNotACrash() {
        let d = detail(.model("claude-haiku-5-5"))
        #expect(d.snapshot.messageCount == 0 && d.topMessages.isEmpty && d.topSessions.isEmpty)
        #expect(d.firstSeen == nil && d.lastSeen == nil)
        #expect(d.hourly == Array(repeating: 0, count: 24))
    }

    @Test func titlesNameTheTarget() {
        #expect(DrillTarget.model("claude-opus-5-5").title == "Opus 5.5")
        #expect(DrillTarget.skill("brainstorming").title == "brainstorming")
        #expect(DrillTarget.total.title == "All usage")
        #expect(DrillTarget.tool("Read").kind == "Tool")
    }
}
