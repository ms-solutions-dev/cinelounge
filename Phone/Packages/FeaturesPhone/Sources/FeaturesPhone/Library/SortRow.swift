import DesignSystemPhone
import SwiftUI

/// The three orderings — **one button on the left that opens to the right.**
///
/// **User decision of 2026-09-05, in two steps.** First it was a button that opened a
/// sheet: two taps for a choice among three. Then three chips, always visible — and
/// they took up half the bar without being needed often. The third scope solves both:
/// "a button anchored at the bottom left, and when I tap it, the area with the sort
/// buttons opens from left to right."
///
/// **Collapsed, it carries its state.** The capsule shows what the list is currently
/// ordered by — a button that only showed an icon would hide that. This is the same rule
/// as for the active tab: state appears as a **word**, not as a color (with deuteranopia,
/// `rotHell` and `textQuiet` sit at 1.02 : 1).
///
/// **Expanded, the row slides in from the left**, to where there is room — to the right.
/// The other direction would have made the chips appear under the thumb that just pressed
/// the button.
///
/// **A choice collapses it again.** Whoever has sorted wants to see the list, not the
/// choice — and an open row covers a row of tiles.
///
/// **It floats freely and does not sit on a bar** (user finding 2026-09-05: "the background
/// color of the sorting should go away when everything is collapsed"). A band across the
/// full width covers a row of tiles — for a button that sits on the left and is rarely
/// pressed. The capsule brings its own material; with it, it stays legible even on a
/// light poster, and the list stays visible next to it.
struct SortRow: View {

    let choice: OrderChoice
    let possible: [Sorting]
    let tap: (Sorting) -> Void

    @State private var pending = false

    var body: some View {
        HStack(spacing: Metrics.targetSpacing) {
            button

            if pending {
                ForEach(possible) { possible in
                    orderChip(possible)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }

            Spacer(minLength: 0)
        }
        // **Clipped from the left, not overflowing.** Without this line the chips push past
        // the screen edge while sliding in, instead of emerging from under the button.
        .clipped()
    }

    /// A chip with a **direction arrow** when it is the active one.
    ///
    /// **The arrow appears only on the active chip and only when a choice was made.** As long
    /// as the default applies, there is no direction to show — it is the one the catalog
    /// brings with it. An arrow on a chip that was not chosen would be a claim about an
    /// ordering nobody requested.
    ///
    /// **And the label stays as it is.** "A–Z ↓" reads as contradictory — what is meant is
    /// the ordering "by title", and the arrow says in which direction. The TV does it this
    /// way, and it has gone unnoticed there for months.
    @ViewBuilder
    private func orderChip(_ possible: Sorting) -> some View {
        let active = possible == choice.sorting && choice.explicit
        Button {
            tap(possible)
        } label: {
            HStack(spacing: 5) {
                Text(appKey: possible.titleKey)
                    .lineLimit(1)
                if active {
                    Image(systemName: choice.ascending ? Glyph.upward.name : Glyph.downward.name)
                        .iconSize(10, weight: .bold)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.chip(active: active))
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
        .accessibilityValue(
            active ? Text(app: choice.ascending ? "sort.ascending" : "sort.descending") : Text(""))
    }

    /// The anchor on the left — collapsed with the active ordering, expanded only the icon.
    private var button: some View {
        Button {
            withAnimation(Motion.expand) { pending.toggle() }
        } label: {
            HStack(spacing: 6) {
                if pending {
                    // **The arrow points back to where the row disappears.** A cross would say "gone", an
                    // arrow says "in again" — and that is what happens here.
                    Image(systemName: Glyph.back.name)
                        .iconSize(13, weight: .semibold)
                } else {
                    Image(systemName: Glyph.sorting.name)
                        .iconSize(13, weight: .semibold)
                    Text(appKey: choice.sorting.titleKey)
                        .font(TypeLevel.label.font)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    if choice.explicit {
                        Image(
                            systemName: choice.ascending
                                ? Glyph.upward.name : Glyph.downward.name
                        )
                        .iconSize(10, weight: .bold)
                        .foregroundStyle(ColorRole.textMatt.color)
                    }
                    Image(systemName: Glyph.next.name)
                        .iconSize(11, weight: .semibold)
                        .foregroundStyle(ColorRole.brandLight.color)
                }
            }
            .foregroundStyle(ColorRole.text.color)
            .padding(.horizontal, pending ? 0 : 14)
            .frame(minWidth: Metrics.target, minHeight: Metrics.target)
            .background(Material.chromeBar, in: Capsule())
            .overlay { Capsule().strokeBorder(ColorRole.outline.color, lineWidth: 0.5) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(app: "sort.title"))
        .accessibilityValue(Text(appKey: choice.sorting.titleKey))
        .accessibilityHint(Text(app: pending ? "sort.close" : "sort.open"))
    }
}
