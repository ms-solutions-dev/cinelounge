import Core
import DesignSystemPhone
import SwiftUI

/// A title from a person's filmography — **with poster and, where possible, with a path.**
///
/// **The finding of 2026-09-08, reported on screen:** *images are rendered there along with the
/// content, and content has forward navigation — both missing here.* Both were true, and
/// both had the same cause as twice before in this project: **the information was
/// there and was thrown away.** `Core.FilmographyEntry` has always carried `posterURL` and
/// `libraryItemID`; the sheet read neither and drew a text list.
///
/// **The old reasoning applied to the wrong half.** It said: "A foreign title
/// leads nowhere — and a button that does nothing is worse than none." That
/// holds for **foreign** titles. Two thirds of the rows are foreign, and so nothing was built for
/// the last third — the titles that are in the own catalog. They do lead somewhere,
/// and from now on they do.
///
/// **The poster is on every row, foreign ones too.** It is the information "this is the
/// film" and not a control; an image only on the own titles would turn the list into
/// two lists. Where TMDb has none, the area stays empty instead of showing a
/// placeholder — the same rule as at ``EmptyTile``.
struct FilmographyRow: View {

    let entry: FilmographyEntry
    /// What a tap does.
    ///
    /// **"What you have opens; what you don't have explains itself."** The sentence comes
    /// from the TV, where the same question was already answered once on 2026-08-08 — and
    /// wrongly at first: the first decision there was to let foreign rows not answer
    /// at all. The objection ("a button that does nothing on two thirds of the rows
    /// is worse than a row without a button") was right; the answer was just
    /// the smaller of two.
    ///
    /// **On the phone it was the same smaller answer until 2026-09-08** — here the
    /// reasoning even stood verbatim in the body of an empty closure.
    let press: () -> Void

    /// The poster size in the row.
    ///
    /// **Two thirds of ``Styling/MetricsBoard/poster`` and in the same ratio.** A sheet row is
    /// not a shelf tile; a full poster would take half the sheet height here, and with
    /// fifty rows that would be fifty full-size images through a narrow connection.
    ///
    /// **`nonisolated`, and that is the lesson of the same day** (see
    /// ``TransferText``): a `View` binds its static members to the
    /// main actor. A check that reads them from outside still compiles in the debug build and
    /// only fails in the release build — where strict concurrency applies.
    nonisolated static let poster = CGSize(width: 44, height: 66)

    var body: some View {
        button {
            HStack(spacing: MetricsBoard.phone.gutter) {
                RemoteImage(
                    source: entry.posterURL,
                    longestEdge: CGFloat(
                        ImageSizes.pixels(
                            forItem: Self.poster.height, reference: ImageSizes.reference)),
                    withColor: false
                )
                .frame(width: Self.poster.width, height: Self.poster.height)
                .clipShape(RoundedRectangle(cornerRadius: MetricsBoard.phone.imageRadius))

                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: entry.title)
                        .font(TypeLevel.text.font)
                        .foregroundStyle(ColorRole.text.color)
                        .lineLimit(2)

                    if let role = entry.role, !role.isEmpty {
                        Text(verbatim: role)
                            .font(TypeLevel.label.font)
                            .foregroundStyle(ColorRole.textQuiet.color)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 3) {
                    // **Without a year, a word stands there and not a gap** — the same rule
                    // as on the TV. A gap would look like a missing value;
                    // "Announced" is the information it really is.
                    if let year = entry.year {
                        Text(verbatim: String(year)).monospacedDigit()
                    } else {
                        Text(app: "filmography.announced")
                    }

                    // **The rating was there too and was thrown away.** `nil` means
                    // "too few votes" — a zero would stand as a damning verdict
                    // where simply nobody voted.
                    if let note = entry.rating {
                        Text(verbatim: String(format: "★ %.1f", note))
                    }
                }
                .font(TypeLevel.label.font)
                .foregroundStyle(ColorRole.textQuiet.color)

                // **The checkmark sits only on what you have** — the rule verbatim from the
                // TV: a mark on every row that mostly says "no" would be
                // noise; the rare thing should stand out. It is also the information that
                // this row leads further on, and a symbol and not a color: red against
                // olive is 1.02 : 1 under deuteranopia.
                if entry.isInLibrary {
                    Image(systemName: Glyph.done.pair.filled)
                        .iconSize(18)
                        .foregroundStyle(ColorRole.brandLight.color)
                        .accessibilityLabel(Text(app: "filmography.inLibrary"))
                } else {
                    // A foreign title explains itself — the chevron says that it
                    // goes on, without claiming a catalog.
                    Image(systemName: Glyph.next.name)
                        .iconSize(13, weight: .semibold)
                        .foregroundStyle(ColorRole.textQuiet.color)
                }
            }
            .padding(.horizontal, MetricsBoard.phone.margin)
            .padding(.vertical, Metrics.targetSpacing)
            .frame(minHeight: Metrics.target)
            .contentShape(Rectangle())
        }
    }

    /// **A button only where it does something.** A foreign row stays a row: it is the
    /// information and not the path — and `.disabled` on a button that does nothing anyway
    /// also dims it, as if it were broken.
    @ViewBuilder
    private func button(@ViewBuilder _ content: () -> some View) -> some View {
        Button(action: press) { content() }
            .buttonStyle(.plain)
    }
}
