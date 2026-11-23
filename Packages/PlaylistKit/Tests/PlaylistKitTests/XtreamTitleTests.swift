import Testing

@testable import PlaylistKit

/// Square brackets at the end — the notation this provider uses.
@Suite("Xtream title · square brackets")
struct XtreamTitleBracketTests {

    /// **The finding of 2026-09-05:** the library showed "Der Fürstenhain [DE] [1983]". The
    /// markers ate eleven characters of a column that truncates anyway, and the year was
    /// missing where there is room for it.
    @Test("Year and language are cut off")
    func seasoned() {
        let title = XtreamTitle.parse("Der Fürstenhain [DE] [1983]")
        #expect(title.title == "Der Fürstenhain")
        #expect(title.year == 1983)
        #expect(title.originCountry == "DE")
    }

    /// **Repeated, because they occur stacked** — a single pass would leave "[DE]" in
    /// place.
    @Test("Also individually and in both orders")
    func single() {
        #expect(XtreamTitle.parse("After Tidefall [DE] [2022]").title == "After Tidefall")
        #expect(XtreamTitle.parse("Ostrovgrad [1991]").title == "Ostrovgrad")
        #expect(XtreamTitle.parse("Ostrovgrad [1991]").year == 1991)
        #expect(XtreamTitle.parse("Das Boot [DE]").title == "Das Boot")
    }

    /// **Everything else stays.** `[Director's Cut]` and `[4K]` are information; a guessed
    /// rule would remove them.
    @Test("Foreign brackets stay untouched")
    func foreignOnesStay() {
        #expect(
            XtreamTitle.parse("Neon Courier [Director's Cut]").title
                == "Neon Courier [Director's Cut]")
        #expect(XtreamTitle.parse("Sandmere [4K]").title == "Sandmere [4K]")
    }

    /// **A title that consists only of markers stays** — a nameless entry cannot be
    /// found.
    @Test("A name always remains")
    func doNotCutEmpty() {
        #expect(!XtreamTitle.parse("[DE] [1983]").title.isEmpty)
    }
}
