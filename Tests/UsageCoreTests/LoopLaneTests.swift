import Foundation
import Testing
@testable import UsageCore

/// A signal `minute` minutes after the shared test start.
func tsignal(_ id: String, minute: Double, _ kind: FeatureSignal.Kind, session: String = "s1") -> FeatureSignal {
    FeatureSignal(id: id, sessionID: session, timestamp: TimelineTests.t0.addingTimeInterval(minute * 60), kind: kind, isSidechain: false)
}

@Suite struct LoopLaneTests {
    static let t0 = TimelineTests.t0

    /// Five responses: c1, c2 before the first wake-up; c3, c4 (a sub-agent) and c5 after it.
    func records() -> [UsageRecord] {
        [tcall("c1", minute: 1, output: 1_000), tcall("c2", minute: 3.5, output: 2_000), tcall("c3", minute: 24, output: 3_000),
         tcall("c4", minute: 25, output: 4_000, sidechain: true), tcall("c5", minute: 26.5, output: 5_000)]
    }

    /// Invoked at 0, decides to loop at 3 (due at 23), woken at 23.3, stops at 26.
    func signals(withSchedule: Bool = true, withStop: Bool = true) -> [FeatureSignal] {
        var out = [tsignal("i0", minute: 0, .loopInvoked(prompt: "keep going"))]
        if withSchedule {
            out.append(tsignal("t1#sched", minute: 3, .wakeupScheduled(toolUseID: "t1", delaySeconds: 1200, reason: "no event to watch")))
            out.append(tsignal("t1#ack", minute: 3.02, .wakeupAck(toolUseID: "t1", scheduledFor: Self.t0.addingTimeInterval(23 * 60))))
        }
        out.append(tsignal("w1", minute: 23.3, .loopWakeup(taskID: "50d65d60", cron: nil)))
        if withStop { out.append(tsignal("t2#stop", minute: 26, .loopStopped(toolUseID: "t2"))) }
        return out
    }

    func lane(_ signals: [FeatureSignal], prompts: [SessionEvent] = [], records: [UsageRecord]? = nil) -> (LoopLane?, SessionTimeline) {
        let timeline = Timelines.build(records: records ?? self.records(), events: prompts, sessionID: "s1")
        return (FeatureLanes.loop(signals: signals, timeline: timeline, sessionID: "s1"), timeline)
    }

    func cost(_ timeline: SessionTimeline, _ ids: [String]) -> Double {
        timeline.calls.filter { ids.contains($0.id) }.reduce(0) { $0 + $1.cost }
    }

    @Test func iterationsAreCostedFromWakeToWake() throws {
        let (maybe, t) = lane(signals())
        let l = try #require(maybe)
        #expect(l.iterations.count == 2)
        let (it1, it2) = (l.iterations[0], l.iterations[1])
        #expect(abs(it1.cost - cost(t, ["c1", "c2"])) < 1e-12 && it1.callCount == 2)
        #expect(abs(it2.cost - cost(t, ["c3", "c4", "c5"])) < 1e-12 && it2.callCount == 3)  // the sub-agent call counts
        #expect(it1.startedBy == .invoked && it2.startedBy == .scheduledWake)
        #expect(it2.plannedFor == Self.t0.addingTimeInterval(23 * 60))
        #expect(abs(try #require(it2.lateness) - 18) < 0.001)
        #expect(it1.prompt == "keep going" && it2.prompt == "keep going")
        #expect(it1.index == 1 && it2.index == 2)
    }

    @Test func anIterationEndsWhereItsActivityEndsNotWhereTheWaitEnds() throws {
        let l = try #require(lane(signals()).0)
        #expect(l.iterations[0].end == Self.t0.addingTimeInterval(3.5 * 60))
        #expect(l.iterations[1].end == Self.t0.addingTimeInterval(26.5 * 60))
    }

    @Test func decisionsMarkAgainAndStop() throws {
        let l = try #require(lane(signals()).0)
        #expect(l.decisions.map(\.kind) == [.again(delaySeconds: 1200, reason: "no event to watch"), .stop])
        #expect(l.decisions.map(\.afterIteration) == [1, 2])
        #expect(l.decisions[0].time == Self.t0.addingTimeInterval(3 * 60))
    }

    @Test func aTypedPromptEndsAnIteration() throws {
        let prompt = tevent("p1", minute: 24.5, .prompt(preview: "wait, stop"))
        let (maybe, t) = lane(signals(), prompts: [prompt])
        let it2 = try #require(maybe).iterations[1]
        #expect(it2.callCount == 1 && abs(it2.cost - cost(t, ["c3"])) < 1e-12)
    }

    @Test func anIterationWithNoDecisionLeadsToAFallbackWake() throws {
        let l = try #require(lane(signals(withSchedule: false)).0)
        #expect(l.iterations[1].startedBy == .fallbackWake)
        #expect(l.iterations[1].plannedFor == nil && l.iterations[1].lateness == nil)
        #expect(l.decisions.map(\.kind) == [.stop])
    }

    @Test func anOpenLoopRunsToTheEndOfTheTimeline() throws {
        let (maybe, t) = lane(signals(withStop: false))
        let l = try #require(maybe)
        #expect(l.iterations.last?.end == t.end)
        #expect(!l.decisions.contains { $0.kind == .stop })
        #expect(l.iterations.last?.callCount == 3)
    }

    @Test func aLoopCommandRightAroundAWakeupIsNotANewInvocation() throws {
        var s = signals()
        s.append(tsignal("cmd-after", minute: 23.3 + 1.0 / 60, .loopInvoked(prompt: "keep going")))
        s.append(tsignal("cmd-before", minute: 23.3 - 1.0 / 60, .loopInvoked(prompt: "keep going")))
        #expect(try #require(lane(s).0).iterations.count == 2)
    }

    @Test func noLoopSignalsMeansNoLane() {
        #expect(lane([]).0 == nil)
        #expect(lane([tsignal("o", minute: 1, .loopInvoked(prompt: "x"), session: "other")]).0 == nil)
    }

    @Test func totalsAndAverage() throws {
        let (maybe, t) = lane(signals())
        let l = try #require(maybe)
        #expect(abs(l.totalCost - cost(t, ["c1", "c2", "c3", "c4", "c5"])) < 1e-12)
        #expect(abs(l.averageCost - l.totalCost / 2) < 1e-12)
    }
}
