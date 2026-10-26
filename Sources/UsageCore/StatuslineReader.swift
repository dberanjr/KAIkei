import Foundation

/// What Claude Code's statusLine hook receives for a session. Only present while a bridge script
/// (the Claude Console plugin's statusline-handler.sh writes these) is installed, so everything
/// here is optional enrichment: the widget works from transcripts alone.
public struct StatuslineInfo: Equatable, Sendable {
    public var sessionID: String
    public var modelDisplayName: String?
    public var effort: String?
    public var costUSD: Double
    public var durationSeconds: Int
    public var linesAdded: Int
    public var linesRemoved: Int
    public var contextWindowSize: Int?
    public var contextUsedPercent: Double?
    public var cacheHitRatio: Double?
    public var cacheExpiresAt: Date?
    public var fastMode: Bool
    public var tty: String?
}

public enum StatuslineReader {
    public static let defaultDirectory = URL(fileURLWithPath: "/tmp/claude-console/sessions")

    public static func parse(_ data: Data) -> StatuslineInfo? {
        guard let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let id = d["session_id"] as? String
        else { return nil }
        func num(_ dict: [String: Any]?, _ key: String) -> Double? { (dict?[key] as? NSNumber)?.doubleValue }
        let cost = d["cost"] as? [String: Any]
        let ctx = d["context_window"] as? [String: Any]
        let cache = d["prompt_cache"] as? [String: Any]
        return StatuslineInfo(
            sessionID: id,
            modelDisplayName: (d["model"] as? [String: Any])?["display_name"] as? String,
            effort: (d["effort"] as? [String: Any])?["level"] as? String,
            costUSD: num(cost, "total_cost_usd") ?? 0,
            durationSeconds: Int((num(cost, "total_duration_ms") ?? 0) / 1000),
            linesAdded: Int(num(cost, "total_lines_added") ?? 0),
            linesRemoved: Int(num(cost, "total_lines_removed") ?? 0),
            contextWindowSize: num(ctx, "context_window_size").map(Int.init),
            contextUsedPercent: num(ctx, "used_percentage"),
            cacheHitRatio: num(cache, "hit_ratio"),
            cacheExpiresAt: num(cache, "expires_at").map { Date(timeIntervalSince1970: $0) },
            fastMode: d["fast_mode"] as? Bool ?? false, tty: nil)
    }

    /// One entry per session. Per-tab files (ttysNNN.json) win over shared.json because they carry the tty.
    public static func load(from dir: URL = defaultDirectory) -> [String: StatuslineInfo] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var out: [String: StatuslineInfo] = [:]
        for url in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: url), var info = parse(data) else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            if name.hasPrefix("ttys") { info.tty = name }
            if out[info.sessionID]?.tty == nil { out[info.sessionID] = info }
        }
        return out
    }
}
