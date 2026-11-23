import Core
import Foundation
import Styling
import Testing

@testable import DesignSystem

/// **The six profile colors, recomputed** (AP41, row 5).
///
/// They are not decoration: at three meters the colored circle is the first thing by which one
/// recognizes whose row this is. A color that disappears on the background or swallows
/// the initial turns the feature into a blob.
@Suite("The profile colors")
struct ProfileColorTests {

    private static let marks = ["bernstein", "tuerkis", "koralle", "flieder", "moos", "schiefer"]

    /// The surfaces on which a profile circle ever lies: the background and the row surface
    /// of every color theme.
    private static let surfaces: [(String, UInt32)] = [
        ("Background", 0x00_00_00),
        ("Cinema", ColorBoard.patterns("cinema", forItem: .tv).surface),
        ("Midnight", ColorBoard.patterns("midnight", forItem: .tv).surface),
        ("Contrast", ColorBoard.patterns("contrast", forItem: .tv).surface),
    ]

    /// **The formula from `Styling`** (AP58) — until 2026-09-26 there was a third
    /// copy here, with a different linearization threshold (0.04045 instead of 0.03928).
    static func contrast(_ single: UInt32, _ other: UInt32) -> Double {
        Contrast.ratio(single, other)
    }

    @Test("There are exactly six, and each has a value")
    func sixBrands() {
        for tag in Self.marks {
            #expect(ProfileColor.brandValue(tag) != nil, "\(tag) has no value")
        }
        #expect(ProfileColor.brandValue("doesnotexist") == nil)
    }

    /// **The initial stands dark in the circle** — as in ``AccountRow``. It is
    /// text and needs 4.5 : 1 against the circle color.
    @Test("The initial is readable in every circle")
    func letterStaysReadable() throws {
        for tag in Self.marks {
            let value = try #require(ProfileColor.brandValue(tag))
            let ratio = Self.contrast(value, 0x00_00_00)
            #expect(ratio >= 4.5, "\(tag): only \(ratio) : 1 against the background")
        }
    }

    /// **And the circle itself must be visible on every surface.** A shape needs 3 : 1;
    /// it is computed against all three color themes, not only the default one —
    /// the same error that was made twice in ``BrandTests`` with `textFaint`.
    @Test("Every circle stands out from every surface")
    func circleStandsOut() throws {
        for tag in Self.marks {
            let value = try #require(ProfileColor.brandValue(tag))
            for (name, surface) in Self.surfaces {
                let ratio = Self.contrast(value, surface)
                #expect(
                    ratio >= 3,
                    "\(tag) on \(name): only \(ratio) : 1")
            }
        }
    }

    /// **And they must be distinguishable from one another.** Two marks with almost
    /// the same luminance are the same mark under deuteranopia — exactly the finding from
    /// E47 (red against olive, 1.02 : 1), which led there to the child-account
    /// mark carrying a **symbol** and not only a color.
    ///
    /// **That is why the color is never alone here.** The circle holds the
    /// initial, next to it the name; this test ensures that the color
    /// still contributes something instead of silently collapsing.
    @Test("No two brand colors collapse in brightness")
    func brandsDoNotCollapse() throws {
        var seen: [(String, Double)] = []
        for tag in Self.marks {
            let value = try #require(ProfileColor.brandValue(tag))
            let brightness = Self.contrast(value, 0x00_00_00)
            for (other, otherBrightness) in seen {
                let difference = max(brightness, otherBrightness) / min(brightness, otherBrightness)
                #expect(
                    difference >= 1.1,
                    "\(tag) and \(other) are together at \(difference) : 1")
            }
            seen.append((tag, brightness))
        }
    }

    /// **An unknown name does not yield an invisible circle.** It yields the
    /// brand tone — a drawing bug would look like a loading error.
    @Test("An unknown name falls back to the brand tone")
    func unknownName() {
        #expect(ProfileColor.tag("doesnotexist") == ColorRole.brandLight.color)
    }
}
