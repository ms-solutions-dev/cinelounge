import DesignSystemPhone
import SwiftUI

/// A row in Settings that does **not** lead further.
///
/// **Three forms, three jobs.** What leads further is ``DisclosureRow``; what toggles is
/// ``SwitchRow``; what only says something is this one. Mixing them would be
/// convenient and would blur the one question a settings list answers: can I do something
/// here, and what?
struct SettingsRow: View {
    /// How far the row indents — ``Styling/MetricsBoard/margin`` on the background,
    /// ``Metrics/cardInset`` in an ``SettingsCard``.
    @Environment(\.rowInset) private var inset

    /// Key in the catalog.
    let title: String
    var value: String?
    var icon: String?

    var body: some View {
        HStack(spacing: MetricsBoard.phone.gutter) {
            if let icon {
                Image(systemName: icon)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .frame(width: 22)
            }
            Text(appKey: title)
                .font(TypeLevel.text.font)
                .foregroundStyle(ColorRole.text.color)
            Spacer(minLength: Metrics.targetSpacing)
            if let value {
                Text(verbatim: value)
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
                    .lineLimit(1)
                    // Identifiers and numbers get typed in and read aloud — for that one
                    // has to be able to select them.
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, inset)
        .frame(minHeight: Metrics.choiceRow)
    }
}
