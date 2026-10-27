import Foundation
import Testing
@testable import UsageCore

@Suite struct StatusLineTextTests {
    func timeline(context: Int = 180_000, model: String = "claude-sonnet-5-5") -> SessionTimeline {
        AdvisorWorld(model: model, turns: [.light, .light], context: context).timeline()
    }

    @Test func showsContextCacheAndCost() {
        let t = timeline()
        let text = StatusLineText.make(timeline: t, advice: nil, now: t.mainCalls.last!.time.addingTimeInterval(60), color: false)
        #expect(text.hasPrefix("KAIkei"))
        #expect(text.contains("ctx 18%"))
        #expect(text.contains("cache 4m"))     // five-minute cache, one minute in
        #expect(text.contains("$"))
        #expect(!text.contains("\u{1B}"))
    }

    @Test func aLapsedCacheSaysCold() {
        let t = timeline()
        let text = StatusLineText.make(timeline: t, advice: nil, now: t.mainCalls.last!.time.addingTimeInterval(3_600), color: false)
        #expect(text.contains("cache cold"))
    }

    @Test func adviceRidesAtTheEnd() {
        let t = timeline()
        let advice = TerminalAdvice(compact: .compact, model: nil, urgency: 1, line: "KAIkei ▸ long", short: "compact: pays back in ~4 calls", key: "compact")
        let text = StatusLineText.make(timeline: t, advice: advice, now: t.mainCalls.last!.time.addingTimeInterval(60), color: false)
        #expect(text.hasSuffix("▸ compact: pays back in ~4 calls"))
    }

    @Test func colourIsOptionalAndAdviceIsHighlighted() {
        let t = timeline()
        let advice = TerminalAdvice(compact: .compact, model: nil, urgency: 2, line: "KAIkei ▸ long", short: "compact: 86% full", key: "compact")
        let text = StatusLineText.make(timeline: t, advice: advice, now: t.mainCalls.last!.time.addingTimeInterval(60), color: true)
        #expect(text.contains("\u{1B}["))
        #expect(text.hasSuffix("\u{1B}[0m"))
    }

    @Test func anEmptySessionShowsJustTheName() {
        #expect(StatusLineText.make(timeline: SessionTimeline(), advice: nil, now: .now, color: false) == "KAIkei")
    }
}
