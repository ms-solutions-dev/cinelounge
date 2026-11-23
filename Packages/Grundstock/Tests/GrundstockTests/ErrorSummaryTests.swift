import Foundation
import Testing

@testable import Grundstock

/// The sentence for the viewer — AP5 · B6.
///
/// **The finding:** on the TV, in 25 pt red, there appeared `badRequest`,
/// `badStatus(400)`, `Netzwerkfehler -999` and `containerNotNativelySupported`,
/// plus, twice, an `NSError` dump about 700 characters long with
/// memory addresses — under a label that promises "the cause in plain
/// language".
@Suite("The error in the viewer's language")
struct ErrorSummaryTests {

    /// **The direction is the information**, not the code: their network, the
    /// server or the provider.
    @Test("Network errors are sorted by their direction")
    func directions() {
        #expect(ErrorSummary.key(forItem: URLError(.notConnectedToInternet), status: nil) == "fehler.netz")
        #expect(ErrorSummary.key(forItem: URLError(.timedOut), status: nil) == "fehler.langsam")
        #expect(ErrorSummary.key(forItem: URLError(.cannotFindHost), status: nil) == "fehler.unerreichbar")
        #expect(
            ErrorSummary.key(forItem: URLError(.serverCertificateUntrusted), status: nil)
                == "fehler.zertifikat")
    }

    /// **And the developer instruction stays out.** For
    /// `appTransportSecurityRequiresSecureConnection`,
    /// ``Diagnostics/explain(_:)`` prints "Check: Is NSAllowsArbitraryLoads in the
    /// Info.plist …" — a sentence for the developer that ended up in the living room.
    @Test("The instruction to the developer does not appear in the living room")
    func noDeveloperInstruction() {
        let key = ErrorSummary.key(
            forItem: URLError(.appTransportSecurityRequiresSecureConnection), status: nil)

        #expect(key == "fehler.zertifikat")
        // The trace still gets the whole sentence — the two readers are
        // separate, not one swapped for the other.
        #expect(
            Diagnostics.explain(URLError(.appTransportSecurityRequiresSecureConnection))
                .contains("NSAllowsArbitraryLoads"))
    }

    /// A refusal by the server is not a network question — the status comes from outside.
    @Test("The server's refusal means access")
    func rejection() {
        struct Rejection: Error {}
        #expect(ErrorSummary.key(forItem: Rejection(), status: 407) == "fehler.zugang")
        #expect(ErrorSummary.key(forItem: Rejection(), status: 503) == "fehler.serverstoerung")
        #expect(ErrorSummary.key(forItem: Rejection(), status: 404) == "fehler.allgemein")
    }

    /// An unknown error gets a sentence and no dump.
    @Test("Unknown errors get a sentence")
    func unknown() {
        struct Custom: Error {}
        #expect(ErrorSummary.key(forItem: Custom(), status: nil) == "fehler.allgemein")
    }

    /// **The 700-character dump is shortened.** Nobody reads anything longer on the
    /// TV — and the whole line is in the trace anyway.
    @Test("The extra is cut to 200 characters")
    func addendumTruncated() {
        struct Long: Error, CustomStringConvertible {
            var description: String { String(repeating: "x", count: 700) }
        }
        let extras = ErrorSummary.extras(Long())

        #expect(extras != nil)
        #expect((extras?.count ?? 0) <= ErrorSummary.maxLength + 2)
    }

    /// And a short one stays whole.
    @Test("A short extra stays whole")
    func shortAddendum() {
        struct Short: Error, CustomStringConvertible {
            var description: String { "Short and readable" }
        }
        #expect(ErrorSummary.extras(Short()) == "Short and readable")
    }
}
