import Foundation

/// One sub-agent run: everything its sidechain rows billed, from its first response to its last.
public struct SubagentRun: Identifiable, Equatable, Sendable {
    /// The `agentId` carried on the run's rows.
    public var id: String
    /// The spawn's description, or "sub-agent" when the parent's `Agent` call is not in the transcript.
    public var label: String
    public var type: String?
    public var start: Date
    public var end: Date
    public var cost: Double
    public var callCount: Int
    public var outputTokens: Int
    /// 0-based stacking row, so runs that overlap in time do not draw on top of each other.
    public var row: Int
}

public struct SubagentLane: Equatable, Sendable {
    public var runs: [SubagentRun]
    public var totalCost: Double { runs.reduce(0) { $0 + $1.cost } }
    public var rowCount: Int { (runs.map(\.row).max() ?? -1) + 1 }
}

extension FeatureLanes {
    public static func subagents(signals: [FeatureSignal], timeline: SessionTimeline) -> SubagentLane? {
        var spawns: [String: (type: String?, description: String)] = [:]
        var spawnOfAgent: [String: String] = [:]
        for s in signals {
            switch s.kind {
            case .agentSpawned(let id, let type, let description): spawns[id] = (type, description)
            case .agentLaunched(let toolID, let agentID): spawnOfAgent[agentID] = toolID
            default: break
            }
        }
        let grouped = Dictionary(grouping: timeline.calls.filter { $0.isSidechain && $0.agentID != nil }) { $0.agentID! }
        guard !grouped.isEmpty else { return nil }

        var runs: [SubagentRun] = grouped.map { agent, calls in
            // The launch result is the reliable link. A fork's own rows also carry its spawn id, which is the fallback.
            let spawn = (spawnOfAgent[agent] ?? calls.compactMap(\.spawnToolUseID).first).flatMap { spawns[$0] }
            return SubagentRun(
                id: agent, label: spawn.map { $0.description.isEmpty ? "sub-agent" : $0.description } ?? "sub-agent", type: spawn?.type,
                start: calls.map(\.time).min()!, end: calls.map(\.time).max()!, cost: calls.reduce(0) { $0 + $1.cost },
                callCount: calls.count, outputTokens: calls.reduce(0) { $0 + $1.output }, row: 0)
        }.sorted { ($0.start, $0.id) < ($1.start, $1.id) }

        // Greedy packing: a run takes the first row whose last run has already ended.
        var rowEnds: [Date] = []
        for i in runs.indices {
            if let row = rowEnds.firstIndex(where: { $0 < runs[i].start }) {
                runs[i].row = row; rowEnds[row] = runs[i].end
            } else {
                runs[i].row = rowEnds.count; rowEnds.append(runs[i].end)
            }
        }
        return SubagentLane(runs: runs)
    }
}
