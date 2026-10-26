import Foundation

/// What a click on a number or bar opens. Each case is a filter over the same records the main view aggregates.
public enum DrillTarget: Hashable, Sendable, Codable {
    case total
    case model(String), skill(String), plugin(String), tool(String), project(String), session(String)
    case day(Date)

    public var title: String {
        switch self {
        case .total: "All usage"
        case .model(let id): ModelFamily.displayName(modelID: id)
        case .skill(let s), .plugin(let s), .tool(let s), .project(let s): s
        case .session(let id): "Session " + id.prefix(8)
        case .day(let d): d.formatted(.dateTime.weekday(.wide).month().day())
        }
    }

    public var kind: String {
        switch self {
        case .total: "All usage"
        case .model: "Model"
        case .skill: "Skill"
        case .plugin: "Plugin"
        case .tool: "Tool"
        case .project: "Project"
        case .session: "Session"
        case .day: "Day"
        }
    }
}

public struct MessageRow: Identifiable, Equatable, Sendable {
    public var messageID: String
    public var sessionID: String
    public var timestamp: Date
    public var model: String
    public var cost: Double
    public var usage: TokenUsage
    public var tools: [String]
    public var skill: String?
    public var project: String
    public var id: String { sessionID + "|" + messageID }
}

public struct SessionRow: Identifiable, Equatable, Sendable {
    public var sessionID: String
    public var project: String
    public var cost: Double
    public var messageCount: Int
    public var firstSeen: Date
    public var lastSeen: Date
    public var id: String { sessionID }
}

public struct ContextPoint: Equatable, Sendable {
    public var time: Date
    public var tokens: Int
}

public struct DrillDetail: Sendable {
    public var target: DrillTarget
    /// Totals and breakdowns for the selected range (or the single day, for a day target).
    public var snapshot: Snapshot
    /// Daily cost over the last 30 days for this target only, whatever range is selected.
    public var trend: [DailyPoint]
    public var firstSeen: Date?
    public var lastSeen: Date?
    public var topSessions: [SessionRow]
    public var topMessages: [MessageRow]
    /// Cost by hour of day (0...23, local time) over the selected range.
    public var hourly: [Double]
    /// Context-window occupancy over time. Only filled for a session target.
    public var contextTimeline: [ContextPoint]
    /// The full context-window, model and cache picture over time. Only filled for a session target.
    public var timeline: SessionTimeline?
}

public enum Drilldown {
    public static let listLimit = 10

