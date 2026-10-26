import Foundation

/// A cost-based nudge about when to compact or clear. Every figure is an estimate from list prices, and says so.
public struct CompactAdvice: Equatable, Sendable {
    public enum Level: Equatable, Sendable {
        /// Nothing to do yet.
        case fine
        /// Compacting would pay for itself within a handful of calls.
        case consider
        /// The window is nearly full, so a compaction is coming either way.
        case compactSoon
        /// The cache has expired: the next prompt re-sends the whole context at the write price.
        case coldCache
    }
    public enum PostSource: Equatable, Sendable { case observed, assumed }

    public var level: Level
    public var headline: String
    public var detail: String

    public var contextTokens: Int
    public var windowTokens: Int
    public var contextPercent: Double
    /// What every call spends re-reading the context from the cache.
    public var carryCostPerCall: Double
    /// One-off cost of compacting: read the context, write the summary, cache the shorter context.
    public var compactCost: Double
    public var savingsPerCall: Double
    public var breakEvenCalls: Double?
    public var postCompactTokens: Int
    public var postCompactSource: PostSource
    public var cacheExpiresAt: Date
    public var cacheIsCold: Bool
    /// Extra dollars the next call costs because the cache expired, versus reading it warm. Nil while the cache is warm.
    public var coldPenalty: Double?
}

public enum CompactAdvisor {
    static let assumedPostCompactTokens = 20_000
    /// Below this the context is cheap to carry or re-send, so the advice stays quiet.
    static let worthMentioning = 30_000
    static let worthCompacting = 100_000
    static let payBackWithin = 15.0
    static let windowWarningPercent = 80.0

    public static func advise(timeline: SessionTimeline, now: Date, billing: CacheWriteBilling = .listPrice) -> CompactAdvice? {
        guard let last = timeline.mainCalls.last else { return nil }
        let context = last.contextTokens
        let perMTok = 1_000_000.0
        let rates = Pricing.effectiveRates(model: last.model, contextTokens: context)
        let ttl = timeline.cacheTTL
        // A re-written cache entry is billed at the 1-hour or 5-minute write rate, matching how this session caches.
        let writeMultiplier = ttl >= 3600 ? (billing == .listPrice ? 2.0 : 1.25) : 1.25
        func writeRate(_ r: (input: Double, output: Double, cacheRead: Double)) -> Double { r.input * writeMultiplier }

        let observed = timeline.markers.compactMap { m -> Int? in if case .compact(_, _, let post?, _) = m.kind { post } else { nil } }.sorted()
        let postSource: CompactAdvice.PostSource = observed.isEmpty ? .assumed : .observed
        let rawPost = observed.isEmpty ? assumedPostCompactTokens
            : (observed.count % 2 == 1 ? observed[observed.count / 2] : (observed[observed.count / 2 - 1] + observed[observed.count / 2]) / 2)
        let post = min(rawPost, context)
        let postRates = Pricing.effectiveRates(model: last.model, contextTokens: post)

        let carry = Double(context) * rates.cacheRead / perMTok
        let compactCost = carry + Double(post) * rates.output / perMTok + Double(post) * writeRate(postRates) / perMTok
        let savings = carry - Double(post) * postRates.cacheRead / perMTok
        let breakEven: Double? = savings > 0 ? compactCost / savings : nil

        let expires = last.time.addingTimeInterval(ttl)
        let cold = now > expires
        let coldPenalty: Double? = cold ? Double(context) * (writeRate(rates) - rates.cacheRead) / perMTok : nil
        let window = timeline.contextWindow
        let percent = window > 0 ? Double(context) / Double(window) * 100 : 0

        let level: CompactAdvice.Level
        if cold && context >= worthMentioning { level = .coldCache }
        else if percent >= windowWarningPercent { level = .compactSoon }
        else if context >= worthCompacting, let breakEven, breakEven <= payBackWithin { level = .consider }
        else { level = .fine }

        let (headline, detail) = words(
            level, context: context, percent: percent, carry: carry, compactCost: compactCost, savings: savings,
            breakEven: breakEven, post: post, source: postSource, coldPenalty: coldPenalty)
        return CompactAdvice(
            level: level, headline: headline, detail: detail, contextTokens: context, windowTokens: window, contextPercent: percent,
            carryCostPerCall: carry, compactCost: compactCost, savingsPerCall: savings, breakEvenCalls: breakEven,
            postCompactTokens: post, postCompactSource: postSource, cacheExpiresAt: expires, cacheIsCold: cold, coldPenalty: coldPenalty)
    }

    private static func words(
        _ level: CompactAdvice.Level, context: Int, percent: Double, carry: Double, compactCost: Double, savings: Double,
        breakEven: Double?, post: Int, source: CompactAdvice.PostSource, coldPenalty: Double?
    ) -> (String, String) {
        let ctx = tokens(context), after = tokens(post) + (source == .assumed ? " (an estimate)" : " (typical for this session)")
        switch level {
        case .coldCache:
            return ("The cache has expired",
                    "The next prompt re-sends \(ctx) tokens at the cache-write price, about \(money(coldPenalty ?? 0)) more than a warm cache. "
                    + "If you don't need all of it, /compact or /clear first.")
        case .compactSoon:
            return ("Context is \(Int(percent.rounded()))% full",
                    "A compaction is coming either way. Doing it at a natural break costs about \(money(compactCost)) once.")
        case .consider:
            let calls = Int((breakEven ?? 0).rounded(.up))
            return ("Compacting would pay for itself in about \(calls) calls",
                    "Each call re-reads \(ctx) tokens for about \(money(carry)). Compacting to roughly \(after) costs about \(money(compactCost)) "
                    + "once and saves about \(money(savings)) per call after that.")
        case .fine:
            return ("No need to compact yet", "Each call carries \(ctx) tokens for about \(money(carry)).")
        }
    }

    static func tokens(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.2fM", Double(n) / 1e6) : n >= 10_000 ? String(format: "%.0fK", Double(n) / 1e3) : n >= 1_000 ? String(format: "%.1fK", Double(n) / 1e3) : "\(n)"
    }

    static func money(_ v: Double) -> String { v < 0.01 ? "<$0.01" : v < 1 ? String(format: "$%.2f", v) : String(format: "$%.2f", v) }
}
