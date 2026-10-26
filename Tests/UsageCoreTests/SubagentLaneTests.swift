import Foundation
import Testing
@testable import UsageCore

/// A sub-agent response `minute` minutes after the shared test start, belonging to agent run `agent`.
func agentCall(_ id: String, minute: Double, agent: String?, spawn: String? = nil, output: Int = 100) -> UsageRecord {
    var r = tcall(id, minute: minute, output: output, sidechain: true)
    r.agentID = agent
    r.spawnToolUseID = spawn
    return r
}

@Suite struct SubagentLaneTests {
    func lane(_ records: [UsageRecord], _ signals: [FeatureSignal] = []) -> (SubagentLane?, SessionTimeline) {
        let timeline = Timelines.build(records: records, events: [], sessionID: "s1")
        return (FeatureLanes.subagents(signals: signals, timeline: timeline), timeline)
    }

    @Test func aRunSpansItsFirstToItsLastCallAndSumsCost() throws {
        let (maybe, t) = lane([agentCall("a", minute: 1, agent: "ag1", output: 1_000), agentCall("b", minute: 2, agent: "ag1", output: 2_000),
                               agentCall("c", minute: 4, agent: "ag1", output: 3_000)])
        let run = try #require(maybe).runs[0]
        #expect(run.id == "ag1" && run.callCount == 3 && run.outputTokens == 6_000)
        #expect(run.start == TimelineTests.t0.addingTimeInterval(60) && run.end == TimelineTests.t0.addingTimeInterval(240))
        #expect(abs(run.cost - t.calls.reduce(0) { $0 + $1.cost }) < 1e-12)
    }

    @Test func labelComesFromTheMatchingSpawn() throws {
        let spawn = tsignal("toolu_x#agent", minute: 0.5, .agentSpawned(toolUseID: "toolu_x", type: "fork", description: "Explore data"))
        let run = try #require(lane([agentCall("a", minute: 1, agent: "ag1", spawn: "toolu_x")], [spawn]).0).runs[0]
        #expect(run.label == "Explore data" && run.type == "fork")
    }

    @Test func overlappingRunsStackInSeparateRows() throws {
        let l = try #require(lane([
            agentCall("a1", minute: 1, agent: "ag1"), agentCall("a2", minute: 4, agent: "ag1"),
            agentCall("b1", minute: 2, agent: "ag2"), agentCall("b2", minute: 5, agent: "ag2"),
            agentCall("c1", minute: 6, agent: "ag3"), agentCall("c2", minute: 7, agent: "ag3"),
        ]).0)
        #expect(l.runs.map(\.id) == ["ag1", "ag2", "ag3"])
        #expect(l.runs.map(\.row) == [0, 1, 0])
        #expect(l.rowCount == 2)
    }

    @Test func aRunWithoutASpawnRowIsStillShown() throws {
        let (maybe, t) = lane([agentCall("a", minute: 1, agent: "ag1", spawn: "toolu_missing", output: 5_000)])
        let l = try #require(maybe)
        #expect(l.runs[0].label == "sub-agent" && l.runs[0].type == nil)
        #expect(abs(l.totalCost - t.calls[0].cost) < 1e-12)
    }

    @Test func noSidechainCallsMeansNoLane() {
        #expect(lane([tcall("a", minute: 1)]).0 == nil)
        #expect(lane([agentCall("a", minute: 1, agent: nil)]).0 == nil)
    }
}
