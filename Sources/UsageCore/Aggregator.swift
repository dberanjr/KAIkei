import Foundation

public enum TimeRange: String, CaseIterable, Identifiable, Sendable {
    case today = "Today", week = "7 days", month = "30 days", all = "All time"
    public var id: String { rawValue }
}

public struct BreakdownRow: Identifiable, Equatable, Sendable {
    public var key: String
    public var cost: Double = 0
    public var usage = TokenUsage()
    /// Messages for model/skill/plugin/project rows; tool calls for tool rows.
    public var count: Int = 0
    public var id: String { key }
}

public struct DailyPoint: Identifiable, Equatable, Sendable {
    public var day: Date
    public var model: String
    public var cost: Double
    public var id: String { "\(day.timeIntervalSince1970)|\(model)" }
}

public struct Snapshot: Equatable, Sendable {
    public static let noSkill = "(no skill)"
    public var totalCost = 0.0
    public var totalUsage = TokenUsage()
    public var costParts = CostParts()
    public var messageCount = 0
    public var byModel: [BreakdownRow] = []
    public var bySkill: [BreakdownRow] = []
    public var byPlugin: [BreakdownRow] = []
    public var byTool: [BreakdownRow] = []
    public var byProject: [BreakdownRow] = []
    public var daily: [DailyPoint] = []
    public init() {}
}

public struct SessionSummary: Equatable, Sendable {
    public var sessionID: String
    public var cost = 0.0
    public var usage = TokenUsage()
    public var messageCount = 0
    public var firstSeen: Date
    public var lastSeen: Date
    public var lastModel: String
    public var cwd: String?
    /// Context window occupancy from the most recent response (what the next request will carry).
    public var contextTokens = 0
    public var byModel: [BreakdownRow] = []
}

public enum Aggregator {
    public static func start(of range: TimeRange, now: Date, calendar: Calendar) -> Date {
        switch range {
        case .today: return calendar.startOfDay(for: now)
        case .week: return now.addingTimeInterval(-7 * 86_400)
        case .month: return now.addingTimeInterval(-30 * 86_400)
        case .all: return .distantPast
        }
    }

    public static func snapshot(records: [UsageRecord], range: TimeRange, now: Date, calendar: Calendar, billing: CacheWriteBilling = .listPrice) -> Snapshot {
        let from = start(of: range, now: now, calendar: calendar)
        var snap = Snapshot()
        var model: [String: BreakdownRow] = [:], skill = model, plugin = model, tool = model, project = model
        var daily: [String: DailyPoint] = [:]

        func bump(_ dict: inout [String: BreakdownRow], _ key: String, cost: Double, usage: TokenUsage, count: Int = 1) {
            var row = dict[key] ?? BreakdownRow(key: key)
            row.cost += cost; row.usage += usage; row.count += count
            dict[key] = row
        }

        for r in records where r.timestamp >= from && r.timestamp <= now.addingTimeInterval(86_400) {
            let cost = r.cost(billing)
            snap.totalCost += cost; snap.totalUsage += r.usage; snap.messageCount += 1
            snap.costParts = snap.costParts + Pricing.costParts(of: r.usage, model: r.model, billing: billing)
            bump(&model, Pricing.normalize(r.model), cost: cost, usage: r.usage)
            bump(&skill, r.skill ?? Snapshot.noSkill, cost: cost, usage: r.usage)
            if let p = r.plugin { bump(&plugin, p, cost: cost, usage: r.usage) }
            bump(&project, projectName(r.cwd), cost: cost, usage: r.usage)
            // A message that made N tool calls gets 1/N of its cost per call: a rough, labelled attribution.
            if !r.tools.isEmpty {
                let share = cost / Double(r.tools.count)
                let usageShare = TokenUsage(
                    input: r.usage.input / r.tools.count, output: r.usage.output / r.tools.count,
                    cacheWrite5m: r.usage.cacheWrite5m / r.tools.count, cacheWrite1h: r.usage.cacheWrite1h / r.tools.count,
                    cacheRead: r.usage.cacheRead / r.tools.count)
                for name in r.tools.values { bump(&tool, name, cost: share, usage: usageShare) }
            }
            let day = calendar.startOfDay(for: r.timestamp)
            let m = Pricing.normalize(r.model)
            let key = "\(day.timeIntervalSince1970)|\(m)"
            daily[key, default: DailyPoint(day: day, model: m, cost: 0)].cost += cost
        }

        func sorted(_ d: [String: BreakdownRow]) -> [BreakdownRow] {
            d.values.sorted { ($0.cost, $0.key) > ($1.cost, $1.key) }
        }
        snap.byModel = sorted(model); snap.bySkill = sorted(skill); snap.byPlugin = sorted(plugin)
        snap.byTool = sorted(tool); snap.byProject = sorted(project)
        snap.daily = daily.values.sorted { ($0.day, $0.model) < ($1.day, $1.model) }
        return snap
    }

    public static func projectName(_ cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "(unknown)" }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    public static func sessions(records: [UsageRecord], billing: CacheWriteBilling = .listPrice) -> [String: SessionSummary] {
        var out: [String: SessionSummary] = [:]
        var latest: [String: Date] = [:]
        var models: [String: [String: BreakdownRow]] = [:]
        for r in records {
            var s = out[r.sessionID] ?? SessionSummary(
                sessionID: r.sessionID, firstSeen: r.timestamp, lastSeen: r.timestamp, lastModel: r.model, cwd: r.cwd)
            let cost = r.cost(billing)
            s.cost += cost; s.usage += r.usage; s.messageCount += 1
            s.firstSeen = min(s.firstSeen, r.timestamp)
            s.cwd = s.cwd ?? r.cwd
            if r.timestamp >= (latest[r.sessionID] ?? .distantPast) {
                latest[r.sessionID] = r.timestamp
                s.lastSeen = r.timestamp; s.lastModel = r.model; s.contextTokens = r.usage.contextTokens
            }
            let key = Pricing.normalize(r.model)
            var row = models[r.sessionID, default: [:]][key] ?? BreakdownRow(key: key)
            row.cost += cost; row.usage += r.usage; row.count += 1
            models[r.sessionID, default: [:]][key] = row
            out[r.sessionID] = s
        }
        for (id, rows) in models { out[id]?.byModel = rows.values.sorted { $0.cost > $1.cost } }
        return out
    }
}
