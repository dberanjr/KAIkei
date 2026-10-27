import Foundation

/// One billed response, laid out for a timeline: how big the context was, what it was made of, and what it cost.
public struct CallPoint: Identifiable, Equatable, Sendable {
    public var id: String
    public var time: Date
    /// Normalised model id (no date suffix), so `claude-opus-5-5-20260101` and `claude-opus-5-5` are one model.
    public var model: String
    public var usage: TokenUsage
    public var thinkingTokens: Int
    public var effort: String?
    public var cost: Double
    public var costParts: CostParts
    public var isSidechain: Bool
    /// Seconds since the previous main-thread response. Nil for the first one, and always for sub-agent calls.
    public var idleGap: TimeInterval?
    /// True when the gap outlasted the cache lifetime, so this call had to re-write the context instead of reading it.
    public var cacheExpired: Bool
    /// How many real prompts the user had typed by this call. 0 means it ran before the first prompt.
    public var turn: Int
    public var tools: [String]
    public var skill: String?
    public var plugin: String?
    /// Set on sub-agent calls: the run they belong to and the parent `Agent` tool_use that spawned it.
    public var agentID: String?
    public var spawnToolUseID: String?
    /// Spend so far in this session, up to and including this call (sub-agent calls included).
    public var cumulativeCost: Double

    public var contextTokens: Int { usage.contextTokens }
    public var cacheRead: Int { usage.cacheRead }
    public var cacheWrite: Int { usage.cacheWrite }
    public var freshInput: Int { usage.input }
    public var output: Int { usage.output }
    public var visibleOutput: Int { max(0, usage.output - thinkingTokens) }
}

public struct TimelineMarker: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case prompt(preview: String)
        case compact(trigger: String, preTokens: Int?, postTokens: Int?, durationMs: Int?)
        case clear
        case command(name: String)
    }
    public var id: String
    public var time: Date
    public var kind: Kind
}

/// A stretch of the main thread running on one model.
public struct ModelSpan: Identifiable, Equatable, Sendable {
    public var model: String
    public var start: Date
    public var end: Date
    public var callCount: Int
    /// What the main thread spent while on this model.
    public var cost: Double
    public var id: String { "\(model)|\(start.timeIntervalSince1970)" }
}

/// What one prompt led to: the main-thread responses and sub-agent calls made before the next prompt.
public struct TurnSummary: Equatable, Sendable {
    public var calls: Int
    public var cost: Double
    public var outputTokens: Int
    public var start: Date
    public var end: Date
}

/// The moment the main thread finished answering prompt number `turn`, and what that turn took.
public struct TurnEnd: Identifiable, Equatable, Sendable {
    public var turn: Int
    /// When the last main-thread response of the turn landed.
    public var time: Date
    /// From the prompt being typed to `time`.
    public var duration: TimeInterval
    /// Main-thread responses and tool calls in the turn.
    public var calls: Int
    public var tools: Int
    /// Tokens the model read across the turn's main-thread responses (fresh and cached), and tokens it wrote.
    public var inputTokens: Int
    public var outputTokens: Int
    /// Extended-thinking tokens in the turn's main-thread responses (already counted inside `outputTokens`).
    public var thinkingTokens: Int
    /// Everything the turn billed, sub-agents included.
    public var cost: Double
    public var id: String { "turn-\(turn)" }
}

public struct SessionTimeline: Equatable, Sendable {
    /// Every response in time order, sub-agent calls included (they cost money) but flagged.
    public var calls: [CallPoint] = []
    public var markers: [TimelineMarker] = []
    /// One per prompt that got an answer, in order.
    public var turnEnds: [TurnEnd] = []
    public var modelSpans: [ModelSpan] = []
    /// How long a cache entry lives: an hour if the session ever wrote a 1-hour entry, otherwise five minutes.
    public var cacheTTL: TimeInterval = 300
    public var peakContext = 0
    public var contextWindow = 0
    public var start = Date.distantPast
    public var end = Date.distantPast

    /// The conversation the user is steering. Sub-agents run separate, smaller conversations that would distort its curve.
    public var mainCalls: [CallPoint] { calls.filter { !$0.isSidechain } }
    public var totalCost: Double { calls.reduce(0) { $0 + $1.cost } }
    public var promptCount: Int { markers.filter { if case .prompt = $0.kind { true } else { false } }.count }
    /// Calls that had to re-write the context because the cache had expired while the session sat idle.
    public var expiryCount: Int { mainCalls.filter(\.cacheExpired).count }
    /// What those re-writes cost beyond what reading the same tokens from a warm cache would have.
    public var coldRewriteExtraCost: Double {
        mainCalls.filter(\.cacheExpired).reduce(0) { sum, call in
            let read = Pricing.effectiveRates(model: call.model, contextTokens: call.contextTokens).cacheRead
            return sum + max(0, call.costParts.cacheWrite - Double(call.cacheWrite) * read / 1_000_000)
        }
    }
    /// Markers that fall in a stretch of time: after `start`, up to and including `end`. A slice is the time between two calls.
    public func markers(after start: Date, through end: Date) -> [TimelineMarker] {
        markers.filter { $0.time > start && $0.time <= end }
    }

    /// What prompt number `n` (1-based) led to. Nil for 0 (work before any prompt) or a number that never happened.
    public func turnSummary(_ n: Int) -> TurnSummary? {
        guard n > 0 else { return nil }
        let turn = calls.filter { $0.turn == n }
        guard let first = turn.first, let last = turn.last else { return nil }
        return TurnSummary(calls: turn.count, cost: turn.reduce(0) { $0 + $1.cost }, outputTokens: turn.reduce(0) { $0 + $1.output },
                           start: first.time, end: last.time)
    }

