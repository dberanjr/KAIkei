import Foundation

/// Dollars per million tokens. Cache write rates are derived: 1.25x input for the 5-minute TTL,
/// 2x input for the 1-hour TTL. Cache read varies by model, so it is explicit.
public struct ModelRate: Equatable, Sendable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var contextWindow: Int
    /// Some models bill a higher rate once a single prompt passes a size threshold.
    public var longContext: LongContext?

    public struct LongContext: Equatable, Sendable {
        public var threshold: Int
        public var input: Double
        public var output: Double
        public var cacheRead: Double
    }

    public var cacheWrite5m: Double { input * 1.25 }
    public var cacheWrite1h: Double { input * 2.0 }

    init(_ input: Double, _ output: Double, cacheRead: Double? = nil, window: Int = 1_000_000, longContext: LongContext? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead ?? input * 0.1
        self.contextWindow = window
        self.longContext = longContext
    }
}

/// How cache writes are priced. The two bases differ by up to ~20% on sessions that use the 1-hour TTL.
/// Neither reproduces Claude Code's own status-line cost, which is an internal estimate (see README).
public enum CacheWriteBilling: String, CaseIterable, Identifiable, Sendable {
    /// Published API pricing: 1.25x input for 5-minute writes, 2x for 1-hour writes.
    case listPrice = "API list price (1h writes 2×)"
    /// Every cache write at 1.25x input: the lower bound if the 1-hour premium isn't charged to you.
    case flatWriteRate = "All cache writes at 1.25×"
    public var id: String { rawValue }
}

public enum Pricing {
    public struct Lookup: Sendable {
        public var rate: ModelRate
        /// True when the model id was not in the table and a family default was used.
        public var isEstimate: Bool
    }

    // Source: Anthropic first-party API rates as listed in the claude-api reference (cached 2026-10-06).
    static let table: [String: ModelRate] = [
        "claude-fable-5-1": ModelRate(10, 50, cacheRead: 0.25),
        "claude-mythos-5-1": ModelRate(10, 50, cacheRead: 0.25),
        "claude-fable-5": ModelRate(10, 50, cacheRead: 1.0),
        "claude-mythos-5": ModelRate(10, 50, cacheRead: 1.0),
        "claude-opus-5-5": ModelRate(4, 20, cacheRead: 0.20),
        "claude-opus-5": ModelRate(5, 25),
        "claude-opus-4-8": ModelRate(5, 25),
        "claude-opus-4-7": ModelRate(5, 25),
        "claude-opus-4-6": ModelRate(5, 25),
        "claude-sonnet-5-5": ModelRate(2, 10, cacheRead: 0.20),
        "claude-sonnet-5": ModelRate(2, 10),
        "claude-sonnet-4-6": ModelRate(3, 15),
        "claude-haiku-5-5": ModelRate(
            0.10, 0.50,
            longContext: .init(threshold: 100_000, input: 0.50, output: 2.50, cacheRead: 0.05)),
        "claude-haiku-4-5": ModelRate(1, 5, window: 200_000),
    ]

    /// Newest known model per family, used when an id is not in the table.
    static let familyDefaults: [(needle: String, id: String)] = [
        ("fable", "claude-fable-5-1"), ("mythos", "claude-mythos-5-1"),
        ("opus", "claude-opus-5-5"), ("sonnet", "claude-sonnet-5-5"), ("haiku", "claude-haiku-5-5"),
    ]

    public static func normalize(_ modelID: String) -> String {
        // Strip a trailing -YYYYMMDD snapshot suffix and any bracketed context hint like "[1m]".
        var id = modelID.lowercased()
        if let bracket = id.firstIndex(of: "[") { id = String(id[..<bracket]) }
        if let range = id.range(of: #"-\d{8}$"#, options: .regularExpression) { id.removeSubrange(range) }
        return id
    }

    public static func lookup(_ modelID: String) -> Lookup {
        let id = normalize(modelID)
        if let rate = table[id] { return Lookup(rate: rate, isEstimate: false) }
        for (needle, fallbackID) in familyDefaults where id.contains(needle) {
            return Lookup(rate: table[fallbackID]!, isEstimate: true)
        }
        // Completely unrecognized (e.g. "<synthetic>"): price at the cheapest tier so it can't inflate totals.
        return Lookup(rate: table["claude-haiku-5-5"]!, isEstimate: true)
    }

    public static func cost(of usage: TokenUsage, model: String, billing: CacheWriteBilling = .listPrice) -> Double {
        costParts(of: usage, model: model, billing: billing).total
    }

    /// Per-million-token rates for a prompt of this size: the long-context tier applies once a single prompt passes its threshold.
    public static func effectiveRates(model: String, contextTokens: Int) -> (input: Double, output: Double, cacheRead: Double) {
        let rate = lookup(model).rate
        if let long = rate.longContext, contextTokens > long.threshold { return (long.input, long.output, long.cacheRead) }
        return (rate.input, rate.output, rate.cacheRead)
    }

    public static func costParts(of usage: TokenUsage, model: String, billing: CacheWriteBilling = .listPrice) -> CostParts {
        let (input, output, read) = effectiveRates(model: model, contextTokens: usage.contextTokens)
        let oneHourMultiplier = billing == .listPrice ? 2.0 : 1.25
        let perMTok = 1_000_000.0
        return CostParts(
            input: Double(usage.input) * input / perMTok,
            output: Double(usage.output) * output / perMTok,
            cacheWrite: (Double(usage.cacheWrite5m) * 1.25 + Double(usage.cacheWrite1h) * oneHourMultiplier) * input / perMTok,
            cacheRead: Double(usage.cacheRead) * read / perMTok)
    }
}

/// Dollars split by what was billed, to show where the money goes.
public struct CostParts: Equatable, Sendable {
    public var input = 0.0, output = 0.0, cacheWrite = 0.0, cacheRead = 0.0
    public var total: Double { input + output + cacheWrite + cacheRead }
    public init(input: Double = 0, output: Double = 0, cacheWrite: Double = 0, cacheRead: Double = 0) {
        self.input = input; self.output = output; self.cacheWrite = cacheWrite; self.cacheRead = cacheRead
    }
    public static func + (a: CostParts, b: CostParts) -> CostParts {
        CostParts(input: a.input + b.input, output: a.output + b.output, cacheWrite: a.cacheWrite + b.cacheWrite, cacheRead: a.cacheRead + b.cacheRead)
    }
}
