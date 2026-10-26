import Foundation
import Testing
@testable import UsageCore

/// Zoom works on a window of real dates, so it survives a live session growing and a switch between the Time and Calls axes.
@Suite struct ZoomTests {
    let timeline = TimelineGeometryTests.timeline()   // calls at minutes 0, 5, 10, 20; a prompt at 5 and a compaction at 10
    var t0: Date { TimelineTests.t0 }
    func time(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }
    func geo(byCalls: Bool = false, window: ClosedRange<Date>? = nil) -> TimelineGeometry {
        TimelineGeometry(timeline: timeline, byCalls: byCalls, window: window)
    }

    @Test func withoutAWindowTheWholeSessionShows() {
        let g = geo()
        #expect(!g.isZoomed && g.zoomFactor == 1 && g.domain == g.fullDomain)
        #expect(g.visibleCalls == [0, 1, 2, 3])
    }

    @Test func aWindowNarrowsTheDomainToItsOwnSeconds() {
        let g = geo(window: time(300)...time(600))
        #expect(g.isZoomed && g.domain == 300...600)
        #expect(abs(g.zoomFactor - 1212.0 / 300) < 1e-9)
        #expect(g.visibleCalls == [1, 2])
    }

    @Test func aWindowOnTheCallsAxisCoversWholeCallSlots() {
        let g = geo(byCalls: true, window: time(300)...time(600))
        #expect(g.domain == 0.5...2.5 && g.visibleCalls == [1, 2])
    }

    @Test func theSameWindowShowsTheSameCallsOnBothAxes() {
        let w = time(250)...time(700)
        #expect(geo(window: w).visibleCalls == geo(byCalls: true, window: w).visibleCalls)
    }

    @Test func zoomingByAFactorKeepsTheAnchorInViewAndShrinksTheWindow() throws {
        let g = geo()
        let w = try #require(g.window(zoomFactor: 4, anchor: 600))
        let zoomed = geo(window: w)
        #expect(abs(zoomed.zoomFactor - 4) < 1e-6)
        #expect(zoomed.domain.contains(600))
        #expect(abs((zoomed.domain.lowerBound + zoomed.domain.upperBound) / 2 - 600) < 1e-6)
    }

    @Test func zoomingNearAnEdgeSlidesTheWindowInsteadOfLeavingTheSession() throws {
        let g = geo()
        let end = try #require(g.window(zoomFactor: 4, anchor: 1200))
        #expect(abs(geo(window: end).domain.upperBound - g.fullDomain.upperBound) < 1e-6)
        let start = try #require(g.window(zoomFactor: 4, anchor: 0))
        #expect(abs(geo(window: start).domain.lowerBound) < 1e-6)
    }

    @Test func aFactorOfOneMeansNoZoomAtAll() {
        #expect(geo().window(zoomFactor: 1, anchor: 300) == nil)
        #expect(geo().window(zoomFactor: 0.5, anchor: 300) == nil)
    }

    @Test func theFactorIsCappedSoTheWindowNeverCollapses() throws {
        let w = try #require(geo().window(zoomFactor: 10_000, anchor: 600))
        #expect(geo(window: w).domain.upperBound - geo(window: w).domain.lowerBound >= TimelineGeometry.minimumSeconds - 1e-6)
    }

    @Test func zoomingAZoomedWindowAnchorsOnItsMiddleByDefault() throws {
        let first = try #require(geo().window(zoomFactor: 2, anchor: 600))
        let g = geo(window: first)
        let again = try #require(g.window(zoomFactor: 4, anchor: nil))
        let after = geo(window: again)
        #expect(abs(after.zoomFactor - 4) < 1e-6)
        #expect(abs((after.domain.lowerBound + after.domain.upperBound) / 2 - (g.domain.lowerBound + g.domain.upperBound) / 2) < 1e-6)
    }

    @Test func draggingASelectionZoomsToIt_inEitherDirection() throws {
        let g = geo()
        let a = try #require(g.window(selecting: 300, 600)), b = try #require(g.window(selecting: 600, 300))
        #expect(a == b && geo(window: a).domain == 300...600)
    }

    @Test func aSelectionOutsideTheSessionIsClampedToIt() throws {
        let g = geo()
        let w = try #require(g.window(selecting: -500, 400))
        #expect(geo(window: w).domain == 0...400)
    }

