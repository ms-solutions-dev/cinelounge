import SwiftUI
import Testing

@testable import Core
@testable import DesignSystem

/// **That the two apps are seen as one family** — AP27, 2026-09-11.
///
/// The answer to the question of a recognition feature was unspectacular: four
/// small places. What is checked here are the two that can be expressed as a number
/// — the pattern and the colors. The sign itself and the wordmark one sees.
struct BrandTests {

    /// **The phone's numbers do NOT come along.**
    ///
    /// There one point stands for 1.89 arcminutes (arm's length), here for **0.73** (three
    /// meters). The phone's four-point limit would here be 2.9′ — invisible. Whoever
    /// transfers the numbers transfers the viewing conditions too, and those do not exist here.
    ///
    /// Computed: 6 pt on the phone correspond to 6 × 1.89 / 0.73 ≈ **15.5** pt; the rule
    /// in the roadmap names 12–14 for the stripe width and 10–12 for the band height.
    @Test("The stripe metrics are those of this distance and not those of the phone")
    func dimensionsAreForThreeMeters() {
        #expect(StripeBand.stripeWidth >= 12)
        #expect(StripeBand.stripeWidth <= 16)
        #expect(StripeBand.bandHeight >= 10)
        #expect(StripeBand.bandHeight <= 12)

        // And explicitly not the numbers from over there.
        #expect(StripeBand.stripeWidth != 6, "that is the stripe width of the phone")
        #expect(StripeBand.bandHeight != 4, "that is the band height of the phone")
    }

    /// **The three semantic colors agree between "Cinema" and "Midnight".**
    ///
    /// **The finding was counted: 0 of 14 shared values.** The most conspicuous was
    /// `progress` — gold in one, **turquoise** in the other —, and the progress bar
    /// is often the only colored element in the picture at three meters.
    @Test("Progress, live and success are the same in Cinema and Midnight")
    func semanticColorsMatch() {
        #expect(Theme.cinema.progress == Theme.midnight.progress)
        #expect(Theme.cinema.live == Theme.midnight.live)
        #expect(Theme.cinema.success == Theme.midnight.success)
    }

    /// **The brand colors stay different — and that is not carelessness.**
    ///
    /// `brand` here is at the same time the **ring color** of the focus. Aligning it would mean
    /// a red focus ring in the cool theme, which ``AccentPalette`` explicitly warns against. From
    /// 0 of 14 it therefore becomes 3 of 14 and not 6 of 14.
    @Test("The ring color stays specific to each pattern")
    func ringColorStaysDistinct() {
        #expect(Theme.cinema.brand != Theme.midnight.brand)
        #expect(Theme.cinema.accent.hue != Theme.midnight.accent.hue)
    }

    /// **"Contrast" gets the phone's contrast values and not those of "Cinema".**
    ///
    /// The theme is lighter **because** it is meant to be lighter. The color is aligned,
    /// not the purpose — whoever put "Cinema" in here would take away the theme's reason.
    @Test("The Contrast pattern stays lighter than Cinema")
    func contrastStaysBrighter() {
        func brightness(_ value: UInt32) -> Double {
            let r = Double((value >> 16) & 0xFF)
            let g = Double((value >> 8) & 0xFF)
            let b = Double(value & 0xFF)
            return 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        #expect(brightness(Theme.contrast.progress) > brightness(Theme.cinema.progress))
        #expect(brightness(Theme.contrast.live) > brightness(Theme.cinema.live))
        #expect(brightness(Theme.contrast.success) > brightness(Theme.cinema.success))
    }
}
