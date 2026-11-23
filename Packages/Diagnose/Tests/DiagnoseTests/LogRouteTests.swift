import Core
import Foundation
import Testing

@testable import Diagnose

/// The path of a line on the TV — **the same rule as in the phone's book.**
@Suite("Log route")
struct LogRouteTests {

    /// `swift test` runs on the computer, and that is not a TV. The branch for
    /// tvOS is compiled only in the full run; what is checked here is that the computer does not
    /// accidentally fall onto the TV path and the book tests alongside
    /// go nowhere.
    @Test("On the computer the error log applies")
    func computerWritesToLog() {
        #expect(LogRoute.effective == .errorLog)
    }

    @Test("An ordinary step reaches the trace only with verbose recording")
    func stepOnlyVerbose() {
        #expect(LogRoute.traceEntry(.network, .step, "Fetch", verbose: false) == nil)
        let entry = LogRoute.traceEntry(.network, .step, "Fetch", verbose: true)
        #expect(entry?.target == "Fetch")
        #expect(entry?.outcome == .succeeded(""))
    }

    /// A note is no damage, but it belongs in the book — so also in the trace.
    @Test("Hints are always in the trace, as a success")
    func noticeAlways() {
        let entry = LogRoute.traceEntry(
            .surface, .hint, "OMDb is silent", verbose: false)
        #expect(entry?.outcome == .succeeded(""))
        #expect(entry?.target == "OMDb is silent")
    }

    /// Only a `.failed` ends up in the error trace on disk, which runs along
    /// without a switch — an error booked as a success would be missing from the TV's report.
    @Test("Errors and aborts enter as a failure, with the area as the step")
    func errorAsFailure() {
        let error = LogRoute.traceEntry(
            .login, .error, "Access denied", verbose: false)
        #expect(error?.outcome == .failed("Access denied"))
        #expect(error?.step == "ANM")
        #expect(error?.target == "")

        let abort = LogRoute.traceEntry(
            .playback, .abort, "Engine gone", verbose: true)
        #expect(abort?.outcome == .failed("Engine gone"))
        #expect(abort?.step == "SPIEL")
    }
}
