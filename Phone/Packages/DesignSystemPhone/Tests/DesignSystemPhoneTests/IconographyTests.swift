import Testing

@testable import DesignSystemPhone

/// The phone's tabs, from this side. That every symbol in the register resolves has been
/// tested since the final step of AP58 by `GlyphTests` in `Styling` — for both devices
/// and via ``Styling/Glyph/allNames``, tabs included.
@Suite("Iconography")
struct IconographyTests {

    @Test("Every tab has a pair, and the two differ")
    func tabPairs() {
        #expect(Glyph.Tab.all.count == 5)
        for pair in Glyph.Tab.all {
            #expect(pair.outlined != pair.filled)
            #expect(pair.zu(active: true) == pair.filled)
            #expect(pair.zu(active: false) == pair.outlined)
        }
    }
}
