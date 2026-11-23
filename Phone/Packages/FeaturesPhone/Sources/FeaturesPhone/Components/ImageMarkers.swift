import DesignSystemPhone
import SwiftUI

/// The badges on the image — `1080p`, `DE·JA`, FSK, "5 days left".
///
/// They sit **on** the image and therefore cost no tile height. Eleven points is the smallest
/// size in the type table; nothing goes below it.
///
/// On material instead of a semi-transparent color: the background is a poster and thus
/// unknown. At the original opacity, the matte lettering over the brightest poster color of
/// the design achieved only 4.26 : 1 — the only remedy is less transparency.
struct ImageMarkers: View {

    let marks: [TileContent.Brand]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(marks) { tag in
                // **A band three points wide in front of the word** (2026-09-07). It ties the badge to the app's
                // mark without costing a word — and it sits **next to** the text and not behind it, because
                // a striped background lowers the contrast to the worse of its two stripes. The rule for
                // this is at ``DesignSystemPhone/StripeBand``.
                HStack(spacing: 4) {
                    StripeBand()
                        .frame(width: 3, height: 11)
                        .clipShape(Capsule())
                    Text(verbatim: tag.text)
                        .font(TypeLevel.lowercased.font)
                        .foregroundStyle(color(tag.kind))
                }
                .padding(.leading, 4)
                .padding(.trailing, 5)
                .padding(.vertical, 3)
                .background(Material.tag, in: RoundedRectangle(cornerRadius: 5))
                .edge()
            }
        }
    }

    private func color(_ kind: TileContent.Brand.Kind) -> Color {
        switch kind {
        case .plain: ColorRole.text.color
        case .gold: ColorRole.progress.color
        case .quiet: ColorRole.textMatt.color
        }
    }
}
