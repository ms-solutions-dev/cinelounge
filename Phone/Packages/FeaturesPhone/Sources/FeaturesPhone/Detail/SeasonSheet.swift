import Core
import DesignSystemPhone
import SwiftUI

/// The season picker as a sheet — one row per season.
///
/// **On the right it shows how many episodes are still open**, not how many there are. The
/// episode count is in every wiki; "4 left" answers the question for which you open the picker
/// at all. For a fully watched season the spot stays empty — a zero
/// would be a number where there is nothing left to do.
///
/// The same construction as the library's index: the same grip, the same look,
/// the same number on the right.
struct SeasonSheet: View {

    let seasons: [Season]
    let pending: Int?
    let select: (Season) -> Void

    var body: some View {
        SheetFrame(title: "detail.seasons") {
            ForEach(seasons) { season in
                ChoiceRow(
                    name: season.label,
                    number: season.pending > 0
                        ? AppLanguageSetting.text("season.open \(season.pending)") : nil,
                    subRow: nil,
                    chosen: season.id == pending
                ) {
                    select(season)
                }
            }
        }
    }
}
