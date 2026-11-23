import DesignSystemPhone
import Flows
import SwiftUI

/// The banner above downloads when the bar has dropped.
///
/// **A banner and not a block.** ``StateBlock`` takes half a screen height and stands where
/// the content would otherwise be — right where there is none. Here there is some: The
/// downloads lie below it and are the reason this screen can do anything at all. A block above
/// them would turn a catalog into a fault message with a list in the footer.
///
/// **The words come from ``PlaybackPhase/networkAirplaneMode`` and not from here.** The state has been built
/// since E17, had no place until AP3 and was thus unreachable; it gets one here. Anyone who
/// wrote the sentence in this file instead would have it twice — once in the state's catalog and
/// once next to it.
///
/// **Its side path is explicitly not drawn.** It is called "Open downloads", and downloads are
/// the screen the banner sits on. A button to where you already are is none.
struct InFlightBand: View {

    /// Look again. **The second way back and not the only one** — the bar returns by itself as soon
    /// as something carries (``NetworkStatus/NetworkWatch/lookUp()``).
    let retry: () -> Void

    private var state: PlaybackPhase { .networkAirplaneMode }

    var body: some View {
        HStack(spacing: Metrics.targetSpacing) {
            if let icon = state.form.icon {
                Image(systemName: icon)
                    .foregroundStyle(ColorRole.textMatt.color)
            }

            if let headline = state.form.headline {
                Text(appKey: headline)
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .lineLimit(2)
            }

            Spacer(minLength: Metrics.targetSpacing)

            Button(action: retry) {
                Text(app: "common.retry")
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.brandLight.color)
                    .frame(minHeight: Metrics.target)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
        .frame(minHeight: Metrics.target)
        .background(ColorRole.surface.color)
    }
}
