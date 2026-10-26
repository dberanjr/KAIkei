import Foundation
import Testing
@testable import UsageCore

@Suite struct FeatureLanesTests {
    func timeline(_ records: [UsageRecord]) -> SessionTimeline { Timelines.build(records: records, events: [], sessionID: "s1") }

    @Test func aSessionWithNoFeaturesIsEmpty() {
        let lanes = FeatureLanes.build(signals: [], timeline: timeline([tcall("a", minute: 1)]), sessionID: "s1")
        #expect(lanes.isEmpty && lanes.present.isEmpty)
    }

    @Test func presentListsOnlyLanesWithDataInOrder() {
        var withPlugin = tcall("a", minute: 1)
        withPlugin.plugin = "superpowers"
        var agent = tcall("b", minute: 2, sidechain: true)
        agent.agentID = "ag1"
        let signals = [
            tsignal("i", minute: 0, .loopInvoked(prompt: "go")),
            tsignal("c#test", minute: 3, .testCommand(toolUseID: "c", command: "swift test")),
        ]
        let lanes = FeatureLanes.build(signals: signals, timeline: timeline([withPlugin, agent]), sessionID: "s1")
        #expect(lanes.present == [.loop, .subagents, .tests, .plugins])
        #expect(!lanes.isEmpty)
    }

    @Test func signalsFromOtherSessionsAreIgnored() {
        let other = tsignal("i", minute: 0, .loopInvoked(prompt: "go"), session: "other")
        let lanes = FeatureLanes.build(signals: [other], timeline: timeline([tcall("a", minute: 1)]), sessionID: "s1")
        #expect(lanes.loop == nil && lanes.isEmpty)
    }

    @Test func theCacheKeyChangesWhenTheSameCallsAreCostedDifferently() {
        let records = [tcall("a", minute: 1, write1h: 10_000, output: 500)]
        let list = Timelines.build(records: records, events: [], sessionID: "s1", billing: .listPrice)
        let other = Timelines.build(records: records, events: [], sessionID: "s1", billing: CacheWriteBilling.allCases.first { $0 != .listPrice } ?? .listPrice)
        #expect(FeatureLanes.cacheKey(timeline: list, signalCount: 0) != FeatureLanes.cacheKey(timeline: other, signalCount: 0))
        #expect(FeatureLanes.cacheKey(timeline: list, signalCount: 0) == FeatureLanes.cacheKey(timeline: list, signalCount: 0))
        #expect(FeatureLanes.cacheKey(timeline: list, signalCount: 0) != FeatureLanes.cacheKey(timeline: list, signalCount: 1))
    }

    @Test func everyLaneHasATitle() {
        #expect(FeatureLane.allCases.map(\.title) == ["/loop", "/goal", "Sub-agents", "Test runs", "Plugins and skills"])
    }
}

@Suite struct LaneStackLayoutTests {
    @Test func laneItemsProduceLaneBandsAndShiftNothingAbove() {
        let base: [StackItem] = [.init(kind: .ribbon, height: 20), .init(kind: .prompts, height: 14), .init(kind: .data, height: 100)]
        let plain = TimelineStackLayout(items: base, spacing: 2).bands
        let lanes: [StackItem] = [.init(kind: .header, height: 28), .init(kind: .lane, height: 60), .init(kind: .header, height: 28), .init(kind: .lane, height: 40)]
        let with = TimelineStackLayout(items: base + lanes, spacing: 2).bands
        #expect(Array(with.prefix(3)) == plain)
        #expect(with.suffix(2).map(\.kind) == [.lane, .lane])
        #expect(with[3].minY == plain[2].maxY + 2 + 28 + 2 && with[3].maxY == with[3].minY + 60)
    }
}

@Suite struct LaneHitTests {
    static let t0 = TimelineTests.t0
    func minute(_ m: Double) -> Date { Self.t0.addingTimeInterval(m * 60) }

