import Foundation
import Testing
@testable import UsageCore

/// A session of finished turns on one model. Each turn is a prompt, then one response `minutes` later.
struct AdvisorWorld {
    struct Turn {
        var tools = 1; var output = 300; var thinking = 0; var minutes = 0.5
        static let light = Turn(), heavy = Turn(tools: 15, output: 3_000, thinking: 0, minutes: 2)
    }
    var model = "claude-sonnet-5-5"
    var turns: [Turn] = []
    var context = 20_000

    func timeline() -> SessionTimeline {
        var records: [UsageRecord] = [], events: [SessionEvent] = []
        var minute = 0.0
        for (i, turn) in turns.enumerated() {
            events.append(tevent("p\(i)", minute: minute, .prompt(preview: "p")))
            var r = tcall("c\(i)", minute: minute + turn.minutes, model: model, read: context, output: turn.output, thinking: turn.thinking)
            r.tools = Dictionary(uniqueKeysWithValues: (0..<turn.tools).map { ("t\(i)-\($0)", "Read") })
            records.append(r)
            minute += turn.minutes + 1
        }
        return Timelines.build(records: records, events: events, sessionID: "s1")
    }

    /// One minute after the last response: the cache is warm.
    func now(_ t: SessionTimeline) -> Date { (t.mainCalls.last?.time ?? .now).addingTimeInterval(60) }

    func advise(_ prompt: String?, project: ProjectProfile? = nil, laterBy: TimeInterval = 0) -> TerminalAdvice? {
        let t = timeline()
        return PromptAdvisor.advise(timeline: t, prompt: prompt, now: now(t).addingTimeInterval(laterBy), project: project)
    }
}

@Suite struct ModelAdviceTests {
    func world(_ model: String, _ turns: [AdvisorWorld.Turn], context: Int = 20_000) -> AdvisorWorld {
        AdvisorWorld(model: model, turns: turns, context: context)
    }
    let light3 = Array(repeating: AdvisorWorld.Turn.light, count: 3)
    let heavy3 = Array(repeating: AdvisorWorld.Turn.heavy, count: 3)

    @Test func lightWorkAfterLightTurnsOnOpusSuggestsSonnet() throws {
        let advice = try #require(world("claude-opus-5-5", light3).advise("fix the typo in the README"))
        #expect(advice.model?.tier == .sonnet && advice.model?.direction == .cheaper)
        #expect(advice.line.contains("/model sonnet"))
    }

    @Test func aDownshiftNeedsTheSessionToHaveBeenLightToo() {
        #expect(world("claude-opus-5-5", [.light, AdvisorWorld.Turn.heavy, .light]).advise("fix the typo in the README")?.model == nil)
        #expect(world("claude-opus-5-5", []).advise("fix the typo in the README")?.model == nil)
    }

    @Test func aShortUnlabelledPromptNeedsThreeLightTurnsToDownshift() {
        #expect(world("claude-opus-5-5", light3).advise("add a loading spinner to the save button")?.model?.tier == .sonnet)
        #expect(world("claude-opus-5-5", [.light, .light]).advise("add a loading spinner to the save button")?.model == nil)
    }

    @Test func aHardPromptNeverDownshifts() {
        #expect(world("claude-opus-5-5", light3).advise("find the root cause of the memory leak")?.model == nil)
    }

    @Test func aHeavyProjectBlocksADownshiftOnAnUnlabelledPrompt() {
        let heavyProject = ProjectProfile(turns: 40, heavy: 24, light: 4)
        #expect(world("claude-opus-5-5", light3).advise("add a loading spinner to the save button", project: heavyProject)?.model == nil)
        #expect(world("claude-opus-5-5", light3).advise("fix the typo in the README", project: heavyProject)?.model?.tier == .sonnet)
    }

    @Test func sonnetToHaikuNeedsAnExplicitlyLightPrompt() {
        #expect(world("claude-sonnet-5-5", light3).advise("fix the typo in the README")?.model?.tier == .haiku)
        #expect(world("claude-sonnet-5-5", light3).advise("add a loading spinner to the save button")?.model == nil)
    }

    @Test func nothingIsCheaperThanHaiku() {
        #expect(world("claude-haiku-5-5", light3).advise("fix the typo in the README")?.model == nil)
    }

    @Test func aHardPromptOnSonnetSuggestsOpus() throws {
        let advice = try #require(world("claude-sonnet-5-5", [.light]).advise("design the architecture for the sync engine"))
        #expect(advice.model?.tier == .opus && advice.model?.direction == .stronger)
        #expect(advice.line.contains("/model opus") && advice.line.contains("architecture"))
    }

    @Test func aWeaklyHardPromptNeedsHeavyTurnsBehindIt() {
        #expect(world("claude-sonnet-5-5", light3).advise("refactor the parser")?.model == nil)
        #expect(world("claude-sonnet-5-5", [.heavy, .heavy, .light]).advise("refactor the parser")?.model?.tier == .opus)
    }

    @Test func threeHeavyTurnsInARowOnSonnetSuggestOpus() throws {
        let advice = try #require(world("claude-sonnet-5-5", heavy3).advise("ok now the second endpoint"))
        #expect(advice.model?.tier == .opus)
        #expect(advice.line.contains("3 heavy turns"))
    }

    @Test func aHardPromptOnOpusStaysOnOpusUnlessTheSessionIsStruggling() {
        #expect(world("claude-opus-5-5", light3).advise("design the architecture for the sync engine")?.model == nil)
        #expect(world("claude-opus-5-5", heavy3).advise("design the architecture for the sync engine")?.model?.tier == .fable)
    }

