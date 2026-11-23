import Testing

@testable import DesignSystemPhone

/// The test that was missing in the TV program.
///
/// It runs every text against every background instead of asserting individual pairs. A new
/// color theme is thereby noticed at build time and not on the device.
@Suite("Contrast of the color patterns")
struct ContrastTests {

    /// The numbers from `GESTALTUNG.md` §1 — copied and thereby testable.
    ///
    /// If one of them no longer holds, either the board was changed or the calculation. Both
    /// should be noticed.
    @Test("The documented values match to two decimals")
    func documentedValues() {
        let t = ColorBoard.phoneCinema
        #expect(abs(Contrast.ratio(t.textQuiet, t.reason) - 5.93) < 0.01)
        #expect(abs(Contrast.ratio(t.textQuiet, t.surface) - 5.58) < 0.01)
        #expect(abs(Contrast.ratio(t.textQuiet, t.surfaceHigh) - 5.04) < 0.01)
        #expect(abs(Contrast.ratio(t.textMatt, t.reason) - 7.85) < 0.01)
        #expect(abs(Contrast.ratio(t.textMatt, t.surface) - 7.38) < 0.01)
        #expect(abs(Contrast.ratio(t.outline, t.reason) - 3.06) < 0.01)
        #expect(abs(Contrast.ratio(t.outlineSheet, t.surfaceHigh) - 3.25) < 0.01)
    }

    @Test("Every text is legible on every background", arguments: ColorBoard.all(forItem: .phone))
    func textOnSurface(board: ColorBoard) {
        let backgrounds = [
            ("reason", board.reason), ("surface", board.surface), ("surfaceHigh", board.surfaceHigh),
        ]
        let captions = [
            ("text", board.text), ("textMatt", board.textMatt), ("textQuiet", board.textQuiet),
        ]
        for (bottomName, bottom) in backgrounds {
            for (topName, top) in captions {
                let value = Contrast.ratio(top, bottom)
                #expect(
                    value >= Contrast.bodyText,
                    "\(board.id): \(topName) on \(bottomName) only reaches \(value)")
            }
        }
    }

    /// The reason ``ColorBoard/outlineSheet`` exists at all.
    @Test("Every outline is visible on its own background", arguments: ColorBoard.all(forItem: .phone))
    func outlines(board: ColorBoard) {
        #expect(Contrast.carries(board.outline, to: board.reason, atLeast: Contrast.control))
        #expect(
            Contrast.carries(
                board.outlineSheet, to: board.surfaceHigh, atLeast: Contrast.control))
    }

    /// The counter-check — and why it applies to only one theme.
    ///
    /// In "Cinema" the ordinary outline does **not** carry on the sheet (2.60 : 1), and exactly
    /// that is why the second value exists there. This test protects it from being deleted during
    /// cleanup.
    ///
    /// It does not apply in general, though: in "Contrast" the same outline also carries on the
    /// sheet (3.66 : 1). The second value is a **consequence of the threshold, not a rule** —
    /// whoever makes a law of it forbids a theme that is simply bright enough.
    @Test("In Cinema the second outline is really needed")
    func secondOutlineInCinema() {
        #expect(
            !Contrast.carries(
                ColorBoard.phoneCinema.outline, to: ColorBoard.phoneCinema.surfaceHigh,
                atLeast: Contrast.control))
    }

    @Test("Signal colors are legible on the background", arguments: ColorBoard.all(forItem: .phone))
    func signals(board: ColorBoard) {
        for (name, color) in [("gold", board.progress), ("live", board.live), ("good", board.success)] {
            let value = Contrast.ratio(color, board.reason)
            #expect(value >= Contrast.bodyText, "\(board.id): \(name) only reaches \(value)")
        }
    }

    /// The play button: light text on the accent color.
    ///
    /// The accent color itself carries only 3.56 : 1 as **text** on the background — it is a fill
    /// and not text, and this test records the difference.
    ///
    /// **Without exception since 2026-09-26.** "Midnight" has carried the TV's blue brand
    /// color since decision 24, and ``Styling/ColorBoard/text`` on it stood at 4.25 : 1. The
    /// brand color has since been made minimally darker (`#2D6ACA`) and holds 4.54 : 1.
    @Test("Text on the brand color is legible", arguments: ColorBoard.all(forItem: .phone))
    func textOnBrand(board: ColorBoard) {
        let value = Contrast.ratio(board.text, board.tag)
        #expect(value >= Contrast.bodyText, "\(board.id): text on brand only \(value)")
        #expect(Contrast.ratio(board.tag, board.reason) < Contrast.bodyText)
    }

    /// **The brand name is text and claims no exception** (contradiction W5).
    ///
    /// The pass of 2026-09-06 found a contradiction here: once the brand name counted as a violation
    /// ("LOUNGE carries 3.56 : 1"), once as a permitted exception for trademarks — with the same
    /// rule. **Re-measured on 2026-09-10 it resolves, and into a mix-up:** the 3.56 belongs to
    /// ``Styling/ColorBoard/tag``, the accent color, and that is a **fill** and appears
    /// nowhere as text — the test above records exactly that. ``BrandMark`` sets "LOUNGE" in
    /// ``Styling/ColorBoard/brandLight``, and that carries **5.30 : 1** (Kino) and **5.24 : 1**
    /// (Mitternacht) on the background.
    ///
    /// **With that the rule stands, and it does not need the exception:** the WCAG exception for
    /// logotypes applies to what is **drawn as a mark** — the armchair, a channel logo supplied
    /// by a provider. It does not apply to what is **set as text**, even if a brand name stands
    /// there: what is set with ``Styling/TypeLevel`` and a board color is text and carries
    /// 4.5 : 1.
    ///
    /// The proposal from finding 15 — lightening the surfaces — remains explicitly rejected: it
    /// pushed ``ColorBoard/textQuiet`` to 3.93 : 1 and thereby brought back exactly the error that
    /// was fixed on 2026-09-02.
    @Test("The brand name works as text, without exception", arguments: ColorBoard.all(forItem: .phone))
    func brandNameWorksAsText(board: ColorBoard) {
        let lounge = Contrast.ratio(board.brandLight, board.reason)
        #expect(
            lounge >= Contrast.bodyText,
            "\(board.id): \u{201C}LOUNGE\u{201D} only reaches \(lounge) — then it is not an exception but a violation"
        )

        // **And the mix-up itself is recorded.** Whoever took `rot` instead of `rotHell` for the
        // name would get exactly the 3.56 from the finding back.
        #expect(Contrast.ratio(board.tag, board.reason) < lounge)
    }
}
