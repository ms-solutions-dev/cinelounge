import Testing

@testable import Grundstock

/// The color derivation has proven deceptive twice, so the
/// property that matters is verified: all series colors must look **equally
/// strong**. Without normalizing to perceived brightness,
/// a yellow-green shines many times brighter than a red with numerically
/// the same value.
@Suite("Accent colors")
struct AccentPaletteTests {

    /// Three sample hues: a red, a blue and an orange.
    static let crimson = AccentPalette(hue: 349, saturation: 0.6)
    static let indigo = AccentPalette(hue: 229, saturation: 0.9)
    static let amber = AccentPalette(hue: 19, saturation: 0.78)

    @Test(
        "Every hue hits the given perceived lightness",
        arguments: [
            AccentPalette(hue: 349, saturation: 0.6),
            AccentPalette(hue: 229, saturation: 0.9),
            AccentPalette(hue: 19, saturation: 0.78),
            AccentPalette(hue: 70, saturation: 0.7),  // Yellow-green, the difficult case
        ]
    )
    func hitsTargetLuminance(palette: AccentPalette) {
        for level in AccentPalette.Level.allCases {
            let c = palette.components(level)
            let luminance = AccentPalette.relativeLuminance(c.red, c.green, c.blue)

            #expect(
                abs(luminance - level.rawValue) < 0.01,
                "Hue \(palette.hue) misses the target lightness at \(level)"
            )
        }
    }

    @Test("The three series colors look equally strong")
    func equalStrength() {
        let luminances = [Self.crimson, Self.indigo, Self.amber].map { palette -> Double in
            let c = palette.components(.base)
            return AccentPalette.relativeLuminance(c.red, c.green, c.blue)
        }

        let spread = luminances.max()! - luminances.min()!
        #expect(spread < 0.01, "The accents must not differ in effect")
    }

    @Test("Yellow-green does not look lighter than red")
    func greenIsNotBrighter() {
        // This very case went wrong on the first attempt: a yellow-green with
        // the same numeric brightness value shone far brighter.
        let green = AccentPalette(hue: 70, saturation: 0.7).components(.base)
        let red = AccentPalette(hue: 0, saturation: 0.7).components(.base)

        let lg = AccentPalette.relativeLuminance(green.red, green.green, green.blue)
        let lr = AccentPalette.relativeLuminance(red.red, red.green, red.blue)

        #expect(abs(lg - lr) < 0.01)
    }

    @Test("The steps get lighter from dark to light")
    func levelsAscend() {
        let p = Self.amber
        func lum(_ level: AccentPalette.Level) -> Double {
            let c = p.components(level)
            return AccentPalette.relativeLuminance(c.red, c.green, c.blue)
        }

        #expect(lum(.deep) < lum(.base))
        #expect(lum(.base) < lum(.bright))
    }

    @Test("Hex values have the expected format")
    func hexFormat() {
        let hex = Self.amber.hex(.base)

        #expect(hex.hasPrefix("#"))
        #expect(hex.count == 7)
    }

    @Test("Hue is limited to the circle, saturation to zero to one")
    func clamping() {
        #expect(AccentPalette(hue: 380, saturation: 0.5).hue == 20)
        #expect(AccentPalette(hue: 100, saturation: 1.7).saturation == 1)
        #expect(AccentPalette(hue: 100, saturation: -0.4).saturation == 0)
    }

    @Test("The brand color is the red from the logo")
    func brandIsRed() {
        // Red lies at the start of the color wheel; anything above 30 degrees would be orange.
        #expect(AccentPalette.brand.hue < 30 || AccentPalette.brand.hue > 330)
    }
}