    func loopWorld() -> (FeatureLanes, TimelineGeometry) {
        let s = LoopLaneTests()
        let timeline = Timelines.build(records: s.records(), events: [], sessionID: "s1")
        let lanes = FeatureLanes.build(signals: s.signals(), timeline: timeline, sessionID: "s1")
        return (lanes, TimelineGeometry(timeline: timeline, byCalls: false))
    }

    @Test func hoveringInsideAnIterationFindsIt() {
        let (lanes, g) = loopWorld()
        #expect(lanes.target(lane: .loop, atX: g.x(time: minute(25)), row: nil, tolerance: 1, geometry: g) == .iteration(2))
        #expect(lanes.target(lane: .loop, atX: g.x(time: minute(2)), row: nil, tolerance: 1, geometry: g) == .iteration(1))
    }

    @Test func hoveringADecisionTimeFindsTheDecisionBeforeTheIteration() {
        let (lanes, g) = loopWorld()
        #expect(lanes.target(lane: .loop, atX: g.x(time: minute(3)) + 2, row: nil, tolerance: 5, geometry: g) == .decision("t1#sched"))
    }

    @Test func hoveringAnEmptyStretchFindsNothing() {
        let (lanes, g) = loopWorld()
        #expect(lanes.target(lane: .loop, atX: g.x(time: minute(15)), row: nil, tolerance: 1, geometry: g) == nil)
    }

    @Test func hoveringAnOverlappingSubagentRowFindsTheRunInThatRow() {
        let records = [agentCall("a1", minute: 1, agent: "ag1"), agentCall("a2", minute: 6, agent: "ag1"),
                       agentCall("b1", minute: 2, agent: "ag2"), agentCall("b2", minute: 5, agent: "ag2")]
        let timeline = Timelines.build(records: records, events: [], sessionID: "s1")
        let lanes = FeatureLanes.build(signals: [], timeline: timeline, sessionID: "s1")
        let g = TimelineGeometry(timeline: timeline, byCalls: false)
        let x = g.x(time: minute(3))
        #expect(lanes.target(lane: .subagents, atX: x, row: 0, tolerance: 1, geometry: g) == .subagent("ag1"))
        #expect(lanes.target(lane: .subagents, atX: x, row: 1, tolerance: 1, geometry: g) == .subagent("ag2"))
    }

    @Test func hoveringATestRunFindsTheNearestRunWithinTolerance() {
        let signals = [tsignal("t1#test", minute: 1, .testCommand(toolUseID: "t1", command: "swift test")),
                       tsignal("t1#out", minute: 2, .testOutput(toolUseID: "t1", summary: TestSummary(runner: "swift test", passed: 3, failed: 0, skipped: 0)))]
        let timeline = Timelines.build(records: [tcall("a", minute: 0), tcall("b", minute: 10)], events: [], sessionID: "s1")
        let lanes = FeatureLanes.build(signals: signals, timeline: timeline, sessionID: "s1")
        let g = TimelineGeometry(timeline: timeline, byCalls: false)
        #expect(lanes.target(lane: .tests, atX: g.x(time: minute(2)) + 3, row: nil, tolerance: 5, geometry: g) == .testRun("t1"))
        #expect(lanes.target(lane: .tests, atX: g.x(time: minute(2)) + 300, row: nil, tolerance: 5, geometry: g) == nil)
    }

    @Test func theHitTesterResolvesALaneBandToItsLane() {
        let (lanes, g) = loopWorld()
        let bands = [PanelBand(kind: .lane, minY: 100, maxY: 160, lane: .loop)]
        let width = 400.0
        let px = TimelineHitTester.pixel(forX: g.x(time: minute(25)), width: width, geometry: g)
        let hit = TimelineHitTester.target(atX: px, y: 130, width: width, bands: bands, geometry: g, lanes: lanes)
        #expect(hit == .lane(.iteration(2)))
    }
}
