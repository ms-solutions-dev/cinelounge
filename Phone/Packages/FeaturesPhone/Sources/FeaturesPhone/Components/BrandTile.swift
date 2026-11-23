import DesignSystemPhone
import SwiftUI

/// A channel logo on a plate — **fitted, not filled.**
///
/// **Why this third tile exists.** ``PosterTile`` and ``EpisodeTile`` fill their surface,
/// and that is right for a poster and an episode image: both are images, and every crop of
/// them remains an image. A channel logo is a drawing with a margin — whoever fills it cuts
/// off half of it, and "ARD" becomes a red bar. Seen on screen on 2026-09-06, twice in a row:
/// first portrait, then wide, both times cropped.
///
/// **The plate is dark, the logo light on it.** Channel logos almost all come on a white
/// background; without a plate a white rectangle would stand in a dark row and be the loudest
/// thing on the screen.
struct BrandTile: View {

    let content: TileContent
    var width: CGFloat = MetricsBoard.phone.episode.width

    private var height: CGFloat {
        (width * MetricsBoard.phone.episode.height / MetricsBoard.phone.episode.width).rounded()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                ColorRole.surface.color
                RemoteImage(
                    source: content.image, longestEdge: width, withColor: false,
                    isFilling: false, placeholder: Glyph.Tab.live.outlined
                )
                .padding(10)

                if let portion = content.progress {
                    ProgressBar(portion: portion, height: 2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: MetricsBoard.phone.imageRadius))

            Text(verbatim: content.title)
                .font(TypeLevel.label.font)
                .foregroundStyle(ColorRole.text.color)
                .lineLimit(1)
                .padding(.top, 7)

            if let beside = content.beside {
                Text(verbatim: beside)
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
                    .lineLimit(1)
                    .padding(.top, 1)
            }
        }
        .frame(width: width, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        // **The same hit area as for ``PosterTile``** (2026-09-07) — third branch of the same `switch`
        // in ``StartView``, the same gap.
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
