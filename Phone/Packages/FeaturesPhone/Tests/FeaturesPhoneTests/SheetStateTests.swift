import Testing

@testable import FeaturesPhone

@Suite("Sheet state")
@MainActor
struct SheetStateTests {

    @Test("At the start none is open")
    func initially() {
        #expect(SheetState().pending == nil)
    }

    /// The rule that the prototype's walkthrough checks specifically.
    @Test("A second sheet replaces the first; one never lies on top of another")
    func onlyOne() {
        let state = SheetState()
        state.open(.catalogChoice)
        #expect(state.pending == .catalogChoice)
        state.open(.sources)
        #expect(state.pending == .sources)
        state.close()
        #expect(!state.isOpen)
    }

    /// Every sheet comes from the bottom, and the height is a proportion — not a number.
    ///
    /// **The upper bound is inclusive since the person sheet was measured.**
    /// 0.70 is the calculated value from the design (520 points plus the switch row of the
    /// child mode, out of 852) and at the same time the ceiling: what wants to be taller wants `.large`
    /// and no proportion — a sheet that covers almost everything is a screen with a
    /// handle on top.
    @Test("Every sheet has a fraction between 0.4 and 0.7", arguments: SheetID.allCases)
    func portion(sheet: SheetID) {
        #expect(sheet.portion > 0.4 && sheet.portion <= 0.7)
    }

    /// **Twenty-five since AP13.** The season picker was added on 2026-09-05: in the
    /// design it was a chip row, and with twelve seasons the row scrolled the chosen one
    /// out of view. The number is not an end in itself here — it is the brake against a
    /// sheet that someone introduces on the side without checking in the design whether one is
    /// needed.
    /// **Twenty-seven** — the track picker came with the player, the group picker with
    /// the Live package. The number is not an end in itself here: it is the brake against
    /// a sheet that someone introduces on the side without checking in the design whether one is
    /// needed.
    ///
    /// *Before, two paragraphs stood here about sheets that no longer exist: the
    /// Live diagnostics and — since 2026-09-09 — `reise`, "For the trip". The product owner
    /// removed it (the view is not needed; only the downloads view is), and with it the airplane button that opened it. The brake
    /// counts in both directions: whoever removes a sheet comes by here and writes
    /// the reasoning after it — otherwise a sentence stands over a sheet that nobody
    /// finds any more.*
    ///
    /// **Twenty-eight since the evening of 2026-09-08** — `titleProfile`, and it is **not** in the
    /// design. The reason is there nonetheless and older than this project: *"What you have
    /// opens; what you do not have explains itself."* The TV project answered the question
    /// on 2026-08-08, first wrongly — foreign rows were not supposed to answer at all —,
    /// and the correction stands there in the source. Two thirds of the titles in a person's career
    /// are not in the own library; without this sheet that would be
    /// two thirds of rows that stay silent when pressed.
    ///
    /// **Twenty-nine since 2026-09-25** — `profileImage` (AP49). The choice needs a
    /// sheet of its own because it carries a grid and a preview; in the person sheet it would
    /// sit under the account list and the child mode, and nobody looks for it there.
    ///
    /// **Thirty since the evening of 2026-09-25** — `profilePin` (AP52): the profile PIN needs
    /// a sheet of its own because it opens from out of the person sheet and before an account switch
    /// — both places where another sheet is just closing.
    ///
    /// **Thirty-one since 2026-09-26** — `infoBoard` (AP58 G1, A4): cast, further
    /// episodes and similar titles from the player — on the TV the area below, here a
    /// sheet of its own, because the track sheet already carries audio, subtitles and speed.
    @Test("Thirty-one sheets, each with a reason")
    func count() {
        #expect(SheetID.allCases.count == 31)
    }
}
