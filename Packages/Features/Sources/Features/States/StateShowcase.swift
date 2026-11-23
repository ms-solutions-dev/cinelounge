import Core
import DesignSystem
import Flows
import SwiftUI

/// All twenty states to look through — **without any of them having to occur.**
///
/// **The reason is the rule of this project: "done means seen on the device".** For
/// focus and key presses no test counts, only the TV. Producing twenty states on the
/// device, however, would mean causing twenty faults — switching off a server, letting
/// an access token expire, occupying a provider account twice. Most of them cannot be
/// produced at all, and none is repeatable.
///
/// **Hence this screen.** It is not a toy but the tool with which the pointers after AP1
/// can be worked through at all: One goes through it once on the device and sees every
/// state as it would stand in the real case.
///
/// **It shows every state in the form in which it really occurs.** A state that appears
/// as a whole page is shown here as a whole page — otherwise one would be testing
/// something other than what the app does. The choice of form therefore does not stand
/// here but follows from ``PlaybackPhase/form``.
///
/// **Reachable only via the diagnostics.** It belongs to the tools and not to the app;
/// on the release path nobody stumbles into it.
struct StateShowcase: View {

    /// Which state is currently being demonstrated. `nil` means: the list.
    @State private var chosen: PlaybackPhase?
    @FocusState private var focus: String?

    var body: some View {
        if let chosen {
            demo(chosen)
        } else {
            list
        }
    }

    // MARK: - The list

    private var list: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                SettingsHeader("state.review.title", hint: "state.review.hint")

                ForEach(PlaybackPhase.onTV) { state in
                    row(state)
                }
            }
            .padding(.bottom, 60)
        }
    }

    private func row(_ state: PlaybackPhase) -> some View {
        Button {
            chosen = state
        } label: {
            HStack(spacing: 20) {
                // **The form stands beside it, and that is half the information.** Whoever checks
                // wants to know whether this case should have a button — otherwise they do not notice
                // a missing one.
                Text(verbatim: abbreviation(state.form))
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
                    .frame(width: 110, alignment: .leading)
                    .monospaced()

                Text(verbatim: state.rawValue)
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(
                        focus == state.rawValue ? ColorRole.reason.color : ColorRole.text.color)

                Spacer(minLength: 20)

                // Where it would stand in the real case — the answer from ``PlaybackPhase/host``.
                Text(verbatim: String(describing: state.host))
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                focus == state.rawValue ? ColorRole.text.color : ColorRole.surface.color,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .bareFocusableButton()
        .focused($focus, equals: state.rawValue)
        .padding(.vertical, 4)
    }

    private func abbreviation(_ form: StateForm) -> String {
        switch form {
        case .load: "loading"
        case .info: "info"
        case .job: "job"
        case .muted: "muted"
        }
    }

    // MARK: - The showcase

    /// A state as it would stand in the real case.
    ///
    /// **The way back is on the Menu button and not on a button.** A second button next to
    /// the task's one would take from the state exactly what is to be checked here: where
    /// the focus goes when there is **one**.
    private func demo(_ state: PlaybackPhase) -> some View {
        ZStack {
            StateView(state: state) { _ in
                // In the demo the action leads nowhere — what is checked is that the button is there
                // and has the focus, not where it leads.
                chosen = nil
            }

            if state == .portalFetchAddress {
                // **The only state that is more than its form.** It carries the steps, and those belong
                // in the demonstration — otherwise one checks a loading spinner instead of the thing
                // itself.
                VStack {
                    Spacer()
                    StepwiseFallback(probe: .fallbackViaBridge)
                        .padding(.bottom, 80)
                }
            }
        }
        .onExitCommand { chosen = nil }
    }
}
