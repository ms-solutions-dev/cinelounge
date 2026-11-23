import Core
import DesignSystem
import Flows
import SwiftUI

/// A state as a **block in a list** — where a row would stand.
///
/// **The difference from the whole page is not size but focus.** On the page the state
/// is all there is; here it stands between things that remain operable. A button that
/// takes the focus here (as ``StateView`` does and must do) would tear it out of
/// the viewer's hand while they were somewhere else — when a row reloads in the middle
/// of paging.
///
/// **That is why this block never takes the focus by itself.** It is reachable, not
/// intrusive.
struct StateBlock: View {

    let state: PlaybackPhase
    var onAction: (ActionTarget) -> Void = { _ in }

    @FocusState private var focus: Bool

    var body: some View {
        HStack(spacing: 24) {
            switch state.form {
            case .load(let info):
                ProgressView()
                Text(appKey: info.message)
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.textMatt.color)

            case .info(let info):
                content(
                    icon: info.icon, headline: info.headline,
                    message: info.message)

            case .job(let job):
                content(
                    icon: job.icon, headline: job.headline,
                    message: job.message)
                Spacer(minLength: 20)
                Button {
                    onAction(job.target)
                } label: {
                    Text(appKey: job.button)
                        .font(TypeLevel.footer.font)
                        .foregroundStyle(focus ? ColorRole.reason.color : ColorRole.text.color)
                        .padding(.horizontal, 30)
                        .padding(.vertical, 14)
                        .background(
                            focus ? ColorRole.text.color : ColorRole.surfaceHigh.color,
                            in: Capsule())
                }
                .bareFocusableButton()
                .focused($focus)
            case .muted:
                EmptyView()
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ColorRole.surface.color, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func content(icon: String, headline: String, message: String) -> some View {
        HStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(ColorRole.textQuiet.color)
            VStack(alignment: .leading, spacing: 4) {
                Text(appKey: headline)
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.text.color)
                Text(appKey: message)
                    .font(TypeLevel.lowercased.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A state as **one row** — the smallest of the three forms.
///
/// For places where it is already clear what it is about: under a shelf, next to a
/// group. **Without a button, always** — where one row suffices there is no room for an
/// action, and an action that is easily overlooked is none.
///
/// **It therefore shows only states without a task.** Drawing a task here would mean
/// omitting its button — and then ``InfoVersusAction`` would promise something that
/// does not arrive on the screen.
struct StateRow: View {

    let state: PlaybackPhase

    var body: some View {
        HStack(spacing: 12) {
            switch state.form {
            case .load(let info):
                ProgressView()
                Text(appKey: info.message)
            case .info(let info):
                Image(systemName: info.icon)
                Text(appKey: info.headline)
            case .job(let job):
                Image(systemName: job.icon)
                Text(appKey: job.headline)
            case .muted:
                EmptyView()
            }
        }
        .font(TypeLevel.lowercased.font)
        .foregroundStyle(ColorRole.textQuiet.color)
    }

    /// Which states may be shown in this form at all.
    ///
    /// **A question to the type and not a request to the call site.** Whoever draws a task
    /// as a row takes its button away; the test catches that.
    ///
    /// **`nonisolated`, and the release build demanded it.** A `View` is bound to the main
    /// actor under Swift 6, and with it its static members; the test, however, calls it
    /// synchronously and without an actor. The debug build let that pass, the build with
    /// `-O` did not — exactly what the second build in the quality run is for. The rule
    /// depends on no state of the view: It reads only the state it is given.
    nonisolated static func showsOnly(_ state: PlaybackPhase) -> Bool {
        !InfoVersusAction.hasAction(state)
    }
}
