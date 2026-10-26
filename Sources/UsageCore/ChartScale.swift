import Foundation

/// Round-number axis ticks, so a $0.073 scale reads $0.025 / $0.05 / $0.075 and a 300K one reads 100K / 200K / 300K.
public enum NiceScale {
    public static func step(max: Double, count: Int) -> Double {
        let raw = max / Double(Swift.max(count, 1))
        let magnitude = pow(10, floor(log10(raw)))
        let normalized = raw / magnitude
        let nice: Double = normalized <= 1 ? 1 : normalized <= 2 ? 2 : normalized <= 2.5 ? 2.5 : normalized <= 5 ? 5 : 10
        return nice * magnitude
    }

    /// Positive ticks up to and including the first one at or above `max`. Empty when there is nothing to scale.
    public static func ticks(max: Double, count: Int = 3) -> [Double] {
        guard max > 0, max.isFinite else { return [] }
        let step = step(max: max, count: count)
        let n = Int((max / step).rounded(.up))
        return (1...n).map { Double($0) * step }
    }

    /// Upper bound of the axis: the last tick, or 1 when there is no data so an empty chart still has a frame.
    public static func top(for max: Double, count: Int = 3) -> Double { ticks(max: max, count: count).last ?? 1 }
}

public enum TimeTicks {
    private static let steps: [TimeInterval] = [5, 10, 15, 30, 60, 300, 600, 900, 1_800, 3_600, 7_200, 10_800, 21_600, 43_200, 86_400, 172_800, 604_800]

    /// The smallest standard step that keeps the tick count at or under `maxTicks`.
    public static func step(forSpan span: TimeInterval, maxTicks: Int) -> TimeInterval {
        steps.first { span / $0 <= Double(maxTicks) } ?? steps.last!
    }

    /// Seconds after `start` at which a tick falls, aligned to multiples of `step` on the local clock.
    public static func offsets(start: Date, span: TimeInterval, step: TimeInterval, timeZone: TimeZone) -> [Double] {
        guard step > 0, span > 0 else { return [] }
        let local = start.timeIntervalSince1970 + Double(timeZone.secondsFromGMT(for: start))
        var next = (local / step).rounded(.up) * step
        var out: [Double] = []
        while next - local <= span {
            out.append(next - local)
            next += step
        }
        return out
    }
}
