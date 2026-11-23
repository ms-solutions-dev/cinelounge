import DesignSystemPhone
import Flows
import SwiftUI

/// A spinner never stands alone.
///
/// Always above a sentence that says what is being waited for — and after a while above a
/// second one that says it takes longer than usual. A squiggle without text is a claim; you
/// know neither what is loading nor whether it is still loading at all.
///
/// The sentence from the TV program is the build rule: *"Every wait ends in a result or a
/// message. An endless loading circle without explanation is one of the most frequent
/// complaints about comparable apps."*
struct LoadingState: View {

    let info: LoadingInfo

    /// After this many seconds the second sentence comes.
    ///
    /// Four seconds: shorter than what someone puts up with without an explanation, and longer than
    /// any ordinary fetch on the home network — otherwise the sentence would stand there on every
    /// opening and have nothing left to say.
    var slowAfter: Duration = .seconds(4)

    var secondaryAction: (() -> Void)?

    @State private var slow = false

    /// Convenient access for the many places that have only one sentence.
    init(message: String, slowAfter: Duration = .seconds(4)) {
        self.info = LoadingInfo(message: message)
        self.slowAfter = slowAfter
    }

    /// The loading state of a ``PlaybackPhase`` — **for the places that previously copied its key**
    /// (the Mediathek sentence in three views). The key lives in the shared catalog, and a copy at
    /// the call site would be a second place that holds it.
    init(forItem state: PlaybackPhase, slowAfter: Duration = .seconds(4)) {
        if case .load(let info) = state.form {
            self.info = info
        } else {
            self.info = LoadingInfo(message: state.form.message ?? "")
        }
        self.slowAfter = slowAfter
    }

    init(info: LoadingInfo, slowAfter: Duration = .seconds(4), secondaryAction: (() -> Void)? = nil) {
        self.info = info
        self.slowAfter = slowAfter
        self.secondaryAction = secondaryAction
    }

    private var isShowingSlowHint: Bool { slow || info.slowImmediately }

    var body: some View {
        VStack(spacing: 12) {
            // **The loading band instead of the system spinner** (2026-09-07). This app loads often and for a
            // long time — measured between 0.28 and 7.34 Mbit/s, depending on the cell — and a screen you
            // see a hundred times may look like this app. The rule and the handling of "Reduce Motion" are
            // at ``DesignSystemPhone/LoadingBand``.
            LoadingBand()
                .frame(width: 132)
                .padding(.bottom, 2)
            Text(appKey: info.message)
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.textMatt.color)
            if isShowingSlowHint {
                Text(appKey: LoadingInfo.slowWording)
                    .font(TypeLevel.label.font)
                    .foregroundStyle(ColorRole.textQuiet.color)
                    .transition(.opacity)
            }
            // The same rule as in ``StateBlock``: draw only if someone operates it.
            if isShowingSlowHint, let sidePath = info.sidePath, secondaryAction != nil {
                Button {
                    secondaryAction?()
                } label: {
                    Text(appKey: sidePath)
                        .font(TypeLevel.footer.font)
                        .foregroundStyle(ColorRole.textMatt.color)
                }
                .textHitTarget()
                .padding(.top, 4)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, MetricsBoard.phone.margin)
        // **Horizontally centered, and here.** Seen on 2026-09-06 in Live and in the portals: The spinner
        // stuck to the left edge. Both views put their content in a `VStack(alignment: .leading)` —
        // right for titles and chips, wrong for a loading state. The alignment belongs to the loading
        // state and not to every view that uses it: Otherwise the third one forgets it.
        .frame(maxWidth: .infinity)
        .task {
            try? await Task.sleep(for: slowAfter)
            withAnimation(Motion.expand) { slow = true }
        }
    }
}
