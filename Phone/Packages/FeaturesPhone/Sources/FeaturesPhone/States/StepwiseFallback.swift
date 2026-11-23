import DesignSystemPhone
import Flows
import SwiftUI

/// A fallback is shown, not hidden.
///
/// When a portal takes the path via the bridge, that costs time. The design shows the steps
/// **with their time costs** instead of spinning a spinner for twelve seconds: Anyone who sees
/// that the second of three paths is being tried waits — anyone who sees a squiggle presses Back
/// from second eight.
///
/// **The times stand on the right and come from the measurement.** They are passed through and
/// not formed here: A display that invents its own durations is a claim about a line it does not
/// know.
struct StepwiseFallback: View {

    let probe: RouteProbe

    /// "approx. 2 s" per step, at the identifier. What is not measured does not stand there either.
    var times: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(probe.steps) { step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    character(step.state)
                        .frame(width: 18)
                    Text(appKey: step.message)
                        .font(TypeLevel.footer.font)
                        .foregroundStyle(
                            step.state == .pending ? ColorRole.textQuiet.color : ColorRole.textMatt.color)
                    Spacer(minLength: 8)
                    if let time = times[step.id] {
                        Text(verbatim: time)
                            .font(TypeLevel.label.font)
                            .foregroundStyle(ColorRole.textQuiet.color)
                            .monospacedDigit()
                    }
                }
            }
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
    }

    @ViewBuilder
    private func character(_ state: RouteProbe.Step.State) -> some View {
        switch state {
        case .done:
            Image(systemName: Glyph.done.pair.filled).foregroundStyle(ColorRole.success.color)
        case .isRunning:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: Glyph.failed.name).foregroundStyle(ColorRole.textQuiet.color)
        case .pending:
            Image(systemName: Glyph.pending.name)
                .foregroundStyle(ColorRole.textQuiet.color.opacity(0.5))
        }
    }
}
