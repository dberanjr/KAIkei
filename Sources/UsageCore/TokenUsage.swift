import Foundation

/// Token counts for one API response (or a sum of several).
public struct TokenUsage: Equatable, Sendable {
    public var input: Int
    public var output: Int
    public var cacheWrite5m: Int
    public var cacheWrite1h: Int
    public var cacheRead: Int

    public init(input: Int = 0, output: Int = 0, cacheWrite5m: Int = 0, cacheWrite1h: Int = 0, cacheRead: Int = 0) {
        self.input = input
        self.output = output
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
    }

    public var cacheWrite: Int { cacheWrite5m + cacheWrite1h }

    /// Everything the model had to read for this request: the context window occupancy.
    public var contextTokens: Int { input + cacheWrite + cacheRead }

    public var total: Int { input + output + cacheWrite + cacheRead }

    public static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: a.input + b.input, output: a.output + b.output,
            cacheWrite5m: a.cacheWrite5m + b.cacheWrite5m, cacheWrite1h: a.cacheWrite1h + b.cacheWrite1h,
            cacheRead: a.cacheRead + b.cacheRead)
    }

    public static func += (a: inout TokenUsage, b: TokenUsage) { a = a + b }
}

extension TokenUsage {
    /// Share of the input side served from the prompt cache. Output is excluded: it is never cached.
    public var cacheHitRate: Double? {
        let reads = Double(contextTokens)
        return reads > 0 ? Double(cacheRead) / reads : nil
    }
}
