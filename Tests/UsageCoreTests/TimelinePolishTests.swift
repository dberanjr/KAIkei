import Foundation
import Testing
@testable import UsageCore

@Suite struct AdviceHistoryTests {
    static let t0 = TimelineTests.t0
    func minute(_ m: Double) -> Date { Self.t0.addingTimeInterval(m * 60) }

    /// One call per entry of `contexts`, a minute apart, on Sonnet 5.5, with one 1-hour cache write so the cache lives an hour.
    func timeline(_ contexts: [Int], gapsAfter: [Int: Double] = [:]) -> SessionTimeline {
        var minuteNow = 0.0
        let records = contexts.enumerated().map { i, c -> UsageRecord in
            defer { minuteNow += 1 + (gapsAfter[i] ?? 0) }
            return tcall("c\(i)", minute: minuteNow, input: 2, read: c - 2, write1h: i == 0 ? 100 : 0)
        }
        return Timelines.build(records: records, events: [], sessionID: "s1")
    }

    @Test func aSessionThatNeverGetsBigHasNoSuggestions() {
        #expect(AdviceHistory.markers(timeline: timeline([30_000, 31_000, 32_000])).isEmpty)
    }

    @Test func aBigWarmContextIsMarkedWhereTheSuggestionFirstApplied() throws {
        let markers = AdviceHistory.markers(timeline: timeline([30_000, 300_000, 301_000, 302_000]))
        #expect(markers.count == 1)  // the same level is not repeated while it lasts
        let m = try #require(markers.first)
        #expect(m.level == .consider && m.time == minute(1))
        #expect(!m.headline.isEmpty && !m.detail.isEmpty)
    }

    @Test func aCacheThatExpiredDuringAnIdleGapIsMarkedWhenItExpired() throws {
        // 90K is not worth compacting, but a 100-minute pause outlasts the 1-hour cache.
        let t = timeline([90_000, 91_000], gapsAfter: [0: 100])
        let m = try #require(AdviceHistory.markers(timeline: t).first)
        #expect(m.level == .coldCache && m.time == minute(60))
    }

    @Test func aLevelThatComesBackAfterTheSessionWasFineIsMarkedAgain() {
        // Big, then a compaction-sized drop, then big again, spaced beyond the repeat guard.
        let big = Array(repeating: 300_000, count: 3), small = Array(repeating: 30_000, count: 15)
        #expect(AdviceHistory.markers(timeline: timeline(big + small + big)).count == 2)
    }

    @Test func adviceFlickeringAroundAThresholdIsMarkedOnce() {
        // Big, one small call, big again within a few calls: one suggestion, not two.
        #expect(AdviceHistory.markers(timeline: timeline([300_000, 30_000, 300_000, 300_000])).count == 1)
    }

    @Test func aVeryLongSessionIsSkippedRatherThanSlowingTheWindow() {
        #expect(AdviceHistory.markers(timeline: timeline(Array(repeating: 300_000, count: 10)), limit: 5).isEmpty)
    }
}

@Suite struct TestRunSummaryTextTests {
    func run(_ command: String) -> TestRun { TestRun(id: "t", time: Date(), command: command, summary: nil) }

    @Test func theCommandIsReducedToTheSegmentThatRunsTheTests() {
        let heredoc = "grep -n x Sources/*.swift | head -10; python3 -I - <<'EOF'\nimport re\nprint(1)\nEOF\nswift test --scratch-path ~/Library/Caches/Foo/build 2>&1 | tail -3"
        #expect(run(heredoc).shortCommand == "swift test --scratch-path ~/Library/Caches/Foo/build 2>&1")
        #expect(run(#"cd "/work/my app" && pytest -q"#).shortCommand == "pytest -q")
    }

    @Test func aLongCommandIsTruncated() {
        let long = "swift test " + String(repeating: "--filter VeryLongSuiteName ", count: 6)
        let short = run(long).shortCommand
        #expect(short.count <= 61 && short.hasSuffix("…") && short.hasPrefix("swift test --filter"))
    }
}

@Suite struct OverlayHitTests {
    static let t0 = TimelineTests.t0

    func world() -> (FeatureLanes, TimelineGeometry) {
        let signals = [tsignal("t1#test", minute: 1, .testCommand(toolUseID: "t1", command: "swift test")),
                       tsignal("t1#out", minute: 2, .testOutput(toolUseID: "t1", summary: TestSummary(runner: "swift test", passed: 3, failed: 0, skipped: 0)))]
        let timeline = Timelines.build(records: [tcall("a", minute: 0), tcall("b", minute: 10)], events: [], sessionID: "s1")
        return (FeatureLanes.build(signals: signals, timeline: timeline, sessionID: "s1"), TimelineGeometry(timeline: timeline, byCalls: false))
    }

    func hit(y: Double, overlay: Set<FeatureLane>) -> HoverTarget? {
        let (lanes, g) = world()
        let width = 500.0
        let px = TimelineHitTester.pixel(forX: g.x(time: Self.t0.addingTimeInterval(120)), width: width, geometry: g)
        let bands = [PanelBand(kind: .data, minY: 0, maxY: 200, overlay: true)]
        return TimelineHitTester.target(atX: px, y: y, width: width, bands: bands, geometry: g, lanes: lanes, overlay: overlay)
    }

    @Test func aTestDotOnTheOverlayOpensItsCard() {
        let dotY = 200 * (1 - FeatureOverlayLayout.testDotFraction)
        #expect(hit(y: dotY, overlay: [.tests]) == .lane(.testRun("t1")))
        #expect(hit(y: dotY + 4, overlay: [.tests]) == .lane(.testRun("t1")))
    }

    @Test func awayFromTheDotItIsTheCallAsBefore() {
        if case .call? = hit(y: 150, overlay: [.tests]) {} else { Issue.record("expected a call target") }
    }

    @Test func withTheOverlayOffTheDotIsNotHoverable() {
        let dotY = 200 * (1 - FeatureOverlayLayout.testDotFraction)
        if case .call? = hit(y: dotY, overlay: []) {} else { Issue.record("expected a call target") }
    }

    @Test func theAdviceBarResolvesToTheNearestMarker() {
        let (_, g) = world()
        let marker = AdviceMarker(id: "a1", time: Self.t0.addingTimeInterval(120), level: .consider, headline: "h", detail: "d", contextTokens: 1)
        let width = 500.0
        let px = TimelineHitTester.pixel(forX: g.x(time: marker.time), width: width, geometry: g)
        let bands = [PanelBand(kind: .advice, minY: 0, maxY: 14)]
        #expect(TimelineHitTester.target(atX: px + 2, y: 7, width: width, bands: bands, geometry: g, advice: [marker]) == .advice("a1"))
        #expect(TimelineHitTester.target(atX: px + 60, y: 7, width: width, bands: bands, geometry: g, advice: [marker]) == nil)
    }

    @Test func layoutMarksTheMainChartAndTheAdviceBar() {
        let items: [StackItem] = [.init(kind: .advice, height: 14), .init(kind: .data, height: 100, overlay: true), .init(kind: .data, height: 50)]
        let bands = TimelineStackLayout(items: items, spacing: 2).bands
        #expect(bands.map(\.kind) == [.advice, .data, .data] && bands.map(\.overlay) == [false, true, false])
    }
}
