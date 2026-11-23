import DesignSystemPhone
import SwiftUI

/// The categories of a provider — the level **below** the index.
///
/// **Why not in the index:** The tested provider carries twenty-four film categories.
/// Lifting them into the index would mean twenty-four rows between "Films" and "In
/// downloads" — the index promises completeness, and these rows would not fulfill the
/// promise better, they would make it unreadable. The TV made exactly this
/// mistake and reverted it on 2026-08-22.
///
/// **It comes from below, like every choice in this app.** On the large title the list
/// would lie between y = 152 and 480 and thus completely above the thumb limit of 560.
struct XtreamCategories: View {

    let categories: [GenreCategory]
    let chosen: GenreCategory?
    let select: (GenreCategory) -> Void

    @State private var needle = ""

    var body: some View {
        SheetFrame(title: "library.pickCategory") {
            // **A search field above a hundred and eight rows.** Measured: at 59 points per
            // row that is 6,372 points — twelve sheet lengths of swiping. The names are
            // long loaded; filtering costs not a single request, and with an
            // account with **one** permitted connection that is exactly the point.
            if categories.count > 12 {
                SearchField(text: $needle, placeholder: "library.findCategory")
                    .padding(.horizontal, MetricsBoard.phone.margin)
                    .padding(.bottom, MetricsBoard.phone.gutter)
            }

            ForEach(found) { category in
                CategoryRow(category: category, chosen: category.id == chosen?.id) {
                    select(category)
                }
            }

            if categories.isEmpty {
                Footnote(message: "library.noCategories")
            } else if found.isEmpty {
                Footnote(message: "library.noCategoryFound")
            }
        }
    }

    /// **Regardless of case and decorative characters.** The
    /// category names are raw provider text; whoever types "kriegs" should find "DE| KRIEGS
    /// FILME".
    private var found: [GenreCategory] {
        let term = needle.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return categories }
        return categories.filter {
            $0.name.localizedCaseInsensitiveContains(term)
        }
    }
}
