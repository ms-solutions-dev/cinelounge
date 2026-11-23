import Core
import DesignSystemPhone
import SwiftUI

/// Which certificates this device trusts.
///
/// **Revoking really removes something — and says what happens afterwards.** A "Revoke
/// trust" button that only deletes an entry and stays silent looks like a
/// lock: one does not dare to press it. It is none — on the next connect
/// the app asks for the fingerprint again, and until then the server stays
/// reachable. Exactly that stands beside it.
///
/// **Empty is the normal case.** A server with a valid certificate needs no entry
/// here; an empty list does not mean that anything is missing.
public struct CertificatesView: View {

    @State private var trusted: [(calculator: String, digest: CertificateFingerprint)] = []
    @State private var revoked: String?

    private let loading: CertificateTrustStore

    public init(loading: CertificateTrustStore = CertificateTrustStore()) {
        self.loading = loading
    }

    public var body: some View {
        ZStack {
            ColorRole.reason.color.ignoresSafeArea()

            ScrollSurface {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: "settings.certificates")

                    if trusted.isEmpty {
                        Footnote(message: "certs.empty")
                    } else {
                        ForEach(trusted, id: \.calculator) { entry in
                            row(entry)
                        }
                        Footnote(message: "certs.revokeText")
                            .padding(.top, MetricsBoard.phone.gutter)
                    }
                }
            }
        }
        .task { load() }
    }

    /// An entry: host name, fingerprint, revoke.
    ///
    /// **The digest is shown in numbered groups of four.** Nobody compares sixty-four characters in
    /// one piece; one that cannot be compared is a button with a text
    /// next to it. `CertificateFingerprint.readable` groups it — the same
    /// calculation as on the TV, and that is why the same string of characters stands there.
    private func row(
        _ entry: (calculator: String, digest: CertificateFingerprint)
    )
        -> some View
    {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: entry.calculator)
                .font(TypeLevel.text.font)
                .foregroundStyle(ColorRole.text.color)

            Text(verbatim: entry.digest.readable)
                .font(TypeLevel.label.font.monospaced())
                .foregroundStyle(ColorRole.textMatt.color)
                .textSelection(.enabled)

            Button {
                revoke(entry.calculator)
            } label: {
                Text(appKey: "certs.revoke")
                    .font(TypeLevel.footer.font)
                    .foregroundStyle(ColorRole.brandLight.color)
            }
            .textHitTarget()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, MetricsBoard.phone.margin)
        .padding(.vertical, MetricsBoard.phone.gutter)
    }

    private func load() {
        trusted = loading.trusted()
            .map { (calculator: $0.key, digest: $0.value) }
            .sorted { $0.calculator < $1.calculator }
    }

    private func revoke(_ calculator: String) {
        try? loading.forget(calculator)
        load()
    }
}
