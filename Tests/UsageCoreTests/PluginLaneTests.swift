import Foundation
import Testing
@testable import UsageCore

@Suite struct PluginLaneTests {
    func call(_ id: String, minute: Double, plugin: String?, output: Int, sidechain: Bool = false) -> UsageRecord {
        var r = tcall(id, minute: minute, output: output, sidechain: sidechain)
        r.plugin = plugin
        return r
    }

    func lane(_ records: [UsageRecord], top: Int = 4) -> (PluginLane?, SessionTimeline) {
        let t = Timelines.build(records: records, events: [], sessionID: "s1")
        return (FeatureLanes.plugins(timeline: t, top: top), t)
    }

    @Test func costIsSummedPerPluginLargestFirst() throws {
        let (maybe, t) = lane([call("a", minute: 1, plugin: "dynatrace", output: 1_000), call("b", minute: 2, plugin: "superpowers", output: 5_000),
                               call("c", minute: 3, plugin: "superpowers", output: 5_000, sidechain: true)])
        let l = try #require(maybe)
        #expect(l.segments.map(\.name) == ["superpowers", "dynatrace"])
        #expect(abs(l.segments[0].cost - (t.calls[1].cost + t.calls[2].cost)) < 1e-12)  // sub-agent spend counts
        #expect(abs(l.total - t.calls.reduce(0) { $0 + $1.cost }) < 1e-12)
    }

    @Test func smallPluginsFoldIntoOther() throws {
        let l = try #require(lane((1...5).map { call("c\($0)", minute: Double($0), plugin: "p\($0)", output: $0 * 1_000) }, top: 2).0)
        #expect(l.segments.map(\.name) == ["p5", "p4", "other"])
    }

    @Test func unattributedCallsFoldIntoOther() throws {
        let l = try #require(lane([call("a", minute: 1, plugin: "dynatrace", output: 1_000), call("b", minute: 2, plugin: nil, output: 9_000)]).0)
        #expect(l.segments.map(\.name) == ["dynatrace", "other"])
    }

    @Test func noPluginAttributionMeansNoLane() {
        #expect(lane([call("a", minute: 1, plugin: nil, output: 1_000)]).0 == nil)
    }
}
