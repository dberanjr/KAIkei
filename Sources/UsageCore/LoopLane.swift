import Foundation

/// One run of a `/loop`: from the moment it started to the last thing it did, with what the iteration cost.
public struct LoopIteration: Identifiable, Equatable, Sendable {
    public enum Start: Equatable, Sendable {
        /// The user ran `/loop`, or Claude invoked the loop skill.
        case invoked
        /// The wake-up Claude asked for with `ScheduleWakeup`.
        case scheduledWake
        /// A wake-up nobody asked for: the previous iteration neither rescheduled nor stopped.
        case fallbackWake
    }
    public var id: String
    /// 1-based position within the session's loop.
    public var index: Int
    public var start: Date
    /// When the iteration last did anything. The wait before the next one is not part of it.
    public var end: Date
    /// Every billed response from `start` until the next iteration, a prompt you typed, or the end of the session,
    /// sub-agent calls included.
    public var cost: Double
    public var callCount: Int
    public var outputTokens: Int
    public var startedBy: Start
    /// When Claude said this wake-up was due.
    public var plannedFor: Date?
    public var prompt: String
    /// How late the wake-up fired compared with when it was due.
    public var lateness: TimeInterval? { plannedFor.map { start.timeIntervalSince($0) } }
}

/// What Claude decided at the end of an iteration.
public struct LoopDecision: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case again(delaySeconds: Int, reason: String?)
        case stop
    }
    public var id: String
    public var time: Date
    public var kind: Kind
    public var afterIteration: Int
}

public struct LoopLane: Equatable, Sendable {
    public var iterations: [LoopIteration]
    public var decisions: [LoopDecision]
    public var totalCost: Double { iterations.reduce(0) { $0 + $1.cost } }
    public var averageCost: Double { iterations.isEmpty ? 0 : totalCost / Double(iterations.count) }
}

extension FeatureLanes {
    /// Two rows that describe the same wake-up (the harness's fire row and the `/loop` command it types) are this close.
    private static let wakeupCommandWindow: TimeInterval = 2

    public static func loop(signals: [FeatureSignal], timeline: SessionTimeline, sessionID: String) -> LoopLane? {
        let mine = signals.filter { $0.sessionID == sessionID && !$0.isSidechain }.sorted { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }
        let wakeTimes = mine.compactMap { s -> Date? in if case .loopWakeup = s.kind { s.timestamp } else { nil } }

        struct Boundary { var time: Date; var isWake: Bool; var prompt: String }
        var boundaries: [Boundary] = []
        var prompt = ""
        for s in mine {
            switch s.kind {
            case .loopInvoked(let p):
                if wakeTimes.contains(where: { abs($0.timeIntervalSince(s.timestamp)) <= wakeupCommandWindow }) { prompt = p; continue }
                prompt = p
                boundaries.append(Boundary(time: s.timestamp, isWake: false, prompt: p))
            case .loopWakeup:
                boundaries.append(Boundary(time: s.timestamp, isWake: true, prompt: prompt))
            default: break
            }
        }
        guard !boundaries.isEmpty else { return nil }

        var decisions: [LoopDecision] = []
        for s in mine {
            let kind: LoopDecision.Kind
            switch s.kind {
            case .wakeupScheduled(_, let delay, let reason): kind = .again(delaySeconds: delay, reason: reason)
            case .loopStopped: kind = .stop
            default: continue
            }
            guard let owner = boundaries.lastIndex(where: { $0.time <= s.timestamp }) else { continue }
            decisions.append(LoopDecision(id: s.id, time: s.timestamp, kind: kind, afterIteration: owner + 1))
        }
        let acks = mine.compactMap { s -> (time: Date, due: Date)? in if case .wakeupAck(_, let due) = s.kind { (s.timestamp, due) } else { nil } }
        let promptTimes = timeline.markers.compactMap { m -> Date? in if case .prompt = m.kind { m.time } else { nil } }

        var iterations: [LoopIteration] = []
        for (i, b) in boundaries.enumerated() {
            let nextStart = i + 1 < boundaries.count ? boundaries[i + 1].time : Date.distantFuture
            let limit = min(nextStart, promptTimes.filter { $0 > b.time }.min() ?? .distantFuture)
            let calls = timeline.calls.filter { $0.time >= b.time && $0.time < limit }
            let lastActivity = (calls.map(\.time) + decisions.filter { $0.afterIteration == i + 1 && $0.time < limit }.map(\.time)).max() ?? b.time

            var startedBy = LoopIteration.Start.invoked
            var planned: Date?
            if b.isWake {
                let previousAgain = decisions.contains { $0.afterIteration == i && { if case .again = $0.kind { true } else { false } }($0) }
                startedBy = (i == 0 || previousAgain) ? .scheduledWake : .fallbackWake
                let since = i > 0 ? boundaries[i - 1].time : Date.distantPast
                planned = acks.filter { $0.time > since && $0.time <= b.time }.max { $0.time < $1.time }?.due
            }
            iterations.append(LoopIteration(
                id: "\(sessionID)|loop|\(i + 1)", index: i + 1, start: b.time, end: lastActivity,
                cost: calls.reduce(0) { $0 + $1.cost }, callCount: calls.count, outputTokens: calls.reduce(0) { $0 + $1.output },
                startedBy: startedBy, plannedFor: planned, prompt: b.prompt))
        }
        return LoopLane(iterations: iterations, decisions: decisions)
    }
}
