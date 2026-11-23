import Core
import DesignSystem
import Flows
import SwiftUI

/// A fallback is **shown, not concealed.**
///
/// When a portal takes the path via the bridge, that costs time. Instead of spinning a
/// spinner for twelve seconds, the steps are shown: Whoever sees that the second of
/// three paths is being tried waits — whoever sees a squiggle presses Back from second
/// eight on.
///
/// **On the TV this weighs more than on the phone.** There the device is in the hand
/// and one sees that it is working; here one sits three metres away, and a spinner
/// without text cannot be told apart from a frozen picture. The user finding "I press
/// and nothing happens" was a package of its own here (E28).
///
/// **This view takes no focus.** It has nothing to press — it reports, and what is
/// reported ends by itself. A focus target in it would hold the button while the app
/// is working, and on the switch to the next state the focus would again be the
/// problem from ``StateView``.
struct StepwiseFallback: View {

    let probe: RouteProbe

    /// "approx. 2 s" per step, at the identifier. **What is not measured is not stated
    /// either** — an invented duration is worse than none.
    var times: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(probe.steps) { step in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    character(step.state)
                        .frame(width: 26)
                    Text(appKey: step.message)
                        .font(TypeLevel.footer.font)
                        .foregroundStyle(
                            step.state == .pending
                                ? ColorRole.textQuiet.color : ColorRole.textMatt.color)
                    Spacer(minLength: 12)
                    if let time = times[step.id] {
                        Text(verbatim: time)
                            .font(TypeLevel.lowercased.font)
                            .foregroundStyle(ColorRole.textQuiet.color)
                            .monospacedDigit()
                    }
                }
            }
        }
        .frame(maxWidth: 820, alignment: .leading)
    }

    /// **A symbol and not only colour** — as with every marker in this app: An indicator
    /// carried by colour alone is missing for one in ten.
    @ViewBuilder
    private func character(_ state: RouteProbe.Step.State) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(ColorRole.progress.color)
        case .isRunning:
            ProgressView()
        case .failed:
            Image(systemName: "xmark.circle").foregroundStyle(ColorRole.textQuiet.color)
        case .pending:
            Image(systemName: "circle.dotted").foregroundStyle(ColorRole.textQuiet.color)
        }
    }
}
