import Foundation
import Testing

@testable import Grundstock

/// The color derivation has proven deceptive twice — once
/// an orange series turned blue, once a green shone twice as bright as a red
/// with the same numeric value. That is why it is pinned down here.
@Suite("Lead color from pixels")
struct AccentDerivationTests {

    /// Builds pixels from repeated colors. Four bytes per pixel, as a
    /// bitmap delivers them.
    private func pixels(_ colors: [(UInt8, UInt8, UInt8)], each: Int = 1) -> [UInt8] {
        var out: [UInt8] = []
        for color in colors {
            for _ in 0..<each {
                out.append(contentsOf: [color.0, color.1, color.2, 255])
            }
        }
        return out
    }

    @Test("A single-color image gives exactly this hue")
    func singleColor() throws {
        // A strong orange: hue at about 30 degrees.
        let derived = try #require(AccentDerivationTests.derive(self, (230, 120, 30)))

        #expect(abs(derived.hue - 30) < 12, "hue near 30 degrees, was \(derived.hue)")
        #expect(derived.saturation >= 0.6)
    }

    @Test("The majority decides the color, not the order")
    func majorityWins() throws {
        // Ninety blue pixels against ten red ones. Blue has to win — regardless
        // of which color comes first in memory.
        let blueFirst = pixels([(40, 90, 220)], each: 90) + pixels([(220, 50, 40)], each: 10)
        let redFirst = pixels([(220, 50, 40)], each: 10) + pixels([(40, 90, 220)], each: 90)

        let a = try #require(AccentPalette.derive(fromRGBA: blueFirst))
        let b = try #require(AccentPalette.derive(fromRGBA: redFirst))

        #expect(abs(a.hue - b.hue) < 1, "the order must not change anything")
        #expect(a.hue > 200 && a.hue < 260, "blue, was \(a.hue)")
    }

    @Test("A strong color beats a pale majority")
    func chromaBeatsCount() throws {
        // Sixty pale pixels against forty vivid ones. The vivid ones carry the
        // statement — otherwise the washed-out background determines the color in every image
        // and all series look the same.
        let washedOut = pixels([(150, 160, 190)], each: 60)
        let vivid = pixels([(230, 60, 20)], each: 40)

        let derived = try #require(AccentPalette.derive(fromRGBA: washedOut + vivid))

        #expect(derived.hue < 30 || derived.hue > 330, "red, was \(derived.hue)")
    }

    @Test("A grayscale image gives no color")
    func grayscaleYieldsNothing() {
        // It matters that nothing is guessed here: for gray the brand color applies,
        // and it is chosen deliberately instead of derived from noise.
        let grays = pixels([(20, 20, 20), (120, 120, 120), (230, 230, 230)], each: 40)

        #expect(AccentPalette.derive(fromRGBA: grays) == nil)
    }

    @Test("Transparent pixels do not count")
    func transparentIgnored() {
        // Behind a transparent pixel, memory usually holds black.
        // If it were counted, every color would shift toward dark.
        var transparent: [UInt8] = []
        for _ in 0..<200 { transparent.append(contentsOf: [0, 0, 255, 0]) }

        #expect(AccentPalette.derive(fromRGBA: transparent) == nil)
    }

    @Test("Highlights and shadows do not decide the color")
    func extremesCarryLittleWeight() throws {
        // Almost white and almost black pixels carry hardly any color, yet push
        // to the front in every count. Here eighty very light
        // bluish ones stand against twenty medium green ones.
        let highlights = pixels([(225, 235, 250)], each: 80)
        let midtones = pixels([(60, 170, 90)], each: 20)

        let derived = try #require(AccentPalette.derive(fromRGBA: highlights + midtones))

        #expect(derived.hue > 90 && derived.hue < 180, "green, was \(derived.hue)")
    }

    @Test("Saturation stays in the usable band")
    func saturationBounded() throws {
        // Bounded below so that the accent carries; bounded above so that it does not
        // turn garish. Checked on a fully saturated red.
        let derived = try #require(AccentPalette.derive(fromRGBA: pixels([(255, 0, 0)], each: 50)))

        #expect(derived.saturation >= 0.6 && derived.saturation <= 0.9)
    }

    @Test("Too few pixels give no color instead of a random one")
    func tooFewPixels() {
        #expect(AccentPalette.derive(fromRGBA: []) == nil)
        #expect(AccentPalette.derive(fromRGBA: [255, 0, 0]) == nil, "incomplete pixel")
    }

    // MARK: - Umrechnung

    @Test("The conversion to hue, lightness, saturation is right at the corners")
    func hlsConversion() {
        // Pure red lies at 0 degrees, green at 120, blue at 240 — the corners
        // of the color wheel. If they are wrong, everything built on them is wrong.
        #expect(AccentPalette.hls(1, 0, 0).hue == 0)
        #expect(abs(AccentPalette.hls(0, 1, 0).hue - 120) < 0.01)
        #expect(abs(AccentPalette.hls(0, 0, 1).hue - 240) < 0.01)

        // Gray has no hue and no saturation.
        let gray = AccentPalette.hls(0.5, 0.5, 0.5)
        #expect(gray.saturation == 0)
        #expect(abs(gray.lightness - 0.5) < 0.01)
    }

    /// Helper call for the first test — single color, enough pixels.
    private static func derive(
        _ suite: AccentDerivationTests,
        _ color: (UInt8, UInt8, UInt8)
    ) -> AccentPalette? {
        AccentPalette.derive(fromRGBA: suite.pixels([color], each: 50))
    }
}
