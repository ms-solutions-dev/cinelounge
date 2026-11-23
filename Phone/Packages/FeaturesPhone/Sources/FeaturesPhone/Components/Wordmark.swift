import DesignSystemPhone
import SwiftUI

/// The title as a drawn logotype if the server has one — otherwise as text.
///
/// **A logo is different for every title, set system type never.** The logotype
/// belongs to the movie like its poster; showing it is the difference between a
/// header area and a list with a large image above it.
///
/// **The text fallback is no stopgap but the normal case.** The media server has no
/// logo for many titles, and almost never for series. A hero choice that filtered for
/// available logos would have two candidates in a typical library.
///
/// **Limit the height instead of the width.** Logos come in every aspect ratio — a wide
/// word logo and an almost square emblem brought to the same width side by side would
/// give two completely different optical weights. Brought to the same height they
/// look equally large.
struct Wordmark: View {

    /// The height at which the logotype sits in the header area.
    ///
    /// **As a named value and not a number in two places:** The cache keys on URL and
    /// size, and the preloading in ``StartModel`` has to request the same number —
    /// otherwise every image is there twice and none is found.
    static let heightInHeader: CGFloat = 44

    let image: URL?
    let title: String
    var height: CGFloat = heightInHeader

    /// The size class in which the logotype sits — **it alone determines the requested
    /// image width.**
    ///
    /// **Behind ``height`` and not before it**, so that the generated memberwise init keeps
    /// its order; the two callers pass `image` and `title` by name anyway.
    ///
    /// **``heightInHeader`` and ``height`` stay where they are.** A logotype is not taller on
    /// the iPad: 44 points are the row in which it stands above the box content, and that
    /// depends on the type and not on the device. What is requested, on the other hand, is
    /// by **width** (finding of 2026-09-05), and that grows with it — see
    /// ``MetricClass/headerBox(_:)``.
    @Environment(\.horizontalSizeClass) private var width

    var body: some View {
        if let image {
            // **Left-aligned, and within the `RemoteImage` itself.** A `frame` with
            // `alignment` is not enough: The measurer inside is `Color.clear`, which stretches
            // over the whole width — the image lands in its middle, whatever is set
            // outside. On screen the logotype therefore looked as if it had shrunk to
            // a ninth.
            // **`height` and not `maxHeight`.** Seen on screen: In the header image
            // the logotype stood large, on the detail page as a postage stamp — the same
            // building block, the same image. `maxHeight` is an **upper bound and not a
            // default**, and the measurer inside is `Color.clear` with an ideal height of
            // zero. In a `ZStack` the siblings determined the height, in a `VStack` nobody
            // did.
            // **The width, not the height.** A word logo at 44 points of height is up to
            // 300 points wide; capped by height, it was built with 132 pixels
            // and drawn at 900.
            // **And since 2026-09-23 this width is that of the size class.** The
            // logotype runs as far as the box it sits in; on the iPad
            // that is no longer a phone width. Until then the fixed 400 stood here.
            RemoteImage(
                source: image, longestEdge: MetricClass.headerBox(width), isFilling: false,
                alignment: .leading
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height)
            .accessibilityLabel(Text(verbatim: title))
        } else {
            Text(verbatim: title)
                .font(TypeLevel.title.font)
                .minimumScaleFactor(0.7)
                .lineLimit(2)
                .foregroundStyle(ColorRole.text.color)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
