import Testing

@testable import Downloads

/// Which tier is there without any action.
///
/// **The finding (AP6):** The suggested resolution was a **constant**, while
/// `ARCHITEKTUR.md` lists it as one of the five consumers of the network information. Measured on
/// 2026-09-06. (M1/M6), the same cellular cell lay between **0.28 and 7.34 Mbit/s** —
/// twenty-six to one, and the difference was a change of location.
@Suite("The tier suggestion")
struct SelectionSuggestionTests {

    /// **Downwards and not upwards.** The reason for 720p is the screen size and
    /// not the line; on Wi-Fi it applies just the same. A rule that suggests more at
    /// home would overrule a decision that has nothing to do with the network.
    @Test("On a capable route the suggestion stands")
    func sustainableStaysSame() {
        #expect(SelectionRule.suggestion(largeVolumesAcceptable: true) == SelectionRule.suggestion)
    }

    /// 720p through the bottom end of a cell is not a film but a wait.
    @Test("On an expensive or narrow route one tier lower")
    func expensiveGoesLower() {
        let frugal = SelectionRule.suggestion(largeVolumesAcceptable: false)

        #expect(frugal == .minimal)
        #expect(frugal != SelectionRule.suggestion)
    }

    /// **A suggestion and not a limit.** Both tiers stay in the list; what the
    /// rule prevents is the tier someone gets *without* choosing it.
    @Test("Both tiers stay selectable")
    func bothStayInTheList() {
        #expect(SelectionRule.slots.contains(SelectionRule.suggestion))
        #expect(SelectionRule.slots.contains(SelectionRule.suggestion(largeVolumesAcceptable: false)))
    }
}
