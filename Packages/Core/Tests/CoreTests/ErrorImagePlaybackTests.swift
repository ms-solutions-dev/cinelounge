import Foundation
import Testing

@testable import Core

/// Which TV errors reveal their status — the half of
/// ``ErrorSummary`` that knows the remuxer.
@Suite("The status from playback errors")
struct ErrorImagePlaybackTests {

    /// A refusal by the provider is not a network question.
    @Test("The provider's refusal means access")
    func rejection() {
        #expect(
            ErrorSummary.key(forItem: LiveRemuxSession.SessionFailure.refused(status: 407))
                == "fehler.zugang")
        #expect(
            ErrorSummary.key(forItem: ByteRangeFailure.badStatus(503))
                == "fehler.serverstoerung")
    }

    @Test("A network error has no status, and neither does a foreign one")
    func withoutStatus() {
        struct Custom: Error {}
        #expect(ErrorSummary.httpStatus(of: URLError(.timedOut)) == nil)
        #expect(ErrorSummary.httpStatus(of: Custom()) == nil)
        #expect(ErrorSummary.key(forItem: URLError(.timedOut)) == "fehler.langsam")
    }
}
