import Foundation

/// A transcript row that matters to the feature lanes: a loop wake-up or decision, a sub-agent spawn, or a test run.
/// Rows are small facts; `FeatureLanes` assembles them into lanes.
public struct FeatureSignal: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A `/loop` command row, or Claude calling the Skill tool with skill "loop". The prompt is truncated for display.
        case loopInvoked(prompt: String)
        /// A `system` row, subtype `scheduled_task_fire`, task kind `loop`: the harness waking Claude for the next iteration.
        case loopWakeup(taskID: String, cron: String?)
        /// Claude calling `ScheduleWakeup` to loop again.
        case wakeupScheduled(toolUseID: String, delaySeconds: Int, reason: String?)
        /// The result of that call, which says when the wake-up is due.
        case wakeupAck(toolUseID: String, scheduledFor: Date)
        /// `ScheduleWakeup` with `stop: true`.
        case loopStopped(toolUseID: String)
        /// Claude calling the `Agent` tool.
        case agentSpawned(toolUseID: String, type: String?, description: String)
        /// A Bash call whose command runs a known test runner.
        case testCommand(toolUseID: String, command: String)
        /// A tool result whose text contains something that looks like a runner summary.
        case testOutput(toolUseID: String, text: String)
    }

    /// The row's uuid, or `<toolUseID>#<tag>` for tool rows. Claude Code can write the same tool call into several rows
    /// and replay rows into forked sessions, so tool signals are identified by the call, not the row.
    public var id: String
    public var sessionID: String
    public var timestamp: Date
    public var kind: Kind
    public var isSidechain: Bool
}

