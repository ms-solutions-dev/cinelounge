import DesignSystemPhone
import SwiftUI

/// A row that says something and does nothing.
///
/// **No button and no capsule.** A ``StateBlock`` would have a heading and a next step —
/// there is none here: that M3U lists flag nothing is a property of the lists and nothing one
/// could switch off. A row that looks as if it could be pressed would be an imposition at
/// this spot.
struct HintRow: View {
    /// How far the row indents — ``Styling/MetricsBoard/margin`` on the background,
    /// ``Metrics/cardInset`` in an ``SettingsCard``.
    @Environment(\.rowInset) private var inset

    let icon: String
    var color: Color = ColorRole.textQuiet.color
    /// Key in the catalog.
    let title: String
    var message: String?
    /// Finished wording instead of a key — for names and numbers of the server.
    var wording: String?

    var body: some View {
        HStack(alignment: .top, spacing: MetricsBoard.phone.gutter) {
            Image(systemName: icon)
                .font(TypeLevel.footer.font)
                .foregroundStyle(color)
                .frame(width: 22)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(appKey: title)
                    .font(TypeLevel.text.font)
                    .foregroundStyle(ColorRole.text.color)
                if let wording {
                    subRow { Text(verbatim: wording) }
                } else if let message {
                    subRow { Text(appKey: message) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, inset)
        .padding(.vertical, MetricsBoard.phone.gutter)
        .accessibilityElement(children: .combine)
    }

    private func subRow(@ViewBuilder _ text: () -> some View) -> some View {
        text()
            .font(TypeLevel.label.font)
            .foregroundStyle(ColorRole.textQuiet.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
