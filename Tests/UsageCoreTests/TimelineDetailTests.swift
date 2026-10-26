import Foundation
import Testing
@testable import UsageCore

/// What the hover cards need from a timeline: running cost, tools, per-prompt totals and what happened in a slice.
@Suite struct TimelineDetailTests {
    func build(_ records: [UsageRecord], _ events: [SessionEvent] = []) -> SessionTimeline {
        Timelines.build(records: records, events: events, sessionID: "s1")
    }

    @Test func costRunsUpAcrossEveryCallIncludingSubAgents() {
        let t = build([tcall("a", minute: 0, output: 1_000_000), tcall("sub", minute: 1, input: 1_000_000, output: 0, sidechain: true), tcall("b", minute: 2, output: 500_000)])
        let costs = t.calls.map(\.cost)
        #expect(t.calls.map(\.cumulativeCost) == [costs[0], costs[0] + costs[1], costs[0] + costs[1] + costs[2]])
        #expect(abs(t.calls.last!.cumulativeCost - t.totalCost) < 1e-12)
    }

    @Test func callsKnowTheirToolsAndSkill() {
        var r = tcall("a", minute: 0)
        r.tools = ["t1": "Read", "t2": "Bash", "t3": "Read"]
        r.skill = "brainstorming"
        let c = build([r]).calls[0]
        #expect(c.tools == ["Bash", "Read", "Read"] && c.skill == "brainstorming")
    }

    @Test func aSliceListsTheMarkersBetweenTwoCalls() {
        let events = [
            tevent("p1", minute: 1, .prompt(preview: "early")), tevent("p2", minute: 5, .prompt(preview: "in slice")),
            tevent("c", minute: 8, .compact(trigger: "auto", preTokens: 1, postTokens: 1, durationMs: 1)),
            tevent("p3", minute: 12, .prompt(preview: "later")),
        ]
        let t = build([tcall("a", minute: 0), tcall("b", minute: 10)], events)
        let start = TimelineTests.t0, end = TimelineTests.t0.addingTimeInterval(600)
        #expect(t.markers(after: start, through: end).map(\.id) == ["p1", "p2", "c"])   // start excluded, end included
        #expect(t.markers(after: end, through: end).isEmpty)
    }

    @Test func eachPromptKnowsWhatItsAnswerCost() throws {
        let events = [tevent("p1", minute: 1, .prompt(preview: "one")), tevent("p2", minute: 10, .prompt(preview: "two"))]
        let t = build([tcall("pre", minute: 0), tcall("a", minute: 2, output: 1_000_000, thinking: 400_000),
                       tcall("sub", minute: 3, input: 1_000_000, output: 0, sidechain: true), tcall("b", minute: 11, output: 100)], events)
        let first = try #require(t.turnSummary(1))
        #expect(first.calls == 2)                                   // a and the sub-agent call it triggered
        #expect(abs(first.cost - (t.calls[1].cost + t.calls[2].cost)) < 1e-12)
        #expect(first.outputTokens == 1_000_000)
        #expect(try #require(t.turnSummary(2)).calls == 1)
        #expect(t.turnSummary(0) == nil && t.turnSummary(3) == nil)
    }

    @Test func modelSpansTotalWhatTheyCost() {
        let t = build([tcall("1", minute: 0, model: "claude-opus-5-5", output: 1000), tcall("2", minute: 5, model: "claude-sonnet-5-5", output: 1000),
                       tcall("3", minute: 6, model: "claude-sonnet-5-5", output: 2000)])
        #expect(t.modelSpans.count == 2)
        #expect(abs(t.modelSpans[1].cost - (t.calls[1].cost + t.calls[2].cost)) < 1e-12)
    }
}
