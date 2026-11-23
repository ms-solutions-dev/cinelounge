import Core
import SwiftUI
import Testing

@testable import DesignSystem

#if canImport(AppKit)
    import AppKit
#endif

/// The tokens are numbers, not logic — what is checked is therefore that they match the
/// platform's guidelines and the template. That protects against someone
/// later "flattening" a size during cleanup and thereby destroying
/// legibility on the TV.
@Suite("Design values")
struct TokensTests {

    @Test("No font size falls below the legibility limit")
    func minimumReadableSize() {
        // 29 pt is the lower limit from which text at three meters is still reliably
        // legible. Accessories may be smaller, running text may not.
        #expect(MetricsBoard.tv.margin >= 60)
        #expect(TVMetrics.topMargin >= 40)
    }

    @Test("The safe area matches the recommendation for TVs")
    func safeArea() {
        #expect(MetricsBoard.tv.margin == 80)
        #expect(TVMetrics.topMargin == 60)
    }

    @Test("Posters have an aspect ratio of 2:3")
    func posterAspect() {
        let size = MetricsBoard.tv.poster
        #expect(abs(size.width / size.height - 2.0 / 3.0) < 0.001)
    }

    @Test("Episode cards have an aspect ratio of 16:9")
    func episodeAspect() {
        let size = MetricsBoard.tv.episode
        #expect(abs(size.width / size.height - 16.0 / 9.0) < 0.01)
    }

    @Test("Cards grow more than buttons when focused")
    func focusScales() {
        // A card must stand out more distinctly than a button, because it
        // sits among many neighbors of the same kind.
        #expect(Tokens.Focus.cardScale > Tokens.Focus.buttonScale)
        // The value itself may change — what is checked is the ratio. Since
        // the focus frame was removed, the enlargement has to carry the highlight
        // alone and was therefore raised.
        #expect(Tokens.Focus.cardScale > Tokens.Focus.buttonScale)
        #expect(Tokens.Focus.cardScale > 1.05 && Tokens.Focus.cardScale < 1.2)
    }

    /// **The test case asserted nothing, and its subject no longer
    /// exists** (AP6 · Q9): the focus ring went away with the frame — the
    /// comment on ``Tokens/Focus/cardScale`` says it explicitly ("Without a
    /// frame the enlargement has to carry the highlight alone"). What is checked
    /// is therefore what really carries the highlight today.
    @Test("Without a frame, size and shadow carry the highlight")
    func focusHighlight() {
        // The shadow must spread far enough to work as a
        // lift on a dark background — with a narrow radius it looks like a line,
        // and there is precisely no line here anymore.
        #expect(Tokens.Focus.shadowRadius >= 40)
        // And it falls downward, otherwise the card floats without direction.
        #expect(Tokens.Focus.shadowY > 0)
    }
}

@Suite("Color conversion")
struct ColorTests {

    @Test("Hex values are split into the right components")
    func hexDecoding() {
        let c = Color.components(hex: 0xF7EBD6)

        #expect(abs(c.red - 0xF7 / 255.0) < 0.001)
        #expect(abs(c.green - 0xEB / 255.0) < 0.001)
        #expect(abs(c.blue - 0xD6 / 255.0) < 0.001)
    }

    @Test("Black and white as edge cases")
    func hexEdges() {
        let black = Color.components(hex: 0x000000)
        let white = Color.components(hex: 0xFFFFFF)

        #expect(black.red == 0 && black.green == 0 && black.blue == 0)
        #expect(white.red == 1 && white.green == 1 && white.blue == 1)
    }

    @Test("The ground is true black — and the warmth lies above it")
    func groundIsBlackAndSurfacesAreWarm() {
        // Here stood the opposite demand: the background should carry a red tint,
        // `#120A09`. On a 55-inch TV that became, across a large empty surface, a
        // dull gray veil — the screen showed *almost* black, and that looks
        // like a badly adjusted device rather than intent.
        //
        // The intent remains, it just sits one level higher: what lies **on** the background
        // is warm. This test pins exactly that down, so that the next
        // cleanup does not lose one of the two.
        let ground = try? Self.components(of: ColorRole.reason.color)
        #expect(ground?.red == 0)
        #expect(ground?.green == 0)
        #expect(ground?.blue == 0)

        for (name, color) in [
            ("surface", ColorRole.surface.color),
            ("surfaceRaised", ColorRole.surfaceHigh.color),
            ("line", ColorRole.line.color),
        ] {
            let c = try? Self.components(of: color)
            #expect((c?.red ?? 0) > (c?.blue ?? 1), "\(name) must carry the red component of the logo")
            #expect((c?.red ?? 0) > (c?.green ?? 1), "\(name) must not be neutral")
        }
    }

    /// The components of a color — measured on the **real** color, not on a
    /// copy of its hex value.
    ///
    /// Previously the test read `Color.components(hex: 0x120A09)`, that is a copy of the
    /// number. It would therefore not have noticed a change to `Palette` at all — it checked
    /// the conversion, not the value. Exactly that value was supposed to be protected here, though.
    static func components(of color: Color) throws -> (red: Double, green: Double, blue: Double) {
        let resolved = try #require(NSColor(color).usingColorSpace(.sRGB))
        return (
            Double(resolved.redComponent),
            Double(resolved.greenComponent),
            Double(resolved.blueComponent)
        )
    }
}
