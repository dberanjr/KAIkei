import Foundation

/// One billed API response, reconstructed from a transcript.
public struct UsageRecord: Equatable, Sendable {
    public var messageID: String
    public var sessionID: String
    public var timestamp: Date
    public var model: String
    public var usage: TokenUsage
    public var skill: String?
    public var plugin: String?
    /// tool_use id -> tool name. Keyed by id so repeated rows for one message merge cleanly.
    public var tools: [String: String]
    public var cwd: String?
    public var isSidechain: Bool
    /// Part of `usage.output` spent on extended thinking. It is billed as output; it is split out so it can be shown.
    public var thinkingTokens: Int = 0
    public var effort: String?
    /// Set on sub-agent rows: which agent run this response belongs to, and the parent's `Agent` tool_use that spawned it.
    public var agentID: String?
    public var spawnToolUseID: String?

    public func cost(_ billing: CacheWriteBilling) -> Double { Pricing.cost(of: usage, model: model, billing: billing) }
}

/// Holds one record per (session, message id). Claude Code writes a transcript row per content block,
/// so a single response appears several times; counting rows instead of messages overstates usage ~3x.
public struct RecordStore: Sendable {
    public private(set) var records: [UsageRecord] = []
    /// Prompts, slash commands and compactions, deduplicated by transcript id. Forked sessions replay rows into new files.
    public private(set) var events: [SessionEvent] = []
    private var eventIDs: Set<String> = []
    /// Loop wake-ups and decisions, sub-agent spawns and test runs, deduplicated by signal id.
    public private(set) var signals: [FeatureSignal] = []
    private var signalIDs: Set<String> = []
    private var index: [String: Int] = [:]

    public init() {}

    public mutating func add(_ event: SessionEvent) {
        if eventIDs.insert(event.id).inserted { events.append(event) }
    }

    public mutating func add(_ signal: FeatureSignal) {
        if signalIDs.insert(signal.id).inserted { signals.append(signal) }
    }

    public mutating func add(_ rec: UsageRecord) {
        let key = rec.sessionID + "|" + rec.messageID
        guard let i = index[key] else {
            index[key] = records.count
            records.append(rec)
            return
        }
        var merged = records[i]
        merged.usage = TokenUsage(
            input: max(merged.usage.input, rec.usage.input),
            output: max(merged.usage.output, rec.usage.output),
            cacheWrite5m: max(merged.usage.cacheWrite5m, rec.usage.cacheWrite5m),
            cacheWrite1h: max(merged.usage.cacheWrite1h, rec.usage.cacheWrite1h),
            cacheRead: max(merged.usage.cacheRead, rec.usage.cacheRead))
        merged.tools.merge(rec.tools) { a, _ in a }
        merged.skill = merged.skill ?? rec.skill
        merged.plugin = merged.plugin ?? rec.plugin
        merged.thinkingTokens = max(merged.thinkingTokens, rec.thinkingTokens)
        merged.effort = merged.effort ?? rec.effort
        merged.agentID = merged.agentID ?? rec.agentID
        merged.spawnToolUseID = merged.spawnToolUseID ?? rec.spawnToolUseID
        records[i] = merged
    }
}
