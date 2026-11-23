import Foundation
import Testing

@testable import Grundstock

/// Color schemes — and above all: **whether they can be read.**
///
/// These checks are the reason why ``Theme`` lives in `Core` and carries its colors as
/// numbers instead of as `Color`. A scheme can then be recomputed without building a
/// UI. Exactly this was missing once: when the background changed from brown to
/// black, the palest text slipped to 4.1 — and nobody noticed,
/// because too little contrast on screen looks like an intention.
@Suite("Color themes")
struct ThemeTests {

    @Test("Every text color is readable on every surface", arguments: Theme.all)
    func textIsReadable(_ theme: Theme) {
        // 4.5 is the usual limit for ordinary text. It applies here to **all
        // three** text levels, including the palest: what is too pale to read is
        // no longer a gradation but a surface with hints on it.
        //
        // **And on all three surfaces, not just on the background.** This very gap
        // existed: the correction of textFaint was computed against the background
        // (5.2:1 ✓) — on the raised surface, the capsule backgrounds, the
        // same color fell to 4.1:1, and the check did not see it because it only knew the
        // one pairing. Text sits on all three surfaces in this app;
        // the rule must therefore hold for every pairing.
        for (stepName, color) in [
            ("text", theme.text),
            ("textDim", theme.textDim),
            ("textFaint", theme.textFaint),
        ] {
            for (surfaceName, surface) in [
                ("ground", theme.ground),
                ("surface", theme.surface),
                ("surfaceRaised", theme.surfaceRaised),
            ] {
                let ratio = Theme.contrastRatio(color, surface)
                #expect(
                    ratio >= 4.5,
                    """
                    \(theme.id): \(stepName) on \(surfaceName) \
                    only reaches \(String(format: "%.1f", ratio)):1
                    """
                )
            }
        }
    }

    /// **The loud button: text on the brand color** (2026-09-26). "Midnight" stood here at
    /// 4.25:1, since the blue brand color applies on both devices (decision 24). The brand color
    /// is also the TV's focus glow and must hold 3:1 on the background.
    @Test("Text holds on the brand color, the brand color on the ground", arguments: Theme.all)
    func textHoldsOnBrand(_ theme: Theme) {
        let font = Theme.contrastRatio(theme.text, theme.brand)
        #expect(font >= 4.5, "\(theme.id): text on brand color only \(font)")
        #expect(Theme.contrastRatio(theme.brand, theme.ground) >= 3)
    }

    @Test("The theme's text also holds on the accent ground", arguments: Theme.all)
    func textHoldsOnAccentBase(_ theme: Theme) {
        // The base level of the accent color carries exactly the surfaces that show state:
        // the active filter button, the running season, the focused
        // offer — and on them sits the scheme's text. With a
        // target brightness of 0.22, the cinema's cream reached only 3.3:1 there;
        // it was noticed only when recomputing, because too little contrast on the
        // screen looks like an intention.
        //
        // The normalization makes brightness independent of hue — one hue would
        // therefore suffice. It is still checked all the way around and across saturation,
        // so that the guarantee hangs on the result and not on the normalization.
        let text = Theme.relativeLuminance(theme.text)

        for hue in stride(from: 0.0, to: 360, by: 30) {
            for saturation in [AccentPalette.minimumSaturation, theme.accent.saturation, 0.9] {
                let c = AccentPalette(hue: hue, saturation: saturation).components(.base)
                let accent = AccentPalette.relativeLuminance(c.red, c.green, c.blue)
                let ratio = (max(text, accent) + 0.05) / (min(text, accent) + 0.05)

                #expect(
                    ratio >= 4.5,
                    """
                    \(theme.id): text on accent (hue \(Int(hue)), \
                    saturation \(saturation)) reaches only \
                    \(String(format: "%.1f", ratio)):1
                    """
                )
            }
        }
    }

    @Test("The main text stands out clearly, not just barely", arguments: Theme.all)
    func mainTextHasHeadroom(_ theme: Theme) {
        // Body text on a TV is three meters away and runs through image
        // compression. What barely suffices on a computer screen does not suffice there.
        #expect(Theme.contrastRatio(theme.text, theme.ground) >= 10)
    }

    @Test("Dark text on a light surface holds as well", arguments: Theme.all)
    func inkOnBrightHolds(_ theme: Theme) {
        // ``Theme/inkOnBright`` sits on the light surface of a focused button,
        // and that carries the color of ``Theme/text``. This is the only pairing in the
        // app where the text is the darker of the two — and therefore the one most likely to be
        // forgotten when recoloring a scheme.
        #expect(Theme.contrastRatio(theme.inkOnBright, theme.text) >= 10)
    }

    @Test("The text steps stay distinguishable", arguments: Theme.all)
    func stepsAreDistinct(_ theme: Theme) {
        // Three levels that look the same are one level with two superfluous
        // names — and the structure they are meant to carry is lost.
        let text = Theme.relativeLuminance(theme.text)
        let dim = Theme.relativeLuminance(theme.textDim)
        let faint = Theme.relativeLuminance(theme.textFaint)

        #expect(text > dim)
        #expect(dim > faint)
    }

    @Test("The ground is really dark in every theme", arguments: Theme.all)
    func groundStaysDark(_ theme: Theme) {
        // A scheme may change the colors, not the nature of the app. A light background
        // would no longer be a color scheme but a second design — and every surface
        // computed for a dark background would be wrong.
        #expect(Theme.relativeLuminance(theme.ground) < 0.05)
    }

    @Test("Surfaces lie above the ground and below the text", arguments: Theme.all)
    func surfacesSitBetween(_ theme: Theme) {
        let ground = Theme.relativeLuminance(theme.ground)
        let surface = Theme.relativeLuminance(theme.surface)
        let raised = Theme.relativeLuminance(theme.surfaceRaised)

        #expect(surface > ground, "\(theme.id): the surface does not stand out from the ground")
        #expect(raised > surface, "\(theme.id): the raised surface does not stand out")
        #expect(raised < Theme.relativeLuminance(theme.textFaint))
    }

    /// **Decision 24 (2026-09-26): "Contrast" is neutral gray** — on both devices,
    /// because the identifier is handed off between them. Every surface and every text has
    /// three equal components; a warm tint would be the previous version again.
    @Test("Contrast is neutral gray")
    func contrastIsGray() {
        let t = Theme.contrast
        for rgb in [t.ground, t.surface, t.surfaceRaised, t.line, t.lineSoft, t.text, t.textDim, t.textFaint]
        {
            let r = (rgb >> 16) & 0xFF, g = (rgb >> 8) & 0xFF, b = rgb & 0xFF
            #expect(r == g && g == b, "\(String(rgb, radix: 16)) is not gray")
        }
    }

    /// **Decision 24: the quiet text in "Cinema" is the phone's.**
    @Test("Cinema carries the phone's quiet text")
    func cinemaQuietText() {
        #expect(Theme.cinema.textFaint == 0x9C8A7C)
    }

    // MARK: - Choosing and saving

    @Test("Identifiers are unique")
    func idsAreUnique() {
        #expect(Set(Theme.all.map(\.id)).count == Theme.all.count)
    }

    @Test("An unknown name falls back to Cinema")
    func unknownFallsBack() {
        // Not just the first one that comes along: what comes from storage may stem from an older
        // version in which there was a scheme that no longer exists today. The
        // app must then look as shipped and not random.
        #expect(Theme.named(nil) == .cinema)
        #expect(Theme.named("doesnotexist") == .cinema)
        #expect(Theme.named("midnight") == .midnight)
    }

    @Test("The choice survives a restart")
    func choiceIsPersisted() {
        let store = InMemoryStore()
        #expect(Theme.load(from: store) == .cinema)

        Theme.midnight.save(to: store)
        #expect(Theme.load(from: store) == .midnight)
    }
}
