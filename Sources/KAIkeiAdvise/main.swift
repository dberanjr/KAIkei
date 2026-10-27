import Foundation
import UsageCore

// kaikei-advise: the terminal side of KAIkei. Claude Code runs it as a UserPromptSubmit hook (`prompt`) and as the
// status line command (`statusline`). It prints nothing, and exits 0, whenever it has nothing useful to say or anything goes
// wrong, so it can never get in the way of typing.

let usage = """
    usage: kaikei-advise prompt                     (hook: reads Claude Code's JSON on stdin)
           kaikei-advise statusline [--then CMD]    (status line: reads Claude Code's JSON on stdin)
           kaikei-advise explain TRANSCRIPT.jsonl [PROMPT...]

    """

/// What the status line has collected so far, so the watchdog can print that instead of nothing.
final class StatusParts: @unchecked Sendable {
    private let lock = NSLock()
    private var previous: String?, ours: String?
    func set(previous value: String?) { lock.lock(); previous = value; lock.unlock() }
    func set(ours value: String) { lock.lock(); ours = value; lock.unlock() }
    func text() -> String {
        lock.lock(); defer { lock.unlock() }
        return [previous.flatMap { $0.isEmpty ? nil : $0 }, ours ?? "KAIkei"].compactMap { $0 }.joined(separator: "\n")
    }
}

let args = Array(CommandLine.arguments.dropFirst())
let engine = AdvisorEngine(stateDir: AdvisorEngine.defaultStateDir)
let parts = StatusParts()
let isStatusLine = args.first == "statusline"

// A hung transcript read must never hold up a prompt. A slow status line prints what it has.
DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
    if isStatusLine { print(parts.text()) }
    exit(0)
}

switch args.first {
case "prompt":
    if let out = engine.hookOutput(FileHandle.standardInput.readDataToEndOfFile()) { print(out) }
case "statusline":
    let input = FileHandle.standardInput.readDataToEndOfFile()
    // Wrap the status line command that was there before, so it keeps working: run it on the same input, alongside our own
    // work and under its own time limit, and show it first.
    let group = DispatchGroup()
    if let i = args.firstIndex(of: "--then"), args.indices.contains(i + 1) {
        group.enter()
        DispatchQueue.global().async {
            parts.set(previous: ChildCommand.run(args[i + 1], input: input, timeout: 1.5))
            group.leave()
        }
    }
    parts.set(ours: engine.statusLine(input, color: true))
    group.wait()
    print(parts.text())
case "explain":
    guard args.count >= 2 else { FileHandle.standardError.write(Data(usage.utf8)); exit(2) }
    let prompt = args.count > 2 ? args[2...].joined(separator: " ") : nil
    print(engine.explain(transcript: URL(fileURLWithPath: args[1]), prompt: prompt))
default:
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}
exit(0)
