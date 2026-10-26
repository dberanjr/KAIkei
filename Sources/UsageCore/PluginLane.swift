import Foundation

public struct PluginSegment: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var cost: Double
}

/// What each plugin's skills and agents cost over the whole session, largest first, with "other" last.
public struct PluginLane: Equatable, Sendable {
    public var segments: [PluginSegment]
    public var total: Double { segments.reduce(0) { $0 + $1.cost } }
}

extension FeatureLanes {
    public static let otherPluginName = "other"

    /// The `top` costliest plugins by name. Everything else, and calls no plugin is credited with, is "other".
    public static func plugins(timeline: SessionTimeline, top: Int = 4) -> PluginLane? {
        guard timeline.calls.contains(where: { $0.plugin != nil }) else { return nil }
        var byName: [String: Double] = [:]
        for call in timeline.calls { byName[call.plugin ?? otherPluginName, default: 0] += call.cost }
        let named = byName.filter { $0.key != otherPluginName }.sorted { ($1.value, $0.key) < ($0.value, $1.key) }
        var segments = named.prefix(top).map { PluginSegment(name: $0.key, cost: $0.value) }
        let other = named.dropFirst(top).reduce(byName[otherPluginName] ?? 0) { $0 + $1.value }
        if other > 0 || byName[otherPluginName] != nil { segments.append(PluginSegment(name: otherPluginName, cost: other)) }
        return PluginLane(segments: segments)
    }
}
