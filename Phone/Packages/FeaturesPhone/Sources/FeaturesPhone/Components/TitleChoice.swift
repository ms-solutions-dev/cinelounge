import DesignSystemPhone
import SwiftUI

/// The large title as the trigger of a choice.
///
/// Wordmark and chevron lie in **one** hit area of at least 44 points. The title is
/// the trigger — the choice is made at the bottom in the sheet, not at the top at the
/// title. That was the most embarrassing finding of the review: The choice unfolded at
/// the title and so lay entirely above the thumb limit, while the note next to it
/// cited exactly this menu as a counterexample.
///
/// **The title names the catalog you are in** — "Movies", not "My library". Before
/// AP12, Jellyfin was a single catalog, and the collective name was right; since there
/// are six, the choice would otherwise have nothing to choose.
struct TitleChoice: View {

    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                // **The same building block as everywhere** — and so also the same scale-down
                // behavior. Before, this was 0.7 here and 0.8 in the header: two numbers for the
                // same decision, one of which gave a visibly smaller title at large system type.
                LargeTitle(wording: title, isStretching: false)
                Image(systemName: Glyph.down.name)
                    .iconSize(15, weight: .semibold)
                    .foregroundStyle(ColorRole.brandLight.color)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, MetricsBoard.phone.margin)
            .frame(minHeight: Metrics.target)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityHint(Text(app: "library.pickStock"))
    }
}
