import DesignSystemPhone
import SwiftUI

/// The heading above a group of rows.
///
/// **Letter-spaced capitals set small** — it is meant to name the group without competing for
/// attention with the rows below. A heading at reading size would read like an entry.
///
/// **It carries the origin so that the rows do not have to.** In the register, the same badge
/// would otherwise stand on each of the six Jellyfin libraries — the same information six
/// times is none.
struct SectionHeader: View {
    /// How far the row indents — ``Styling/MetricsBoard/margin`` on the background,
    /// ``Metrics/cardInset`` in an ``SettingsCard``.
    @Environment(\.rowInset) private var inset

    /// Key in the string catalog.
    var title: String?
    /// Finished wording — for names that a service reports.
    var wording: String?

    var body: some View {
        Group {
            if let wording {
                Text(verbatim: wording)
            } else if let title {
                Text(appKey: title)
            }
        }
        .font(TypeLevel.lowercased.font)
        .tracking(1.1)
        .textCase(.uppercase)
        .foregroundStyle(ColorRole.textQuiet.color)
        .padding(.horizontal, inset)
        .padding(.top, MetricsBoard.phone.gutter)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
    }
}
