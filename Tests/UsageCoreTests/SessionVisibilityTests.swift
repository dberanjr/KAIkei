import Testing
@testable import UsageCore

@Suite struct SessionVisibilityTests {
    let ids = ["a", "b", "c", "d"]

    @Test func archivedSessionsLeaveTheListInOrderAndKeepTheirOwnList() {
        let r = SessionVisibility.partition(ids, id: { $0 }, archived: ["b", "d"])
        #expect(r.visible == ["a", "c"] && r.archived == ["b", "d"])
    }

    @Test func nothingArchivedShowsEverything() {
        let r = SessionVisibility.partition(ids, id: { $0 }, archived: [])
        #expect(r.visible == ids && r.archived.isEmpty)
    }

    @Test func archivingAnIdThatIsNotOpenChangesNothing() {
        let r = SessionVisibility.partition(ids, id: { $0 }, archived: ["zzz"])
        #expect(r.visible == ids && r.archived.isEmpty)
    }

    @Test func showingArchivedKeepsThemInTheirOriginalPositions() {
        #expect(SessionVisibility.ordered(ids, id: { $0 }, archived: ["b"], includeArchived: true) == ids)
        #expect(SessionVisibility.ordered(ids, id: { $0 }, archived: ["b"], includeArchived: false) == ["a", "c", "d"])
    }
}
