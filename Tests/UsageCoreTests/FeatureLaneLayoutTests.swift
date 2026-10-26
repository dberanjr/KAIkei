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
