import DesignSystem
import SwiftUI

/// The head of a library page: the name, next to it the number of entries.
///
/// **One header for all levels — and that is exactly what it was not.** The folder and
/// title levels of the same portal carried two different headers: the folder level
/// drew its title *inside* the scroll view and without a count, so it scrolled
/// away when paging; the title level put it above and with a count.
/// Two headers on two levels of the same page read as two different
/// places, and the viewer looks for the difference in themselves.
///
/// **The insets live here and not at the call site.** They are the
/// first thing that makes two copies of the same header drift apart: a
/// number that lives in two places gets changed in only one.
struct LibraryHeader: View {

    let title: String
    /// How many entries the level holds. Subheadings do not count
    /// — see ``PortalList/count(_:)``.
    let count: Int
    /// The library choice at the title (AP89) — `nil` in the normal case.
    ///
    /// **`nil` draws exactly the header from before AP89:** plain text, not focusable, no
    /// chevron. Only a tab with two or more libraries of its kind passes one.
    var choice: TitleChoice?

    /// What turns the title into the trigger of the library list.
    struct TitleChoice {
        /// The focus identifier of the title button.
        let id: String
        let focus: FocusState<String?>.Binding
        let action: () -> Void
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            if let choice {
                choosableTitle(choice)
            } else {
                Text(verbatim: title)
                    .font(TypeLevel.title.font)
                    .foregroundStyle(ColorRole.text.color)
            }
            Text(app: "library.itemCount \(count)")
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.textMatt.color)
        }
        // Leading edge only: in the continuous grid the line sits in the left column,
        // and on the right the gap to the information column handles the separation —
        // a second padding there would take width away from the filter row below.
        .padding(.leading, MetricsBoard.tv.margin)
        // No more gap for the pill: in the grids it takes its own
        // space instead of floating above — see ``MainView/mediaShell``.
        .padding(.top, LibraryView.headerTopPadding)
    }

    /// The title as a button, with the chevron the phone shows next to its title.
    ///
    /// **The highlight lies behind the text and takes no room** — the plate is drawn with
    /// negative padding as a background. With real padding the title would move right and
    /// the header would grow, and the height budget of the grid (`LayoutBudgetTests`) counts
    /// exactly one title line.
    private func choosableTitle(_ choice: TitleChoice) -> some View {
        let isFocused = choice.focus.wrappedValue == choice.id
        return Button(action: choice.action) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(verbatim: title)
                    .font(TypeLevel.title.font)
                Image(systemName: Glyph.down.name)
                    .font(TypeLevel.header.font.weight(.semibold))
                    .foregroundStyle(isFocused ? ColorRole.tag.color : ColorRole.brandLight.color)
            }
            .foregroundStyle(isFocused ? ColorRole.reason.color : ColorRole.text.color)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isFocused ? ColorRole.text.color : Color.clear)
                    .padding(.horizontal, -22)
                    .padding(.vertical, -4)
                    .allowsHitTesting(false)
            }
            .scaleEffect(isFocused ? Self.focusScale : 1, anchor: .leading)
            .shadow(color: .black.opacity(isFocused ? 0.7 : 0), radius: 20, y: 9)
            .animation(.easeOut(duration: 0.15), value: isFocused)
        }
        .bareFocusableButton()
        .focused(choice.focus, equals: choice.id)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityHint(Text(app: "library.pickStock"))
    }

    /// How much the focused title grows — less than a chip, because the title is already
    /// large; anchored at the leading edge so it does not reach under the sidebar.
    static let focusScale: CGFloat = 1.04
}