extension TranscriptParser {
    private static let fireMarker = Data("scheduled_task_fire".utf8)
    private static let loopCommandMarker = Data("<command-name>/loop</command-name>".utf8)
    private static let scheduledForMarker = Data(#""scheduledFor""#.utf8)
    private static let toolResultMarker = Data(#""tool_result""#.utf8)
    private static let toolUseNameMarkers = ["ScheduleWakeup", "Skill", "Agent", "Bash"].map { Data(#""name":"\#($0)""#.utf8) }
    private static let summaryMarkers = ["Test run with", "Executed ", " passed", "Tests:"].map { Data($0.utf8) }
    /// What a command segment starts with when it runs tests. Matching the start (not anywhere in the text) keeps a commit
    /// message or an install that merely mentions a runner from counting as a test run.
    private static let testRunners = [
        "swift test", "pytest", "python -m pytest", "python3 -m pytest", "jest", "npx jest", "vitest", "npx vitest", "npm test",
        "npm run test", "npm t ", "yarn test", "pnpm test", "make test", "xcodebuild test",
    ]
    private static let loopPromptLimit = 100
    private static let outputKeep = 20_000

    /// Returns a signal for the rows the feature lanes read; nil for everything else. Like `parse(line:)` it filters on
    /// raw bytes first, because most rows are large blobs that are not worth decoding.
    public static func parseSignal(line: Data) -> FeatureSignal? {
        func has(_ marker: Data) -> Bool { line.range(of: marker) != nil }
        let isFire = has(fireMarker)
        let isLoopCommand = has(loopCommandMarker)
        let isAck = has(scheduledForMarker)
        let isToolUse = toolUseNameMarkers.contains(where: has)
        let isOutput = has(toolResultMarker) && summaryMarkers.contains(where: has)
        guard isFire || isLoopCommand || isAck || isToolUse || isOutput,
            let root = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
            let sessionID = root["sessionId"] as? String,
            let ts = (root["timestamp"] as? String).flatMap({ isoFractional.date(from: $0) ?? isoPlain.date(from: $0) })
        else { return nil }
        let sidechain = root["isSidechain"] as? Bool ?? false
        let uuid = root["uuid"] as? String ?? "\(sessionID)|\(ts.timeIntervalSince1970)"

        func signal(_ kind: FeatureSignal.Kind, id: String) -> FeatureSignal {
            FeatureSignal(id: id, sessionID: sessionID, timestamp: ts, kind: kind, isSidechain: sidechain)
        }

        switch root["type"] as? String {
        case "system":
            guard root["subtype"] as? String == "scheduled_task_fire", root["taskKind"] as? String == "loop",
                let taskID = root["taskId"] as? String
            else { return nil }
            return signal(.loopWakeup(taskID: taskID, cron: root["cron"] as? String), id: uuid)
        case "assistant":
            let blocks = ((root["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
            for block in blocks where block["type"] as? String == "tool_use" {
                guard let toolID = block["id"] as? String, let name = block["name"] as? String else { continue }
                let input = block["input"] as? [String: Any] ?? [:]
                switch name {
                case "ScheduleWakeup":
                    if input["stop"] as? Bool == true { return signal(.loopStopped(toolUseID: toolID), id: "\(toolID)#stop") }
                    let delay = (input["delaySeconds"] as? NSNumber)?.intValue ?? 0
                    return signal(.wakeupScheduled(toolUseID: toolID, delaySeconds: delay, reason: input["reason"] as? String), id: "\(toolID)#sched")
                case "Skill" where input["skill"] as? String == "loop":
                    return signal(.loopInvoked(prompt: shortened(input["args"] as? String ?? "")), id: "\(toolID)#loop")
                case "Agent":
                    return signal(
                        .agentSpawned(toolUseID: toolID, type: input["subagent_type"] as? String, description: input["description"] as? String ?? ""),
                        id: "\(toolID)#agent")
                case "Bash":
                    guard let command = input["command"] as? String, runsTests(command) else { continue }
                    return signal(.testCommand(toolUseID: toolID, command: command), id: "\(toolID)#test")
                default: continue
                }
            }
            return nil
        case "user":
            let content = (root["message"] as? [String: Any])?["content"]
            if let result = root["toolUseResult"] as? [String: Any], let ms = (result["scheduledFor"] as? NSNumber)?.doubleValue,
                let toolID = toolResultID(content) {
                return signal(.wakeupAck(toolUseID: toolID, scheduledFor: Date(timeIntervalSince1970: ms / 1000)), id: "\(toolID)#ack")
            }
            if let text = content as? String, let args = loopCommandArguments(in: text) {
                return signal(.loopInvoked(prompt: shortened(args)), id: uuid)
            }
            if let blocks = content as? [[String: Any]],
                let block = blocks.first(where: { $0["type"] as? String == "tool_result" }), let toolID = block["tool_use_id"] as? String {
                let text = resultText(block["content"])
                guard summaryMarkers.contains(where: { text.contains(String(decoding: $0, as: UTF8.self)) }) else { return nil }
                return signal(.testOutput(toolUseID: toolID, text: String(text.suffix(outputKeep))), id: "\(toolID)#out")
            }
            return nil
        default:
            return nil
        }
    }

    /// True when any segment of a shell command (split on `&&`, `||`, `;`, `|` and newlines) starts with a known test runner,
    /// after leading `VAR=value` assignments.
    static func runsTests(_ command: String) -> Bool {
        let segments = command.components(separatedBy: CharacterSet(charactersIn: ";|&\n")).map { $0.trimmingCharacters(in: .whitespaces) }
        return segments.contains { segment in
            var words = segment.split(separator: " ", omittingEmptySubsequences: true)[...]
            while let first = words.first, first.contains("="), !first.hasPrefix("-"), first.first?.isLetter == true { words = words.dropFirst() }
            let rest = words.joined(separator: " ") + " "
            return testRunners.contains { rest.hasPrefix($0.hasSuffix(" ") ? $0 : $0 + " ") }
        }
    }

    private static func toolResultID(_ content: Any?) -> String? {
        ((content as? [[String: Any]])?.first { $0["type"] as? String == "tool_result" })?["tool_use_id"] as? String
    }

    /// A tool result's text, whether it is a plain string or a list of text blocks.
    private static func resultText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        let blocks = content as? [[String: Any]] ?? []
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private static func loopCommandArguments(in text: String) -> String? {
        guard text.contains("<command-name>/loop</command-name>") else { return nil }
        guard let open = text.range(of: "<command-args>"), let close = text.range(of: "</command-args>", range: open.upperBound..<text.endIndex)
        else { return "" }
        return String(text[open.upperBound..<close.lowerBound])
    }

    private static func shortened(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > loopPromptLimit ? String(collapsed.prefix(loopPromptLimit)) + "…" : collapsed
    }
}
