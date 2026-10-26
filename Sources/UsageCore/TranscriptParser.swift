import Foundation

public enum TranscriptParser {
    private static let assistantMarker = Data(#""type":"assistant""#.utf8)

    nonisolated(unsafe) static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) static let isoPlain = ISO8601DateFormatter()

    /// Returns a record for assistant rows that carry usage; nil for everything else.
    /// Transcripts contain very large non-assistant rows (request blobs), so a byte-level
    /// prefilter avoids JSON-decoding the bulk of each file.
    public static func parse(line: Data) -> UsageRecord? {
        guard line.range(of: assistantMarker) != nil,
            let root = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
            root["type"] as? String == "assistant",
            let message = root["message"] as? [String: Any],
            let messageID = message["id"] as? String,
            let usageDict = message["usage"] as? [String: Any],
            let sessionID = root["sessionId"] as? String
        else { return nil }

        let usage = parseUsage(usageDict)
        guard usage.total > 0 else { return nil }

        var tools: [String: String] = [:]
        for block in (message["content"] as? [[String: Any]]) ?? [] where block["type"] as? String == "tool_use" {
            if let id = block["id"] as? String, let name = block["name"] as? String { tools[id] = name }
        }

        let ts = (root["timestamp"] as? String).flatMap { isoFractional.date(from: $0) ?? isoPlain.date(from: $0) }
        let thinking = ((usageDict["output_tokens_details"] as? [String: Any])?["thinking_tokens"] as? NSNumber)?.intValue ?? 0
        let spawnID = (root["wireToolInputs"] as? [String: Any])?.keys.sorted().first { $0.hasPrefix("toolu_") }
        var record = UsageRecord(
            messageID: messageID, sessionID: sessionID, timestamp: ts ?? Date(),
            model: message["model"] as? String ?? "unknown", usage: usage,
            skill: root["attributionSkill"] as? String, plugin: root["attributionPlugin"] as? String,
            tools: tools, cwd: root["cwd"] as? String, isSidechain: root["isSidechain"] as? Bool ?? false,
            thinkingTokens: thinking, effort: root["effort"] as? String)
        record.agentID = root["agentId"] as? String
        record.spawnToolUseID = spawnID
        return record
    }

    static func parseUsage(_ u: [String: Any]) -> TokenUsage {
        func int(_ key: String, in d: [String: Any]) -> Int { (d[key] as? NSNumber)?.intValue ?? 0 }
        var write5m = 0, write1h = 0
        if let split = u["cache_creation"] as? [String: Any] {
            write5m = int("ephemeral_5m_input_tokens", in: split)
            write1h = int("ephemeral_1h_input_tokens", in: split)
        }
        // Older rows only report the combined figure; bill it at the cheaper 5-minute rate.
        let combined = int("cache_creation_input_tokens", in: u)
        if write5m + write1h == 0 { write5m = combined }
        return TokenUsage(
            input: int("input_tokens", in: u), output: int("output_tokens", in: u),
            cacheWrite5m: write5m, cacheWrite1h: write1h, cacheRead: int("cache_read_input_tokens", in: u))
    }
}
