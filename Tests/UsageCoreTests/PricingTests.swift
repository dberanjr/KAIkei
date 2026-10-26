import Testing
@testable import UsageCore

@Suite struct PricingTests {
    @Test func sonnet55CostsTwoDollarsInTenOut() {
        let usage = TokenUsage(input: 1_000_000, output: 1_000_000)
        let cost = Pricing.cost(of: usage, model: "claude-sonnet-5-5")
        #expect(abs(cost - 12.00) < 1e-9)
    }

    @Test func listPriceBillsOneHourWritesAtTwiceInput() {
        // Opus 5.5 input is $4/MTok: 5m write = 1.25x ($5), 1h write = 2x ($8), read = $0.20.
        let usage = TokenUsage(cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000, cacheRead: 1_000_000)
        let cost = Pricing.cost(of: usage, model: "claude-opus-5-5", billing: .listPrice)
        #expect(abs(cost - (5.0 + 8.0 + 0.20)) < 1e-9)
    }

    @Test func flatWriteRatePricesEveryCacheWriteAtFiveMinuteRate() {
        let usage = TokenUsage(cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000, cacheRead: 1_000_000)
        let cost = Pricing.cost(of: usage, model: "claude-opus-5-5", billing: .flatWriteRate)
        #expect(abs(cost - (5.0 + 5.0 + 0.20)) < 1e-9)
    }

    @Test func defaultIsPublishedListPrice() {
        let usage = TokenUsage(cacheWrite1h: 1_000_000)
        #expect(abs(Pricing.cost(of: usage, model: "claude-opus-5-5") - 8.0) < 1e-9)
    }

    @Test func fable51CacheReadIsAQuarterDollar() {
        let usage = TokenUsage(cacheRead: 1_000_000)
        #expect(abs(Pricing.cost(of: usage, model: "claude-fable-5-1") - 0.25) < 1e-9)
    }

    @Test func unknownModelFallsBackToFamilyAndIsFlaggedAsEstimate() {
        let lookup = Pricing.lookup("claude-sonnet-9-9")
        #expect(lookup.isEstimate)
        #expect(lookup.rate.input == 2.0) // newest known Sonnet
    }

    @Test func knownModelIsNotAnEstimate() {
        #expect(!Pricing.lookup("claude-opus-5-5").isEstimate)
    }

    @Test func dateSuffixIsIgnored() {
        #expect(!Pricing.lookup("claude-haiku-4-5-20251001").isEstimate)
    }
}

@Suite struct CostPartsTests {
    @Test func partsSumToTheTotalCost() {
        let usage = TokenUsage(input: 123_456, output: 78_910, cacheWrite5m: 11_111, cacheWrite1h: 22_222, cacheRead: 3_333_333)
        for billing in CacheWriteBilling.allCases {
            let parts = Pricing.costParts(of: usage, model: "claude-sonnet-5-5", billing: billing)
            #expect(abs(parts.total - Pricing.cost(of: usage, model: "claude-sonnet-5-5", billing: billing)) < 1e-12)
        }
    }

    @Test func eachTokenKindLandsInItsOwnBucket() {
        // Sonnet 5.5: input $2, output $10, cache read $0.20, 5m write $2.50 per MTok.
        let parts = Pricing.costParts(
            of: TokenUsage(input: 1_000_000, output: 1_000_000, cacheWrite5m: 1_000_000, cacheRead: 1_000_000), model: "claude-sonnet-5-5")
        #expect(abs(parts.input - 2.0) < 1e-9)
        #expect(abs(parts.output - 10.0) < 1e-9)
        #expect(abs(parts.cacheWrite - 2.5) < 1e-9)
        #expect(abs(parts.cacheRead - 0.2) < 1e-9)
    }
}
