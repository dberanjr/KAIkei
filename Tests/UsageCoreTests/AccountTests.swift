import Foundation
import Testing
@testable import UsageCore

@Suite struct AccountTests {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()
    // Sunday 2026-10-25 12:00 UTC: 24.5 of October's 31 days have elapsed.
    static let now = Date(timeIntervalSince1970: 1_792_929_600)

    static func config(uuid: String = "u1", cacheUUID: String = "u1", orgType: String = "claude_enterprise",
                       seat: String = "enterprise_usage_based") -> Data {
        Data("""
        {"oauthAccount":{"accountUuid":"\(uuid)","emailAddress":"ana@acme.com","displayName":"Ana",
          "organizationName":"Acme","organizationType":"\(orgType)","seatTier":"\(seat)",
          "billingType":"stripe_subscription_contracted"},
         "cachedUsageUtilization":{"fetchedAtMs":1792929000000,"accountUuid":"\(cacheUUID)","utilization":{
           "five_hour":null,
           "seven_day":{"utilization":42.5,"resets_at":"2026-10-30T12:00:00Z"},
           "seven_day_opus":{"utilization":10,"resets_at":null},
           "extra_usage":{"is_enabled":true,"monthly_limit":100000,"used_credits":40061,"utilization":40.061,
                          "currency":"USD","decimal_places":2}}}}
        """.utf8)
    }

    @Test func readsTheAccountIdentity() throws {
        let (account, _) = AccountReader.parse(Self.config())
        let a = try #require(account)
        #expect(a.email == "ana@acme.com")
        #expect(a.organization == "Acme")
        #expect(a.displayName == "Ana")
    }

    @Test func licenseLabelCombinesPlanAndSeat() throws {
        let (account, _) = AccountReader.parse(Self.config())
        #expect(account?.licenseLabel == "Enterprise · usage-based")
    }

    @Test func knownPlansGetFriendlyNames() {
        for (type, label) in [("claude_max", "Max"), ("claude_pro", "Pro"), ("claude_team", "Team"), ("claude_free", "Free")] {
            let (account, _) = AccountReader.parse(Self.config(orgType: type, seat: "standard"))
            #expect(account?.licenseLabel == label, "\(type)")
        }
    }

    @Test func unknownPlansAreTidiedNotHidden() {
        let (account, _) = AccountReader.parse(Self.config(orgType: "claude_some_new_plan", seat: "mystery"))
        #expect(account?.licenseLabel == "Some new plan")
    }

    @Test func monthlySpendLimitIsConvertedFromMinorUnits() throws {
        let (_, plan) = AccountReader.parse(Self.config())
        let p = try #require(plan)
        #expect(abs((p.monthlyLimit ?? 0) - 1000) < 1e-9)
        #expect(abs((p.monthlySpend ?? 0) - 400.61) < 1e-9)
        #expect(abs((p.spendPercent ?? 0) - 40.061) < 1e-9)
        #expect(p.currency == "USD")
        #expect(p.fetchedAt == Date(timeIntervalSince1970: 1_792_929_000))
    }

    @Test func onlyPopulatedRateWindowsAreListedWithLabels() throws {
        let (_, plan) = AccountReader.parse(Self.config())
        let windows = try #require(plan).windows
        #expect(windows.map(\.label) == ["Weekly", "Weekly Opus"])  // five_hour is null, so it is absent
        #expect(windows[0].percent == 42.5)
        #expect(windows[0].resetsAt == Date(timeIntervalSince1970: 1_793_361_600))
        #expect(windows[1].resetsAt == nil)
    }

    @Test func aCacheBelongingToAnotherAccountIsIgnored() {
        let (account, plan) = AccountReader.parse(Self.config(uuid: "u1", cacheUUID: "someone-else"))
        #expect(account != nil)
        #expect(plan == nil)
    }

    @Test func missingOrBrokenConfigYieldsNothing() {
        #expect(AccountReader.parse(Data("{}".utf8)).0 == nil)
        #expect(AccountReader.parse(Data("not json".utf8)).0 == nil)
        #expect(AccountReader.load(from: URL(fileURLWithPath: "/nonexistent/.claude.json")).0 == nil)
    }

    @Test func paceProjectsMonthEndSpendFromTheElapsedShareOfTheMonth() throws {
        let (_, plan) = AccountReader.parse(Self.config())
        let projected = try #require(plan?.projectedMonthEnd(now: Self.now, calendar: Self.calendar))
        #expect(abs(projected - 400.61 / (24.5 / 31)) < 1e-6)
    }

    @Test func paceIsWithheldVeryEarlyInTheMonth() throws {
        let (_, plan) = AccountReader.parse(Self.config())
        let earlyOnTheFirst = Date(timeIntervalSince1970: 1_793_491_200 + 3600)  // 2026-11-01 01:00 UTC
        #expect(try #require(plan).projectedMonthEnd(now: earlyOnTheFirst, calendar: Self.calendar) == nil)
    }
}
