import Foundation
import Testing
@testable import UsageCore

/// Rows shaped like the ones Claude Code writes for /loop, sub-agents and test runs (see the real run in the design spec).
private func envelope(_ type: String, _ body: String, uuid: String, session: String, ts: String, sidechain: Bool = false) -> String {
    #"{"type":"\#(type)",\#(body),"uuid":"\#(uuid)","timestamp":"\#(ts)","sessionId":"\#(session)","isSidechain":\#(sidechain)}"#
}

private func toolUseLine(
    _ name: String, input: String, toolID: String, uuid: String = "a1", session: String = "s1",
    ts: String = "2026-10-25T14:25:00.000Z", sidechain: Bool = false
) -> String {
    envelope(
        "assistant",
        #""message":{"model":"claude-sonnet-5-5","id":"m-\#(toolID)","role":"assistant","content":[{"type":"tool_use","id":"\#(toolID)","name":"\#(name)","input":\#(input)}]}"#,
        uuid: uuid, session: session, ts: ts, sidechain: sidechain)
}

func fireLine(taskID: String = "50d65d60", kind: String = "loop", uuid: String = "f1", session: String = "s1", ts: String = "2026-10-25T14:25:00.000Z") -> String {
    envelope(
        "system",
        #""subtype":"scheduled_task_fire","content":"Claude resuming /loop wakeup","isMeta":false,"taskId":"\#(taskID)","cron":"57 11 * * *","prompt":"/loop go","taskKind":"\#(kind)","cronKind":"\#(kind)""#,
        uuid: uuid, session: session, ts: ts)
}

