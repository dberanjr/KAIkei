import Foundation

/// Spend by hour of the day, as a circle of 24: the facts the radial chart and its caption are built from.
public struct HourlyProfile: Equatable, Sendable {
    public let costs: [Double]

    /// Always 24 entries, hour 0 first; short input is padded and long input trimmed.
    public init(costs: [Double]) {
        self.costs = Array((costs + [Double](repeating: 0, count: 24)).prefix(24))
    }

    public var total: Double { costs.reduce(0, +) }
    public var peakCost: Double { costs.max() ?? 0 }
    public var peakHour: Int? { peakCost > 0 ? costs.firstIndex(of: peakCost) : nil }
    public var activeHours: Int { costs.filter { $0 > 0 }.count }

    /// The run of `hours` consecutive hours holding the most spend, and its share of the total. Wraps past midnight, since
    /// 11 PM and 1 AM are neighbours on the dial. Nil when nothing was spent.
    public func busiestWindow(hours: Int) -> (start: Int, share: Double)? {
        guard total > 0, hours > 0, hours <= 24 else { return nil }
        let sums = (0..<24).map { start in (0..<hours).reduce(0.0) { $0 + costs[(start + $1) % 24] } }
        let best = sums.max() ?? 0
        guard let start = sums.firstIndex(of: best) else { return nil }
        return (start, best / total)
    }

    /// "12 AM", "5 AM", "12 PM", "10 PM".
    public static func label(_ hour: Int) -> String { "\(hour % 12 == 0 ? 12 : hour % 12) \(hour < 12 ? "AM" : "PM")" }
}

/// The geometry of a polar-area chart: 24 wedges of 15 degrees, midnight at the top, hours running clockwise like a clock.
public enum Rose {
    public static let wedgeDegrees = 15.0

    /// Degrees clockwise from twelve o'clock where an hour's wedge begins.
    public static func startAngle(hour: Int) -> Double { Double(hour) * wedgeDegrees }

    /// How far out a wedge reaches. Scaled so the wedge's *area*, not its length, is proportional to the value: with a
    /// plain length a wedge twice as long looks four times as big. Zero sits at the edge of the hole, the peak at the rim.
    public static func radius(value: Double, peak: Double, inner: Double, outer: Double) -> Double {
        guard peak > 0, value > 0 else { return inner }
        let share = min(value / peak, 1)
        return (inner * inner + share * (outer * outer - inner * inner)).squareRoot()
    }

    /// A point on a circle, `degrees` clockwise from the top, in screen coordinates where y grows downward.
    public static func point(center: (x: Double, y: Double), radius: Double, degrees: Double) -> (x: Double, y: Double) {
        let a = degrees * .pi / 180
        return (center.x + radius * sin(a), center.y - radius * cos(a))
    }
}
