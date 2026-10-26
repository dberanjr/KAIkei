import Foundation
import Testing
@testable import UsageCore

@Suite struct TimelineGeometryTests {
    static func timeline() -> SessionTimeline {
        // Sonnet for 0-10 minutes, Opus from minute 10 to 20; a prompt at minute 5; a compaction at minute 10.
        Timelines.build(
            records: [tcall("a", minute: 0), tcall("b", minute: 5), tcall("c", minute: 10, model: "claude-opus-5-5"), tcall("d", minute: 20, model: "claude-opus-5-5")],
            events: [tevent("p", minute: 5, .prompt(preview: "go")), tevent("k", minute: 10, .compact(trigger: "auto", preTokens: 9, postTokens: 1, durationMs: 1))],
            sessionID: "s1")
    }

    @Test func timeAxisMapsSecondsFromTheStart() {
        let g = TimelineGeometry(timeline: Self.timeline(), byCalls: false)
        #expect(g.x(callIndex: 1) == 300)
        #expect(g.x(time: TimelineTests.t0.addingTimeInterval(600)) == 600)
        #expect(g.domain.lowerBound == 0 && abs(g.domain.upperBound - 1200 * 1.01) < 1e-9)
    }

    @Test func callsAxisSpacesEveryCallEvenly() {
        let g = TimelineGeometry(timeline: Self.timeline(), byCalls: true)
        #expect(g.x(callIndex: 2) == 2)
        #expect(g.x(time: TimelineTests.t0.addingTimeInterval(600)) == 1.5)      // just before the call made at that moment
        #expect(g.x(endingAt: TimelineTests.t0.addingTimeInterval(1200)) == 3.5) // includes the last call's slot
        #expect(g.domain == -0.5...3.5)
    }

    @Test func modelSpansCoverTheRibbonWithoutGaps() {
        let t = Self.timeline()
        let g = TimelineGeometry(timeline: t, byCalls: false)
        let a = g.xRange(of: t.modelSpans[0]), b = g.xRange(of: t.modelSpans[1])
        #expect(a == 0...600 && b == 600...1200)
    }

    @Test func nearestCallPicksTheClosestSlot() {
        let g = TimelineGeometry(timeline: Self.timeline(), byCalls: false)
        #expect(g.nearestCall(to: 340) == 1 && g.nearestCall(to: 460) == 2 && g.nearestCall(to: 5000) == 3)
    }

    @Test func pixelsAndAxisUnitsConvertBothWays() {
        let g = TimelineGeometry(timeline: Self.timeline(), byCalls: false)
        let x = TimelineHitTester.x(atPixel: 250, width: 1000, geometry: g)
        #expect(abs(x - 0.25 * 1212) < 1e-9)
        #expect(abs(TimelineHitTester.pixel(forX: x, width: 1000, geometry: g) - 250) < 1e-9)
    }
}

@Suite struct HitTestingTests {
    static let width = 1000.0
    // ribbon 0-16, prompt lane 18-32, data panels 34-200 and 202-280; the y values between are gaps.
    static let bands = [PanelBand(kind: .ribbon, minY: 0, maxY: 16), PanelBand(kind: .prompts, minY: 18, maxY: 32),
                        PanelBand(kind: .data, minY: 34, maxY: 200), PanelBand(kind: .data, minY: 202, maxY: 280)]
    let timeline = TimelineGeometryTests.timeline()

    func hit(_ px: Double, _ y: Double, byCalls: Bool = false) -> HoverTarget? {
        TimelineHitTester.target(atX: px, y: y, width: Self.width, bands: Self.bands, geometry: TimelineGeometry(timeline: timeline, byCalls: byCalls))
    }
    /// Pixel of a time on the 1000px-wide time axis (domain is 1212 s).
    func px(minute: Double) -> Double { minute * 60 / 1212 * Self.width }

    @Test func theRibbonNamesTheModelUnderThePointer() {
        #expect(hit(px(minute: 3), 8) == .modelSpan(timeline.modelSpans[0].id))
        #expect(hit(px(minute: 15), 8) == .modelSpan(timeline.modelSpans[1].id))
    }

    @Test func theRibbonPastTheLastCallIsEmpty() {
        #expect(hit(px(minute: 20) + 6, 8) == nil)
    }

    @Test func aPromptTickIsHitWithinAFewPixelsInThePromptLane() {
        #expect(hit(px(minute: 5) + 3, 25) == .marker("p"))
        #expect(hit(px(minute: 5) + 12, 25) == nil)
    }

    @Test func promptsAreOnlyHitInTheirOwnLane() {
        // In the data panels the same x resolves to the nearest call instead.
        #expect(hit(px(minute: 5), 100) == .call(1))
    }

    @Test func compactionAndClearLinesAreHitInEveryPanel() {
        #expect(hit(px(minute: 10) - 2, 25) == .marker("k"))
        #expect(hit(px(minute: 10) + 2, 100) == .marker("k"))
        #expect(hit(px(minute: 10), 240) == .marker("k"))
    }

    @Test func theDataPanelsResolveToTheNearestCall() {
        #expect(hit(px(minute: 6.5), 100) == .call(1))
        #expect(hit(px(minute: 8), 240) == .call(2))
        #expect(hit(px(minute: 19), 100) == .call(3))
    }

