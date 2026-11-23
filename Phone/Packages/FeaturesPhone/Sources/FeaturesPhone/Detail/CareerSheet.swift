import Core
import DesignSystemPhone
import Flows
import SwiftUI

/// What else this person has done.
///
/// **The loading state has a fixed height**, and that is not a matter of looks: without it
/// the list jumps by half the sheet height on arrival, and whoever is tapping at that moment
/// taps on something other than they intended.
///
/// **A Films ↔ Series segment with numbers on it.** A person has 40 films and 8
/// series, and the number answers the question of whether switching is worthwhile before you
/// do it.
///
/// **Titles from the own catalog lead on, foreign ones do not.** Two thirds of the rows
/// are foreign titles — without the distinction the list would be a catalog in which almost nothing
/// is playable, and you would press into nothing in turn. Until 2026-09-08, however, **no** row
/// led on, not even the own ones: the reasoning applied to the foreign ones, and for
/// the own ones nothing was built at all (see ``FilmographyRow``).
///
/// **And every row carries its poster.** `Core.FilmographyEntry.posterURL` has always been
/// there and was thrown away — the same mistake as with `bild_breit` (2026-09-07) and
/// `MediaItem.runtime` (2026-09-08): the information was available, just not read.
struct CareerSheet: View {

    let person: PersonDetail
    let filmography: Filmography?
    let isLoading: Bool
    /// `nil` means: no account configured.
    let credential: Bool

    /// What a press on a row does — **both in one path.**
    ///
    /// If the title is in the own catalog, its detail page opens; if it is not
    /// in it, it explains itself with what the film database knows about it. Which of the
    /// two cases applies is decided by the call site at `libraryItemID` — the row
    /// does not ask the question again.
    var press: ((FilmographyEntry) -> Void)?

    @State private var allSeries = false

    /// The height that the loading state keeps free.
    static let loadingHeight: CGFloat = 220

    var body: some View {
        SheetFrame(wording: person.name) {
            if isLoading {
                VStack(spacing: MetricsBoard.phone.gutter) {
                    ProgressView().tint(ColorRole.textQuiet.color)
                    Text(appKey: PlaybackPhase.loadingStart.form.message ?? "")
                        .font(TypeLevel.label.font)
                        .foregroundStyle(ColorRole.textQuiet.color)
                }
                .frame(maxWidth: .infinity)
                .frame(height: Self.loadingHeight)
            } else if !credential {
                Footnote(message: "detail.noFilmographyKey")
            } else if let filmography, !filmography.isEmpty {
                SegmentPicker(
                    links: AppLanguageSetting.text("filmography.movies \(filmography.movies.count)"),
                    right: AppLanguageSetting.text("filmography.series \(filmography.series.count)"),
                    isRightSelected: $allSeries)

                let entries = allSeries ? filmography.series : filmography.movies
                if entries.isEmpty {
                    Footnote(message: "filmography.emptySide")
                }
                ForEach(entries) { entry in
                    FilmographyRow(entry: entry, press: { press?(entry) })
                    Separator(isIndented: true)
                }
            } else {
                Footnote(message: "filmography.notFound")
            }
        }
    }
}
