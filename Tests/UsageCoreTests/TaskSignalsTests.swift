import Foundation
import Testing
@testable import UsageCore

@Suite struct ModelTierTests {
    @Test func tiersComeFromTheModelId() {
        #expect(ModelTier(modelID: "claude-opus-5-5-20260101") == .opus)
        #expect(ModelTier(modelID: "claude-sonnet-5-5") == .sonnet)
        #expect(ModelTier(modelID: "claude-haiku-4-5") == .haiku)
        #expect(ModelTier(modelID: "claude-fable-5-1") == .fable)
        #expect(ModelTier(modelID: "<synthetic>") == nil)
    }

    @Test func theLadderRunsHaikuSonnetOpusFable() {
        #expect(ModelTier.haiku < .sonnet && .sonnet < .opus && .opus < .fable)
        #expect(ModelTier.opus.cheaper == .sonnet && ModelTier.haiku.cheaper == nil)
        #expect(ModelTier.sonnet.stronger == .opus && ModelTier.fable.stronger == nil)
    }

    @Test func eachTierHasTheNameYouTypeAfterModel() {
        #expect(ModelTier.sonnet.alias == "sonnet" && ModelTier.opus.alias == "opus" && ModelTier.haiku.alias == "haiku")
        #expect(ModelTier.fable.alias == "claude-fable-5-1")
    }
}

@Suite struct PromptClassifierTests {
    @Test func plainMechanicalRequestsAreLight() {
        for p in ["fix the typo in the README", "rename fooBar to barBaz", "what does this function do?", "run the tests",
                  "write a commit message for this", "add a docstring to parse()"] {
            #expect(PromptClassifier.classify(p).kind == .light, "\(p)")
        }
    }

    @Test func hardInvestigationsAndDesignAreStronglyHeavy() {
        for p in ["design the architecture for the sync engine", "investigate why the race condition shows up under load",
                  "do a security review of the auth flow", "find the root cause of the memory leak"] {
            #expect(PromptClassifier.classify(p).kind == .strongHeavy, "\(p)")
        }
    }

    @Test func aLongPromptWithNoCueIsOnlyWeaklyHeavy() {
        let long = String(repeating: "Here is a lot of detail about the thing I want built. ", count: 20)
        #expect(PromptClassifier.classify(long).kind == .weakHeavy)
    }

    @Test func anOrdinaryChangeIsUnknown() {
        #expect(PromptClassifier.classify("add a loading spinner to the save button").kind == .unknown)
    }

    @Test func aHeavyCueBeatsALightOne() {
        #expect(PromptClassifier.classify("explain the root cause of the deadlock").kind == .strongHeavy)
    }

    @Test func theCueIsReportedForTheMessage() {
        #expect(PromptClassifier.classify("find the root cause of the leak").cue == "root cause")
    }

    @Test func aLongOrMultiLinePromptIsNeverLightEvenWithALightWordInIt() {
        let long = "explain why login fails after the token refresh, here is the stack trace from the server logs and the client, "
            + "the retry loop looks wrong when two tabs are open and I am not sure which side is at fault"
        #expect(PromptClassifier.classify(long).kind != .light)
        #expect(PromptClassifier.classify("explain this\nTraceback (most recent call last)").kind != .light)
        #expect(PromptClassifier.classify("explain ```swift\nlet x = 1\n```").kind != .light)
    }

    @Test func cuesMatchWholeWordsNotFragments() {
        #expect(PromptClassifier.classify("fix the eslint config").kind != .light)       // "lint" inside "eslint"
        #expect(PromptClassifier.classify("tweak the typography").kind != .light)        // "typo" inside "typography"
        #expect(PromptClassifier.classify("fix the typos in the docs").kind == .light)   // plural still counts
        #expect(PromptClassifier.classify("overwrite the file").kind != .strongHeavy)    // no "rewrite" in "overwrite"
    }

    @Test func designWordsInADocumentationRequestAreNotHeavy() {
        #expect(PromptClassifier.classify("rewrite the commit message").kind == .light)
        #expect(PromptClassifier.classify("update the architecture diagram in the README").kind != .strongHeavy)
        #expect(PromptClassifier.classify("design the architecture for the sync engine").kind == .strongHeavy)
    }

    @Test func approvalsAreNotTasks() {
        for p in ["yes go ahead", "thanks", "ok", "lgtm!", "continue", "sure, do it"] { #expect(PromptClassifier.isAcknowledgement(p), "\(p)") }
        #expect(!PromptClassifier.isAcknowledgement("ok now the second endpoint"))
    }

    @Test func newTopicWordsAreRecognised() {
        #expect(PromptClassifier.startsNewTopic("new task: add a settings page"))
        #expect(PromptClassifier.startsNewTopic("unrelated, but can you check the CI config"))
        #expect(!PromptClassifier.startsNewTopic("now also handle the empty case"))
    }
}

@Suite struct TurnWeightTests {
    func end(tools: Int = 0, output: Int = 0, thinking: Int = 0, duration: TimeInterval = 10) -> TurnEnd {
        TurnEnd(turn: 1, time: .now, duration: duration, calls: 1, tools: tools, inputTokens: 0, outputTokens: output,
                thinkingTokens: thinking, cost: 0)
    }

    @Test func aShortQuietTurnIsLight() { #expect(TurnWeight.of(end(tools: 2, output: 800)) == .light) }
    @Test func lotsOfToolsIsHeavy() { #expect(TurnWeight.of(end(tools: 14, output: 800)) == .heavy) }
    @Test func lotsOfOutputIsHeavy() { #expect(TurnWeight.of(end(tools: 2, output: 7_000)) == .heavy) }
    @Test func lotsOfThinkingIsHeavy() { #expect(TurnWeight.of(end(thinking: 12_000)) == .heavy) }
    @Test func aTenMinuteTurnIsHeavy() { #expect(TurnWeight.of(end(duration: 700)) == .heavy) }
    @Test func anyThinkingKeepsATurnFromBeingLight() { #expect(TurnWeight.of(end(tools: 1, output: 300, thinking: 900)) == .medium) }
    @Test func inBetweenIsMedium() { #expect(TurnWeight.of(end(tools: 6, output: 3_000)) == .medium) }
}
