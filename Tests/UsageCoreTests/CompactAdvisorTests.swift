import Foundation
import Testing
@testable import UsageCore

@Suite struct CompactAdvisorTests {
    static let t0 = TimelineTests.t0

    /// Sonnet 5.5 rates: $2 in, $10 out, $0.20 cache read, $4 for 1-hour cache writes (2x input).
    func timeline(context: Int, lastCallMinute: Double = 0, oneHour: Bool = true, model: String = "claude-sonnet-5-5",
                  compacts: [Int] = []) -> SessionTimeline {
        var calls = [tcall("warm", minute: lastCallMinute - 1, model: model, read: context / 2, write5m: oneHour ? 0 : 100, write1h: oneHour ? 100 : 0),
                     tcall("last", minute: lastCallMinute, model: model, input: 2, read: context - 2)]
        calls[1].usage.cacheWrite1h = 0
        let events = compacts.enumerated().map {
            tevent("c\($0.offset)", minute: Double($0.offset) - 50, .compact(trigger: "auto", preTokens: 200_000, postTokens: $0.element, durationMs: 1000))
        }
        return Timelines.build(records: calls, events: events, sessionID: "s1")
    }

    func advise(_ t: SessionTimeline, minutesAfterLastCall: Double = 5) -> CompactAdvice? {
        CompactAdvisor.advise(timeline: t, now: t.mainCalls.last!.time.addingTimeInterval(minutesAfterLastCall * 60))
    }

    @Test func carryingTheContextCostsACacheReadPerCall() throws {
        let a = try #require(advise(timeline(context: 300_000)))
        #expect(a.contextTokens == 300_000)
        #expect(abs(a.carryCostPerCall - 300_000 * 0.20 / 1e6) < 1e-9)  // $0.06
    }

    @Test func compactingIsPricedAsReadPlusSummaryPlusRewrite() throws {
        // Reads 300K at $0.20 = 0.06; writes a 20K summary as output at $10 = 0.20; re-caches 20K at the 1h write rate $4 = 0.08.
        let a = try #require(advise(timeline(context: 300_000)))
        #expect(a.postCompactTokens == 20_000 && a.postCompactSource == .assumed)
        #expect(abs(a.compactCost - 0.34) < 1e-9)
        #expect(abs(a.savingsPerCall - 280_000 * 0.20 / 1e6) < 1e-9)
        #expect(abs(try #require(a.breakEvenCalls) - 0.34 / 0.056) < 1e-6)
    }

    @Test func observedCompactionsReplaceTheAssumedSize() throws {
        let a = try #require(advise(timeline(context: 300_000, compacts: [20_000, 30_000])))
        #expect(a.postCompactTokens == 25_000 && a.postCompactSource == .observed)  // median of the session's own compactions
    }

    @Test func aBigWarmContextIsWorthCompactingWhenItPaysBackSoon() throws {
        let a = try #require(advise(timeline(context: 300_000)))
        #expect(a.level == .consider)
        #expect(!a.headline.isEmpty && !a.detail.isEmpty)
    }

    @Test func aSmallContextIsLeftAlone() throws {
        let a = try #require(advise(timeline(context: 30_000)))
        #expect(a.level == .fine)
    }

    @Test func anAlmostFullWindowIsFlaggedWhateverItCostsToCarry() throws {
        let a = try #require(advise(timeline(context: 850_000)))
        #expect(a.level == .compactSoon)
        #expect(abs(a.contextPercent - 85) < 0.01)
    }

    @Test func anExpiredCacheMeansTheNextPromptRewritesEverything() throws {
        let t = timeline(context: 300_000)
        let a = try #require(advise(t, minutesAfterLastCall: 120))     // 1-hour cache, two hours idle
        #expect(a.cacheIsCold && a.level == .coldCache)
        #expect(abs(try #require(a.coldPenalty) - 300_000 * (4.0 - 0.20) / 1e6) < 1e-9)
        #expect(a.cacheExpiresAt == t.mainCalls.last!.time.addingTimeInterval(3600))
    }

    @Test func aWarmCacheReportsWhenItWillExpire() throws {
        let t = timeline(context: 300_000)
        let a = try #require(advise(t, minutesAfterLastCall: 5))
        #expect(!a.cacheIsCold && a.coldPenalty == nil)
        #expect(a.cacheExpiresAt == t.mainCalls.last!.time.addingTimeInterval(3600))
    }

    @Test func aFiveMinuteCacheGoesColdSooner() throws {
        let a = try #require(advise(timeline(context: 300_000, oneHour: false), minutesAfterLastCall: 6))
        #expect(a.cacheIsCold && a.level == .coldCache)
    }

    @Test func aColdCacheOnATinyContextIsNotWorthMentioning() throws {
        let a = try #require(advise(timeline(context: 10_000), minutesAfterLastCall: 120))
        #expect(a.level == .fine)
    }

    @Test func longContextPricingTiersAreRespected() throws {
        // Haiku 5.5 reads at $0.05/MTok once a prompt passes 100K, not the $0.01 base rate.
        let a = try #require(advise(timeline(context: 200_000, model: "claude-haiku-5-5")))
        #expect(abs(a.carryCostPerCall - 200_000 * 0.05 / 1e6) < 1e-9)
    }

    @Test func noMainThreadCallsMeansNoAdvice() {
        let t = Timelines.build(records: [tcall("sub", minute: 0, sidechain: true)], events: [], sessionID: "s1")
        #expect(CompactAdvisor.advise(timeline: t, now: Self.t0) == nil)
    }

    @Test func effectiveRatesSwitchTiersAtTheThreshold() {
        let low = Pricing.effectiveRates(model: "claude-haiku-5-5", contextTokens: 100_000)
        let high = Pricing.effectiveRates(model: "claude-haiku-5-5", contextTokens: 100_001)
        #expect(abs(low.cacheRead - 0.01) < 1e-12 && abs(high.cacheRead - 0.05) < 1e-12)  // base read is 0.1x input; not exact in floating point
        #expect(abs(low.input - 0.10) < 1e-12 && abs(high.input - 0.50) < 1e-12 && abs(high.output - 2.50) < 1e-12)
    }
}
