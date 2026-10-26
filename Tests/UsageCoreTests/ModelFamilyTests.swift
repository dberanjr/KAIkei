import Testing
@testable import UsageCore

@Suite struct ModelFamilyTests {
    @Test func groupsVersionsUnderTheirFamily() {
        #expect(ModelFamily(modelID: "claude-opus-5-5") == .opus)
        #expect(ModelFamily(modelID: "claude-opus-4-7") == .opus)
        #expect(ModelFamily(modelID: "claude-sonnet-5") == .sonnet)
        #expect(ModelFamily(modelID: "claude-haiku-4-5-20251001") == .haiku)
    }

    @Test func fableMythosAndUnknownFoldIntoOther() {
        // Only three families have validated, color-blind-safe chart colors; the rest share one neutral.
        #expect(ModelFamily(modelID: "claude-fable-5-1") == .other)
        #expect(ModelFamily(modelID: "claude-mythos-5") == .other)
        #expect(ModelFamily(modelID: "<synthetic>") == .other)
    }

    @Test func displayNamesAreHumanReadable() {
        #expect(ModelFamily.displayName(modelID: "claude-sonnet-5-5") == "Sonnet 5.5")
        #expect(ModelFamily.displayName(modelID: "claude-opus-4-7") == "Opus 4.7")
        #expect(ModelFamily.displayName(modelID: "claude-haiku-4-5-20251001") == "Haiku 4.5")
        #expect(ModelFamily.displayName(modelID: "claude-fable-5-1") == "Fable 5.1")
        #expect(ModelFamily.displayName(modelID: "something-else") == "something-else")
    }
}
