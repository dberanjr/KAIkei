import Foundation

/// What one test run reported. Skipped tests are shown on their own and are not part of the total.
public struct TestSummary: Equatable, Sendable {
    public var runner: String
    public var passed: Int
    public var failed: Int
    public var skipped: Int
    public var total: Int { passed + failed }
}

/// Reads the summary a test runner prints. Anything it does not recognise is nil, never a guess.
public enum TestSummaryParser {
    public static func parse(_ output: String) -> TestSummary? {
        swift(output) ?? pytest(output) ?? jest(output)
    }

    /// `swift test` prints an XCTest summary (possibly "Executed 0 tests") and a swift-testing summary. Both count.
    private static func swift(_ output: String) -> TestSummary? {
        var total = 0, failed = 0, found = false
        if let m = lastMatch(#"Executed (\d+) tests?, with (\d+) failures?"#, in: output) {
            total += m[0]; failed += m[1]; found = true
        }
        if let m = lastMatch(#"Test run with (\d+) tests?"#, in: output) {
            total += m[0]; found = true
            failed += matches(#"✘ Test (?!run with).+ failed after"#, in: output)
        }
        return found ? TestSummary(runner: "swift test", passed: max(0, total - failed), failed: failed, skipped: 0) : nil
    }

    private static func pytest(_ output: String) -> TestSummary? {
        guard let line = output.split(separator: "\n").last(where: { $0.range(of: #" in [\d.]+s"#, options: .regularExpression) != nil })
        else { return nil }
        let text = String(line)
        func count(_ word: String) -> Int { lastMatch(#"(\d+) \#(word)"#, in: text)?[0] ?? 0 }
        let passed = count("passed"), failed = count("failed") + count("errors?"), skipped = count("skipped")
        return passed + failed + skipped == 0 ? nil : TestSummary(runner: "pytest", passed: passed, failed: failed, skipped: skipped)
    }

    private static func jest(_ output: String) -> TestSummary? {
        guard let line = output.split(separator: "\n").last(where: { $0.contains("Tests:") && $0.contains("total") }) else { return nil }
        let text = String(line)
        func count(_ word: String) -> Int { lastMatch(#"(\d+) \#(word)"#, in: text)?[0] ?? 0 }
        return TestSummary(runner: "jest", passed: count("passed"), failed: count("failed"), skipped: count("skipped"))
    }

    /// The integer capture groups of the last match, or nil.
    private static func lastMatch(_ pattern: String, in text: String) -> [Int]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
            let m = re.matches(in: text, range: NSRange(text.startIndex..., in: text)).last
        else { return nil }
        return (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: text).flatMap { Int(text[$0]) } }
    }

    private static func matches(_ pattern: String, in text: String) -> Int {
        (try? NSRegularExpression(pattern: pattern))?.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) ?? 0
    }
}

/// One test command and what it reported. A nil summary means the output could not be read.
public struct TestRun: Identifiable, Equatable, Sendable {
    public var id: String
    /// When the result arrived, or when the command ran if no result row exists.
    public var time: Date
    public var command: String
    public var summary: TestSummary?
}

public struct TestLane: Equatable, Sendable {
    public enum State: Equatable, Sendable { case green, red, unreadable }
    public var runs: [TestRun]
    /// How the session left its tests. An unreadable last run is never green, whatever came before it.
    public var lastState: State {
        guard let s = runs.last?.summary, s.total > 0 else { return .unreadable }
        return s.failed == 0 ? .green : .red
    }
}

extension FeatureLanes {
    public static func tests(signals: [FeatureSignal]) -> TestLane? {
        var commands: [String: (time: Date, command: String)] = [:]
        var outputs: [String: (time: Date, text: String)] = [:]
        for s in signals.sorted(by: { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }) {
            switch s.kind {
            case .testCommand(let id, let command): commands[id] = (s.timestamp, command)
            case .testOutput(let id, let text): outputs[id] = (s.timestamp, text)
            default: break
            }
        }
        guard !commands.isEmpty else { return nil }
        let runs = commands.map { id, c in
            TestRun(id: id, time: outputs[id]?.time ?? c.time, command: c.command, summary: outputs[id].flatMap { TestSummaryParser.parse($0.text) })
        }.sorted { ($0.time, $0.id) < ($1.time, $1.id) }
        return TestLane(runs: runs)
    }
}
