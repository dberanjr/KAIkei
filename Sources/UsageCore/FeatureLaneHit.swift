import Foundation

/// What a lane's hover card is about.
public enum LaneTarget: Equatable, Hashable, Sendable {
    /// A loop iteration, by its 1-based index.
    case iteration(Int)
    /// A loop decision, by signal id.
    case decision(String)
    /// A sub-agent run, by agent id.
    case subagent(String)
    /// A test run, by tool-use id.
    case testRun(String)
}

extension FeatureLanes {
    /// What is at axis position `x` in a lane. Distances are in axis units (seconds in Time mode, calls in Calls mode), so
    /// the caller converts its pixel tolerance. `row` picks between sub-agent runs that overlap in time.
    public func target(lane: FeatureLane, atX x: Double, row: Int?, tolerance: Double, geometry g: TimelineGeometry) -> LaneTarget? {
        switch lane {
        case .loop:
            guard let loop else { return nil }
            let near = loop.decisions.map { ($0, abs(g.x(time: $0.time) - x)) }.filter { $0.1 <= tolerance }.min { $0.1 < $1.1 }
            if let near { return .decision(near.0.id) }
            return loop.iterations.first {
                let start = g.x(time: $0.start)
                return x >= start - tolerance && x <= max(g.x(endingAt: $0.end), start) + tolerance
            }.map { .iteration($0.index) }
        case .subagents:
            return subagents?.runs.first {
                (row == nil || $0.row == row) && x >= g.x(time: $0.start) - tolerance && x <= max(g.x(endingAt: $0.end), g.x(time: $0.start)) + tolerance
            }.map { .subagent($0.id) }
        case .tests:
            let near = tests?.runs.map { ($0, abs(g.x(time: $0.time) - x)) }.filter { $0.1 <= tolerance }.min { $0.1 < $1.1 }
            return near.map { .testRun($0.0.id) }
        case .goal, .plugins:
            return nil
        }
    }
}