    public static func detail(
        records: [UsageRecord], events: [SessionEvent] = [], target: DrillTarget, range: TimeRange, now: Date, calendar: Calendar,
        billing: CacheWriteBilling = .listPrice
    ) -> DrillDetail {
        let matching = records.filter { matches($0, target) }
        // A day and a session are bounded things in their own right, so the selected range does not apply to them.
        // (A session's row shows its all-time cost; its detail must add up to the same number.)
        let from: Date, to: Date
        switch target {
        case .day(let d):
            from = calendar.startOfDay(for: d)
            to = calendar.date(byAdding: .day, value: 1, to: from) ?? from.addingTimeInterval(86_400)
        case .session:
            from = .distantPast
            to = now.addingTimeInterval(86_400)
        default:
            from = Aggregator.start(of: range, now: now, calendar: calendar)
            to = Aggregator.end(of: range, now: now, calendar: calendar)
        }
        let scoped = matching.filter { $0.timestamp >= from && $0.timestamp < to }

        let snapshot = Aggregator.snapshot(records: scoped, range: .all, now: now, calendar: calendar, billing: billing)
        let trend = Aggregator.snapshot(records: matching, range: .month, now: now, calendar: calendar, billing: billing).daily

        let messages = scoped
            .map { r in
                MessageRow(
                    messageID: r.messageID, sessionID: r.sessionID, timestamp: r.timestamp, model: Pricing.normalize(r.model),
                    cost: r.cost(billing), usage: r.usage, tools: r.tools.values.sorted(), skill: r.skill,
                    project: Aggregator.projectName(r.cwd))
            }
            .sorted { ($0.cost, $0.timestamp) > ($1.cost, $1.timestamp) }

        var bySession: [String: SessionRow] = [:]
        for r in scoped {
            var row = bySession[r.sessionID] ?? SessionRow(
                sessionID: r.sessionID, project: Aggregator.projectName(r.cwd), cost: 0, messageCount: 0,
                firstSeen: r.timestamp, lastSeen: r.timestamp)
            row.cost += r.cost(billing); row.messageCount += 1
            row.firstSeen = min(row.firstSeen, r.timestamp); row.lastSeen = max(row.lastSeen, r.timestamp)
            bySession[r.sessionID] = row
        }

        var hourly = [Double](repeating: 0, count: 24)
        for r in scoped { hourly[calendar.component(.hour, from: r.timestamp)] += r.cost(billing) }

        var timeline: [ContextPoint] = []
        var fullTimeline: SessionTimeline?
        if case .session(let id) = target {
            fullTimeline = Timelines.build(records: records, events: events, sessionID: id, billing: billing)
            timeline = scoped.sorted { $0.timestamp < $1.timestamp }.map { ContextPoint(time: $0.timestamp, tokens: $0.usage.contextTokens) }
        }

        return DrillDetail(
            target: target, snapshot: snapshot, trend: trend,
            firstSeen: scoped.map(\.timestamp).min(), lastSeen: scoped.map(\.timestamp).max(),
            topSessions: Array(bySession.values.sorted { ($0.cost, $0.lastSeen) > ($1.cost, $1.lastSeen) }.prefix(listLimit)),
            topMessages: Array(messages.prefix(listLimit)), hourly: hourly, contextTimeline: timeline, timeline: fullTimeline)
    }

    /// A tool target keeps every response that called the tool, at full cost. The main view's per-call share is an
    /// estimate; here the question is "what did the work around this tool cost", so whole responses are the honest unit.
    static func matches(_ r: UsageRecord, _ target: DrillTarget) -> Bool {
        switch target {
        case .total, .day: true
        case .model(let key): Pricing.normalize(r.model) == key
        case .skill(let key): (r.skill ?? Snapshot.noSkill) == key
        case .plugin(let key): r.plugin == key
        case .tool(let key): r.tools.values.contains(key)
        case .project(let key): Aggregator.projectName(r.cwd) == key
        case .session(let id): r.sessionID == id
        }
    }
}

/// The trail of filters the user has drilled through, from the dashboard down to the page on screen. Each step narrows
/// the view to one thing, so a non-empty trail means the view is filtered.
public struct DrillStack: Equatable, Sendable {
    public struct Crumb: Equatable, Sendable {
        public var label: String
        /// How many levels to keep when this crumb is chosen: 0 is the dashboard.
        public var keeping: Int
    }

    public private(set) var targets: [DrillTarget] = []
    public init() {}

    public var current: DrillTarget? { targets.last }
    public var isFiltered: Bool { !targets.isEmpty }
    public var depth: Int { targets.count }

    public mutating func push(_ target: DrillTarget) {
        guard targets.last != target else { return }
        targets.append(target)
    }

    public mutating func back() { if !targets.isEmpty { targets.removeLast() } }
    public mutating func clear() { targets.removeAll() }

    /// Keeps the first `count` levels and drops the rest. More than exist changes nothing.
    public mutating func keep(_ count: Int) {
        guard count >= 0, count < targets.count else { return }
        targets.removeSubrange(count...)
    }

    /// Where Back leads, in words for the button. Nil on the dashboard.
    public var previousTitle: String? {
        guard !targets.isEmpty else { return nil }
        return targets.count == 1 ? "the dashboard" : targets[targets.count - 2].title
    }

    public var crumbs: [Crumb] {
        [Crumb(label: "Dashboard", keeping: 0)] + targets.enumerated().map { Crumb(label: $0.element.title, keeping: $0.offset + 1) }
    }

    /// "Model: Opus 5.5 › Session: Session abc12345": what the view is filtered to.
    public var summary: String { targets.map { "\($0.kind): \($0.title)" }.joined(separator: " › ") }
}