    @Test func gapsBetweenPanelsResolveToNothing() {
        #expect(hit(px(minute: 3), 17) == nil)
        #expect(hit(px(minute: 3), 201) == nil)
        #expect(hit(px(minute: 3), 400) == nil)
    }

    @Test func theCallsAxisHitsTheSameThings() {
        let calls = TimelineGeometry(timeline: timeline, byCalls: true)
        func at(_ x: Double) -> Double { TimelineHitTester.pixel(forX: x, width: Self.width, geometry: calls) }
        #expect(hit(at(1.1), 100, byCalls: true) == .call(1))
        #expect(hit(at(1.5) + 1, 100, byCalls: true) == .marker("k"))   // the compaction sits between calls 1 and 2
        #expect(hit(at(0.2), 8, byCalls: true) == .modelSpan(timeline.modelSpans[0].id))
    }
}

@Suite struct DwellTrackerTests {
    typealias T = DwellTracker

    @Test func aDataSliceNeedsAnUnmovingPointerFor800ms() {
        var t = T()
        t.pointer(target: .call(5), x: 100, y: 50, now: 0)
        let early = t.tick(now: 0.79), shownEarly = t.shown
        let onTime = t.tick(now: 0.80)
        #expect(!early && shownEarly == nil)
        #expect(onTime && t.shown == .call(5))
    }

    @Test func eventBarsAnswerAlmostAtOnce() {
        var t = T()
        t.pointer(target: .marker("p"), x: 100, y: 25, now: 0)
        let early = t.tick(now: 0.1)
        let onTime = t.tick(now: 0.12)
        #expect(!early && onTime && t.shown == .marker("p"))
        var m = T()
        m.pointer(target: .modelSpan("s"), x: 10, y: 8, now: 0)
        let ribbon = m.tick(now: 0.12)
        #expect(ribbon && m.shown == .modelSpan("s"))
    }

    @Test func jitterDoesNotRestartTheClockButRealMovementDoes() {
        var t = T()
        t.pointer(target: .call(5), x: 100, y: 50, now: 0)
        t.pointer(target: .call(5), x: 102, y: 51, now: 0.5)   // about 2px: still the same dwell
        let steady = t.tick(now: 0.8)
        #expect(steady)
        var moved = T()
        moved.pointer(target: .call(5), x: 100, y: 50, now: 0)
        moved.pointer(target: .call(5), x: 110, y: 50, now: 0.5)  // 10px: starts over
        let tooSoon = moved.tick(now: 0.9)
        let later = moved.tick(now: 1.3)
        #expect(!tooSoon && later)
    }

    @Test func slidingToTheNeighbouringCallWithinJitterKeepsTheClock() {
        var t = T()
        t.pointer(target: .call(5), x: 100, y: 50, now: 0)
        t.pointer(target: .call(6), x: 102, y: 50, now: 0.4)
        let shown = t.tick(now: 0.8)
        #expect(shown && t.shown == .call(6))   // shows the call under the pointer now
    }

    @Test func leavingHidesAndCancels() {
        var t = T()
        t.pointer(target: .call(5), x: 100, y: 50, now: 0)
        _ = t.tick(now: 0.8)
        t.leave()
        let after = t.tick(now: 5)
        #expect(t.shown == nil && t.candidate == nil && t.nextDeadline == nil && !after)
    }

    @Test func overNothingHidesTheCard() {
        var t = T()
        t.pointer(target: .call(5), x: 100, y: 50, now: 0)
        _ = t.tick(now: 0.8)
        t.pointer(target: nil, x: 100, y: 300, now: 1)
        #expect(t.shown == nil)
    }

    @Test func aShownCardStaysWhileThePointerDriftsAndGoesWhenItTravels() {
        var t = T()
        t.pointer(target: .call(5), x: 100, y: 50, now: 0)
        _ = t.tick(now: 0.8)
        t.pointer(target: .call(5), x: 104, y: 50, now: 1)       // 4px away: stays
        #expect(t.shown == .call(5))
        t.pointer(target: .call(6), x: 130, y: 50, now: 1.1)     // far: hides and starts a new dwell
        #expect(t.shown == nil)
        let early = t.tick(now: 1.8)
        let onTime = t.tick(now: 1.9)
        #expect(!early && onTime && t.shown == .call(6))
    }

    @Test func movingFromASliceOntoAnEventSwapsTheCard() {
        var t = T()
        t.pointer(target: .call(5), x: 100, y: 50, now: 0)
        _ = t.tick(now: 0.8)
        t.pointer(target: .marker("k"), x: 101, y: 50, now: 2)
        #expect(t.shown == nil)                                  // the slice card is gone straight away
        let quick = t.tick(now: 2.12)
        #expect(quick && t.shown == .marker("k"))                // and the quick event card follows
    }

    @Test func theNextDeadlineTellsTheDriverWhenToCheckAgain() {
        var t = T()
        #expect(t.nextDeadline == nil)
        t.pointer(target: .call(5), x: 0, y: 0, now: 10)
        #expect(abs(t.nextDeadline! - 10.8) < 1e-9)
        _ = t.tick(now: 10.8)
        #expect(t.nextDeadline == nil)                           // already showing
    }
}
