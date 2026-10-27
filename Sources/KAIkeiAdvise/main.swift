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

// A hung transcript read must never hold up a prompt.
DispatchQueue.global().asyncAfter(deadline: .now() + 3) { exit(0) }

let args = Array(CommandLine.arguments.dropFirst())
let engine = AdvisorEngine(stateDir: AdvisorEngine.defaultStateDir)

switch args.first {
case "prompt":
    if let out = engine.hookOutput(FileHandle.standardInput.readDataToEndOfFile()) { print(out) }
case "statusline":
    let input = FileHandle.standardInput.readDataToEndOfFile()
    var lines: [String] = []
    // Wrap the status line command that was there before, so it keeps working: run it on the same input and show it first.
    if let i = args.firstIndex(of: "--then"), args.indices.contains(i + 1) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", args[i + 1]]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil {
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
            let previous = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .newlines)
            if !previous.isEmpty { lines.append(previous) }
        }
    }
    lines.append(engine.statusLine(input, color: true))
    print(lines.joined(separator: "\n"))
case "explain":
    guard args.count >= 2 else { FileHandle.standardError.write(Data(usage.utf8)); exit(2) }
    let prompt = args.count > 2 ? args[2...].joined(separator: " ") : nil
    print(engine.explain(transcript: URL(fileURLWithPath: args[1]), prompt: prompt))
default:
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}
exit(0)
