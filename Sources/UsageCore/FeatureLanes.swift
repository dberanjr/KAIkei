import Foundation

/// The Claude Code features that get a lane under the session timeline, in the order they are drawn.
public enum FeatureLane: String, CaseIterable, Identifiable, Sendable {
    case loop, goal, subagents, tests, plugins
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .loop: "/loop"
        case .goal: "/goal"
        case .subagents: "Sub-agents"
        case .tests: "Test runs"
        case .plugins: "Plugins and skills"
        }
    }
}

/// Every lane one session has data for. A lane the session never used is nil, so it takes no room.
public struct FeatureLanes: Equatable, Sendable {
    public var loop: LoopLane?
    public var subagents: SubagentLane?
    public var tests: TestLane?
    public var plugins: PluginLane?

    public init(loop: LoopLane? = nil, subagents: SubagentLane? = nil, tests: TestLane? = nil, plugins: PluginLane? = nil) {
        self.loop = loop; self.subagents = subagents; self.tests = tests; self.plugins = plugins
    }

    /// Lanes with data, in drawing order.
    public var present: [FeatureLane] {
        FeatureLane.allCases.filter { lane in
            switch lane {
            case .loop: loop != nil
            case .goal: false  // until the goal lane exists
            case .subagents: subagents != nil
            case .tests: tests != nil
            case .plugins: plugins != nil
            }
        }
    }
    public var isEmpty: Bool { present.isEmpty }

    /// What a cached `FeatureLanes` was built from. Includes the total cost so that costing the same calls differently (the
    /// billing setting) or a response whose usage grew after it was first written does not leave stale numbers on screen.
    public static func cacheKey(timeline: SessionTimeline, signalCount: Int) -> [Int] {
        [timeline.calls.count, signalCount, Int(timeline.end.timeIntervalSince1970), Int((timeline.totalCost * 1_000_000).rounded())]
    }

    public static func build(signals: [FeatureSignal], timeline: SessionTimeline, sessionID: String) -> FeatureLanes {
        let mine = signals.filter { $0.sessionID == sessionID }
        return FeatureLanes(
            loop: loop(signals: mine, timeline: timeline, sessionID: sessionID),
            subagents: subagents(signals: mine, timeline: timeline),
            tests: tests(signals: mine),
            plugins: plugins(timeline: timeline))
    }
}

/// Where the lanes' markers sit on the context chart, as a share of its height from the bottom. The overlay draws them
/// there and the hit-tester looks for them there, so the two cannot disagree.
public enum FeatureOverlayLayout {
    public static let iconFraction = 0.93
    public static let testDotFraction = 0.82
}
