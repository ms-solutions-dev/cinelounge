import DesignSystemPhone
import SwiftUI

/// A toggle switch, and **the whole row toggles it.**
///
/// A switch alone is 51 × 31 points and sits at the right edge — at 393 points that
/// means: aiming. The row is the target; the switch only indicates.
///
/// **The state is in the position of the knob, not in its color.** That is the rule of
/// the system switch itself, and it is the reason to use it instead of drawing our
/// own: With deuteranopia the position stays legible, the color does not.
struct SwitchRow: View {
    /// How far the row is inset — ``Styling/MetricsBoard/margin`` on the background,
    /// ``Metrics/cardInset`` in a ``SettingsCard``.
    @Environment(\.rowInset) private var inset

    /// Key in the catalog. **Empty if a ``wording`` is given instead.**
    var title: String = ""

    /// The title verbatim — for names that come from the viewer or from a service.
    ///
    /// **A portal name is not translated** (2026-09-07): It comes from the bridge, and a key
    /// for it would have to be maintained for every new portal. The same split as with
    /// ``CaptionLabel/wording(_:)`` and with ``SectionHeader``.
    var wording: String?
    /// The explanatory sentence below — **only where it explains something.**
    ///
    /// A row "Subtitles — turns subtitles on" says the same thing twice and makes the
    /// list twice as long.
    var message: String?

    /// The symbol in the leading column — **`nil` where the card has none.**
    ///
    /// **Added on 2026-09-09, and the row was the last one without** (client's finding,
    /// see ``AccountSwitchSheet``). ``DisclosureRow`` and ``ValueRow`` have carried the
    /// column since 2026-09-07; when a switch row sat in the same card, its text began forty
    /// points further left than that of its neighbors. The same two properties and the
    /// same meaning as there — hence no separate construction.
    var icon: String?

    /// Whether the symbol sits in a ``IconTile`` — see ``DisclosureRow/isContained``.
    var isContained = false

    @Binding var on: Bool

    var body: some View {
        // **The symbol sits INSIDE the switch's label and not next to it.** Otherwise the
        // tile would be the one piece of the row that does not toggle — and the promise of
        // this building block is that the whole row is the target.
        Toggle(isOn: $on) {
            HStack(spacing: MetricsBoard.phone.gutter) {
                if let icon {
                    if isContained {
                        IconTile(icon: icon)
                    } else {
                        Image(systemName: icon)
                            .foregroundStyle(ColorRole.textMatt.color)
                            .frame(width: 22)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Group {
                        if let wording {
                            Text(verbatim: wording)
                        } else {
                            Text(appKey: title)
                        }
                    }
                    .font(TypeLevel.text.font)
                    .foregroundStyle(ColorRole.text.color)
                    if let message {
                        Text(appKey: message)
                            .font(TypeLevel.label.font)
                            .foregroundStyle(ColorRole.textQuiet.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .tint(ColorRole.tag.color)
        .padding(.horizontal, inset)
        .frame(minHeight: Metrics.choiceRow)
    }
}
