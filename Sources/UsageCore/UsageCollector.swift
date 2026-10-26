import Foundation

/// One open Claude Code session as the widget shows it: a status-line style row.
public struct LiveRow: Identifiable, Equatable, Sendable {
    public var session: LiveSession
    public var summary: SessionSummary?
    public var statusline: StatuslineInfo?
    public var tty: String?
    /// The account Claude Code is signed in as. Every session reads the same `~/.claude.json`, so rows share it.
    public var account: AccountInfo?

    public var id: String { session.sessionID }
    public var messageCount: Int { summary?.messageCount ?? 0 }
    public var usage: TokenUsage { summary?.usage ?? TokenUsage() }
    public var model: String { summary?.lastModel ?? "" }
    public var modelLabel: String { statusline?.modelDisplayName ?? ModelFamily.displayName(modelID: model) }
    public var byModel: [BreakdownRow] { summary?.byModel ?? [] }

    /// Computed from transcript token counts at list price, so rows add up to the totals and breakdowns.
    public var cost: Double { summary?.cost ?? 0 }
    /// Claude Code's own running figure, shown beside ours. It is an internal estimate and differs ~10%.
    public var statuslineCost: Double? { statusline?.costUSD }
    public var contextTokens: Int { summary?.contextTokens ?? 0 }
    public var contextWindow: Int { statusline?.contextWindowSize ?? Pricing.lookup(model).rate.contextWindow }
    public var contextPercent: Double {
        if let p = statusline?.contextUsedPercent { return p }
        return contextWindow > 0 ? Double(contextTokens) / Double(contextWindow) * 100 : 0
    }
}

public struct Dashboard: Sendable {
    public var generatedAt: Date
    public var live: [LiveRow]
    public var snapshots: [TimeRange: Snapshot]
    public var account: AccountInfo?
    public var plan: PlanUsage?
    /// Week-over-week, daily average and peak, from the full history.
    public var trend: TrendSummary
    /// Every deduplicated response, so a click can be answered by re-filtering instead of re-reading transcripts.
    public var records: [UsageRecord]
    /// Prompts, slash commands and compactions, for the session timeline.
    public var events: [SessionEvent]
    /// Loop, sub-agent and test-run rows, for the feature lanes under the session timeline.
    public var signals: [FeatureSignal]
    public var liveCost: Double { live.reduce(0) { $0 + $1.cost } }
    public var liveUsage: TokenUsage { live.reduce(TokenUsage()) { $0 + $1.usage } }
}

/// Reads everything on disk and turns it into a Dashboard. Not thread-safe: own it from one queue.
public final class UsageCollector {
    private let projectsDir: URL, sessionsDir: URL, statuslineDir: URL
    private var reader = IncrementalReader()
    private var store = RecordStore()
    private var ttyCache: [Int: String?] = [:]
    private let calendar: Calendar
    private let accountConfig: URL
    private let accountRefreshInterval: TimeInterval
    private var account: (info: AccountInfo?, plan: PlanUsage?, readAt: Date)?
    public var billing: CacheWriteBilling = .listPrice

    public init(
        projectsDir: URL = DataHome.url.appendingPathComponent(".claude/projects"),
        sessionsDir: URL = SessionDiscovery.defaultDirectory,
        statuslineDir: URL = StatuslineReader.defaultDirectory,
        accountConfig: URL = AccountReader.defaultURL,
        accountRefreshInterval: TimeInterval = 30,
        calendar: Calendar = .current
    ) {
        self.accountConfig = accountConfig
        self.accountRefreshInterval = accountRefreshInterval
        self.projectsDir = projectsDir
        self.sessionsDir = sessionsDir
        self.statuslineDir = statuslineDir
        self.calendar = calendar
    }

    public func refresh(now: Date = Date()) -> Dashboard {
        for url in transcriptFiles() { reader.ingest(url, into: &store) }
        let records = store.records
        let summaries = Aggregator.sessions(records: records, billing: billing)
        let statuslines = StatuslineReader.load(from: statuslineDir)

        let (accountInfo, plan) = currentAccount(now: now)
        let live = SessionDiscovery.liveSessions(in: sessionsDir).map { s in
            LiveRow(
                session: s, summary: summaries[s.sessionID], statusline: statuslines[s.sessionID], tty: tty(for: s.pid),
                account: accountInfo)
        }
        var snapshots: [TimeRange: Snapshot] = [:]
        for range in TimeRange.allCases {
            snapshots[range] = Aggregator.snapshot(records: records, range: range, now: now, calendar: calendar, billing: billing)
        }
        let trend = Trends.summary(daily: snapshots[.all]?.daily ?? [], now: now, calendar: calendar)
        return Dashboard(generatedAt: now, live: live, snapshots: snapshots, account: accountInfo, plan: plan, trend: trend, records: records, events: store.events, signals: store.signals)
    }

    /// The identity file is a few hundred KB that Claude Code rewrites constantly, and who you are changes rarely,
    /// so it is parsed at most once per interval rather than on every 3-second refresh.
    private func currentAccount(now: Date) -> (AccountInfo?, PlanUsage?) {
        if let cached = account, now.timeIntervalSince(cached.readAt) < accountRefreshInterval { return (cached.info, cached.plan) }
        let (info, plan) = AccountReader.load(from: accountConfig)
        account = (info, plan, now)
        return (info, plan)
    }

    /// Sub-agent and nested transcripts live in subdirectories, so walk the whole tree.
    private func transcriptFiles() -> [URL] {
        guard let walker = FileManager.default.enumerator(at: projectsDir, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { ($0 as? URL).flatMap { $0.pathExtension == "jsonl" ? $0 : nil } }
    }

    private func tty(for pid: Int) -> String? {
        if let cached = ttyCache[pid] { return cached }
        let out = Self.run("/bin/ps", ["-o", "tty=", "-p", String(pid)])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (out == nil || out == "??" || out == "") ? nil : out
        ttyCache[pid] = value
        return value
    }

    static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
