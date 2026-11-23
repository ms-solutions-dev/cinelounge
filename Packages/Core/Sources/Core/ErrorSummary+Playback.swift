import Foundation

/// Which of the TV's errors carry a response status — the remuxer's rejection
/// and the failed range request.
///
/// **The cut** (Grundstock, 2026-09-17): the translation into a sentence for
/// the viewer lives in the foundation; what a `SessionFailure` is, only `Core` knows.
/// So this version reads out the status and passes it on.
extension ErrorSummary {

    /// The language key for an error — with the status that the
    /// TV's playback errors know.
    public static func key(forItem error: Error) -> String {
        key(forItem: error, status: httpStatus(of: error))
    }

    /// The response status, if the error carries one.
    static func httpStatus(of error: Error) -> Int? {
        switch error {
        case let rejection as LiveRemuxSession.SessionFailure:
            if case .refused(let status) = rejection { return status }
            return nil
        case let area as ByteRangeFailure:
            if case .badStatus(let status) = area { return status }
            return nil
        default:
            return nil
        }
    }
}
