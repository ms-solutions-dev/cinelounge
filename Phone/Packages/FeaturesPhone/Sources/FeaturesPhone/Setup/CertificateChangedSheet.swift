import Core
import DesignSystemPhone
import SwiftUI

/// Sheet: the fingerprint has changed.
///
/// **Old and new digest one below the other — this is the screen at which either a
/// server has moved or somebody stands in between.** It looks similar to the ``CertificateSheet``
/// and is something else: there an unknown certificate is the normal case,
/// here a changed one is the warning the whole procedure was built for.
///
/// **One below the other and not side by side.** Two columns of sixty-four characters each
/// have no room on 393 points; what stands there is wrapped and then can
/// no longer be compared. One below the other the groups of four stand at the same
/// horizontal position — and the difference jumps to the eye instead of being searched for.
///
/// **No loud button, on neither side.** "Trust anyway" is the
/// action that can be regretted here; drawing it loudly would mean recommending it.
/// Drawing "Cancel" loudly would be just as wrong — a moved server is the
/// more frequent case, and whoever knows it should not have to work against the screen.
///
/// **The way out stands as a sentence and not as a button:** whoever is unsure compares the
/// digest on the server. A button "decide later" would be the same as "Cancel", only
/// with a friendlier word.
struct CertificateChangedSheet: View {

    let query: CertificatePrompt.Pending
    /// The known digest — without it the situation belongs in the ``CertificateSheet``.
    let known: CertificateFingerprint
    let trustAnyway: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
            SectionHeader(title: "cert.changed.title")

            // **Gold and not red.** Red means "broken"; this is not broken,
            // but ambiguous — and the ambiguity is the whole information.
            HintRow(
                icon: Glyph.warning.name, color: ColorRole.progress.color,
                title: "cert.changed.warn", message: "cert.changed.explain")

            FingerprintField(title: "cert.host", wording: query.host, isFixedWidth: false)
            FingerprintField(title: "cert.changed.known", wording: known.readable)
            FingerprintField(
                title: "cert.changed.presented", wording: query.fingerprint.readable)

            Button(action: cancel) {
                Text(app: "common.cancel").frame(maxWidth: .infinity)
            }
            .buttonStyle(.quiet)
            .padding(.horizontal, MetricsBoard.phone.margin)
            .padding(.top, MetricsBoard.phone.gutter)

            Button(action: trustAnyway) {
                Text(app: "cert.changed.anyway").frame(maxWidth: .infinity)
            }
            .buttonStyle(.quiet)
            .padding(.horizontal, MetricsBoard.phone.margin)

            Footnote(message: "cert.changed.footnote")
        }
        .padding(.vertical, MetricsBoard.phone.gutter)
    }
}