    @Test func aTinySelectionWidensToTheMinimumSoAnAccidentalClickDoesNotZoomToNothing() throws {
        let w = try #require(geo().window(selecting: 600, 601))
        let d = geo(window: w).domain
        #expect(abs((d.upperBound - d.lowerBound) - TimelineGeometry.minimumSeconds) < 1e-6)
        #expect(d.contains(600))
    }

    @Test func aSelectionOnTheCallsAxisSnapsToTheCallsItTouches() throws {
        let g = geo(byCalls: true)
        let w = try #require(g.window(selecting: 0.7, 2.2))
        let zoomed = geo(byCalls: true, window: w)
        #expect(zoomed.domain == 0.5...2.5 && zoomed.visibleCalls == [1, 2])
    }

    @Test func aSingleCallSelectionOnTheCallsAxisStillShowsThatOneCall() throws {
        let g = geo(byCalls: true)
        let w = try #require(g.window(selecting: 1.9, 2.1))
        #expect(geo(byCalls: true, window: w).visibleCalls == [2])
    }

    @Test func panningMovesByAFractionOfTheWindowAndStopsAtTheEnds() throws {
        let zoomed = geo(window: time(300)...time(600))
        let right = try #require(zoomed.panned(by: 0.5))
        #expect(geo(window: right).domain == 450...750)
        let far = try #require(zoomed.panned(by: 100))
        #expect(abs(geo(window: far).domain.upperBound - zoomed.fullDomain.upperBound) < 1e-6)
        #expect(abs((geo(window: far).domain.upperBound - geo(window: far).domain.lowerBound) - 300) < 1e-6)
        let left = try #require(zoomed.panned(by: -100))
        #expect(abs(geo(window: left).domain.lowerBound) < 1e-6)
    }

    @Test func panningWithoutAZoomDoesNothing() { #expect(geo().panned(by: 0.5) == nil) }

    @Test func theNearestCallIsChosenAmongTheVisibleOnes() {
        let g = geo(window: time(300)...time(600))
        #expect(g.nearestCall(to: 590) == 2 && g.nearestCall(to: 310) == 1)
        // The call at minute 20 is closest to x=1000 overall, but it is out of view, so it must not be offered.
        #expect(geo(window: time(0)...time(310)).nearestCall(to: 305) == 1)
    }

    @Test func aWindowWithNoCallsHasNothingToHover() {
        #expect(geo(window: time(700)...time(900)).nearestCall(to: 800) == nil)
    }

    @Test func theViewSummarisesWhatIsInView() {
        let g = geo(window: time(300)...time(600))
        #expect(g.visibleStart == time(300) && g.visibleEnd == time(600))
        let expected = timeline.calls[1].cost + timeline.calls[2].cost
        #expect(abs(g.visibleCost - expected) < 1e-12)
        let full = geo()
        #expect(full.visibleStart == timeline.start && abs(full.visibleCost - timeline.totalCost) < 1e-12)
    }

    @Test func theCallsAxisReportsTheTimesOfTheFirstAndLastVisibleCalls() {
        let g = geo(byCalls: true, window: time(300)...time(600))
        #expect(g.visibleStart == timeline.calls[1].time && g.visibleEnd == timeline.calls[2].time)
    }

    @Test func hitTestingFollowsTheZoom() {
        // Zoomed to minutes 5-10: the prompt at minute 5 is the left edge and the compaction at minute 10 the right edge.
        let g = geo(window: time(300)...time(600))
        let bands = [PanelBand(kind: .prompts, minY: 0, maxY: 14), PanelBand(kind: .data, minY: 16, maxY: 100)]
        #expect(TimelineHitTester.target(atX: 3, y: 5, width: 1000, bands: bands, geometry: g) == .marker("p"))
        #expect(TimelineHitTester.target(atX: 998, y: 50, width: 1000, bands: bands, geometry: g) == .marker("k"))
        #expect(TimelineHitTester.target(atX: 500, y: 50, width: 1000, bands: bands, geometry: g) == .call(1))
    }
}

@Suite struct DwellDelayTests {
    @Test func theSliceDelayIsConfigurableAndEventBarsScaleWithIt() {
        var t = DwellTracker(sliceDelay: 0.3)
        t.pointer(target: .call(1), x: 0, y: 0, now: 0)
        let early = t.tick(now: 0.29), on = t.tick(now: 0.30)
        #expect(!early && on)
        var e = DwellTracker(sliceDelay: 0.4)
        e.pointer(target: .marker("p"), x: 0, y: 0, now: 0)
        #expect(abs((e.nextDeadline ?? 0) - 0.06) < 1e-9)   // 15% of the slice delay, so 0.8 s keeps its 0.12 s
    }

