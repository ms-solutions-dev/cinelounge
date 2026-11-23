import DesignSystemPhone
import SwiftUI

/// Checkmark, symbol, name — and the number on the right.
///
/// The basic building block of all sheets. **At least 59 points tall**: That is a row
/// that bounds a tile, and 59 is above the target size of 44 by itself.
///
/// **The number sits on the right and not in a subline** (decision of 2026-09-05). On the
/// right the numbers stand one beneath the other — 103, 24, 23, 16 then read as a
/// size comparison, and that is exactly the information you look for in the index. In
/// a subline there would be more room, but every row would get a second height, and
/// with eight catalogs the sheet already scrolls without it.
///
/// **`monospacedDigit`**, because numbers standing one beneath the other otherwise do
/// not stand beneath each other: Proportional digits shift each row by a few points,
/// and the comparison turns into flicker.
struct ChoiceRow: View {

    /// How far the row is inset — ``Styling/MetricsBoard/margin`` in the sheet, ``Metrics/cardInset`` in
    /// a ``SettingsCard``. Since 2026-09-07 it exists in both places.
    @Environment(\.rowInset) private var inset

    let name: String
    var icon: String?
    var number: String?
    var subRow: String?
    var chosen = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ChoiceRowContent(
                name: name, icon: icon, number: number, subRow: subRow,
                chosen: chosen, inset: inset)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }
}

/// The same row **without** the button around it.
///
/// **Why separate** (AP7, 2026-09-10): `ShareLink` brings its own button and takes a
/// label. Whoever gave it a ``ChoiceRow`` would put a button inside a button — on iOS
/// that means: the inner action wins, the share sheet never appears. Separate, the
/// share row looks like every other and still does what only `ShareLink` can.
///
/// **The inset comes from outside.** It lives in the environment and is read where the
/// `body` is evaluated **inside** the card — a row that the parent view composes
/// itself would read it from outside. The same boundary as in E48.
struct ChoiceRowContent: View {

    let name: String
    var icon: String?
    var number: String?
    var subRow: String?
    var chosen = false
    var inset: CGFloat = MetricsBoard.phone.margin

    var body: some View {
        HStack(spacing: MetricsBoard.phone.gutter) {
            // The checkmark keeps its place even when it is not there — otherwise all names
            // shift by thirteen points as soon as you choose something else.
            Image(systemName: Glyph.done.pair.outlined)
                .iconSize(13, weight: .semibold)
                .foregroundStyle(ColorRole.brandLight.color)
                .opacity(chosen ? 1 : 0)
                .frame(width: 15)

            if let icon {
                Image(systemName: icon)
                    .iconSize(15)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .frame(width: 22)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: name)
                    .font(TypeLevel.text.font)
                    .foregroundStyle(ColorRole.text.color)
                    .lineLimit(1)
                if let subRow {
                    Text(verbatim: subRow)
                        .font(TypeLevel.label.font)
                        .foregroundStyle(ColorRole.textQuiet.color)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: MetricsBoard.phone.gutter)

            if let number {
                Text(verbatim: number)
                    .font(TypeLevel.footer.font)
                    .monospacedDigit()
                    .foregroundStyle(ColorRole.textMatt.color)
            }
        }
        .padding(.horizontal, inset)
        .frame(minHeight: Metrics.choiceRow)
        .contentShape(Rectangle())
    }
}
