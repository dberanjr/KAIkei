import Foundation

/// Who Claude Code is signed in as, read from the identity fields of `~/.claude.json`. No tokens are read.
public struct AccountInfo: Equatable, Sendable {
    public var uuid: String
    public var email: String
    public var displayName: String?
    public var organization: String?
    public var organizationType: String?
    public var seatTier: String?

    private static let plans = [
        "claude_enterprise": "Enterprise", "claude_team": "Team", "claude_max": "Max", "claude_pro": "Pro", "claude_free": "Free",
    ]

    /// "Enterprise · usage-based", "Max", "Pro". Unknown plans are tidied rather than hidden, so a new plan name still shows.
    public var licenseLabel: String {
        guard let type = organizationType, !type.isEmpty else { return "Signed in" }
        let plan = Self.plans[type] ?? Self.tidy(type)
        if let seat = seatTier, seat.contains("usage_based") { return "\(plan) · usage-based" }
        return plan
    }

    static func tidy(_ raw: String) -> String {
        let words = raw.replacingOccurrences(of: "claude_", with: "", options: .anchored).replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

public struct PlanWindow: Equatable, Sendable {
    public var label: String
    public var percent: Double
    public var resetsAt: Date?
}

/// The numbers behind Claude's Settings > Usage screen, as Claude Code caches them locally.
public struct PlanUsage: Equatable, Sendable {
    public var fetchedAt: Date
    public var monthlySpend: Double?
    public var monthlyLimit: Double?
    public var spendPercent: Double?
    public var currency: String
    public var windows: [PlanWindow]

    /// Month-end spend if the rest of the month looks like the elapsed part. Withheld in the first ~day, where it swings wildly.
    public func projectedMonthEnd(now: Date, calendar: Calendar) -> Double? {
        guard let spend = monthlySpend, let month = calendar.dateInterval(of: .month, for: now) else { return nil }
        let fraction = now.timeIntervalSince(month.start) / month.duration
        return fraction >= 0.05 ? spend / fraction : nil
    }
}

public enum AccountReader {
    public static let defaultURL = DataHome.url.appendingPathComponent(".claude.json")

    public static func load(from url: URL = defaultURL) -> (AccountInfo?, PlanUsage?) {
        guard let data = try? Data(contentsOf: url) else { return (nil, nil) }
        return parse(data)
    }

    public static func parse(_ data: Data) -> (AccountInfo?, PlanUsage?) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let oauth = root["oauthAccount"] as? [String: Any], let email = oauth["emailAddress"] as? String
        else { return (nil, nil) }
        let uuid = oauth["accountUuid"] as? String ?? ""
        let account = AccountInfo(
            uuid: uuid, email: email, displayName: oauth["displayName"] as? String, organization: oauth["organizationName"] as? String,
            organizationType: oauth["organizationType"] as? String, seatTier: oauth["seatTier"] as? String)
        // The cache is per account; one written for a different sign-in must not be shown as this account's usage.
        guard let cache = root["cachedUsageUtilization"] as? [String: Any], cache["accountUuid"] as? String == uuid,
            let ms = cache["fetchedAtMs"] as? Double, let usage = cache["utilization"] as? [String: Any]
        else { return (account, nil) }
        return (account, plan(from: usage, fetchedAt: Date(timeIntervalSince1970: ms / 1000)))
    }

    private static func plan(from usage: [String: Any], fetchedAt: Date) -> PlanUsage {
        var plan = PlanUsage(fetchedAt: fetchedAt, monthlySpend: nil, monthlyLimit: nil, spendPercent: nil, currency: "USD", windows: [])
        if let extra = usage["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true {
            let scale = pow(10, Double(extra["decimal_places"] as? Int ?? 2))
            if let limit = extra["monthly_limit"] as? Double { plan.monthlyLimit = limit / scale }
            if let used = extra["used_credits"] as? Double { plan.monthlySpend = used / scale }
            plan.spendPercent = extra["utilization"] as? Double
            plan.currency = extra["currency"] as? String ?? "USD"
        }
        let labels = [("five_hour", "5-hour"), ("seven_day", "Weekly"), ("seven_day_opus", "Weekly Opus"), ("seven_day_sonnet", "Weekly Sonnet")]
        for (key, label) in labels {
            guard let w = usage[key] as? [String: Any], let percent = w["utilization"] as? Double else { continue }
            plan.windows.append(PlanWindow(label: label, percent: percent, resetsAt: (w["resets_at"] as? String).flatMap(parseDate)))
        }
        return plan
    }

    private static func parseDate(_ s: String) -> Date? {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: s) ?? fractional.date(from: s)
    }
}
