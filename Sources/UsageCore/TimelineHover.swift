import Foundation

/// A horizontal band of the timeline stack, in points from its top. Hit-testing needs to know which kind of panel the
/// pointer is over, because the same x means different things in the model ribbon, the prompt lane and a data panel.
public struct PanelBand: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case ribbon, prompts, data }
    public var kind: Kind
    public var minY: Double
    public var maxY: Double
    public init(kind: Kind, minY: Double, maxY: Double) {
        self.kind = kind; self.minY = minY; self.maxY = maxY
    }
}

/// What a hover card is about.
public enum HoverTarget: Equatable, Hashable, Sendable {
    /// A call, by its position in the timeline's call list: the "time slice" ending at that call.
    case call(Int)
    /// A prompt, compaction or clear, by marker id.
    case marker(String)
    /// A stretch of the model ribbon, by span id.
    case modelSpan(String)
}

public enum TimelineHitTester {
    /// How close, in points, the pointer must be to a thin line (a prompt tick, a compaction) to count as on it.
    public static let tolerance = 5.0

    public static func x(atPixel px: Double, width: Double, geometry: TimelineGeometry) -> Double {
        let d = geometry.domain
        return d.lowerBound + px / max(width, 1) * (d.upperBound - d.lowerBound)
    }

    public static func pixel(forX x: Double, width: Double, geometry: TimelineGeometry) -> Double {
        let d = geometry.domain
        return (x - d.lowerBound) / (d.upperBound - d.lowerBound) * width
    }

    /// What is under the pointer. Nil over gaps between panels and over empty parts of a lane.
    public static func target(atX px: Double, y: Double, width: Double, bands: [PanelBand], geometry g: TimelineGeometry) -> HoverTarget? {
        guard let band = bands.first(where: { y >= $0.minY && y <= $0.maxY }) else { return nil }
        let x = Self.x(atPixel: px, width: width, geometry: g)

        func nearestMarker(where include: (TimelineMarker) -> Bool) -> HoverTarget? {
            let hits = g.timeline.markers.filter(include).map { ($0, abs(pixel(forX: g.x(time: $0.time), width: width, geometry: g) - px)) }
                .filter { $0.1 <= tolerance }
            return hits.min { $0.1 < $1.1 }.map { .marker($0.0.id) }
        }
        func isDrawn(_ m: TimelineMarker) -> Bool { if case .command = m.kind { false } else { true } }
        func isStructural(_ m: TimelineMarker) -> Bool {
            switch m.kind {
            case .compact, .clear: true
            default: false
            }
        }

        switch band.kind {
        case .ribbon:
            return g.timeline.modelSpans.first { g.xRange(of: $0).contains(x) }.map { .modelSpan($0.id) }
        case .prompts:
            return nearestMarker(where: isDrawn)
        case .data:
            if let line = nearestMarker(where: isStructural) { return line }
            return g.nearestCall(to: x).map { .call($0) }
        }
    }
}

/// Decides when a hover card appears. A slice card waits for the pointer to rest for `sliceDelay` (0.8 s by default, set by
/// the user between 0 and 1 s); the small cards on event bars answer in a fraction of that. Pure and clock-free (the caller
/// passes `now`), so the timing rules can be tested exactly.
public struct DwellTracker: Equatable, Sendable {
    public static let defaultSliceDelay = 0.8
    public static let maximumDelay = 1.0
    /// Event bars wait this share of the slice delay, so the default 0.8 s gives the familiar 0.12 s.
    public static let eventDelayRatio = 0.15
    /// Movement under this many points is hand tremor and does not restart the wait.
    public static let jitter = 3.0
    /// A shown card stays until the pointer has travelled this far from where it settled.
    public static let leash = 6.0

    public var sliceDelay: TimeInterval { didSet { sliceDelay = Self.clamp(sliceDelay) } }
    public var eventDelay: TimeInterval { sliceDelay * Self.eventDelayRatio }

    public private(set) var candidate: HoverTarget?
    public private(set) var shown: HoverTarget?
    private var anchorX = 0.0, anchorY = 0.0, since = 0.0
    private var shownX = 0.0, shownY = 0.0

    public init(sliceDelay: TimeInterval = DwellTracker.defaultSliceDelay) { self.sliceDelay = Self.clamp(sliceDelay) }

    public static func clamp(_ delay: TimeInterval) -> TimeInterval { min(max(delay, 0), maximumDelay) }

    public func delay(for target: HoverTarget) -> TimeInterval {
        if case .call = target { return sliceDelay }
        return eventDelay
    }

    public mutating func pointer(target: HoverTarget?, x: Double, y: Double, now: TimeInterval) {
        guard let target else { leave(); return }
        if let current = shown {
            if target == current || (isCall(target) && isCall(current)), distance(x, y, shownX, shownY) <= Self.leash { return }
            shown = nil
        }
        let moved = distance(x, y, anchorX, anchorY) > Self.jitter
        if let c = candidate, !moved, c == target || (isCall(c) && isCall(target)) {
            candidate = target  // still the same wait; track the slice now under the pointer
        } else {
            candidate = target
            anchorX = x; anchorY = y; since = now
        }
    }

    public mutating func leave() {
        candidate = nil
        shown = nil
    }

    /// Shows the card once the wait is over. True when something new became visible.
    @discardableResult
    public mutating func tick(now: TimeInterval) -> Bool {
        guard shown == nil, let c = candidate, now - since >= delay(for: c) - 1e-9 else { return false }
        shown = c
        shownX = anchorX; shownY = anchorY
        return true
    }

    /// When `tick` should next run, or nil when there is nothing pending.
    public var nextDeadline: TimeInterval? {
        guard shown == nil, let c = candidate else { return nil }
        return since + delay(for: c)
    }

    private func isCall(_ t: HoverTarget) -> Bool { if case .call = t { true } else { false } }
    private func distance(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double { ((x1 - x2) * (x1 - x2) + (y1 - y2) * (y1 - y2)).squareRoot() }
}

/// One item in the timeline's vertical stack.
public struct StackItem: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case ribbon, prompts, data, header }
    public var kind: Kind
    public var height: Double
    public init(kind: Kind, height: Double) { self.kind = kind; self.height = height }
}

/// The vertical layout of the chart stack, described once so the views and the hit-testing cannot drift apart: the same
/// items build the views and produce the `PanelBand`s the pointer is matched against. Headers take space but are not hoverable.
public struct TimelineStackLayout: Equatable, Sendable {
    public var items: [StackItem]
    public var spacing: Double
    public init(items: [StackItem], spacing: Double) { self.items = items; self.spacing = spacing }

    public var bands: [PanelBand] {
        var y = 0.0
        var out: [PanelBand] = []
        for item in items {
            switch item.kind {
            case .ribbon: out.append(PanelBand(kind: .ribbon, minY: y, maxY: y + item.height))
            case .prompts: out.append(PanelBand(kind: .prompts, minY: y, maxY: y + item.height))
            case .data: out.append(PanelBand(kind: .data, minY: y, maxY: y + item.height))
            case .header: break
            }
            y += item.height + spacing
        }
        return out
    }

    public var totalHeight: Double { items.isEmpty ? 0 : items.reduce(0) { $0 + $1.height } + spacing * Double(items.count - 1) }
}
