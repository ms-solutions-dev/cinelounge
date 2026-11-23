import DesignSystemPhone
import Downloads
import SwiftUI

/// The season picker above the episode list — **"Season 1 ⌄", not a chip row.**
///
/// **The finding of 2026-09-05 on *The Flaihuski Freipri Taspreis*** with twelve seasons: the row scrolls,
/// and the chosen season disappears from view. You no longer know what
/// you are looking at — and have to scroll back to find out.
///
/// **No switching at a threshold** ("up to four a row, above that a sheet"). That
/// would be the same trap as in the library: a form that flips is not
/// predictable, and the same grip would do two different things for two series.
///
/// **Instead the same grammar as for the catalog:** the title is the trigger, the
/// choice comes from below. One pattern for both instead of two for one — and the choice sits
/// below the thumb line instead of at the title, which is at y ≈ 400.
///
/// **It disappears with a single season.** A switch with one side is not a
/// switch; then only the heading is shown.
struct SeasonBlock: View {

    let seasons: [Season]
    let pending: Season?
    let select: () -> Void

    /// The button for the **whole season** — `nil` where nothing can be downloaded.
    ///
    /// **It sits at the head and not additionally on every episode.** Both at once would give
    /// nine buttons for the same thing; the scope comes from the trigger, and the trigger is
    /// the season here.
    var downloadState: DownloadState?
    var onDownloadsTap: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Metrics.targetSpacing) {
                if seasons.count > 1, let pending {
                    TitleChoice(title: pending.label, action: select)
                } else if let pending {
                    Text(verbatim: pending.label)
                        .font(TypeLevel.section.font)
                        .foregroundStyle(ColorRole.text.color)
                        .padding(.horizontal, MetricsBoard.phone.margin)
                }

                Spacer(minLength: 0)

                if let downloadState {
                    DownloadButton(state: downloadState, lowercased: true, action: onDownloadsTap)
                        .padding(.trailing, MetricsBoard.phone.margin - 10)
                }
            }

            // **The season's story arc** (user request 2026-08-16: each season
            // represents an arc, so that you can read up on what it is about). It
            // changes with the choice and therefore sits here and not up at the synopsis
            // of the series: those are two different texts about two different things.
            if let description = pending?.description {
                ExpandableText(text: description, rows: 3)
                    .padding(.horizontal, MetricsBoard.phone.margin)
            }
        }
    }
}
