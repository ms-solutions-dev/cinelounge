import Core
import DesignSystemPhone
import SwiftUI

/// Sheet: confirm fingerprint.
///
/// **The way there was built and ended in nothing.** `CertificateTrustStore.evaluate`
/// answers with `.askUser`, the connection delegate aborts and puts the question into the
/// mailbox (``CertificatePrompt``) — and on the phone nobody took it out. What arrived at the
/// viewer was "Server not reachable": a message that points in the wrong
/// direction, because the server is reachable and answers.
///
/// **On the home network this is the normal case and no exception.** A `.home` name carries a
/// self-issued certificate; without this screen a media server behind
/// HTTPS on the own network cannot be set up at all.
///
/// **In numbered groups of four, and that is the whole point.** A fingerprint in one
/// piece is not compared but looked at and tapped away — sixty-four characters
/// without structure cannot be held against a second screen by anyone. The groups come
/// from `CertificateFingerprint.readable` and are not rebuilt here.
///
/// **Trust is the quiet button.** The loud one would be the invitation to press it —
/// and that is the one place where nobody should be invited.
struct CertificateSheet: View {

    let query: CertificatePrompt.Pending
    let trust: () -> Void
    let reject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MetricsBoard.phone.gutter) {
            SectionHeader(title: "cert.title")

            Text(app: "cert.explain")
                .font(TypeLevel.footer.font)
                .foregroundStyle(ColorRole.textMatt.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, MetricsBoard.phone.margin)

            FingerprintField(title: "cert.host", wording: query.host, isFixedWidth: false)
            FingerprintField(
                title: "cert.fingerprint", wording: query.fingerprint.readable)

            Button(action: trust) {
                Text(app: "cert.trust").frame(maxWidth: .infinity)
            }
            .buttonStyle(.quiet)
            .padding(.horizontal, MetricsBoard.phone.margin)
            .padding(.top, MetricsBoard.phone.gutter)

            Button(action: reject) {
                Text(app: "common.cancel").frame(maxWidth: .infinity)
            }
            .buttonStyle(.quiet)
            .padding(.horizontal, MetricsBoard.phone.margin)

            Footnote(message: "cert.footnote")
        }
        .padding(.vertical, MetricsBoard.phone.gutter)
    }
}

/// A labeled row with a value that you compare.
///
/// **Monospaced type, and mandatory here.** When comparing two fingerprints
/// an `l` against a `1` and a `0` against an `O` decide; in a
/// proportional font the groups also do not line up one below the other, and then
/// you do not compare but guess.
///
/// **Selectable, because it gets retyped.** Whoever holds it against the server copies it —
/// a field that does not allow that forces copying sixty-four characters by hand.
struct FingerprintField: View {

    let title: String
    let wording: String
    var isFixedWidth = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(appKey: title)
                .font(TypeLevel.lowercased.font)
                .tracking(1.1)
                .textCase(.uppercase)
                .foregroundStyle(ColorRole.textQuiet.color)
            Text(verbatim: wording)
                .font(isFixedWidth ? TypeLevel.footer.font.monospaced() : TypeLevel.text.font)
                .foregroundStyle(ColorRole.text.color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.cardInset)
        .background(
            ColorRole.surface.color, in: RoundedRectangle(cornerRadius: MetricsBoard.phone.fieldRadius)
        )
        .edge()
        .padding(.horizontal, MetricsBoard.phone.margin)
        .accessibilityElement(children: .combine)
    }
}
