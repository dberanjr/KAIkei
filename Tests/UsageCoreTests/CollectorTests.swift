import Foundation
import Testing
@testable import UsageCore

@Suite struct CollectorTests {
    struct Fixture {
        let root: URL
        var projects: URL { root.appendingPathComponent("projects/-work-alpha") }
        var sessions: URL { root.appendingPathComponent("sessions") }
        var statusline: URL { root.appendingPathComponent("statusline") }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("col-\(UUID().uuidString)")
            for d in [projects, sessions, statusline] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        }
        var config: URL { root.appendingPathComponent("claude.json") }
        func collector() -> UsageCollector {
            UsageCollector(
                projectsDir: root.appendingPathComponent("projects"), sessionsDir: sessions, statuslineDir: statusline,
                accountConfig: config)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    func registerLive(_ fx: Fixture, id: String) throws {
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        try #"{"pid":\#(me),"sessionId":"\#(id)","cwd":"/work/alpha","startedAt":1792938350554,"entrypoint":"cli","name":"alpha","status":"idle","updatedAt":1792939356191,"version":"2.1"}"#
            .write(to: fx.sessions.appendingPathComponent("\(me).json"), atomically: true, encoding: .utf8)
    }

    @Test func liveRowCombinesTranscriptUsageWithSessionFile() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let lines = [
            assistantLine(id: "m1", model: "claude-sonnet-5-5", session: "live1", input: 1_000_000),   // $2
            assistantLine(id: "m2", model: "claude-sonnet-5-5", session: "live1", input: 5, output: 1, write5m: 10_000, read: 50_000),
            assistantLine(id: "m3", model: "claude-sonnet-5-5", session: "ended1", output: 1_000_000), // other session
        ].joined(separator: "\n") + "\n"
        try lines.write(to: fx.projects.appendingPathComponent("t.jsonl"), atomically: true, encoding: .utf8)
        try registerLive(fx, id: "live1")

        let dash = fx.collector().refresh(now: Date(timeIntervalSince1970: 1_792_938_400))
        #expect(dash.live.count == 1)
        let row = try #require(dash.live.first)
        #expect(row.contextTokens == 5 + 10_000 + 50_000)  // latest message only
        #expect(row.contextWindow == 1_000_000)             // sonnet 5.5
        #expect(abs(row.contextPercent - 6.0005) < 0.001)
        #expect(row.cost > 2.0 && row.cost < 2.1)
        #expect(row.messageCount == 2)
    }

    @Test func statuslineSuppliesContextExactlyButNeverReplacesComputedCost() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        try (assistantLine(id: "m1", session: "live1", read: 10_000) + "\n")
            .write(to: fx.projects.appendingPathComponent("t.jsonl"), atomically: true, encoding: .utf8)
        try registerLive(fx, id: "live1")
        try #"{"session_id":"live1","cost":{"total_cost_usd":9.99},"context_window":{"context_window_size":200000,"used_percentage":42}}"#
            .write(to: fx.statusline.appendingPathComponent("shared.json"), atomically: true, encoding: .utf8)

