import Foundation
import Testing

@testable import Grundstock

/// Trust on first use — the same procedure as with SSH.
///
/// The difference to "accept all certificates" is the whole point: anyone on the
/// same network could otherwise slip in unnoticed. That is why
/// these cases mainly check that a **changed** certificate does not
/// pass silently.
@Suite("Certificate trust")
struct CertificateTrustTests {

    static func store() -> CertificateTrustStore {
        // Volatile store: access to the real Keychain makes the
        // test run hang on the machine, because an approval is expected there.
        CertificateTrustStore(store: InMemoryStore())
    }

    static func fingerprint(_ seed: String) -> CertificateFingerprint {
        CertificateFingerprint(certificateData: Data(seed.utf8))
    }

    @Test("An unknown certificate is not accepted but asked about")
    func unknownAsksUser() throws {
        let trust = Self.store()
        let fp = Self.fingerprint("certificate-a")

        #expect(trust.evaluate(fp, for: "new.example") == .askUser(fp))
    }

    @Test("After confirmation the same certificate is accepted")
    func confirmedIsAccepted() throws {
        let trust = Self.store()
        let fp = Self.fingerprint("certificate-b")

        try trust.trust(fp, for: "known.example")

        #expect(trust.evaluate(fp, for: "known.example") == .accept)
    }

    @Test("A changed certificate is reported, not accepted")
    func changedIsReported() throws {
        // The serious case: either it was renewed, or someone is slipping in
        // between. Both must be noticed.
        let trust = Self.store()
        let original = Self.fingerprint("certificate-c")
        let impostor = Self.fingerprint("certificate-fremd")

        try trust.trust(original, for: "changed.example")
        let verdict = trust.evaluate(impostor, for: "changed.example")

        #expect(verdict == .changed(known: original, presented: impostor))
        #expect(verdict != .accept, "must never pass silently")
    }

    @Test("Trust applies per server, not across the board")
    func trustIsPerHost() throws {
        // Otherwise a one-time confirmation would cover every further server
        // — exactly the barn door that is to be avoided.
        let trust = Self.store()
        let fp = Self.fingerprint("certificate-d")

        try trust.trust(fp, for: "one.example")

        #expect(trust.evaluate(fp, for: "other.example") == .askUser(fp))
    }

    @Test("The case of the server name does not matter")
    func hostIsCaseInsensitive() throws {
        let trust = Self.store()
        let fp = Self.fingerprint("certificate-e")

        try trust.trust(fp, for: "Media.Example")

        #expect(trust.evaluate(fp, for: "media.example") == .accept)
    }

    @Test("Forgetting withdraws the trust again")
    func forgetting() throws {
        let trust = Self.store()
        let fp = Self.fingerprint("certificate-f")

        try trust.trust(fp, for: "temp.example")
        #expect(trust.evaluate(fp, for: "temp.example") == .accept)

        try trust.forget("temp.example")
        #expect(trust.evaluate(fp, for: "temp.example") == .askUser(fp))
    }

    // MARK: - Darstellung

    @Test("The fingerprint is made readable in groups of four")
    func readableGrouping() {
        // On the TV one must be able to compare it with what is on the
        // computer — in one piece that is hopeless.
        let fp = CertificateFingerprint(value: "ABCDEF0123456789")

        #expect(fp.readable == "ABCD EF01 2345 6789")
        #expect(fp.short == "ABCD EF01 2345 6789 …")
    }

    @Test("Equal data gives the same fingerprint, other data a different one")
    func deterministic() {
        #expect(Self.fingerprint("same") == Self.fingerprint("same"))
        #expect(Self.fingerprint("same") != Self.fingerprint("different"))
    }

    @Test("The fingerprint has the length of a SHA-256 checksum")
    func length() {
        // 32 Byte, hexadezimal also 64 Zeichen.
        #expect(Self.fingerprint("arbitrary").value.count == 64)
    }

    @Test("Case is normalized")
    func normalizesCase() {
        #expect(CertificateFingerprint(value: "abcdef").value == "ABCDEF")
    }
}
