import Foundation
import Testing
@testable import UsageCore

@Suite struct AdvisorEngineTests {
    /// A temp project folder with one transcript of `turns` light turns on `model`, and a state folder for the advisor.
    struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("adv-\(UUID().uuidString)")
        var project: URL { root.appendingPathComponent("projects/-work-proj") }
        var state: URL { root.appendingPathComponent("state") }
        var transcript: URL { project.appendingPathComponent("s1.jsonl") }
        /// 14:00 on 25 Oct 2026, UTC. Turn i prompts at 14:0i:00 and is answered 20 seconds later.
        func ts(_ minute: Int, _ second: Int = 0) -> String { String(format: "2026-10-25T14:%02d:%02d.000Z", minute, second) }
        var lastAnswer: Date {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: ts(3, 20))!
        }

        init(model: String = "claude-opus-5-5", turns: Int = 4, session: String = "s1") throws {
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            var lines: [String] = []
            for i in 0..<turns {
                lines.append(promptLine("p\(i)", uuid: "u\(i)", session: session, ts: ts(i)))
                lines.append(assistantLine(id: "m\(i)", model: model, session: session, ts: ts(i, 20), input: 2, output: 200, read: 20_000))
            }
            try (lines.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        }
        func input(prompt: String?, session: String = "s1") -> Data {
            var d: [String: Any] = ["session_id": session, "transcript_path": transcript.path, "cwd": "/work/proj", "hook_event_name": "UserPromptSubmit"]
            if let prompt { d["prompt"] = prompt }
            return try! JSONSerialization.data(withJSONObject: d)
        }
        func engine() -> AdvisorEngine { AdvisorEngine(stateDir: state, now: { lastAnswer.addingTimeInterval(60) }) }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    func message(_ output: String?) throws -> String {
        let data = try #require(output).data(using: .utf8)!
        return try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["systemMessage"] as? String)
    }

    @Test func theHookOutputIsAUserOnlyMessage() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let out = fx.engine().hookOutput(fx.input(prompt: "fix the typo in the README"))
        #expect(try message(out).contains("/model sonnet"))
        // Never plain text and never additionalContext: those would go to Claude, not the user.
        #expect(try #require(out).hasPrefix("{"))
        #expect(!(out ?? "").contains("additionalContext"))
    }

    @Test func aQuietPromptPrintsNothing() throws {
        let fx = try Fixture(model: "claude-sonnet-5-5"); defer { fx.cleanup() }
        #expect(fx.engine().hookOutput(fx.input(prompt: "add a loading spinner to the save button")) == nil)
    }

    @Test func theSameAdviceIsNotRepeatedOnTheNextPrompt() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let engine = fx.engine()
        #expect(engine.hookOutput(fx.input(prompt: "fix the typo in the README")) != nil)
        #expect(engine.hookOutput(fx.input(prompt: "fix the typo in the README")) == nil)
    }

    @Test func sessionsKeepSeparateQuietPeriods() throws {
        let fx = try Fixture(), other = try Fixture(session: "other")
        defer { fx.cleanup(); other.cleanup() }
        _ = fx.engine().hookOutput(fx.input(prompt: "fix the typo in the README"))
        // Same state folder, a different session: its first piece of advice is shown.
        let engine = AdvisorEngine(stateDir: fx.state, now: { other.lastAnswer.addingTimeInterval(60) })
        #expect(engine.hookOutput(other.input(prompt: "fix the typo in the README", session: "other")) != nil)
    }

    @Test func garbageInputNeverThrowsOrPrints() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        #expect(fx.engine().hookOutput(Data("not json".utf8)) == nil)
        #expect(fx.engine().hookOutput(Data(#"{"session_id":"s1","transcript_path":"/nope.jsonl","prompt":"x"}"#.utf8)) == nil)
    }

    @Test func theStatusLineUsesClaudeCodesOwnFigures() throws {
        let fx = try Fixture(model: "claude-sonnet-5-5"); defer { fx.cleanup() }
        let json = #"{"session_id":"s1","transcript_path":"\#(fx.transcript.path)","cost":{"total_cost_usd":3.21},"context_window":{"used_percentage":42}}"#
        let text = fx.engine().statusLine(Data(json.utf8), color: false)
        #expect(text.contains("ctx 42%") && text.contains("$3.21"))
    }

    @Test func theStatusLineIsServedFromCacheWhileNothingHasChanged() throws {
        let fx = try Fixture(model: "claude-sonnet-5-5"); defer { fx.cleanup() }
        let json = Data(#"{"session_id":"s1","transcript_path":"\#(fx.transcript.path)","cost":{"total_cost_usd":3.21},"context_window":{"used_percentage":42}}"#.utf8)
        let first = fx.engine().statusLine(json, color: false)
        // Break the cached text on disk: an unchanged transcript, minute and figures must return exactly that, without re-reading.
        let dir = fx.state.appendingPathComponent("cache")
        let file = try #require(try FileManager.default.contentsOfDirectory(atPath: dir.path).first { $0.hasPrefix("status-") })
        var cached = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent(file))) as! [String: Any]
        cached["text"] = "from cache"
        try JSONSerialization.data(withJSONObject: cached).write(to: dir.appendingPathComponent(file))
        #expect(fx.engine().statusLine(json, color: false) == "from cache")
        #expect(first != "from cache")
        // A different cost figure is a different key.
        let changed = Data(#"{"session_id":"s1","transcript_path":"\#(fx.transcript.path)","cost":{"total_cost_usd":4.00},"context_window":{"used_percentage":42}}"#.utf8)
        #expect(fx.engine().statusLine(changed, color: false).contains("$4.00"))
    }

    @Test func theStatusLineWithoutATranscriptIsJustTheName() {
        #expect(AdvisorEngine(stateDir: FileManager.default.temporaryDirectory).statusLine(Data("{}".utf8), color: false) == "KAIkei")
    }

    /// A heavy transcript last touched an hour ago, plus a light one touched just now (a session still running).
    func addProjectTranscripts(_ fx: Fixture) throws -> (idle: URL, live: URL) {
        func write(_ name: String, session: String, tools: Int, age: TimeInterval) throws -> URL {
            var lines: [String] = []
            for i in 0..<12 {
                lines.append(promptLine("q\(i)", uuid: "\(session)u\(i)", session: session, ts: fx.ts(i)))
                for j in 0..<tools { lines.append(assistantLine(id: "\(session)-\(i)-\(j)", session: session, ts: fx.ts(i, 10 + j), output: 100, tool: ("\(session)x\(i)-\(j)", "Bash"))) }
            }
            let url = fx.project.appendingPathComponent(name)
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
            return url
        }
        return (try write("idle.jsonl", session: "idle", tools: 14, age: 3_600), try write("live.jsonl", session: "live", tools: 1, age: 5))
    }

    @Test func aSessionStillRunningDoesNotChangeTheProfile() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let (idle, live) = try addProjectTranscripts(fx)
        let a = fx.engine().projectProfile(for: fx.transcript)
        #expect(a.turns == 12 && a.heavy == 12)          // only the idle one counts
        // Two sessions in one project see the same profile, and share one cache file instead of overwriting each other's.
        #expect(fx.engine().projectProfile(for: live) == a)
        #expect(fx.engine().projectProfile(for: idle) == a)
        let files = try FileManager.default.contentsOfDirectory(atPath: fx.state.appendingPathComponent("cache").path).filter { $0.hasPrefix("profile-") }
        #expect(files.count == 1)
    }

    @Test func claudeCodesWindowSizeDecidesWhenTheWindowIsNearlyFull() throws {
        // 170K in a 200K window is 85% full, though KAIkei's own table says 1M.
        let fx = try Fixture(model: "claude-sonnet-5-5", turns: 3)
        defer { fx.cleanup() }
        var lines = try String(contentsOf: fx.transcript, encoding: .utf8).split(separator: "\n").map(String.init)
        lines.append(assistantLine(id: "big", model: "claude-sonnet-5-5", ts: fx.ts(3), input: 2, output: 100, read: 170_000))
        try (lines.joined(separator: "\n") + "\n").write(to: fx.transcript, atomically: true, encoding: .utf8)
        let json = #"{"session_id":"s1","transcript_path":"\#(fx.transcript.path)","cost":{"total_cost_usd":3},"context_window":{"used_percentage":85,"context_window_size":200000}}"#
        let engine = AdvisorEngine(stateDir: fx.state, now: { fx.lastAnswer.addingTimeInterval(10) })
        #expect(engine.statusLine(Data(json.utf8), color: false).contains("compact: 85% full"))
    }

    @Test func oldStateFilesArePrunedAndRecentOnesKept() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let state = fx.state.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let old = state.appendingPathComponent("throttle-old.json"), recent = state.appendingPathComponent("throttle-recent.json")
        try Data("{}".utf8).write(to: old); try Data("{}".utf8).write(to: recent)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30 * 86_400)], ofItemAtPath: old.path)
        _ = fx.engine().hookOutput(fx.input(prompt: "hello"))
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
    }

    @Test func explainShowsWhatTheAdviceRestedOn() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let text = fx.engine().explain(transcript: fx.transcript, prompt: "fix the typo in the README")
        #expect(text.contains("Opus") && text.contains("light") && text.contains("typo"))
        #expect(text.contains("/model sonnet"))
    }

    @Test func theProjectProfileComesFromTheOtherTranscripts() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        // A second transcript in the same project, all heavy turns: the project is usually heavy.
        var lines: [String] = []
        for i in 0..<12 {
            lines.append(promptLine("q\(i)", uuid: "v\(i)", session: "s2", ts: fx.ts(i)))
            for j in 0..<14 { lines.append(assistantLine(id: "n\(i)-\(j)", session: "s2", ts: fx.ts(i, 10 + j), output: 100, tool: ("x\(i)-\(j)", "Bash"))) }
        }
        let s2 = fx.project.appendingPathComponent("s2.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: s2, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3_600)], ofItemAtPath: s2.path)
        let profile = fx.engine().projectProfile(for: fx.transcript)
        #expect(profile.turns >= 12 && profile.isUsuallyHeavy)
        // A second look reuses the cache file.
        #expect(try FileManager.default.contentsOfDirectory(atPath: fx.state.appendingPathComponent("cache").path).contains { $0.hasPrefix("profile-") })
    }
}

@Suite struct TranscriptTailTests {
    func file(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tail-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func aSmallFileIsReadWhole() throws {
        let url = try file([assistantLine(id: "m1"), assistantLine(id: "m2")]); defer { try? FileManager.default.removeItem(at: url) }
        #expect(TranscriptTail.load(url, maxBytes: 1_000_000).records.count == 2)
    }

    @Test func aBigFileIsReadFromItsEndWithoutAHalfLine() throws {
        let lines = (0..<50).map { assistantLine(id: "m\($0)", ts: String(format: "2026-10-25T14:%02d:00.000Z", $0 % 60)) }
        let url = try file(lines); defer { try? FileManager.default.removeItem(at: url) }
        let cap = lines.last!.utf8.count * 5
        let store = TranscriptTail.load(url, maxBytes: cap)
        #expect(store.records.count >= 3 && store.records.count <= 5)
        #expect(store.records.last?.messageID == "m49")
    }

    @Test func aMissingFileIsEmpty() {
        #expect(TranscriptTail.load(URL(fileURLWithPath: "/nope/missing.jsonl"), maxBytes: 100).records.isEmpty)
    }
}
