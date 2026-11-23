import Testing

@testable import Features

/// **The 79 groups were on the first level** — AP46, 2026-09-24.
///
/// A provider brings around eighty channel groups, and each was a row in the "Live"
/// section. Against that a **register** was built on 2026-09-12. ("over ninety presses become
/// two") — that helps with reaching them and does not change the number. The done condition
/// of the package, however, demands that the focus targets per section on the first level
/// be **under 15**.
@Suite("The group row")
struct GroupRowTests {

    /// **The count is half the information**, and it must hit both numbers: how many appear and
    /// how many there are. "46 of 79" answers the question for which one would otherwise have
    /// to go in.
    @Test("The count names visible and all groups")
    func countStateNamesBoth() {
        let known = ["Sport", "Nachrichten", "Kinder", "Musik"]
        let hidden: Set<String> = ["Musik"]

        #expect(LiveSettings.rows(known: known, hidden: hidden).count == 4)
        // **The calculation from the source and not one in the test.** Whoever recomputes it here
        // checks their own calculation — and that stays green even if the one in the code is
        // wrong.
        #expect(LiveSettings.visible(known: known, hidden: hidden) == 3)
    }

    /// **A hidden group does not drop out of the list**, it just does not count as visible.
    ///
    /// Otherwise it could no longer be switched on — the same error as with a selected channel
    /// whose group is switched off (finding S3-12).
    @Test("Hidden groups stay in the list")
    func hiddenStayHidden() {
        let known = ["Sport", "Musik"]
        let rows = LiveSettings.rows(known: known, hidden: ["Musik"])
        #expect(rows.contains("Musik"))
    }

    /// Without groups there is nothing to show — and then no row either.
    @Test("Without groups the row is omitted")
    func noRowWithoutGroups() {
        #expect(LiveSettings.rows(known: [], hidden: []).isEmpty)
    }
}
