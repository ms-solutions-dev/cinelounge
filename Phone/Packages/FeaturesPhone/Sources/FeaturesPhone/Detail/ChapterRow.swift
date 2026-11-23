import Core
import DesignSystemPhone
import SwiftUI

/// The chapters as a springboard: selecting starts **from there**.
///
/// **Before playing and not only in the player.** Whoever knows where they want to go should not
/// have to start first and then scrub — on a phone, scrubbing means dragging a twelve-point-wide
/// handle across 350 points.
///
/// **The time is always shown, the name only when it is one.** "Chapter 3" is the
/// number in another language; such names are already discarded when building, see
/// ``JellyfinDetailSource/chapters(zu:source:)``. Without a name the card counts itself.
///
/// **Still frames are all or none** — finding of 2026-09-05 on *Bringrarn Piosiaspeit Slausnonspel*:
/// Of sixteen chapters **one** carried an image. Fifteen empty boxes stood there, and
/// that looked like a load error, although there was nothing to load. Jellyfin pulls
/// chapter images in a maintenance task that does not run at all on many servers.
///
/// Without images the row becomes **one line narrower**, not a row of empty boxes:
/// mark and time in a capsule. The same rule as for the episode descriptions — in
/// a row, equal shape is the message that the entries are alike.
struct ChapterRow: View {

    let chapters: [ChapterDetail]
    let jump: (TimeInterval) -> Void

    /// Whether **every** mark has an image — from the server or from the grid.
    private var hasImages: Bool { chapters.allSatisfy(\.hasImage) }

    var body: some View {
        if !chapters.isEmpty {
            ShelfRow(
                title: AppLanguageSetting.text("detail.chapters"),
                tally: chapters.count.formatted(.number)
            ) {
                ForEach(chapters) { tag in
                    Button {
                        jump(tag.start)
                    } label: {
                        if hasImages {
                            withImage(tag)
                        } else {
                            asCapsule(tag)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func withImage(_ tag: ChapterDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // **The own still frame takes precedence.** It shows exactly the start of the chapter;
            // the grid delivers the nearest one from a ten-second interval.
            Group {
                if let own = tag.image {
                    RemoteImage(source: own, longestEdge: MetricsBoard.phone.episode.width)
                } else if let slice = tag.lookahead {
                    AtlasImage(
                        sheet: slice.sheet, columns: slice.columns,
                        rows: slice.rows, column: slice.column,
                        row: slice.row, width: MetricsBoard.phone.episode.width)
                }
            }
            .frame(width: MetricsBoard.phone.episode.width, height: MetricsBoard.phone.episode.height)
            .clipShape(RoundedRectangle(cornerRadius: MetricsBoard.phone.imageRadius))
            label(tag)
        }
        .frame(width: MetricsBoard.phone.episode.width, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
    }

    /// **Without an image a capsule, no empty box.** It is as tall as a target and
    /// carries the same: mark and time.
    private func asCapsule(_ tag: ChapterDetail) -> some View {
        HStack(spacing: 8) {
            Image(systemName: Glyph.chapters.name)
                .iconSize(12)
                .foregroundStyle(ColorRole.textQuiet.color)
            label(tag)
        }
        .padding(.horizontal, Metrics.pillInset)
        .frame(minHeight: Metrics.target)
        .background(ColorRole.surface.color, in: Capsule())
        .overlay { Capsule().strokeBorder(ColorRole.outline.color, lineWidth: 0.5) }
        .contentShape(Capsule())
    }

    private func label(_ tag: ChapterDetail) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Group {
                if let name = tag.name {
                    Text(verbatim: name)
                } else {
                    Text(app: "detail.chapterNumber \(tag.id + 1)")
                }
            }
            .font(TypeLevel.label.font)
            .foregroundStyle(ColorRole.text.color)
            .lineLimit(1)

            Text(verbatim: tag.timeText)
                .font(TypeLevel.lowercased.font)
                .monospacedDigit()
                .foregroundStyle(ColorRole.textQuiet.color)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
