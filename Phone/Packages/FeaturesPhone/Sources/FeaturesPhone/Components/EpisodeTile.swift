import DesignSystemPhone
import Flows
import SwiftUI

/// An episode or background image, 200 × 112 — aspect ratio 16 : 9.
///
/// The series color is **not** computed here: an episode image is a still frame from the show
/// and not a designed surface; its dominant tone is usually the wall color of the set. And it
/// carries no edge that would show it.
struct EpisodeTile: View {

    let content: TileContent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                if content.image == nil {
                    EmptyTile(title: content.title)
                } else {
                    RemoteImage(
                        source: content.image, longestEdge: MetricsBoard.phone.episode.width, withColor: false
                    )
                }

                if content.seen {
                    WatchedCheck().padding(6)
                }

                if let progress = content.progress {
                    ProgressBar(portion: progress)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .frame(width: MetricsBoard.phone.episode.width, height: MetricsBoard.phone.episode.height)
            .clipShape(RoundedRectangle(cornerRadius: MetricsBoard.phone.imageRadius))

            Text(verbatim: content.title)
                .font(TypeLevel.label.font)
                .foregroundStyle(ColorRole.text.color)
                .lineLimit(2)
                .padding(.top, 7)

            if let beside = content.beside {
                Text(verbatim: beside)
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
                    .lineLimit(1)
                    .padding(.top, 1)
            }
        }
        .frame(width: MetricsBoard.phone.episode.width, alignment: .leading)
        // **The same hit area as for ``PosterTile``** (2026-09-07) — and for the same reason: this
        // tile sits in the **same** `Button` in ``StartView``, only in the other branch of the
        // `switch`. A bug that was measured in one place holds for its siblings too; the rationale
        // is stated there at length.
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
