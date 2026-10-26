import Foundation
import Testing
@testable import UsageCore

/// A main-thread (or sub-agent) response at `minutes` after a fixed start.
func tcall(
    _ id: String, minute: Double, model: String = "claude-sonnet-5-5", session: String = "s1",
    input: Int = 2, read: Int = 0, write5m: Int = 0, write1h: Int = 0, output: Int = 100, thinking: Int = 0,
    sidechain: Bool = false, effort: String? = nil
) -> UsageRecord {
    var r = UsageRecord(
        messageID: id, sessionID: session, timestamp: TimelineTests.t0.addingTimeInterval(minute * 60), model: model,
        usage: TokenUsage(input: input, output: output, cacheWrite5m: write5m, cacheWrite1h: write1h, cacheRead: read),
        skill: nil, plugin: nil, tools: [:], cwd: "/work/alpha", isSidechain: sidechain)
    r.thinkingTokens = thinking
    r.effort = effort
    return r
}

func tevent(_ id: String, minute: Double, _ kind: SessionEvent.Kind, session: String = "s1", sidechain: Bool = false) -> SessionEvent {
    SessionEvent(id: id, sessionID: session, timestamp: TimelineTests.t0.addingTimeInterval(minute * 60), kind: kind, isSidechain: sidechain)
}

@Suite struct TimelineTests {
    static let t0 = Date(timeIntervalSince1970: 1_792_929_600)  // 2026-10-25 12:00 UTC

    func build(_ records: [UsageRecord], _ events: [SessionEvent] = [], session: String = "s1") -> SessionTimeline {
        Timelines.build(records: records, events: events, sessionID: session)
    }

    @Test func callsCarryPluginAndAgent() {
        var r = tcall("a", minute: 1, sidechain: true)
        r.plugin = "superpowers"; r.agentID = "ag1"; r.spawnToolUseID = "toolu_x"
        let c = build([r]).calls[0]
        #expect(c.plugin == "superpowers" && c.agentID == "ag1" && c.spawnToolUseID == "toolu_x")
    }

    @Test func mergingDuplicateRowsKeepsAgentID() {
        var store = RecordStore()
        var first = tcall("a", minute: 1, sidechain: true)
        var second = first
        second.agentID = "ag1"; second.spawnToolUseID = "toolu_x"
        first.agentID = nil
        store.add(first); store.add(second)
        #expect(store.records.count == 1)
        #expect(store.records[0].agentID == "ag1" && store.records[0].spawnToolUseID == "toolu_x")
    }

    @Test func callsAreTimeOrderedAndCarryContextCompositionAndCost() throws {
        let t = build([tcall("b", minute: 5, input: 10, read: 800, write5m: 190), tcall("a", minute: 1, input: 1_000_000, output: 0)])
        #expect(t.calls.map(\.id) == ["a", "b"])
        let b = t.calls[1]
        #expect(b.contextTokens == 1_000 && b.cacheRead == 800 && b.cacheWrite == 190 && b.freshInput == 10)
        #expect(abs(b.cost - Pricing.cost(of: b.usage, model: "claude-sonnet-5-5")) < 1e-12)
        #expect(b.costParts == Pricing.costParts(of: b.usage, model: "claude-sonnet-5-5"))
        #expect(t.calls[0].cost > 1.99 && t.calls[0].cost < 2.01)  // 1M uncached input on Sonnet 5.5
    }

    @Test func onlyTheRequestedSessionIsUsed() {
        let t = build([tcall("a", minute: 1), tcall("x", minute: 2, session: "other")],
                      [tevent("e1", minute: 1, .prompt(preview: "hi")), tevent("e2", minute: 1, .prompt(preview: "no"), session: "other")])
        #expect(t.calls.map(\.id) == ["a"])
        #expect(t.markers.count == 1)
    }

    @Test func subAgentCallsAreFlaggedAndExcludedFromTheMainThread() {
        let t = build([tcall("m1", minute: 1, read: 5000), tcall("sub", minute: 2, read: 100, sidechain: true), tcall("m2", minute: 3, read: 6000)])
        #expect(t.calls.count == 3)
        #expect(t.mainCalls.map(\.id) == ["m1", "m2"])
        #expect(t.calls[1].isSidechain)
        #expect(t.calls[2].idleGap == 120)  // measured against m1, not the sub-agent call between them
    }

    @Test func idleGapsMarkWhereTheCacheExpired_fiveMinuteTTL() {
        let t = build([tcall("a", minute: 0, write5m: 1000), tcall("b", minute: 2, read: 1000), tcall("c", minute: 10, read: 1000)])
        #expect(t.cacheTTL == 300)
        #expect(t.calls[0].idleGap == nil && !t.calls[0].cacheExpired)
        #expect(t.calls[1].idleGap == 120 && !t.calls[1].cacheExpired)
        #expect(t.calls[2].idleGap == 480 && t.calls[2].cacheExpired)
    }

    @Test func aOneHourWriteLengthensTheTTL() {
        let t = build([tcall("a", minute: 0, write1h: 1000), tcall("b", minute: 10, read: 1000), tcall("c", minute: 100, read: 1000)])
        #expect(t.cacheTTL == 3600)
        #expect(!t.calls[1].cacheExpired)   // 10 minutes is fine on a 1-hour cache
        #expect(t.calls[2].cacheExpired)    // 90 minutes is not
    }

