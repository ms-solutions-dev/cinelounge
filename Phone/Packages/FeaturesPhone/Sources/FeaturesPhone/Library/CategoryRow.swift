import DesignSystemPhone
import SwiftUI

/// A row in the category picker.
///
/// **The same construction as the catalog row**, and that is deliberate: it is the same
/// gesture one level deeper. Two pick lists with two looks would be two things to learn
/// for the same action — the same reasoning by which the season picker on the detail
/// page took over the grammar of the catalog picker.
///
/// **The name appears as the provider reports it.** "DE | KINO", "TR - DIZI", "4K UHD" —
/// these are its ordering terms, not ours. Smoothing them turns a piece of information
/// into a guess.
struct CategoryRow: View {

    let category: GenreCategory
    let chosen: Bool
    let action: () -> Void

    var body: some View {
        ChoiceRow(
            name: category.name,
            icon: Glyph.folder.name,
            number: category.extent?.formatted(.number),
            chosen: chosen,
            action: action)
    }
}
