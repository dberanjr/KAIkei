import Foundation

/// Maps times and calls onto the timeline's shared horizontal axis. Every panel uses the same mapping, so a prompt, a
/// compaction and the cost it caused line up vertically. "Time" spaces calls by when they happened (idle gaps show, which
/// is when caches expire); "Calls" spaces them evenly (long sessions stay readable).
///
/// A zoom is a `window` of real dates, not a range of axis units: it keeps its meaning when the session grows while the
/// window is open, and when the axis is switched between Time and Calls.
public struct TimelineGeometry: Sendable {
    public let timeline: SessionTimeline
    public let byCalls: Bool
    public let window: ClosedRange<Date>?

    /// The narrowest stretch of time a zoom may show, so a stray click never zooms into nothing.
    public static let minimumSeconds = 20.0
    /// Slider ceiling. Time mode is also held to `minimumSeconds`; Calls mode snaps to whole calls.
    public static let maxZoom = 64.0

    public init(timeline: SessionTimeline, byCalls: Bool, window: ClosedRange<Date>? = nil) {
        self.timeline = timeline
        self.byCalls = byCalls
        self.window = window
    }

    private var calls: [CallPoint] { timeline.calls }
    public var spanSeconds: Double { max(timeline.end.timeIntervalSince(timeline.start), 60) }

    /// The whole session.
    public var fullDomain: ClosedRange<Double> {
        byCalls ? -0.5...(Double(max(calls.count, 1)) - 0.5) : 0...(spanSeconds * 1.01)
    }

    /// What the panels draw: the zoom window if there is one (kept inside the session), otherwise everything.
    public var domain: ClosedRange<Double> {
        guard let window else { return fullDomain }
        let full = fullDomain
        let lo: Double, hi: Double
        if byCalls {
            lo = x(time: window.lowerBound)
            hi = x(endingAt: window.upperBound)
        } else {
            lo = max(window.lowerBound.timeIntervalSince(timeline.start), full.lowerBound)
            hi = min(window.upperBound.timeIntervalSince(timeline.start), full.upperBound)
        }
        return lo < hi ? lo...hi : fullDomain
    }

    public var zoomFactor: Double {
        let full = fullDomain, d = domain
        return (full.upperBound - full.lowerBound) / max(d.upperBound - d.lowerBound, 1e-9)
    }
    public var isZoomed: Bool { zoomFactor > 1.0001 }

    public func x(callIndex i: Int) -> Double { byCalls ? Double(i) : calls[i].time.timeIntervalSince(timeline.start) }

    /// Position of a moment. In Calls mode that is just before the first call at or after it.
    public func x(time: Date) -> Double {
        guard byCalls else { return time.timeIntervalSince(timeline.start) }
        return Double(calls.firstIndex { $0.time >= time } ?? calls.count) - 0.5
    }

    /// Right edge of a span that ends at a call: includes that call's slot in Calls mode.
    public func x(endingAt time: Date) -> Double {
        guard byCalls else { return time.timeIntervalSince(timeline.start) }
        return Double(calls.lastIndex { $0.time <= time } ?? 0) + 0.5
    }

    /// The stretch of axis a model span covers. Spans meet end to start, so the ribbon has no gaps.
    public func xRange(of span: ModelSpan) -> ClosedRange<Double> {
        let isLast = span.id == timeline.modelSpans.last?.id
        return x(time: span.start)...(isLast ? x(endingAt: span.end) : x(time: span.end))
    }

    // MARK: what is in view

    /// Calls inside the current domain, by their position in the full list.
    public var visibleCalls: [Int] {
        let d = domain, eps = 1e-6
        return calls.indices.filter { let v = x(callIndex: $0); return v >= d.lowerBound - eps && v <= d.upperBound + eps }
    }

    /// Hover only offers calls that are on screen: with a zoom, the nearest call overall may be far outside the window.
    public func nearestCall(to x: Double) -> Int? {
        let candidates = isZoomed ? visibleCalls : Array(calls.indices)
        return candidates.min { abs(self.x(callIndex: $0) - x) < abs(self.x(callIndex: $1) - x) }
    }

    public var visibleStart: Date {
        guard isZoomed else { return timeline.start }
        if byCalls { return visibleCalls.first.map { calls[$0].time } ?? window?.lowerBound ?? timeline.start }
        return timeline.start.addingTimeInterval(domain.lowerBound)
    }

    public var visibleEnd: Date {
        guard isZoomed else { return timeline.end }
        if byCalls { return visibleCalls.last.map { calls[$0].time } ?? window?.upperBound ?? timeline.end }
        return timeline.start.addingTimeInterval(domain.upperBound)
    }

    /// What was spent in the calls on screen (sub-agents included, as in the session total).
    public var visibleCost: Double { visibleCalls.reduce(0) { $0 + calls[$1].cost } }

    // MARK: zooming

    private var minimumWidth: Double { byCalls ? 1 : Self.minimumSeconds }

