import Foundation
import Testing
@testable import UsageCore

@Suite struct TurnEndTests {
    static let t0 = TimelineTests.t0

    func build(_ records: [UsageRecord], _ events: [SessionEvent]) -> SessionTimeline {
        Timelines.build(records: records, events: events, sessionID: "s1")
    }

    func withTools(_ r: UsageRecord, _ tools: [String: String]) -> UsageRecord { var r = r; r.tools = tools; return r }

    @Test func aTurnEndsAtItsLastResponseAndSumsTheTurn() {
        let t = build(
            [withTools(tcall("a", minute: 1, input: 10, read: 1_000, output: 50), ["t1": "Read", "t2": "Bash"]),
             withTools(tcall("b", minute: 4, input: 20, read: 2_000, output: 70), ["t3": "Edit"]),
             tcall("c", minute: 9, output: 5)],
            [tevent("p1", minute: 0, .prompt(preview: "one")), tevent("p2", minute: 8, .prompt(preview: "two"))])
        #expect(t.turnEnds.count == 2)
        let first = t.turnEnds[0]
        #expect(first.turn == 1)
        #expect(first.time == Self.t0.addingTimeInterval(4 * 60))
        #expect(first.duration == 4 * 60)                       // from the prompt, not from the first response
        #expect(first.tools == 3)
        #expect(first.inputTokens == 10 + 1_000 + 20 + 2_000)
        #expect(first.outputTokens == 120)
        #expect(first.calls == 2)
    }

    @Test func workBeforeTheFirstPromptIsNotATurn() {
        let t = build([tcall("a", minute: 0)], [tevent("p1", minute: 5, .prompt(preview: "x"))])
        #expect(t.turnEnds.isEmpty)
    }

    @Test func aTurnEndsWithTheMainThreadNotALateSubAgent() {
        let t = build(
            [tcall("a", minute: 1), tcall("sub", minute: 2, sidechain: true), tcall("b", minute: 1.5)],
            [tevent("p1", minute: 0, .prompt(preview: "x"))])
        #expect(t.turnEnds.first?.time == Self.t0.addingTimeInterval(1.5 * 60))
    }
}

@Suite struct TurnEndHitTests {
    static let t0 = TimelineTests.t0

    func world() -> (SessionTimeline, TimelineGeometry) {
        let t = Timelines.build(
            records: [tcall("a", minute: 1), tcall("b", minute: 9)],
            events: [tevent("p1", minute: 0, .prompt(preview: "x")), tevent("p2", minute: 5, .prompt(preview: "y"))], sessionID: "s1")
        return (t, TimelineGeometry(timeline: t, byCalls: false))
    }

    func hit(minute: Double, y: Double) -> HoverTarget? {
        let (t, g) = world()
        let width = 600.0
        let px = TimelineHitTester.pixel(forX: g.x(time: Self.t0.addingTimeInterval(minute * 60)), width: width, geometry: g)
        return TimelineHitTester.target(
            atX: px, y: y, width: width, bands: [PanelBand(kind: .prompts, minY: 0, maxY: 20)], geometry: g, turnEnds: t.turnEnds)
    }

    @Test func theLowerHalfAtATurnEndOpensTheTurnCard() {
        #expect(hit(minute: 1, y: 15) == .turnEnd(1))
        #expect(hit(minute: 9, y: 15) == .turnEnd(2))
    }

    @Test func theUpperHalfStillHitsThePromptTick() {
        if case .marker? = hit(minute: 0, y: 4) {} else { Issue.record("expected the prompt marker") }
    }

    @Test func awayFromAnyEndTheLowerHalfIsEmpty() {
        #expect(hit(minute: 6.5, y: 15) == nil)
    }
}

@Suite struct TimelineScaleTests {
    @Test func aSessionWithTensOfThousandsOfPromptsBuildsQuickly() {
        let n = 20_000
        let records = (0..<n).map { tcall("c\($0)", minute: Double($0) + 0.5) }
        let events = (0..<n).map { tevent("p\($0)", minute: Double($0), .prompt(preview: "p")) }
        let start = Date()
        let t = Timelines.build(records: records, events: events, sessionID: "s1")
        #expect(t.turnEnds.count == n)
        #expect(t.calls.last?.turn == n && t.calls.first?.turn == 1)
        // Quadratic work here took many seconds; the bound is generous so a slow machine does not flake.
        #expect(Date().timeIntervalSince(start) < 4)
    }
}
