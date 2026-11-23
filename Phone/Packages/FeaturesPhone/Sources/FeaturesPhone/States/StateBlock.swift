import DesignSystemPhone
import Flows
import SwiftUI

/// Shows a state — and looks different depending on whether it explains
/// something or demands something.
///
/// **The loud button is not in here.** It belongs in the thumb zone and is placed by
/// ``StateView`` into a ``FloatingBar``; the block keeps the quiet
/// secondary path. Whoever uses this block on its own therefore gets a job **without**
/// its next step — the reasoning is at ``StateForm/loudButton``.
struct StateBlock: View {

    let form: StateForm
    var secondaryAction: (() -> Void)?

    var body: some View {
        switch form {
        case .muted:
            // Not an `EmptyView()` by accident, but on purpose: the abort after
            // a call shows nothing because it has nothing to report.
            EmptyView()

        case .load(let info):
            LoadingState(info: info, secondaryAction: secondaryAction)

        case .info(let info):
            VStack(spacing: 10) {
                Image(systemName: info.icon)
                    .iconSize(32, weight: .light)
                    .foregroundStyle(ColorRole.textQuiet.color)
                Text(appKey: info.headline)
                    .font(TypeLevel.header.font)
                    .foregroundStyle(ColorRole.text.color)
                Text(appKey: info.message)
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .multilineTextAlignment(.center)
                if let sidePath = info.sidePath, secondaryAction != nil {
                    secondaryButton(sidePath)
                }
            }
            .padding(.horizontal, MetricsBoard.phone.margin)
            // **Capping and centering belong together** (AP7, 2026-09-23). The cap
            // alone leaves the position to the parent, and that pins to the left: on the
            // iPad "What are you looking for?" sat centered in a 393-point column at the left
            // edge instead of in the middle of the screen. On the phone this never shows, because
            // the available width there is smaller than the cap.
            .frame(maxWidth: 400)
            .frame(maxWidth: .infinity)

        case .job(let job):
            VStack(spacing: 10) {
                Image(systemName: job.icon)
                    .iconSize(30, weight: .regular)
                    // Gold means "this costs something", red means "this is broken". The
                    // occupied connection is not a failure but a bill.
                    .foregroundStyle(job.costs ? ColorRole.progress.color : ColorRole.brandLight.color)
                Text(appKey: job.headline)
                    .font(TypeLevel.header.font)
                    .foregroundStyle(ColorRole.text.color)
                Text(appKey: job.message)
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .multilineTextAlignment(.center)
                if let sidePath = job.sidePath, secondaryAction != nil {
                    secondaryButton(sidePath)
                }
            }
            .padding(MetricsBoard.phone.margin)
            // **Capping and centering belong together** (AP7, 2026-09-23). The cap
            // alone leaves the position to the parent, and that pins to the left: on the
            // iPad "What are you looking for?" sat centered in a 393-point column at the left
            // edge instead of in the middle of the screen. On the phone this never shows, because
            // the available width there is smaller than the cap.
            .frame(maxWidth: 400)
            .frame(maxWidth: .infinity)
            .background(
                ColorRole.surface.color, in: RoundedRectangle(cornerRadius: MetricsBoard.phone.fieldRadius)
            )
            .overlay {
                RoundedRectangle(cornerRadius: MetricsBoard.phone.fieldRadius)
                    .strokeBorder(ColorRole.outline.color, lineWidth: 0.5)
            }
            .padding(.horizontal, MetricsBoard.phone.margin)
        }
    }

    /// The quiet path — quiet, but recognizably a button.
    ///
    /// **Finding from 2026-09-05, seen in the simulator.** The first version was bare text in
    /// `textMatt` — the same tone as the sentence one line above. "To Settings →
    /// Live" thus read as a fourth line of body text, and a button that nobody recognizes as a
    /// button is not one. It now carries an outline and a chevron: both
    /// say "this leads elsewhere" without getting loud. The outline is the same
    /// `ColorRole.outline.color` that otherwise delimits controls — 3 : 1, not 4.5 : 1,
    /// because it is a border and not text.
    /// - Note: Called only if ``secondaryAction`` is set — see above. A quiet
    ///   button without a handler would be the same error as a loud one: **the state names the
    ///   path, but nobody takes it.** Five secondary paths pointed to "Meanwhile to
    ///   downloads" on 2026-09-06, while `import Vorrat` had zero hits.
    private func secondaryButton(_ key: String) -> some View {
        Button {
            secondaryAction?()
        } label: {
            HStack(spacing: 6) {
                Text(appKey: key)
                Image(systemName: Glyph.next.name)
                    .font(TypeLevel.label.font)
            }
            .font(TypeLevel.footer.font)
            .foregroundStyle(ColorRole.textMatt.color)
            .padding(.horizontal, Metrics.cardInset)
            .frame(minHeight: Metrics.target)
            .overlay {
                Capsule().strokeBorder(ColorRole.outline.color, lineWidth: 0.5)
            }
        }
        .padding(.top, 4)
    }
}
