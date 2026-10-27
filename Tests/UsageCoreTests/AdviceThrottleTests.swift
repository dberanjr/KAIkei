import Foundation
import Testing
@testable import UsageCore

@Suite struct AdviceThrottleTests {
    func advice(_ key: String, urgency: Int = 1) -> TerminalAdvice {
        TerminalAdvice(compact: nil, model: nil, urgency: urgency, line: "KAIkei ▸ x", short: "x", key: key)
    }

    @Test func theFirstAdviceIsShown() {
        var t = AdviceThrottle()
        let first = t.shouldShow(advice("compact"))
        #expect(first)
    }

    @Test func theSameAdviceIsNotRepeatedForTheNextThreePrompts() {
        var t = AdviceThrottle()
        _ = t.shouldShow(advice("compact"))
        let quiet = (0..<3).map { _ in t.shouldShow(advice("compact")) }
        #expect(quiet == [false, false, false])
        let fourth = t.shouldShow(advice("compact"))   // the fourth prompt after it
        #expect(fourth)
    }

    @Test func differentAdviceIsShownAtOnce() {
        var t = AdviceThrottle()
        _ = t.shouldShow(advice("compact"))
        let other = t.shouldShow(advice("model:sonnet"))
        #expect(other)
    }

    @Test func moreUrgentAdviceBreaksThrough() {
        var t = AdviceThrottle()
        _ = t.shouldShow(advice("compact", urgency: 1))
        let urgent = t.shouldShow(advice("compact", urgency: 2))
        #expect(urgent)
    }

    @Test func adviceThatWentAwayCanComeBack() {
        var t = AdviceThrottle()
        _ = t.shouldShow(advice("compact"))
        let gone = t.shouldShow(nil)
        let back = t.shouldShow(advice("compact"))
        #expect(!gone && back)
    }

    @Test func theStateSurvivesTheFileBetweenPrompts() throws {
        var t = AdviceThrottle()
        _ = t.shouldShow(advice("compact"))
        var reloaded = try JSONDecoder().decode(AdviceThrottle.self, from: JSONEncoder().encode(t))
        let again = reloaded.shouldShow(advice("compact"))
        #expect(!again)
    }
}
