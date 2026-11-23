import Foundation
import Testing

@testable import Grundstock

/// **A cancellation is not an error** — CineLounge on-device test build 1332, finding 12: in the always
/// kept error log there were "Fetch ratings ✗ Network error -999" seven times per
/// scroll and "Portal request unreachable: Network error -999".
@Suite("Cancellations in the log")
struct CancellationTests {

    @Test("What counts as a cancellation: -999, CancellationError, and the same as NSError")
    func detection() {
        #expect(Diagnostics.isCancellation(URLError(.cancelled)))
        #expect(Diagnostics.isCancellation(CancellationError()))
        #expect(Diagnostics.isCancellation(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
        #expect(!Diagnostics.isCancellation(URLError(.timedOut)))
        #expect(!Diagnostics.isCancellation(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
    }

    /// **Checked against the shared trace this would be a race** with the other suites that
    /// empty it; the decision is therefore a calculation. The control run against the old
    /// code went through ``Diagnostics/failure(_:step:error:)`` and the trace itself.
    @Test("A cancelled request leaves no failure — a real one does")
    func traceOutcome() {
        #expect(Diagnostics.traceOutcome(forItem: URLError(.cancelled), recording: false) == nil)
        #expect(
            Diagnostics.traceOutcome(forItem: URLError(.cancelled), recording: true)
                == .succeeded("cancelled"))
        guard
            case .failed(let reason)? = Diagnostics.traceOutcome(
                forItem: URLError(.timedOut), recording: false)
        else {
            Issue.record("Timeout without a failure")
            return
        }
        #expect(reason.hasPrefix("Timeout"))
    }

    @Test("A defect with an error: cancelled gives no entry, otherwise one with a translated cause")
    func defectMessage() {
        #expect(Diagnostics.defectMessage("Portal request unreachable", error: URLError(.cancelled)) == nil)
        #expect(
            Diagnostics.defectMessage("Portal request unreachable", error: URLError(.timedOut))?
                .hasPrefix("Portal request unreachable: Timeout") == true)
    }

    @Test("The translation names -999 instead of “Network error -999”")
    func explanation() {
        #expect(Diagnostics.explain(URLError(.cancelled)).hasPrefix("Cancelled (-999)"))
    }
}
