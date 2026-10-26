import Foundation
import Testing
@testable import UsageCore

/// Lines shaped like the user and system rows Claude Code writes next to the assistant rows.
func promptLine(
    _ text: String, uuid: String = "u1", session: String = "s1", ts: String = "2026-10-25T14:25:00.000Z",
    sidechain: Bool = false, meta: Bool = false, asBlocks: Bool = false, extra: String = ""
) -> String {
    let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    let content = asBlocks ? #"[{"type":"text","text":"\#(escaped)"}]"# : #""\#(escaped)""#
    return #"{"parentUuid":null,"isSidechain":\#(sidechain),"isMeta":\#(meta),"promptId":"p1","type":"user","message":{"role":"user","content":\#(content)},"uuid":"\#(uuid)","timestamp":"\#(ts)","sessionId":"\#(session)","cwd":"/work/proj"\#(extra)}"#
}

func toolResultLine(uuid: String = "r1", session: String = "s1") -> String {
    #"{"isSidechain":false,"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]},"uuid":"\#(uuid)","timestamp":"2026-10-25T14:25:05.000Z","sessionId":"\#(session)"}"#
}

func compactBoundaryLine(
    uuid: String = "c1", session: String = "s1", trigger: String = "auto", pre: Int? = 222_385, post: Int? = 21_928,
    duration: Int? = 47_650, ts: String = "2026-10-25T14:30:00.000Z"
) -> String {
    let meta = [pre.map { #""preTokens":\#($0)"# }, post.map { #""postTokens":\#($0)"# },
                duration.map { #""durationMs":\#($0)"# }].compactMap { $0 }.joined(separator: ",")
    return #"{"type":"system","subtype":"compact_boundary","content":"Conversation compacted","isMeta":false,"level":"info","compactMetadata":{"trigger":"\#(trigger)",\#(meta)},"uuid":"\#(uuid)","timestamp":"\#(ts)","sessionId":"\#(session)"}"#
}

@Suite struct EventParsingTests {
    func event(_ line: String) -> SessionEvent? { TranscriptParser.parseEvent(line: Data(line.utf8)) }

    @Test func aTypedPromptBecomesAPromptEvent() throws {
        let e = try #require(event(promptLine("Fix the login bug please")))
        #expect(e.kind == .prompt(preview: "Fix the login bug please"))
        #expect(e.sessionID == "s1" && e.id == "u1" && !e.isSidechain)
        #expect(abs(e.timestamp.timeIntervalSince1970 - 1_792_938_300) < 0.001)
    }

    @Test func promptsWrittenAsTextBlocksAreRecognisedToo() throws {
        let e = try #require(event(promptLine("hello there", asBlocks: true)))
        #expect(e.kind == .prompt(preview: "hello there"))
    }

    @Test func previewCollapsesWhitespaceAndIsCapped() throws {
        let long = "line one\n\n   line two " + String(repeating: "x", count: 600)
        guard case .prompt(let preview) = try #require(event(promptLine(long))).kind else { Issue.record("not a prompt"); return }
        #expect(preview.hasPrefix("line one line two xxx"))
        #expect(preview.count == 401 && preview.hasSuffix("…"))  // 400 characters plus the ellipsis
    }

    @Test func toolResultsAreNotPrompts() {
        #expect(event(toolResultLine()) == nil)
    }

    @Test func injectedAndSummaryRowsAreNotPrompts() {
        #expect(event(promptLine("anything", meta: true)) == nil)
        #expect(event(promptLine("This session is being continued...", extra: #","isCompactSummary":true"#)) == nil)
        #expect(event(promptLine("<system-reminder>be careful</system-reminder>")) == nil)
        #expect(event(promptLine("<local-command-stdout>output</local-command-stdout>")) == nil)
        #expect(event(promptLine("<bash-input>ls</bash-input>")) == nil)
    }

    @Test func sidechainPromptsAreFlagged() throws {
        #expect(try #require(event(promptLine("research this", sidechain: true))).isSidechain)
    }

    @Test func slashCommandsBecomeCommandEvents() throws {
        let clear = "<command-name>/clear</command-name>\n<command-message>clear</command-message>\n<command-args></command-args>"
        #expect(try #require(event(promptLine(clear))).kind == .command(name: "/clear"))
        #expect(try #require(event(promptLine("<command-name>/model</command-name><command-args>opus</command-args>"))).kind == .command(name: "/model"))
    }

    @Test func compactBoundaryCarriesTriggerAndTokenCounts() throws {
        let e = try #require(event(compactBoundaryLine()))
        #expect(e.kind == .compact(trigger: "auto", preTokens: 222_385, postTokens: 21_928, durationMs: 47_650))
        #expect(e.id == "c1" && e.sessionID == "s1")
    }

    @Test func compactBoundaryWithMissingFieldsStillParses() throws {
        let e = try #require(event(compactBoundaryLine(trigger: "manual", pre: nil, post: nil, duration: nil)))
        #expect(e.kind == .compact(trigger: "manual", preTokens: nil, postTokens: nil, durationMs: nil))
    }

    @Test func otherRowsAndGarbageYieldNothing() {
        #expect(event(assistantLine(id: "m1")) == nil)
        #expect(event(#"{"type":"system","subtype":"turn_duration","durationMs":5}"#) == nil)
        #expect(event("not json") == nil)
        #expect(event("") == nil)
    }

    @Test func assistantRowsRecordThinkingTokensAndEffort() throws {
        let rec = try #require(TranscriptParser.parse(line: Data(assistantLine(id: "m1", output: 1000, thinking: 707, effort: "xhigh").utf8)))
        #expect(rec.thinkingTokens == 707)
        #expect(rec.effort == "xhigh")
        let plain = try #require(TranscriptParser.parse(line: Data(assistantLine(id: "m2").utf8)))
        #expect(plain.thinkingTokens == 0 && plain.effort == nil)
    }
}

@Suite struct EventStoreTests {
    @Test func theSameEventSeenTwiceIsKeptOnce() throws {
        // Forked or resumed sessions replay earlier rows into a new file, so events repeat verbatim.
        var store = RecordStore()
        let e = try #require(TranscriptParser.parseEvent(line: Data(promptLine("hi").utf8)))
        store.add(e); store.add(e)
        #expect(store.events.count == 1)
    }

    @Test func differentEventsAreAllKept() throws {
        var store = RecordStore()
        for line in [promptLine("a", uuid: "u1"), promptLine("b", uuid: "u2"), compactBoundaryLine(uuid: "c1")] {
            store.add(try #require(TranscriptParser.parseEvent(line: Data(line.utf8))))
        }
        #expect(store.events.count == 3)
    }

    @Test func mergingRecordsKeepsTheLargerThinkingCountAndFirstEffort() throws {
        var store = RecordStore()
        store.add(try #require(TranscriptParser.parse(line: Data(assistantLine(id: "m1", output: 10, thinking: 3).utf8))))
        store.add(try #require(TranscriptParser.parse(line: Data(assistantLine(id: "m1", output: 10, thinking: 9, effort: "high").utf8))))
        #expect(store.records.count == 1)
        #expect(store.records[0].thinkingTokens == 9 && store.records[0].effort == "high")
    }

    @Test func theReaderPicksUpEventsAlongsideUsage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ev-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("t.jsonl")
        try [promptLine("go"), assistantLine(id: "m1"), toolResultLine(), compactBoundaryLine()]
            .joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
        var reader = IncrementalReader(), store = RecordStore()
        reader.ingest(file, into: &store)
        #expect(store.records.count == 1)
        #expect(store.events.count == 2)  // the prompt and the compact; the tool result is not an event
    }
}
