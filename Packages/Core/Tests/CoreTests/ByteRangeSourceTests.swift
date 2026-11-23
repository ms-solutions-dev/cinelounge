import Foundation
import Testing

@testable import Core

/// The length query over the network — and its second path.
///
/// **Why there is a second path** (on-device finding 2026-08-15, evening): Xtream panels
/// answer HEAD with `200` and `Content-Length: 0` — the true length is there only in
/// the `Content-Range` of a real partial request. A film whose length cannot be
/// determined does not play via the repackager at all; the whole evening hung on this
/// header line.
@Suite("Range requests: the total length")
struct ByteRangeSourceTests {

    @Test("The total length follows the slash")
    func totalComesAfterTheSlash() {
        #expect(
            HTTPByteRangeSource.totalLength(fromContentRange: "bytes 0-0/2573824552")
                == 2_573_824_552)
    }

    @Test("An asterisk means: the server does not know its own file")
    func starMeansUnknown() {
        #expect(HTTPByteRangeSource.totalLength(fromContentRange: "bytes 0-0/*") == nil)
    }

    @Test("Missing or garbled headers yield no length")
    func garbageYieldsNothing() {
        #expect(HTTPByteRangeSource.totalLength(fromContentRange: nil) == nil)
        #expect(HTTPByteRangeSource.totalLength(fromContentRange: "bytes 0-0") == nil)
        #expect(HTTPByteRangeSource.totalLength(fromContentRange: "bytes 0-0/0") == nil)
        #expect(HTTPByteRangeSource.totalLength(fromContentRange: "kartoffel") == nil)
    }
}

/// How often a dropped partial request is repeated — AP3 · V3a.
///
/// **The proof:** "Wombastic" failed with a `-1005`; "Gate 9" got the same error
/// twelve seconds later, its second attempt succeeded, and the film played. The
/// difference between "works" and "does not work" was a single connection drop — with
/// exactly one retry the second drop is the end again.
@Suite("The retry after a dropped connection")
struct RetryTests {

    /// **A drop is not a refusal.** The distinction is the whole reason retrying is
    /// allowed at all: Anyone who keeps asking after a refusal runs into the panel's IP
    /// throttle.
    @Test("Only dropped connections are retried")
    func onlyDisconnects() {
        // −1005: connection lost. −1001: timeout.
        #expect(HTTPByteRangeSource.isWorthRetrying(NSError(domain: "x", code: -1005)))
        #expect(HTTPByteRangeSource.isWorthRetrying(NSError(domain: "x", code: -1001)))
        // −999 is the abort by ourselves, 403 the provider's refusal.
        #expect(!HTTPByteRangeSource.isWorthRetrying(NSError(domain: "x", code: -999)))
        #expect(!HTTPByteRangeSource.isWorthRetrying(ByteRangeFailure.badStatus(403)))
    }

    /// Three attempts, not two — and not arbitrarily many.
    @Test("Three attempts, and the pause grows")
    func threeAttempts() {
        #expect(HTTPByteRangeSource.maximumAttempts == 3)
        #expect(HTTPByteRangeSource.pause(beforeAttempt: 2) == 0.12)
        #expect(abs(HTTPByteRangeSource.pause(beforeAttempt: 3) - 0.36) < 0.0001)
    }

    /// **And all pauses together stay under half a second.** That is the condition under
    /// which a retry is free at all: What takes longer, the viewer sees as a stall.
    @Test("The pauses together stay under half a second")
    func pausesStayShort() {
        let total = (2...HTTPByteRangeSource.maximumAttempts)
            .map { HTTPByteRangeSource.pause(beforeAttempt: $0) }
            .reduce(0, +)
        #expect(total < 0.5)
    }
}
