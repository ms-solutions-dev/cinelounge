import DesignSystemPhone
import SwiftUI

/// The app's name in the header row — **with the mark in front.**
///
/// **Why anything stands there at all** (finding of 2026-09-05): the header row carried the
/// profile picture on the right and nothing on the left — an empty row above the box that
/// only cost space. On Home there is no screen title one could put there: it is not called
/// "Home", it is the beginning.
///
/// **The finding of 2026-09-07 — the mark was there and was never shown.** Product feedback on
/// the first version: the header on the CineLounge start screen looked too rigid, and, on a
/// pure font change as a response, that there was hardly any visible difference and nothing
/// one would call a unique identity. Both were true. The name was set in
/// ``Styling/TypeLevel/header`` — that is, in **the same font and weight as every row
/// caption below** —, and a change of type family would have changed little: a sans-serif is
/// no unique selling point.
///
/// **What is one had been fully drawn since E35 and did not appear in the app:** the red
/// armchair with the striped popcorn bag from `design/logo.svg`. It was on the app icon and
/// vanished the moment someone opened the app. No other media client carries a logo mark in
/// its header; they all carry only their name.
///
/// **The name is still set, stacked.** "CINE" above "LOUNGE" is narrow instead of wide — it
/// fills the height of the header row instead of using up its width, and it is exactly the
/// form the symbol version `wordmark` already has. A picture banner for the whole name, by
/// contrast, would have to travel in three resolutions, be redrawn at every color change and
/// would be silent for the screen reader.
///
/// **Two-colored, because the name has two parts.** "Cine" is the origin, "Lounge" the claim;
/// the accent color lies on the second because the eye lingers at the end of the line.
struct BrandMark: View {

    static let firstPart = "CINE"
    static let secondPart = "LOUNGE"

    /// How tall the armchair stands.
    ///
    /// **Twenty-six, and the number belongs to the header row and not to the image.** The row is
    /// 44 points tall; a mark that fills it crowds the three buttons beside it. The same number
    /// appears in `scripts/appsymbol.py` as `MARKENHOEHE` — there it decides in which resolutions
    /// the image is generated, and the two must not drift apart.
    /// **Does not grow with the type size.** A logo mark is not text: at XXXL it alone would fill
    /// the header row, and the buttons beside it would fall out of view. The name beside it does
    /// grow — it is text and stays so.
    static let markHeight: CGFloat = 26

    var body: some View {
        HStack(spacing: MetricsBoard.phone.gutter) {
            Image("BrandMark", bundle: .main)
                .resizable()
                .scaledToFit()
                .frame(height: Self.markHeight)
                // **Silent for the screen reader.** The name stands beside it as text; a second "CineLounge"
                // would be the same information twice.
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: Self.firstPart)
                    .font(TypeLevel.footer.font.weight(.bold))
                    .foregroundStyle(ColorRole.text.color)
                    .tracking(1.4)
                Text(verbatim: Self.secondPart)
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.brandLight.color)
                    .tracking(2.4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: Self.firstPart + Self.secondPart))
    }
}