    public var compactionCount: Int { markers.filter { if case .compact = $0.kind { true } else { false } }.count }
    public init() {}
}

public enum Timelines {
    public static func build(
        records: [UsageRecord], events: [SessionEvent], sessionID: String, billing: CacheWriteBilling = .listPrice
    ) -> SessionTimeline {
        let mine = records.filter { $0.sessionID == sessionID }.sorted { ($0.timestamp, $0.messageID) < ($1.timestamp, $1.messageID) }
        let sessionEvents = events.filter { $0.sessionID == sessionID && !$0.isSidechain }.sorted { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }

        var timeline = SessionTimeline()
        timeline.markers = sessionEvents.compactMap(marker)
        let promptTimes = timeline.markers.compactMap { m -> Date? in if case .prompt = m.kind { m.time } else { nil } }.sorted()
        /// How many prompts had been typed by `time`: a binary search, because a long session has tens of thousands of both.
        func promptsTyped(by time: Date) -> Int {
            var low = 0, high = promptTimes.count
            while low < high {
                let mid = (low + high) / 2
                if promptTimes[mid] <= time { low = mid + 1 } else { high = mid }
            }
            return low
        }

        let main = mine.filter { !$0.isSidechain }
        timeline.cacheTTL = main.contains { $0.usage.cacheWrite1h > 0 } ? 3600 : 300

        var previousMain: Date?
        timeline.calls = mine.map { r in
            var gap: TimeInterval?
            if !r.isSidechain {
                gap = previousMain.map { r.timestamp.timeIntervalSince($0) }
                previousMain = r.timestamp
            }
            return CallPoint(
                id: r.messageID, time: r.timestamp, model: Pricing.normalize(r.model), usage: r.usage,
                thinkingTokens: r.thinkingTokens, effort: r.effort, cost: r.cost(billing),
                costParts: Pricing.costParts(of: r.usage, model: r.model, billing: billing), isSidechain: r.isSidechain,
                idleGap: gap, cacheExpired: gap.map { $0 > timeline.cacheTTL } ?? false,
                turn: promptsTyped(by: r.timestamp), tools: r.tools.values.sorted(), skill: r.skill, plugin: r.plugin,
                agentID: r.agentID, spawnToolUseID: r.spawnToolUseID, cumulativeCost: 0)
        }
        var running = 0.0
        for i in timeline.calls.indices {
            running += timeline.calls[i].cost
            timeline.calls[i].cumulativeCost = running
        }

        timeline.turnEnds = turnEnds(calls: timeline.calls, promptTimes: promptTimes)
        timeline.modelSpans = spans(of: timeline.mainCalls)
        timeline.peakContext = timeline.mainCalls.map(\.contextTokens).max() ?? 0
        timeline.contextWindow = timeline.mainCalls.last.map { Pricing.lookup($0.model).rate.contextWindow } ?? 0
        let times = timeline.calls.map(\.time) + timeline.markers.map(\.time)
        timeline.start = times.min() ?? .distantPast
        timeline.end = times.max() ?? .distantPast
        return timeline
    }

    private static func turnEnds(calls: [CallPoint], promptTimes: [Date]) -> [TurnEnd] {
        let byTurn = Dictionary(grouping: calls.filter { $0.turn > 0 }, by: \.turn)
        return promptTimes.indices.compactMap { i in
            guard let turn = byTurn[i + 1] else { return nil }
            let main = turn.filter { !$0.isSidechain }
            guard let end = (main.isEmpty ? turn : main).map(\.time).max() else { return nil }
            return TurnEnd(
                turn: i + 1, time: end, duration: max(0, end.timeIntervalSince(promptTimes[i])), calls: main.count,
                tools: main.reduce(0) { $0 + $1.tools.count }, inputTokens: main.reduce(0) { $0 + $1.contextTokens },
                outputTokens: main.reduce(0) { $0 + $1.output },
                thinkingTokens: main.reduce(0) { $0 + $1.thinkingTokens }, cost: turn.reduce(0) { $0 + $1.cost })
        }
    }

    private static func marker(for event: SessionEvent) -> TimelineMarker? {
        switch event.kind {
        case .prompt(let preview): return TimelineMarker(id: event.id, time: event.timestamp, kind: .prompt(preview: preview))
        case .compact(let trigger, let pre, let post, let ms):
            return TimelineMarker(id: event.id, time: event.timestamp, kind: .compact(trigger: trigger, preTokens: pre, postTokens: post, durationMs: ms))
        case .command(let name):
            switch name {
            case "/clear": return TimelineMarker(id: event.id, time: event.timestamp, kind: .clear)
            // The compaction itself is recorded as its own boundary row with sizes and trigger; the command would duplicate it.
            case "/compact": return nil
            default: return TimelineMarker(id: event.id, time: event.timestamp, kind: .command(name: name))
            }
        }
    }

    /// Consecutive calls on the same model form a span. Each span ends where the next begins, so the ribbon has no gaps.
    private static func spans(of calls: [CallPoint]) -> [ModelSpan] {
        var spans: [ModelSpan] = []
        for call in calls {
            if let last = spans.last, last.model == call.model {
                spans[spans.count - 1].callCount += 1
                spans[spans.count - 1].end = call.time
                spans[spans.count - 1].cost += call.cost
            } else {
                if !spans.isEmpty { spans[spans.count - 1].end = call.time }
                spans.append(ModelSpan(model: call.model, start: call.time, end: call.time, callCount: 1, cost: call.cost))
            }
        }
        return spans
    }
}
