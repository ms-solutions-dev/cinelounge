import Core
import Foundation

/// Where a line of the ``Diagnose`` goes besides `os.log` — **one answer per device.**
///
/// **Why there are two paths and not one** (AP58 R0, finding X0). The phone keeps
/// its lines in the ``ErrorLog`` on disk, because there termination
/// is the normal case. The TV has no error book: its report and its error trace have
/// always read the ring buffer `Diagnostics.Trace`, and `TraceRecorder` already puts its errors
/// on disk. A second book on the TV would be a second truth next to the one
/// its report shows.
///
/// **Shared logic does not ask which device it runs on.** It calls
/// `Diagnose.error(…)`, and this board decides — so a line from
/// `Flows` ends up in the book on the phone and in the report on the TV, without any call site
/// writing `#if os(tvOS)`.
public enum LogRoute: Sendable, Equatable {

    /// Into the ``ErrorLog`` — the phone.
    case errorLog

    /// Into the ring buffer `Diagnostics.Trace` — the TV.
    case trace

    /// The path of the running program.
    ///
    /// A translation-time decision and not a switch: which device it is does not change
    /// at runtime, and a switch would have to be set by someone — one
    /// forgotten call at startup, and the phone's book would stay empty.
    public static var effective: LogRoute {
        #if os(tvOS)
            .trace
        #else
            .errorLog
        #endif
    }

    /// The trace entry for a line — or `nil` if it does not belong in.
    ///
    /// **The same rule as in the book** (``Severity/belongsInLog(verbose:)``):
    /// notes and errors always, ordinary steps only with verbose recording.
    /// Otherwise the TV's report would show something different from the phone's book, for
    /// the same line from the same shared flow.
    ///
    /// Errors and aborts come in as `.failed`: only that way do they also end up in the
    /// error trace on disk, which runs along without a switch.
    public static func traceEntry(
        _ area: Area,
        _ severity: Severity,
        _ message: String,
        verbose: Bool,
        timestamp: Date = .now
    ) -> Diagnostics.Trace.Entry? {
        guard severity.belongsInLog(verbose: verbose) else { return nil }
        let tag = area.tag.trimmingCharacters(in: .whitespaces)
        return Diagnostics.Trace.Entry(
            at: timestamp,
            step: tag,
            target: severity >= .error ? "" : message,
            outcome: severity >= .error ? .failed(message) : .succeeded(""))
    }
}
