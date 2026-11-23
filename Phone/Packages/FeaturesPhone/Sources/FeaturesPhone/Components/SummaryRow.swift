import DesignSystemPhone
import SwiftUI

/// "18 of 23 sports" and next to it **All** and **None**.
///
/// **Two bulk commands save twenty-one taps.** Whoever wants only football taps
/// "None" and then one chip; without them it would be twenty-two presses, and nobody
/// does that — they live instead with a bar they did not want.
///
/// **The number sits on the left and is no decoration.** It is the only information
/// that filtering is going on: A chip field in which four of twenty-three are checked
/// looks at a glance exactly like one in which all are checked — both are colorful.
struct SummaryRow: View {
    /// How far the row is inset — ``Styling/MetricsBoard/margin`` on the background,
    /// ``Metrics/cardInset`` in a ``SettingsCard``.
    @Environment(\.rowInset) private var inset

    let wording: String
    let all: () -> Void
    let none: () -> Void

    var body: some View {
        HStack(spacing: Metrics.targetSpacing) {
            Text(verbatim: wording)
                .font(TypeLevel.label.font)
                .foregroundStyle(ColorRole.textQuiet.color)
                .monospacedDigit()

            Spacer(minLength: Metrics.targetSpacing)

            Button(action: all) { Text(app: "common.all") }
                .buttonStyle(.chip(active: false))
            Button(action: none) { Text(app: "settings.none") }
                .buttonStyle(.chip(active: false))
        }
        .padding(.horizontal, inset)
        .padding(.bottom, Metrics.targetSpacing)
    }
}