    @Test func nothingIsStrongerThanFable() {
        #expect(world("claude-fable-5-1", heavy3).advise("design the architecture for the sync engine")?.model == nil)
    }

    @Test func aModelYouJustChoseIsLeftAlone() {
        // Two responses on Sonnet, then three on Opus: the switch to Opus was deliberate and recent.
        var records = (0..<2).map { tcall("a\($0)", minute: Double($0) * 2, model: "claude-sonnet-5-5") }
        records += (0..<3).map { tcall("b\($0)", minute: 10 + Double($0) * 2, model: "claude-opus-5-5") }
        let events = (0..<5).map { tevent("p\($0)", minute: (records[$0].timestamp.timeIntervalSince(TimelineTests.t0) / 60) - 0.1, .prompt(preview: "p")) }
        let t = Timelines.build(records: records, events: events, sessionID: "s1")
        #expect(PromptAdvisor.advise(timeline: t, prompt: "fix the typo in the README", now: t.mainCalls.last!.time.addingTimeInterval(60))?.model == nil)
    }

    @Test func aSwitchThatWouldNotPayBackSoonIsDeferredToTheNextCompactOrClear() throws {
        let advice = try #require(world("claude-opus-5-5", light3, context: 99_000).advise("fix the typo in the README"))
        #expect(advice.model?.deferred == true)
        #expect(advice.line.contains("next /compact or /clear"))
    }

    @Test func theLineSaysWhatTheSwitchCostsOnce() throws {
        let advice = try #require(world("claude-opus-5-5", light3, context: 20_000).advise("fix the typo in the README"))
        #expect(advice.line.contains("re-caches 20K") && advice.line.contains("$0.05"))
    }
}

@Suite struct CompactAdviceLineTests {
    func world(context: Int, model: String = "claude-opus-5-5", turns: [AdvisorWorld.Turn] = [.light, .light, .light]) -> AdvisorWorld {
        AdvisorWorld(model: model, turns: turns, context: context)
    }

    @Test func aColdCacheOnANewTopicSaysClear() throws {
        let advice = try #require(world(context: 120_000).advise("new task: add a settings page", laterBy: 7_200))
        #expect(advice.compact == .clear && advice.line.contains("/clear"))
    }

    @Test func aColdCacheOtherwiseSaysCompactOrClear() throws {
        let advice = try #require(world(context: 120_000).advise("keep going with the parser", laterBy: 7_200))
        #expect(advice.compact == .compact && advice.line.contains("/compact") && advice.line.contains("Cache expired"))
    }

    @Test func aBigContextWithManyCallsLeftSaysCompact() throws {
        let advice = try #require(world(context: 400_000, turns: [.heavy, .heavy, .light]).advise("keep going with the parser"))
        #expect(advice.compact == .compact)
    }

    @Test func compactingAndAnOverkillModelAreOneLine() throws {
        let advice = try #require(world(context: 400_000).advise("fix the typo in the README"))
        #expect(advice.compact == .compact && advice.model?.tier == .sonnet)
        #expect(advice.line.contains("/compact") && advice.line.contains("/model sonnet"))
    }

    @Test func aQuietSessionGetsNoAdvice() {
        #expect(world(context: 20_000, model: "claude-sonnet-5-5", turns: [.light, .heavy, .light]).advise("add a loading spinner") == nil)
    }

    @Test func everyLineIsOneShortLine() {
        let cases: [TerminalAdvice?] = [
            world(context: 120_000).advise("new task: add a settings page", laterBy: 7_200),
            world(context: 400_000).advise("fix the typo in the README"),
            world(context: 20_000).advise("fix the typo in the README"),
            world(context: 99_000).advise("fix the typo in the README"),
            AdvisorWorld(model: "claude-sonnet-5-5", turns: [.light], context: 20_000).advise("design the architecture for the sync engine"),
        ]
        for case let advice? in cases {
            #expect(!advice.line.contains("\n") && advice.line.count <= 130, "\(advice.line.count): \(advice.line)")
            #expect(advice.line.hasPrefix("KAIkei ▸ "))
            #expect(advice.short.count <= 60, "\(advice.short)")
        }
    }
}

@Suite struct ProjectProfileTests {
    @Test func theProfileCountsTurnsByWeight() {
        let a = AdvisorWorld(turns: [.light, .heavy, .light, .heavy]).timeline()
        let b = AdvisorWorld(turns: [.light]).timeline()
        let p = ProjectProfile.build(timelines: [a, b])
        #expect(p.turns == 5 && p.heavy == 2 && p.light == 3)
        #expect(abs(p.heavyShare - 0.4) < 1e-9)
    }

    @Test func anEmptyProfileHasNoOpinion() {
        let p = ProjectProfile.build(timelines: [])
        #expect(p.turns == 0 && p.heavyShare == 0 && !p.isUsuallyHeavy && !p.isUsuallyLight)
    }

    @Test func aProfileNeedsEnoughTurnsToCount() {
        #expect(!ProjectProfile(turns: 4, heavy: 4, light: 0).isUsuallyHeavy)
        #expect(ProjectProfile(turns: 20, heavy: 12, light: 2).isUsuallyHeavy)
    }

    @Test func aProfileSurvivesTheCacheFile() throws {
        let p = ProjectProfile(turns: 20, heavy: 12, light: 2)
        #expect(try JSONDecoder().decode(ProjectProfile.self, from: JSONEncoder().encode(p)) == p)
    }
}
