import DesignSystemPhone
import SwiftUI

/// The six-digit code on the TV.
///
/// **In two groups of three.** Nobody reads six digits in a row off a screen
/// without miscounting; the same rule as for a certificate's fingerprint,
/// only smaller.
struct QuickConnectView: View {

    let model: SourceFormModel

    var body: some View {
        SetupSheet(
            title: "setup.code.title", explanation: "setup.code.text", error: model.error
        ) {
            VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
                if let session = model.code {
                    Text(verbatim: session.groupedCode)
                        .iconSize(40, weight: .semibold, design: .monospaced)
                        .foregroundStyle(ColorRole.text.color)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, MetricsBoard.phone.section)
                        .background(
                            ColorRole.surface.color,
                            in: RoundedRectangle(cornerRadius: MetricsBoard.phone.fieldRadius)
                        )
                        // The code is for typing — the screen reader should say it
                        // digit by digit and not as a six-digit number.
                        .accessibilityLabel(
                            Text(verbatim: session.code.map(String.init).joined(separator: " ")))
                } else {
                    LoadingState(message: "setup.code.waiting")
                }
                Footnote(message: "setup.code.footnote")
            }
            .padding(.top, 4)
        }
    }
}
