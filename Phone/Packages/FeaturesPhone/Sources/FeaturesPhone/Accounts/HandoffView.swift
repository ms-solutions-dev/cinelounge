import DesignSystemPhone
import Flows
import SwiftUI

/// Set up the TV from the phone.
///
/// **Four screens in one, and the order is the promise:** camera, then the
/// table, then the transfer, then the answer. Whoever showed the table after sending
/// would obtain consent to something that has already happened — the reasoning
/// lives at ``HandoffModel`` and at ``CarryOverSheet``.
///
/// **No spinner without text and no rejection without advice.** Each of the six rejections has its
/// own sentence (``SecondScreen/HandoffMessage``); "something went wrong" would be
/// particularly expensive here, because the viewer stands with a second device in hand and
/// does not know which of the two to look at.
public struct HandoffView: View {

    @State private var model: HandoffModel
    private let close: () -> Void

    public init(model: HandoffModel, close: @escaping () -> Void = {}) {
        _model = State(initialValue: model)
        self.close = close
    }

    public var body: some View {
        Group {
            switch model.state {
            case .isSearching: seeker
            case .read:
                CarryOverSheet(
                    confirm: { Task { await model.transfer() } },
                    cancel: close)
            case .sending:
                // **No cancel button.** What runs here is a connection of a few
                // seconds; a button that cuts it in the middle would leave a
                // TV in a state that nobody could name.
                LoadingState(message: "handover.sending")
            case .done: done
            case .failed(let message): failed(message)
            }
        }
        .navigationTitle(Text(app: "settings.handover.title"))
    }

    private var seeker: some View {
        VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
            Text(appKey: "handover.scan.text")
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.textMatt.color)
                .fixedSize(horizontal: false, vertical: true)

            // **Square and not full screen.** The code sits in the middle of
            // the TV; a preview over the whole height tempts one to hold the phone
            // upright against the screen, and then the code lies outside.
            QRScanner(read: { model.read($0) })
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
    }

    /// **An ``Job`` and not an ``StateInfo``**, although nothing is left to do: the
    /// way out is the next step, and a screen without a button would leave the
    /// viewer with a phone that is done and does not move on.
    private var done: some View {
        finish(
            form: .job(
                Job(
                    icon: Glyph.done.pair.filled,
                    headline: "handover.done.title",
                    message: "handover.done.text",
                    button: "common.done", target: .retry)),
            button: "common.done", action: close)
    }

    /// **The sentence comes from the model and not from here.** Each of the six rejections has
    /// its own; which one applies is known only by whoever queried the wire.
    private func failed(_ message: String) -> some View {
        finish(
            form: .job(
                Job(
                    icon: Glyph.offline.name,
                    headline: "handover.error.title",
                    message: message,
                    button: "handover.retry", target: .retry)),
            button: "handover.retry", action: { model.retry() })
    }

    /// Block and loud button — **as ``StateView`` does it**, only for two situations
    /// that are not ``PlaybackPhase`` cases: they belong to this flow and not to the catalog,
    /// and extending the closed list by two entries that occur only here
    /// would turn it into a construction kit.
    private func finish(
        form: StateForm, button: String, action: @escaping () -> Void
    ) -> some View {
        ZStack(alignment: .bottom) {
            StateBlock(form: form)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            FloatingBar {
                Button(action: action) {
                    Text(appKey: button).frame(maxWidth: .infinity)
                }
                .buttonStyle(.loud)
            }
        }
    }
}
