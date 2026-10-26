import Foundation
import Testing
@testable import UsageCore

@Suite struct TestSummaryParserTests {
    func parse(_ s: String) -> TestSummary? { TestSummaryParser.parse(s) }

    @Test func swiftTestingSummary() throws {
        let s = try #require(parse("✔ Test run with 234 tests in 32 suites passed after 0.274 seconds."))
        #expect(s.passed == 234 && s.failed == 0 && s.skipped == 0 && s.total == 234 && s.runner == "swift test")
    }

    @Test func swiftTestingFailureCountsFailedTests() throws {
        let out = """
            ✘ Test a() failed after 0.001 seconds with 1 issue.
            ✘ Test b() failed after 0.001 seconds with 1 issue.
            ✘ Test c() failed after 0.001 seconds with 1 issue.
            ✘ Test run with 234 tests in 32 suites failed after 0.3 seconds with 3 issues.
            """
        let s = try #require(parse(out))
        #expect(s.failed == 3 && s.passed == 231)
    }

    @Test func xctestUsesTheLastExecutedLine() throws {
        let out = """
            Test Suite 'A' passed. Executed 5 tests, with 0 failures (0 unexpected) in 0.1 (0.1) seconds
            Test Suite 'All tests' failed. Executed 12 tests, with 2 failures (0 unexpected) in 0.3 (0.3) seconds
            """
        let s = try #require(parse(out))
        #expect(s.passed == 10 && s.failed == 2)
    }

    @Test func anEmptyXCTestRunPlusASwiftTestingRunIsOneSummary() throws {
        let out = """
            Test Suite 'All tests' passed. Executed 0 tests, with 0 failures (0 unexpected) in 0.001 (0.002) seconds
            ✔ Test run with 234 tests in 32 suites passed after 0.274 seconds.
            """
        let s = try #require(parse(out))
        #expect(s.passed == 234 && s.failed == 0)
    }

    @Test func pytestSummaryExcludesSkippedFromTheTotal() throws {
        let s = try #require(parse("======== 8 passed, 1 failed, 2 skipped in 0.52s ========"))
        #expect(s.passed == 8 && s.failed == 1 && s.skipped == 2 && s.total == 9 && s.runner == "pytest")
    }

    @Test func jestSummary() throws {
        let s = try #require(parse("Tests:       1 failed, 5 passed, 6 total"))
        #expect(s.passed == 5 && s.failed == 1 && s.runner == "jest")
    }

    @Test func vitestSummary() throws {
        let out = " Test Files  2 passed (2)\n       Tests  7 passed (7)\n    Start at  11:59:56"
        let s = try #require(parse(out))
        #expect(s.passed == 7 && s.failed == 0 && s.runner == "vitest")
        let bad = try #require(parse("      Tests  1 failed | 4 passed | 2 skipped (7)"))
        #expect(bad.passed == 4 && bad.failed == 1 && bad.skipped == 2)
    }

    @Test func aFailedSwiftTestingRunIsNeverGreenEvenWithoutItsFailedTestLines() throws {
        // A long run can push the per-test lines out of the captured output; the summary line alone must still say it failed.
        let s = try #require(parse("✘ Test run with 300 tests in 3 suites failed after 1.2 seconds with 2 issues."))
        #expect(s.failed >= 1 && s.passed + s.failed == 300)
    }

    @Test func xctestReadsTheSuiteLineThenTheExecutedLineBelowIt() throws {
        let out = "Test Suite 'All tests' failed at 2026-10-25 12:00:00.000.\n\t Executed 12 tests, with 2 failures (0 unexpected) in 0.3 (0.3) seconds"
        let s = try #require(parse(out))
        #expect(s.passed == 10 && s.failed == 2)
    }

    @Test func anInterruptedXCTestRunIsNotASmallGreenRun() {
        // A crash mid-run leaves only per-suite subtotals; they are not the run's result.
        let out = "Test Suite 'FirstTests' passed at 2026-10-25 12:00:00.000.\n\t Executed 5 tests, with 0 failures (0 unexpected) in 0.1 (0.1) seconds"
        #expect(parse(out) == nil)
    }

    @Test func noRecognisableSummaryIsNil() {
        #expect(parse("error: build failed") == nil)
        #expect(parse("3 files passed review") == nil)
    }
}

@Suite struct TestLaneTests {
    func lane(_ signals: [FeatureSignal]) -> TestLane? { FeatureLanes.tests(signals: signals) }

    func run(_ id: String, command minute: Double, output: String?, outputMinute: Double? = nil) -> [FeatureSignal] {
        var out = [tsignal("\(id)#test", minute: minute, .testCommand(toolUseID: id, command: "swift test"))]
        // Output with no readable summary never becomes a signal (see parseSignal), so a run without one is unreadable.
        if let output, let summary = TestSummaryParser.parse(output) {
            out.append(tsignal("\(id)#out", minute: outputMinute ?? minute + 1, .testOutput(toolUseID: id, summary: summary)))
        }
        return out
    }
    let green = "✔ Test run with 10 tests in 2 suites passed after 0.1 seconds."
    let red = "✘ Test a() failed after 0.001 seconds with 1 issue.\n✘ Test run with 10 tests in 2 suites failed after 0.1 seconds with 1 issue."

    @Test func runsPairCommandsWithOutputsByToolUseID() throws {
        let l = try #require(lane(run("t1", command: 1, output: red) + run("t2", command: 5, output: green)))
        #expect(l.runs.map(\.id) == ["t1", "t2"])
        #expect(l.runs[0].summary?.failed == 1 && l.runs[1].summary?.passed == 10)
        #expect(l.runs[1].time == TimelineTests.t0.addingTimeInterval(6 * 60))  // when the result arrived
        #expect(l.lastState == .green)
    }

    @Test func lastStateIsRedWhenTheLastRunFailed() throws {
        #expect(try #require(lane(run("t1", command: 1, output: green) + run("t2", command: 5, output: red))).lastState == .red)
    }

    @Test func aCommandWithUnreadableOutputIsAnUnreadableRun() throws {
        let l = try #require(lane(run("t1", command: 1, output: "3 files passed review")))
        #expect(l.runs[0].summary == nil && l.lastState == .unreadable)
    }

    @Test func lastStateIsUnreadableNotGreenAfterAnEarlierGreenRun() throws {
        let l = try #require(lane(run("t1", command: 1, output: green) + run("t2", command: 5, output: "3 files passed review")))
        #expect(l.lastState == .unreadable)
    }

    @Test func aCommandWithNoOutputRowIsUnreadable() throws {
        let l = try #require(lane(run("t1", command: 1, output: nil)))
        #expect(l.runs[0].time == TimelineTests.t0.addingTimeInterval(60) && l.lastState == .unreadable)
    }

    @Test func anEmptyRunIsNotGreen() throws {
        let l = try #require(lane(run("t1", command: 1, output: "Test Suite 'All tests' passed. Executed 0 tests, with 0 failures (0 unexpected) in 0 (0) seconds")))
        #expect(l.lastState == .unreadable && l.runs[0].summary == nil)  // a run of zero tests is not a result
    }

    @Test func noTestCommandsMeansNoLane() {
        #expect(lane([]) == nil)
        #expect(lane([tsignal("t1#out", minute: 1, .testOutput(toolUseID: "t1", summary: TestSummary(runner: "swift test", passed: 1, failed: 0, skipped: 0)))]) == nil)
    }
}
