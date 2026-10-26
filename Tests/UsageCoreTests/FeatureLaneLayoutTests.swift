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
