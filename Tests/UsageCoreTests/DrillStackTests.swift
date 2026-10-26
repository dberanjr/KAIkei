import Foundation
import Testing
@testable import UsageCore

@Suite struct DrillStackTests {
    func stack(_ targets: DrillTarget...) -> DrillStack {
        var s = DrillStack()
        for t in targets { s.push(t) }
        return s
    }

    @Test func startsUnfilteredAtTheDashboard() {
        let s = DrillStack()
        #expect(!s.isFiltered && s.current == nil && s.depth == 0 && s.previousTitle == nil)
    }

    @Test func pushingNarrowsTheViewAndMarksItFiltered() {
        let s = stack(.model("claude-sonnet-5-5"), .session("abc"))
        #expect(s.isFiltered && s.depth == 2 && s.current == .session("abc"))
    }

    @Test func pushingTheItemAlreadyOnScreenDoesNothing() {
        var s = stack(.model("m"))
        s.push(.model("m"))
        #expect(s.depth == 1)
    }

    @Test func backGoesUpOneLevelAndNamesWhereItGoes() {
        var s = stack(.model("claude-sonnet-5-5"), .session("abc"))
        #expect(s.previousTitle == "Sonnet 5.5")
        s.back()
        #expect(s.current == .model("claude-sonnet-5-5") && s.previousTitle == "the dashboard")
        s.back()
        #expect(!s.isFiltered)
        s.back()   // already at the top: harmless
        #expect(s.depth == 0)
    }

    @Test func clearDropsEveryFilterAtOnce() {
        var s = stack(.skill("x"), .session("abc"), .day(Date(timeIntervalSince1970: 0)))
        s.clear()
        #expect(!s.isFiltered && s.depth == 0)
    }

    @Test func theTrailListsEveryLevelFromTheDashboard() {
        let s = stack(.skill("tdd"), .session("2f72c602-aa7e"))
        let labels = s.crumbs.map(\.label)
        #expect(labels == ["Dashboard", "tdd", "Session 2f72c602"])
        #expect(s.crumbs.map(\.keeping) == [0, 1, 2])
    }

    @Test func jumpingToACrumbKeepsOnlyTheLevelsUpToIt() {
        var s = stack(.model("m"), .skill("s"), .session("abc"))
        s.keep(1)
        #expect(s.targets == [.model("m")])
        s.keep(0)
        #expect(!s.isFiltered)
        s.keep(5)   // asking for more than exists changes nothing
        #expect(s.depth == 0)
    }

    @Test func aFilterReadsAsKindAndName() {
        #expect(stack(.model("claude-opus-5-5")).summary == "Model: Opus 5.5")
        #expect(stack(.model("claude-opus-5-5"), .session("abc12345xyz")).summary == "Model: Opus 5.5 › Session: Session abc12345")
        #expect(DrillStack().summary == "")
    }

    @Test func targetsSurviveBeingWrittenOutAndReadBack() throws {
        let t: DrillTarget = .day(Date(timeIntervalSince1970: 1_792_929_600))
        let data = try JSONEncoder().encode(t)
        #expect(try JSONDecoder().decode(DrillTarget.self, from: data) == t)
        let m = try JSONDecoder().decode(DrillTarget.self, from: JSONEncoder().encode(DrillTarget.model("x")))
        #expect(m == .model("x"))
    }
}