func scheduleLine(toolID: String = "t1", delay: Int = 1200, reason: String = "no event to watch", ts: String = "2026-10-25T14:25:00.000Z") -> String {
    toolUseLine("ScheduleWakeup", input: #"{"delaySeconds":\#(delay),"noop":false,"prompt":"/loop go","reason":"\#(reason)"}"#, toolID: toolID, ts: ts)
}

func stopLine(toolID: String = "t2", ts: String = "2026-10-25T14:25:00.000Z") -> String {
    toolUseLine("ScheduleWakeup", input: #"{"stop":true}"#, toolID: toolID, ts: ts)
}

func ackLine(toolID: String = "t1", scheduledForMs: Int = 1_790_186_220_000, ts: String = "2026-10-25T14:25:01.000Z") -> String {
    envelope(
        "user",
        #""message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(toolID)","content":"Next wakeup scheduled for 11:57:00"}]},"toolUseResult":{"scheduledFor":\#(scheduledForMs),"clampedDelaySeconds":1200,"wasClamped":false}"#,
        uuid: "ack-\(toolID)", session: "s1", ts: ts)
}

func skillLoopLine(toolID: String = "t3", args: String = "keep iterating") -> String {
    toolUseLine("Skill", input: #"{"skill":"loop","args":"\#(args)"}"#, toolID: toolID)
}

func loopCommandLine(args: String = "keep iterating", ts: String = "2026-10-25T14:25:00.000Z") -> String {
    envelope(
        "user",
        #""message":{"role":"user","content":"<command-message>loop</command-message> <command-name>/loop</command-name> <command-args>\#(args)</command-args>"}"#,
        uuid: "cmd1", session: "s1", ts: ts)
}

func agentLine(toolID: String = "t4", type: String = "fork", description: String = "Explore data", sidechain: Bool = false) -> String {
    toolUseLine("Agent", input: #"{"subagent_type":"\#(type)","description":"\#(description)","prompt":"do it"}"#, toolID: toolID, sidechain: sidechain)
}

func bashLine(toolID: String = "t5", command: String) -> String {
    toolUseLine("Bash", input: #"{"command":"\#(command)"}"#, toolID: toolID)
}

func outputLine(toolID: String = "t5", text: String) -> String {
    envelope(
        "user",
        #""message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(toolID)","content":"\#(text)"}]}"#,
        uuid: "out-\(toolID)", session: "s1", ts: "2026-10-25T14:26:00.000Z")
}

@Suite struct FeatureSignalTests {
    func signal(_ line: String) -> FeatureSignal? { TranscriptParser.parseSignal(line: Data(line.utf8)) }

    @Test func aFireRowBecomesAWakeup() throws {
        let s = try #require(signal(fireLine()))
        #expect(s.kind == .loopWakeup(taskID: "50d65d60", cron: "57 11 * * *"))
        #expect(s.sessionID == "s1" && s.id == "f1" && !s.isSidechain)
        #expect(abs(s.timestamp.timeIntervalSince1970 - 1_792_938_300) < 0.001)
    }

    @Test func aScheduleWakeupCallCarriesDelayAndReason() throws {
        let s = try #require(signal(scheduleLine()))
        #expect(s.kind == .wakeupScheduled(toolUseID: "t1", delaySeconds: 1200, reason: "no event to watch"))
        #expect(s.sessionID == "s1")
    }

    @Test func aStopCallIsAStop() throws {
        let s = try #require(signal(stopLine()))
        #expect(s.kind == .loopStopped(toolUseID: "t2"))
    }

    @Test func anAckCarriesTheScheduledTime() throws {
        let s = try #require(signal(ackLine()))
        guard case .wakeupAck(let id, let when) = s.kind else { Issue.record("not an ack: \(s.kind)"); return }
        #expect(id == "t1")
        #expect(when == Date(timeIntervalSince1970: 1_790_186_220))
    }

    @Test func theLoopSkillAndTheLoopCommandBothMeanInvoked() throws {
        #expect(try #require(signal(skillLoopLine())).kind == .loopInvoked(prompt: "keep iterating"))
        #expect(try #require(signal(loopCommandLine())).kind == .loopInvoked(prompt: "keep iterating"))
    }

    @Test func aLongLoopPromptIsTruncatedForDisplay() throws {
        let s = try #require(signal(skillLoopLine(args: String(repeating: "x", count: 300))))
        guard case .loopInvoked(let prompt) = s.kind else { Issue.record("not invoked"); return }
        #expect(prompt.count <= 101)
    }

    @Test func anAgentCallCarriesTypeAndDescription() throws {
        let s = try #require(signal(agentLine()))
        #expect(s.kind == .agentSpawned(toolUseID: "t4", type: "fork", description: "Explore data"))
    }

    @Test func onlyKnownRunnerCommandsBecomeTestCommands() throws {
        let yes = try #require(signal(bashLine(command: "swift test --filter X")))
        #expect(yes.kind == .testCommand(toolUseID: "t5", command: "swift test --filter X"))
        #expect(signal(bashLine(command: "ls -la")) == nil)
    }

    @Test func onlyACommandThatRunsARunnerIsATestCommand() throws {
        // Found in a real transcript: a commit message and an install that merely mention a runner were counted as test runs.
        #expect(signal(bashLine(command: #"git commit -m \"v0.0.12: add Vitest test infrastructure\""#)) == nil)
        #expect(signal(bashLine(command: "npm install --save-dev vitest")) == nil)
        #expect(signal(bashLine(command: "grep -r pytest docs/")) == nil)
        for command in [#"cd \"/work/my app\" && npm test"#, "npx vitest run", "FORCE_COLOR=0 pytest -q", "python3 -m pytest tests", "make test && echo ok",
                        "swift test --filter X", "cd x; yarn test"] {
            #expect(signal(bashLine(command: command)) != nil, "should be a test run: \(command)")
        }
    }

    @Test func aToolResultBecomesTestOutputOnlyWhenItHoldsAReadableSummary() throws {
        let yes = try #require(signal(outputLine(text: "Test run with 3 tests in 1 suites passed after 0.1 seconds.")))
        #expect(yes.kind == .testOutput(toolUseID: "t5", summary: TestSummary(runner: "swift test", passed: 3, failed: 0, skipped: 0)))
        #expect(signal(outputLine(text: "file contents here")) == nil)
        // Matches a marker ("passed") but is not a runner summary, e.g. a source file that was read.
        #expect(signal(outputLine(text: "3 files passed review")) == nil)
    }

    @Test func aLaunchResultLinksTheAgentToItsSpawn() throws {
        let line = envelope(
            "user",
            #""message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_x","content":"Async agent launched"}]},"toolUseResult":{"isAsync":true,"status":"async_launched","agentId":"ag1","description":"Explore data"}"#,
            uuid: "res1", session: "s1", ts: "2026-10-25T14:25:00.000Z")
        #expect(try #require(signal(line)).kind == .agentLaunched(toolUseID: "toolu_x", agentID: "ag1"))
    }

    @Test func unrelatedRowsReturnNil() {
        #expect(signal(promptLine("Fix the login bug please")) == nil)
        #expect(signal(assistantLine(id: "m1")) == nil)
        #expect(signal(fireLine(kind: "cron")) == nil)
        #expect(signal(toolResultLine()) == nil)
    }

    @Test func theSameToolCallKeepsTheSameIdAcrossRewrittenRows() throws {
        let a = try #require(signal(scheduleLine(toolID: "t9")))
        let b = try #require(signal(toolUseLineWithNewUUID(scheduleLine(toolID: "t9"))))
        #expect(a.id == b.id)
    }

    @Test func theSameSignalTwiceCountsOnce() throws {
        var store = RecordStore()
        let s = try #require(signal(scheduleLine(toolID: "t9")))
        store.add(s)
        store.add(s)
        #expect(store.signals == [s])
    }

    private func toolUseLineWithNewUUID(_ line: String) -> String { line.replacingOccurrences(of: #""uuid":"a1""#, with: #""uuid":"zz""#) }
}
