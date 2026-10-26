import Foundation

/// Charts color by family, not by exact model id, so Sonnet 5 and Sonnet 5.5 stack as one series.
public enum ModelFamily: String, CaseIterable, Sendable {
    case opus = "Opus", sonnet = "Sonnet", haiku = "Haiku", other = "Other"

    public init(modelID: String) {
        let id = Pricing.normalize(modelID)
        if id.contains("opus") { self = .opus }
        else if id.contains("sonnet") { self = .sonnet }
        else if id.contains("haiku") { self = .haiku }
        else { self = .other }
    }

    /// "claude-sonnet-5-5" -> "Sonnet 5.5"; ids that don't look like Claude models come back unchanged.
    public static func displayName(modelID: String) -> String {
        let id = Pricing.normalize(modelID)
        let parts = id.split(separator: "-").map(String.init)
        guard parts.first == "claude", parts.count >= 3 else { return modelID }
        let name = parts[1].capitalized
        let version = parts[2...].joined(separator: ".")
        return "\(name) \(version)"
    }
}