    @Test func theDefaultStillMeans800msAnd120ms() {
        let t = DwellTracker()
        #expect(t.sliceDelay == 0.8 && abs(t.eventDelay - 0.12) < 1e-12)
    }

    @Test func zeroMeansTheCardIsDueAtOnce() {
        var t = DwellTracker(sliceDelay: 0)
        t.pointer(target: .call(1), x: 5, y: 5, now: 10)
        #expect(t.nextDeadline == 10)
        let shown = t.tick(now: 10)
        #expect(shown && t.shown == .call(1))
    }

    @Test func theDelayIsKeptBetweenZeroAndOneSecond() {
        #expect(DwellTracker(sliceDelay: -3).sliceDelay == 0)
        #expect(DwellTracker(sliceDelay: 7).sliceDelay == 1)
        var t = DwellTracker()
        t.sliceDelay = 5
        #expect(t.sliceDelay == 1)
    }

    @Test func changingTheDelayAppliesToTheNextWait() {
        var t = DwellTracker()
        t.sliceDelay = 0.2
        t.pointer(target: .call(1), x: 0, y: 0, now: 0)
        let shown = t.tick(now: 0.2)
        #expect(shown)
    }
}

@Suite struct StackLayoutTests {
    @Test func bandsSitAtTheirOffsetsAndHeadersLeaveGaps() {
        let layout = TimelineStackLayout(items: [
            .init(kind: .ribbon, height: 16), .init(kind: .prompts, height: 14), .init(kind: .header, height: 20), .init(kind: .data, height: 100),
        ], spacing: 2)
        #expect(layout.bands == [
            PanelBand(kind: .ribbon, minY: 0, maxY: 16), PanelBand(kind: .prompts, minY: 18, maxY: 32), PanelBand(kind: .data, minY: 56, maxY: 156),
        ])
        #expect(layout.totalHeight == 156)
    }

    @Test func anEmptyLayoutHasNoBands() {
        let layout = TimelineStackLayout(items: [], spacing: 2)
        #expect(layout.bands.isEmpty && layout.totalHeight == 0)
    }
}

@Suite struct TreemapTests {
    let bounds = TreemapRect(x: 10, y: 20, width: 600, height: 400)

    func area(_ r: TreemapRect) -> Double { r.width * r.height }

    @Test func tilesFillTheContainerExactlyAndStayInsideIt() {
        let tiles = Treemap.layout(weights: [6, 6, 4, 3, 2, 2, 1], in: bounds)
        #expect(tiles.count == 7)
        #expect(abs(tiles.reduce(0) { $0 + area($1) } - area(bounds)) < 1e-6)
        for t in tiles {
            #expect(t.x >= bounds.x - 1e-9 && t.y >= bounds.y - 1e-9)
            #expect(t.x + t.width <= bounds.x + bounds.width + 1e-9 && t.y + t.height <= bounds.y + bounds.height + 1e-9)
        }
    }

