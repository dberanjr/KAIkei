import Foundation
import Testing
@testable import UsageCore

/// Builds one transcript line shaped like the real ones Claude Code writes.
func assistantLine(
    id: String, model: String = "claude-opus-5-5", session: String = "s1",
    ts: String = "2026-10-25T14:25:50.554Z", input: Int = 2, output: Int = 100,
    write5m: Int = 0, write1h: Int = 0, read: Int = 0,
    tool: (id: String, name: String)? = nil, skill: String? = nil, plugin: String? = nil,
    sidechain: Bool = false, thinking: Int = 0, effort: String? = nil
) -> String {
    var content = #"{"type":"text","text":"hi"}"#
    if let tool { content = #"{"type":"tool_use","id":"\#(tool.id)","name":"\#(tool.name)","input":{}}"# }
    let attribution =
        (skill.map { #","attributionSkill":"\#($0)""# } ?? "") + (plugin.map { #","attributionPlugin":"\#($0)""# } ?? "")
    return #"{"parentUuid":null,"isSidechain":\#(sidechain),"type":"assistant","message":{"model":"\#(model)","id":"\#(id)","type":"message","role":"assistant","content":[\#(content)],"usage":{"input_tokens":\#(input),"cache_creation_input_tokens":\#(write5m + write1h),"cache_read_input_tokens":\#(read),"output_tokens":\#(output),"output_tokens_details":{"thinking_tokens":\#(thinking)},"cache_creation":{"ephemeral_1h_input_tokens":\#(write1h),"ephemeral_5m_input_tokens":\#(write5m)}}},"timestamp":"\#(ts)","sessionId":"\#(session)","cwd":"/work/proj"\#(attribution)\#(effort.map { #","effort":"\#($0)""# } ?? "")}"#
}

@Suite struct TranscriptParsingTests {
    @Test func parsesModelUsageAndAttribution() throws {
        let line = assistantLine(
            id: "m1", input: 3, output: 200, write5m: 10, write1h: 20, read: 400,
            tool: ("t1", "Bash"), skill: "dtctl", plugin: "dynatrace")
        let rec = try #require(TranscriptParser.parse(line: Data(line.utf8)))
        #expect(rec.messageID == "m1")
        #expect(rec.model == "claude-opus-5-5")
        #expect(rec.sessionID == "s1")
        #expect(rec.usage == TokenUsage(input: 3, output: 200, cacheWrite5m: 10, cacheWrite1h: 20, cacheRead: 400))
        #expect(rec.skill == "dtctl")
        #expect(rec.plugin == "dynatrace")
        #expect(rec.tools == ["t1": "Bash"])
        #expect(rec.cwd == "/work/proj")
        #expect(abs(rec.timestamp.timeIntervalSince1970 - 1_792_938_350.554) < 0.001)
    }

    @Test func parsesAgentIDAndSpawnIDFromSidechainRows() throws {
        let line = assistantLine(id: "m1", sidechain: true).replacingOccurrences(
            of: #""cwd":"/work/proj""#, with: #""cwd":"/work/proj","agentId":"a9556657103b4de13","wireToolInputs":{"toolu_01TWi":{"subagent_type":"fork"}}"#)
        let rec = try #require(TranscriptParser.parse(line: Data(line.utf8)))
        #expect(rec.agentID == "a9556657103b4de13")
        #expect(rec.spawnToolUseID == "toolu_01TWi")
    }

    @Test func mainThreadRowsHaveNoAgentID() throws {
        let rec = try #require(TranscriptParser.parse(line: Data(assistantLine(id: "m1").utf8)))
        #expect(rec.agentID == nil && rec.spawnToolUseID == nil)
    }

    @Test func ignoresNonAssistantLines() {
        let user = #"{"type":"user","message":{"role":"user","content":"hello"},"sessionId":"s1"}"#
        #expect(TranscriptParser.parse(line: Data(user.utf8)) == nil)
    }

    @Test func ignoresAssistantRowsWithoutUsage() {
        let line = #"{"type":"assistant","message":{"id":"x","model":"<synthetic>","content":[],"usage":{"input_tokens":0,"output_tokens":0}},"timestamp":"2026-10-25T14:25:50.554Z","sessionId":"s1"}"#
        #expect(TranscriptParser.parse(line: Data(line.utf8)) == nil)
    }

    @Test func treatsUntypedCacheCreationAsFiveMinute() throws {
        let line = #"{"type":"assistant","message":{"id":"x","model":"claude-opus-5-5","content":[],"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":50,"cache_read_input_tokens":0}},"timestamp":"2026-10-25T14:25:50Z","sessionId":"s1"}"#
        let rec = try #require(TranscriptParser.parse(line: Data(line.utf8)))
        #expect(rec.usage.cacheWrite5m == 50)
        #expect(rec.usage.cacheWrite1h == 0)
    }
}

@Suite struct RecordStoreTests {
    @Test func repeatedMessageIDCountsOnce() throws {
        // Claude Code writes one row per content block; all share message.id and usage.
        var store = RecordStore()
        for _ in 0..<3 {
            let rec = try #require(TranscriptParser.parse(line: Data(assistantLine(id: "m1", output: 100).utf8)))
            store.add(rec)
        }
        #expect(store.records.count == 1)
        #expect(store.records[0].usage.output == 100)
    }

    @Test func duplicateRowsMergeToolsAndKeepLargestUsage() throws {
        var store = RecordStore()
        store.add(try #require(TranscriptParser.parse(line: Data(assistantLine(id: "m1", output: 10, tool: ("t1", "Read")).utf8))))
        store.add(try #require(TranscriptParser.parse(line: Data(assistantLine(id: "m1", output: 90, tool: ("t2", "Bash")).utf8))))
        let rec = store.records[0]
        #expect(rec.usage.output == 90)
        #expect(Set(rec.tools.values) == ["Read", "Bash"])
    }

    @Test func sameMessageIDInDifferentSessionsStaysSeparate() throws {
        var store = RecordStore()
        store.add(try #require(TranscriptParser.parse(line: Data(assistantLine(id: "m1", session: "a").utf8))))
        store.add(try #require(TranscriptParser.parse(line: Data(assistantLine(id: "m1", session: "b").utf8))))
        #expect(store.records.count == 2)
    }
}

@Suite struct IncrementalReaderTests {
    func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tx-\(UUID().uuidString).jsonl")
    }

    @Test func readsOnlyNewCompleteLinesOnEachPass() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        var reader = IncrementalReader()
        var store = RecordStore()

        try (assistantLine(id: "m1") + "\n").write(to: url, atomically: true, encoding: .utf8)
        reader.ingest(url, into: &store)
        #expect(store.records.count == 1)

        // Second line is half-written (no trailing newline yet): must not be consumed or double-counted later.
        let second = assistantLine(id: "m2")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(second.prefix(60).utf8))
        reader.ingest(url, into: &store)
        #expect(store.records.count == 1)

        try handle.write(contentsOf: Data((String(second.dropFirst(60)) + "\n").utf8))
        try handle.close()
        reader.ingest(url, into: &store)
        reader.ingest(url, into: &store) // idempotent when nothing changed
        #expect(store.records.map(\.messageID).sorted() == ["m1", "m2"])
    }

    @Test func restartsWhenFileIsTruncated() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        var reader = IncrementalReader()
        var store = RecordStore()
        try (assistantLine(id: "m1") + "\n" + assistantLine(id: "m2") + "\n").write(to: url, atomically: true, encoding: .utf8)
        reader.ingest(url, into: &store)
        try (assistantLine(id: "m3") + "\n").write(to: url, atomically: true, encoding: .utf8)
        reader.ingest(url, into: &store)
        #expect(store.records.map(\.messageID).sorted() == ["m1", "m2", "m3"])
    }
}