        let row = try #require(fx.collector().refresh(now: .now).live.first)
        #expect(row.contextWindow == 200_000)
        #expect(row.contextPercent == 42)
        #expect(row.statuslineCost == 9.99)
        #expect(row.cost < 1.0) // computed from the transcript, not substituted
    }

    @Test func modelLabelIsHumanReadableWithoutAStatusline() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        try (assistantLine(id: "m1", model: "claude-sonnet-5-5", session: "live1", output: 10) + "\n")
            .write(to: fx.projects.appendingPathComponent("t.jsonl"), atomically: true, encoding: .utf8)
        try registerLive(fx, id: "live1")
        let row = try #require(fx.collector().refresh(now: .now).live.first)
        #expect(row.statusline == nil)
        #expect(row.modelLabel == "Sonnet 5.5")
    }

    @Test func liveTotalsSumAcrossSessions() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        try (assistantLine(id: "m1", session: "live1", output: 1_000_000) + "\n")
            .write(to: fx.projects.appendingPathComponent("t.jsonl"), atomically: true, encoding: .utf8)
        try registerLive(fx, id: "live1")
        let dash = fx.collector().refresh(now: Date(timeIntervalSince1970: 1_792_938_400))
        #expect(abs(dash.liveCost - 20.0) < 1e-3) // opus-5-5 default fixture model: $20/MTok output (+2 fixture input tokens)
        #expect(dash.snapshots[.all]?.messageCount == 1)
    }

    @Test func secondRefreshPicksUpAppendedTranscriptLines() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let file = fx.projects.appendingPathComponent("t.jsonl")
        try (assistantLine(id: "m1", session: "s") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let c = fx.collector()
        #expect(c.refresh(now: .now).snapshots[.all]?.messageCount == 1)
        let h = try FileHandle(forWritingTo: file); try h.seekToEnd()
        try h.write(contentsOf: Data((assistantLine(id: "m2", session: "s") + "\n").utf8)); try h.close()
        #expect(c.refresh(now: .now).snapshots[.all]?.messageCount == 2)
    }

    @Test func everyLiveRowCarriesTheSignedInAccountAndTheDashboardTheirPlan() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        try (assistantLine(id: "m1", session: "live1", output: 10) + "\n")
            .write(to: fx.projects.appendingPathComponent("t.jsonl"), atomically: true, encoding: .utf8)
        try registerLive(fx, id: "live1")
        try AccountTests.config().write(to: fx.config)

        let dash = fx.collector().refresh(now: AccountTests.now)
        #expect(dash.live.first?.account?.email == "ana@acme.com")
        #expect(dash.live.first?.account?.licenseLabel == "Enterprise · usage-based")
        #expect(dash.account?.organization == "Acme")
        #expect(abs((dash.plan?.monthlySpend ?? 0) - 400.61) < 1e-9)
    }

    @Test func aMissingConfigLeavesAccountAndPlanEmptyButNothingElseBroken() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        try (assistantLine(id: "m1", session: "live1", output: 10) + "\n")
            .write(to: fx.projects.appendingPathComponent("t.jsonl"), atomically: true, encoding: .utf8)
        try registerLive(fx, id: "live1")
        let dash = fx.collector().refresh(now: .now)
        #expect(dash.live.first?.account == nil && dash.account == nil && dash.plan == nil)
        #expect(dash.snapshots[.all]?.messageCount == 1)
    }

    @Test func theConfigIsReReadAtMostOncePerInterval() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        try AccountTests.config().write(to: fx.config)
        let c = fx.collector()
        let t0 = AccountTests.now
        #expect(c.refresh(now: t0).account?.organization == "Acme")

        try String(data: AccountTests.config(), encoding: .utf8)!.replacingOccurrences(of: "Acme", with: "Globex")
            .write(to: fx.config, atomically: true, encoding: .utf8)
        #expect(c.refresh(now: t0.addingTimeInterval(5)).account?.organization == "Acme")      // still cached
        #expect(c.refresh(now: t0.addingTimeInterval(31)).account?.organization == "Globex")   // interval elapsed
    }

    @Test func dashboardExposesRecordsAndTrendForDrillDown() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let now = Date(timeIntervalSince1970: 1_792_938_400)
        try [assistantLine(id: "m1", session: "s", output: 1_000_000), assistantLine(id: "m2", session: "s", output: 1_000)]
            .joined(separator: "\n").appending("\n")
            .write(to: fx.projects.appendingPathComponent("t.jsonl"), atomically: true, encoding: .utf8)
        let dash = fx.collector().refresh(now: now)
        #expect(dash.records.count == 2)
        #expect(dash.trend.peak != nil)
    }

    @Test func dashboardExposesTranscriptEventsForTheTimeline() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        try [promptLine("do the thing", session: "s"), assistantLine(id: "m1", session: "s"), compactBoundaryLine(session: "s")]
            .joined(separator: "\n").appending("\n")
            .write(to: fx.projects.appendingPathComponent("t.jsonl"), atomically: true, encoding: .utf8)
        let dash = fx.collector().refresh(now: .now)
        #expect(dash.events.count == 2)
    }
}