    @Test func eachTilesAreaIsItsShareOfTheTotal() {
        let weights = [50.0, 30, 15, 5]
        let tiles = Treemap.layout(weights: weights, in: bounds)
        for (w, t) in zip(weights, tiles) { #expect(abs(area(t) / area(bounds) - w / 100) < 1e-9) }
    }

    @Test func tilesNeverOverlap() {
        let tiles = Treemap.layout(weights: [9, 7, 6, 5, 4, 3, 2, 1], in: bounds)
        for i in tiles.indices { for j in tiles.indices where j > i {
            let w = min(tiles[i].x + tiles[i].width, tiles[j].x + tiles[j].width) - max(tiles[i].x, tiles[j].x)
            let h = min(tiles[i].y + tiles[i].height, tiles[j].y + tiles[j].height) - max(tiles[i].y, tiles[j].y)
            #expect(!(w > 1e-6 && h > 1e-6))
        } }
    }

    @Test func tilesStayCloseToSquareSoLabelsFit() {
        let tiles = Treemap.layout(weights: [6, 6, 4, 3, 2, 2, 1], in: bounds)
        let worst = tiles.map { max($0.width / $0.height, $0.height / $0.width) }.max() ?? 0
        #expect(worst < 3)
    }

    @Test func oneItemFillsTheWholeContainer() {
        #expect(Treemap.layout(weights: [42], in: bounds) == [bounds])
    }

    @Test func zeroWeightsGetEmptyTilesWithoutBreakingTheRest() {
        let tiles = Treemap.layout(weights: [3, 0, 1], in: bounds)
        #expect(tiles.count == 3 && area(tiles[1]) == 0)
        #expect(abs(area(tiles[0]) + area(tiles[2]) - area(bounds)) < 1e-6)
    }

    @Test func nothingToLayOutGivesNothing() {
        #expect(Treemap.layout(weights: [], in: bounds).isEmpty)
        #expect(Treemap.layout(weights: [0, 0], in: bounds).allSatisfy { area($0) == 0 })
    }

    @Test func theTailIsFoldedIntoOneOtherTile() {
        let c = Treemap.collapse(weights: [50, 20, 10, 8, 6, 4, 2], keeping: 4)
        #expect(c.kept == [0, 1, 2, 3] && abs(c.restWeight - 12) < 1e-12 && c.restCount == 3)
        let all = Treemap.collapse(weights: [5, 3], keeping: 4)
        #expect(all.kept == [0, 1] && all.restWeight == 0 && all.restCount == 0)
    }
}

/// Sideways scrolling: trackpad deltas are tiny and continuous, but the Calls axis only moves in whole calls, so the
/// scroll has to say how much it used and let the rest build up.
@Suite struct ScrollPanTests {
    let timeline = TimelineGeometryTests.timeline()   // calls at minutes 0, 5, 10, 20 (seconds 0, 300, 600, 1200)
    var t0: Date { TimelineTests.t0 }
    func time(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    @Test func onTheTimeAxisEveryPointMovesTheViewAndIsUsedUp() throws {
        let g = TimelineGeometry(timeline: timeline, byCalls: false, window: time(300)...time(600))
        let r = try #require(g.panned(byPoints: 50, ofWidth: 1000))
        #expect(r.consumed == 50)
        let moved = TimelineGeometry(timeline: timeline, byCalls: false, window: r.window)
        #expect(abs(moved.domain.lowerBound - 315) < 1e-6 && abs(moved.domain.upperBound - 615) < 1e-6)
    }

    @Test func negativeMovesTheViewEarlier() throws {
        let g = TimelineGeometry(timeline: timeline, byCalls: false, window: time(300)...time(600))
        let r = try #require(g.panned(byPoints: -100, ofWidth: 1000))
        #expect(abs(TimelineGeometry(timeline: timeline, byCalls: false, window: r.window).domain.lowerBound - 270) < 1e-6)
    }

    @Test func onTheCallsAxisASmallScrollMovesNothingAndKeepsItsPoints() throws {
        // Two calls in view across 1000 points: one call is 500 points.
        let g = TimelineGeometry(timeline: timeline, byCalls: true, window: time(300)...time(600))
        let r = try #require(g.panned(byPoints: 300, ofWidth: 1000))
        #expect(r.consumed == 0 && r.window == g.window)
    }

    @Test func onTheCallsAxisItMovesInWholeCallsAndReportsWhatItUsed() throws {
        let g = TimelineGeometry(timeline: timeline, byCalls: true, window: time(300)...time(600))
        let r = try #require(g.panned(byPoints: 620, ofWidth: 1000))
        #expect(r.consumed == 500)
        let moved = TimelineGeometry(timeline: timeline, byCalls: true, window: r.window)
        #expect(moved.visibleCalls == [2, 3])
    }

    @Test func scrollingPastTheEndStopsThereAndDiscardsTheRest() throws {
        let g = TimelineGeometry(timeline: timeline, byCalls: false, window: time(300)...time(600))
        let r = try #require(g.panned(byPoints: 100_000, ofWidth: 1000))
        let moved = TimelineGeometry(timeline: timeline, byCalls: false, window: r.window)
        #expect(abs(moved.domain.upperBound - g.fullDomain.upperBound) < 1e-6)
        #expect(r.consumed == 100_000)   // nothing is left over to jerk the view when the pointer turns round
    }

    @Test func withoutAZoomThereIsNothingToScroll() {
        #expect(TimelineGeometry(timeline: timeline, byCalls: false).panned(byPoints: 50, ofWidth: 1000) == nil)
    }
}
