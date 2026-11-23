import DesignSystemPhone
import SwiftUI

/// Name, value, chevron — at least 44 points tall.
///
/// **The value column is its own text and not a repetition of the name.** "2 · one
/// active", "46 of 79 groups", "TMDb missing" — it says **what is inside**, so that
/// you do not have to open an area to see whether something is missing. That is the
/// done condition of the whole settings package and no ornament: A list of nine names
/// with nine chevrons forces nine taps to answer one question.
///
/// **The value sits on the right and is truncated, the name is not.** When space runs
/// out, the information "what is inside" is the more dispensable of the two — without
/// the name you would not even know what it is talking about.
struct DisclosureRow: View {
    /// How far the row is inset — ``Styling/MetricsBoard/margin`` on the background,
    /// ``Metrics/cardInset`` in a ``SettingsCard``.
    @Environment(\.rowInset) private var inset

    /// Key in the catalog. **Empty if a ``wording`` is given instead.**
    var title: String = ""

    /// The title verbatim — for names that are not translated.
    ///
    /// **A package name is not one you translate** (2026-09-07): "swift-nio" is called that in
    /// every language. The same split as with ``SwitchRow`` and ``SectionHeader``,
    /// and for the same reason — a key for it would have to be maintained for every new
    /// package.
    var wording: String?

    var icon: String?
    /// Finished wording — the value column talks about numbers and names of services.
    var value: String?
    /// Whether the value points to something missing.
    ///
    /// **Gold and not red.** "TMDb missing" is not a fault but a bill: Something is
    /// missing that you can add, and until then nothing is broken.
    var isMissing = false

    /// Whether the symbol sits in a tile.
    ///
    /// **The finding of 2026-09-07:** Bare SF Symbols of very different optical mass in one
    /// column — `play.fill` next to `dot.radiowaves.left.and.right` — do not make a
    /// column but a restlessness. One variant evens out the masses. **Optional and not
    /// everywhere**, because the same row also appears where there is no column: In the
    /// account area there are three rows, and three tiles would be three little boxes
    /// without a row there.
    var isContained = false

    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: MetricsBoard.phone.gutter) {
                if let icon {
                    if isContained {
                        // **Gold only where something is missing.** `GESTALTUNG.md` §1 forbids color
                        // as the sole carrier; next to word and value it is the third
                        // indication and thus allowed.
                        IconTile(icon: icon, tint: isMissing ? ColorRole.progress.color : nil)
                    } else {
                        Image(systemName: icon)
                            .foregroundStyle(ColorRole.textMatt.color)
                            .frame(width: 22)
                    }
                }

                Group {
                    if let wording {
                        Text(verbatim: wording)
                    } else {
                        Text(appKey: title)
                    }
                }
                .font(TypeLevel.text.font)
                .foregroundStyle(ColorRole.text.color)
                .lineLimit(1)
                .layoutPriority(1)

                Spacer(minLength: Metrics.targetSpacing)

                if let value {
                    Text(verbatim: value)
                        .font(TypeLevel.footer.font)
                        .foregroundStyle(isMissing ? ColorRole.progress.color : ColorRole.textQuiet.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Image(systemName: Glyph.next.name)
                    .font(TypeLevel.label.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
            }
            .padding(.horizontal, inset)
            .frame(minHeight: Metrics.choiceRow)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}
