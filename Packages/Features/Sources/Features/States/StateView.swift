import Core
import DesignSystem
import Flows
import SwiftUI

/// A state as a **whole page** — where the content would otherwise stand.
///
/// **The fourth question that exists only on the TV: Where does the focus go?**
///
/// On the phone an empty screen is an empty screen. Here it is a trap: When a view with
/// content becomes a state, all the buttons on which the focus was standing disappear —
/// and tvOS has to reassign it. If it finds nothing focusable, it takes the nearest
/// target outside, and that is the sidebar; if it finds nothing at all, the focus stays
/// where nothing is any more, and **the remote does nothing any more**. Exactly this
/// kind of error was a package of its own on the TV (E27, E28).
///
/// **Hence two rules, and both stand here and not at the call sites:**
///
/// 1. **A task takes the focus.** Its button is the only target on the page, and it
///    should be so immediately — whoever has to go left into the bar and back first to
///    press "Again" has a path that nobody finds.
/// 2. **A piece of information does not take it.** It has nothing to press; an
///    invisible focus target in it would hold the button and lead nowhere. The focus
///    then belongs to the bar, and gets there by itself.
struct StateView: View {

    let state: PlaybackPhase

    /// A **verbatim** addition under the sentence — the reason that a foreign party sends
    /// along.
    ///
    /// **It belongs to the call site and not to the state** (AP25, 2026-09-11). A
    /// ``PlaybackPhase`` is a value: comparable, enumerable, testable — ``InfoVersusAction``
    /// needs that. A text that only arises at runtime would make it a bag of strings.
    ///
    /// **And without it, connecting the portals would have been a step backwards:** The
    /// bridge sends its reason along in plain text, and "setting required but empty" says more
    /// than any pre-formulated sentence. Swapping it for a general message would mean
    /// trading information for a feeling.
    var extras: String?

    /// What the button does. Called only for ``StateForm/job(_:)``.
    var onAction: (ActionTarget) -> Void = { _ in }

    @FocusState private var focus: Bool

    var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            switch state.form {
            case .load(let info):
                load(info)
            case .info(let info):
                block(
                    icon: info.icon, headline: info.headline,
                    message: info.message, button: nil)
            case .job(let job):
                block(
                    icon: job.icon, headline: job.headline,
                    message: job.message, button: job)
            case .muted:
                EmptyView()
            }
        }
    }

    private func load(_ info: LoadingInfo) -> some View {
        VStack(spacing: 22) {
            // **A band instead of a spinner** (AP27, 2026-09-11). The system spinner measures about
            // one point at three metres; it says "something is turning", and does so the same in
            // every app. This app loads often and for a long time — the loading state is one of its
            // most-seen screens, and that is exactly why it is worth making it look like the app.
            // See ``DesignSystem/LoadingBand``.
            LoadingBand()
            Text(appKey: info.message)
                .font(TypeLevel.text.font)
                .foregroundStyle(ColorRole.textMatt.color)
            if info.slowImmediately {
                // **The second sentence is half the information.** "Taking longer than usual" says
                // that the app is still working — without it one takes a standing spinner for a frozen
                // one.
                Text(appKey: LoadingInfo.slowWording)
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
            }
        }
    }

    private func block(
        icon: String, headline: String, message: String, button: Job?
    ) -> some View {
        VStack(spacing: 24) {
            Image(systemName: icon)
                .font(.system(size: 72))
                .foregroundStyle(ColorRole.textQuiet.color)

            Text(appKey: headline)
                .font(TypeLevel.section.font)
                .foregroundStyle(ColorRole.text.color)
                .multilineTextAlignment(.center)

            Text(appKey: message)
                .font(TypeLevel.text.font)
                .foregroundStyle(ColorRole.textMatt.color)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 900)

            if let extras, !extras.isEmpty {
                // Weaker than the sentence above it: It is the justification and not the message — and
                // it comes from outside, hence in the typeface that the house uses for third-party
                // text.
                Text(verbatim: extras)
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 900)
            }

            if let button {
                Button {
                    onAction(button.target)
                } label: {
                    Text(appKey: button.button)
                        .font(TypeLevel.header.font)
                        .foregroundStyle(focus ? ColorRole.reason.color : ColorRole.text.color)
                        .padding(.horizontal, 44)
                        .padding(.vertical, 20)
                        .background(
                            focus ? ColorRole.text.color : ColorRole.surfaceHigh.color,
                            in: Capsule())
                }
                .bareFocusableButton()
                .focused($focus)
                // **Rule 1 from the head of this file.** Without it the focus ends up somewhere after
                // the switch, and the only button on the page can be reached only by a detour.
                .onAppear { focus = true }
            }
        }
        .padding(50)
    }
}