    @Test func eachCallKnowsWhichPromptItBelongsTo() {
        let events = [
            tevent("p1", minute: 10, .prompt(preview: "one")), tevent("p2", minute: 100, .prompt(preview: "two")),
            tevent("sp", minute: 50, .prompt(preview: "subagent"), sidechain: true),
        ]
        let t = build([tcall("a", minute: 5), tcall("b", minute: 20), tcall("c", minute: 120)], events)
        #expect(t.calls.map(\.turn) == [0, 1, 2])
    }

    @Test func markersMapEventKindsAndDropNoise() {
        let events = [
            tevent("c", minute: 30, .compact(trigger: "auto", preTokens: 200_000, postTokens: 20_000, durationMs: 5000)),
            tevent("p", minute: 10, .prompt(preview: "hello")),
            tevent("clr", minute: 40, .command(name: "/clear")),
            tevent("mdl", minute: 20, .command(name: "/model")),
            tevent("cmp", minute: 29, .command(name: "/compact")),               // the boundary row carries this, so no duplicate
            tevent("sp", minute: 15, .prompt(preview: "sub"), sidechain: true),   // sub-agent chatter
        ]
        let t = build([tcall("a", minute: 1)], events)
        #expect(t.markers.map(\.id) == ["p", "mdl", "c", "clr"])
        #expect(t.markers[0].kind == .prompt(preview: "hello"))
        #expect(t.markers[1].kind == .command(name: "/model"))
        #expect(t.markers[2].kind == .compact(trigger: "auto", preTokens: 200_000, postTokens: 20_000, durationMs: 5000))
        #expect(t.markers[3].kind == .clear)
        #expect(t.compactionCount == 1 && t.promptCount == 1)
    }

    @Test func modelSpansShowWhenEachModelWasInUse() {
        let t = build([
            tcall("1", minute: 0, model: "claude-opus-5-5"), tcall("2", minute: 5, model: "claude-opus-5-5-20260101"),
            tcall("3", minute: 10, model: "claude-sonnet-5-5"), tcall("4", minute: 15, model: "claude-sonnet-5-5"),
            tcall("5", minute: 20, model: "claude-opus-5-5"), tcall("sub", minute: 12, model: "claude-haiku-5-5", sidechain: true),
        ])
        #expect(t.modelSpans.map(\.model) == ["claude-opus-5-5", "claude-sonnet-5-5", "claude-opus-5-5"])
        #expect(t.modelSpans.map(\.callCount) == [2, 2, 1])
        #expect(t.modelSpans[0].end == t.modelSpans[1].start)
        #expect(t.modelSpans[2].end == t.calls.last!.time)
        #expect(t.modelSpans[0].start == t.calls.first!.time)
    }

    @Test func peakContextWindowAndSpanDescribeTheMainThread() {
        let t = build([
            tcall("a", minute: 0, read: 100_000), tcall("b", minute: 5, read: 300_000), tcall("sub", minute: 6, read: 900_000, sidechain: true),
            tcall("c", minute: 10, model: "claude-haiku-4-5", read: 50_000),
        ], [tevent("p", minute: -3, .prompt(preview: "x"))])
        #expect(t.peakContext == 300_002)                      // the sub-agent's 900K is not the session's context
        #expect(t.contextWindow == 200_000)                    // the last main call ran on Haiku 4.5
        #expect(t.start == Self.t0.addingTimeInterval(-180) && t.end == Self.t0.addingTimeInterval(600))
    }

    @Test func thinkingIsSplitFromVisibleOutput() {
        let t = build([tcall("a", minute: 0, output: 1000, thinking: 707, effort: "xhigh")])
        #expect(t.calls[0].thinkingTokens == 707 && t.calls[0].visibleOutput == 293 && t.calls[0].effort == "xhigh")
    }

    @Test func cacheExpiriesReportWhatTheRewritesCostBeyondAWarmRead() {
        // 5-minute cache; the second call comes 10 minutes later and has to write 100K tokens it would otherwise have read.
        // Sonnet 5.5: a 5-minute write is $2.50/MTok and a read is $0.20/MTok, so the avoidable part is 100K * $2.30/MTok = $0.23.
        let t = build([tcall("a", minute: 0, write5m: 1000), tcall("b", minute: 10, write5m: 100_000)])
        #expect(t.expiryCount == 1)
        #expect(abs(t.coldRewriteExtraCost - 0.23) < 1e-9)
        #expect(build([tcall("a", minute: 0, write5m: 1000), tcall("b", minute: 2, read: 1000)]).expiryCount == 0)
    }

    @Test func anEmptySessionIsEmptyNotACrash() {
        let t = build([])
        #expect(t.calls.isEmpty && t.markers.isEmpty && t.modelSpans.isEmpty && t.peakContext == 0)
    }

    @Test func totalsAddUpAcrossCalls() {
        let t = build([tcall("a", minute: 0, output: 1_000_000), tcall("b", minute: 1, input: 1_000_000, output: 0, sidechain: true)])
        #expect(abs(t.totalCost - (t.calls[0].cost + t.calls[1].cost)) < 1e-12)
    }
}
