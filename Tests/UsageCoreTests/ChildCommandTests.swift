import Foundation
import Testing
@testable import UsageCore

@Suite struct ChildCommandTests {
    @Test func returnsTheCommandsOutputWithoutItsTrailingNewline() {
        #expect(ChildCommand.run("echo hi", input: Data(), timeout: 5) == "hi")
    }

    @Test func theCommandGetsTheInputOnStdin() {
        #expect(ChildCommand.run("cat", input: Data("from stdin".utf8), timeout: 5) == "from stdin")
    }

    @Test func aSlowCommandIsGivenUpOnAndKilled() {
        let start = Date()
        #expect(ChildCommand.run("sleep 5; echo late", input: Data(), timeout: 0.5) == nil)
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func aCommandThatNeverReadsALargeInputNeitherHangsNorKillsUs() {
        let big = Data(repeating: 0x61, count: 2_000_000)
        #expect(ChildCommand.run("echo ok", input: big, timeout: 5) == "ok")
        #expect(ChildCommand.run("head -c 1 >/dev/null; echo ok", input: big, timeout: 5) == "ok")
    }

    @Test func aLargeInputRoundTripsThroughCat() {
        let big = Data(repeating: 0x61, count: 300_000)
        #expect(ChildCommand.run("cat", input: big, timeout: 5)?.utf8.count == 300_000)
    }

    @Test func aMissingCommandGivesNothing() {
        #expect(ChildCommand.run("definitely-not-a-command-xyz", input: Data(), timeout: 5)?.isEmpty ?? true)
    }
}
