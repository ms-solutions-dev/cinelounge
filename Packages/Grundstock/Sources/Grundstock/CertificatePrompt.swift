import Foundation

/// The certificate question that nobody asked.
///
/// **The finding** (AP5 · B4, expert review 2026-08-24): `cert.title`,
/// `cert.explain`, `cert.trust` and `cert.reject` exist translated in the
/// language file and are **used in no Swift file**. The viewer
/// reads "Dieser Server verwendet ein selbst ausgestelltes Zertifikat" — and
/// gets no button. In the home lab that is the normal case.
///
/// The path there was built and ended in nothing:
/// ``CertificateTrustStore/evaluate(_:for:)`` answers with `.askUser`, the
/// connection delegate aborts and writes "Bestätigung nötig" to the
/// log — and the UI learns nothing of it, because the error that
/// reaches it is only a `URLError`. The fingerprint is lost on the way.
///
/// **Hence this mailbox.** The delegate puts the question in, the
/// UI takes it out and asks it. A detour via the error would be
/// the wrong one: `URLError` has no field for it, and passing a custom error type
/// through three packages would mean touching every call site.
public final class CertificatePrompt: @unchecked Sendable {

    public static let shared = CertificatePrompt()

    /// What is to be confirmed.
    ///
    /// **`Identifiable` via host name and digest.** A sheet that hangs on a value
    /// needs an identifier, and the two together are it: the same host
    /// with a different digest is a **different** question — namely the one the
    /// whole procedure was built for. Taking only the host name would leave the sheet standing
    /// on a change and show the old digest for a new question.
    public struct Pending: Sendable, Equatable, Identifiable {

        public var id: String { host + ":" + fingerprint.value }

        public let host: String
        public let fingerprint: CertificateFingerprint
        /// The known fingerprint, if one has **changed**.
        ///
        /// **The difference is half the information:** An unknown
        /// certificate is the normal case on the home network; a **changed** one is
        /// the warning the whole procedure was built for.
        public let known: CertificateFingerprint?

        public init(
            host: String, fingerprint: CertificateFingerprint,
            known: CertificateFingerprint? = nil
        ) {
            self.host = host
            self.fingerprint = fingerprint
            self.known = known
        }
    }

    private let lock = NSLock()
    private var pending: Pending?

    /// Public since 2026-09-17 (StoryShelf, AP5): Whoever wants to test the question needs
    /// a mailbox of their own — tests run side by side, and a shared
    /// `shared` turns two tests into one that empties itself. In operation
    /// it stays with ``shared``: the guard puts into it there, the sheet takes out there.
    public init() {}

    /// Puts a question in — the latest one applies.
    public func location(_ query: Pending) {
        lock.lock()
        defer { lock.unlock() }
        pending = query
    }

    /// Takes the open question out, **without** consuming it.
    public var current: Pending? {
        lock.lock()
        defer { lock.unlock() }
        return pending
    }

    /// Answered — and empties the mailbox.
    ///
    /// **Only the question that was meant.** Between asking and
    /// answering a second one can arrive (two servers, two calls); whoever
    /// empties blindly then confirms the wrong certificate.
    public func answer(_ query: Pending) {
        lock.lock()
        defer { lock.unlock() }
        if pending == query { pending = nil }
    }

    /// Forgets everything — when leaving the screen.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        pending = nil
    }
}