    /// A window `factor` times narrower than the whole session, around `anchor` (an axis position; the middle of the
    /// current view when nil). Slides inward at the ends rather than leaving the session. Nil for a factor of 1 or less.
    public func window(zoomFactor factor: Double, anchor: Double?) -> ClosedRange<Date>? {
        guard factor > 1 else { return nil }
        let full = fullDomain, fullWidth = full.upperBound - full.lowerBound
        let width = max(fullWidth / min(factor, Self.maxZoom * 1_000), minimumWidth)
        guard width < fullWidth else { return nil }
        let d = domain
        let center = anchor ?? (d.lowerBound + d.upperBound) / 2
        let lo = min(max(center - width / 2, full.lowerBound), full.upperBound - width)
        return window(fromAxis: lo, lo + width)
    }

    /// Zooms to a dragged selection, given in either direction. Clamped to the session and widened to the minimum.
    public func window(selecting a: Double, _ b: Double) -> ClosedRange<Date>? {
        let full = fullDomain
        var lo = max(min(a, b), full.lowerBound), hi = min(max(a, b), full.upperBound)
        if hi - lo < minimumWidth {
            let mid = (lo + hi) / 2
            lo = min(max(mid - minimumWidth / 2, full.lowerBound), full.upperBound - minimumWidth)
            hi = lo + minimumWidth
        }
        return window(fromAxis: lo, hi)
    }

    /// Slides the window by a fraction of its own width, stopping at the ends of the session. Nil when not zoomed.
    public func panned(by fraction: Double) -> ClosedRange<Date>? {
        guard isZoomed else { return nil }
        let full = fullDomain, d = domain, width = d.upperBound - d.lowerBound
        let lo = min(max(d.lowerBound + fraction * width, full.lowerBound), full.upperBound - width)
        return window(fromAxis: lo, lo + width)
    }

    /// The outcome of a scroll: the new window, and how many of the points scrolled it used.
    public struct PanResult: Equatable, Sendable {
        public var window: ClosedRange<Date>?
        public var consumed: Double
    }

    /// Moves the view by points of screen (positive is later), for scroll-wheel and trackpad panning. The Time axis moves
    /// continuously. The Calls axis moves in whole calls, so a scroll too small for one call uses nothing and the caller
    /// keeps accumulating. Hitting an end of the session uses everything, so the view does not lurch when the user reverses.
    public func panned(byPoints points: Double, ofWidth width: Double) -> PanResult? {
        guard isZoomed, width > 0 else { return nil }
        let d = domain, span = d.upperBound - d.lowerBound
        if !byCalls {
            return PanResult(window: panned(by: points / width), consumed: points)
        }
        let slot = width / span
        let whole = (points / slot).rounded(.towardZero)
        guard whole != 0 else { return PanResult(window: window, consumed: 0) }
        let full = fullDomain
        let atEnd = (whole > 0 && d.upperBound >= full.upperBound - 1e-9) || (whole < 0 && d.lowerBound <= full.lowerBound + 1e-9)
        let moved = panned(by: whole / span)
        return PanResult(window: moved, consumed: atEnd ? points : whole * slot)
    }

    /// The window for a stretch of axis. On the Calls axis it snaps outward to the whole calls it touches.
    private func window(fromAxis lo: Double, _ hi: Double) -> ClosedRange<Date>? {
        let full = fullDomain
        if lo <= full.lowerBound + 1e-9, hi >= full.upperBound - 1e-9 { return nil }
        guard byCalls else { return timeline.start.addingTimeInterval(lo)...timeline.start.addingTimeInterval(hi) }
        guard !calls.isEmpty else { return nil }
        let first = min(max(Int((lo + 0.5).rounded(.down)), 0), calls.count - 1)
        let last = min(max(Int((hi - 0.5).rounded(.up)), first), calls.count - 1)
        if first == 0, last == calls.count - 1 { return nil }
        return calls[first].time...calls[last].time
    }

    // MARK: ticks and labels

    public func ticks(maxTicks: Int) -> [Double] {
        let d = domain
        if byCalls {
            let lo = max(Int((d.lowerBound + 0.5).rounded(.up)), 0), hi = min(Int((d.upperBound - 0.5).rounded(.down)), calls.count - 1)
            guard hi >= lo else { return [] }
            let step = max(1, Int(NiceScale.step(max: Double(hi - lo + 1), count: maxTicks).rounded()))
            // Multiples of the step, so ticks stay put while zooming in on a region rather than shifting under the pointer.
            let firstTick = Int((Double(lo) / Double(step)).rounded(.up)) * step
            return stride(from: firstTick, through: hi, by: step).map(Double.init)
        }
        let span = d.upperBound - d.lowerBound
        let step = TimeTicks.step(forSpan: span, maxTicks: maxTicks)
        let origin = timeline.start.addingTimeInterval(d.lowerBound)
        return TimeTicks.offsets(start: origin, span: span, step: step, timeZone: .current).map { $0 + d.lowerBound }
    }

    public func label(forX x: Double) -> String {
        if byCalls { return "#\(Int(x.rounded()) + 1)" }
        let moment = timeline.start.addingTimeInterval(x)
        let d = domain
        if d.upperBound - d.lowerBound <= 150 { return moment.formatted(.dateTime.hour().minute().second()) }
        return spanSeconds > 20 * 3600 && !isZoomed
            ? moment.formatted(.dateTime.month(.abbreviated).day().hour().minute())
            : moment.formatted(.dateTime.hour().minute())
    }
}
