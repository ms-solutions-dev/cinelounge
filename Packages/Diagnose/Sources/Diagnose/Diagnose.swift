import Core
import Foundation

/// The facade — what is called from outside.
///
/// **Deliberately without `await`.** A `catch` should be able to write a line without
/// the surrounding function becoming `async` because of it. The entry travels in a separate
/// task into the ``ErrorLog``; the call site does not wait.
///
/// The price is stated here so that nobody has to look for it later: if the app is terminated in the same
/// second in which the line is created, it can be missing. For an error book that is
/// the right trade — the alternative would be an `await` at every call site, and
/// then half the places would write nothing at all.
///
/// Every entry **also** goes to `os.log` via `Core.Diagnostics`: whoever sits at the computer
/// does not want to read the file but `scripts/log.sh`. On the TV the
/// trace takes the place of the book — see ``LogRoute``.
public enum Diagnose {

    /// An ordinary step. Gets into the book only with verbose recording.
    public static func step(_ area: Area, _ message: @autoclosure () -> String) {
        note(area, .step, message())
    }

    /// Something conspicuous that has caused no damage.
    public static func hint(_ area: Area, _ message: String) {
        note(area, .hint, message)
    }

    /// Something did not work.
    public static func error(_ area: Area, _ message: String) {
        note(area, .error, message)
    }

    /// Something did not work and aborted something in the process.
    public static func abort(_ area: Area, _ message: String) {
        note(area, .abort, message)
    }

    /// A foreign service that delivers nothing — with its own description.
    ///
    /// **A note and not an error**, because a missing response from OMDb or
    /// AniList causes no damage: the screen then shows what the media server
    /// delivers anyway. Booked as `error`, the book would fill with red lines
    /// for the normal case — and red lines that are always there soon nobody reads anymore.
    public static func hint(_ area: Area, _ message: String, _ error: any Error) {
        note(area, .hint, "\(message): \(error.localizedDescription)")
    }

    /// The usual case in the `catch`: an error with its own description.
    ///
    /// The description of a foreign error is exactly the text in which an address
    /// can be stuck somewhere in the middle — ``Redaction`` catches it before it goes into the book.
    public static func error(_ area: Area, _ message: String, _ error: any Error) {
        note(area, .error, "\(message): \(error.localizedDescription)")
    }

    /// Switches verbose recording on for this device's path.
    ///
    /// On the phone the ``ErrorLog`` keeps its own measure and has to learn of it; on the
    /// TV the trace follows `DebugMode.current` anyway. Whoever flips the switch
    /// calls this and does not need to know which of the two cases applies.
    public static func setVerbose(_ isOn: Bool) {
        guard LogRoute.effective == .errorLog else { return }
        Task { await ErrorLog.shared.setVerbose(isOn) }
    }

    /// **Redaction happens once, and before BOTH outputs.**
    ///
    /// **The finding of 2026-09-07. (AP10), and it was no edge case:** ``ErrorLog/note(_:)``
    /// has always sent the sentence through ``Redaction`` — the **system log**, however,
    /// received it one line earlier **raw**, and explicitly with `privacy: .public`.
    /// Affected were, among others, the typed search term (`SearchViewModel`), the
    /// title name during playback (`PlayerModel`) and the server address from setup
    /// (`SetupModel`).
    ///
    /// **Why that is worse than it sounds.** The `os.log` does not live in the app: it
    /// goes into system memory, is sent along in a sysdiagnose bundle and can be
    /// read along in the console on a connected computer. The report that this app
    /// sends was clean — the path next to it was not, and nobody sees that.
    ///
    /// **The area marker stays `.public`, the sentence too — but only after
    /// redaction.** A `privacy: .private` would show `<private>` in the console and
    /// make the line worthless for troubleshooting, without protecting more than the
    /// redaction already does: whatever contains `://` or looks like a path never goes out
    /// in the first place.
    ///
    /// **The book still redacts by itself.** Redacting twice costs nothing — the
    /// rule is idempotent —, and ``ErrorLog`` is a shared actor:
    /// whoever addresses it past this point should not be unprotected.
    private static func note(_ area: Area, _ severity: Severity, _ message: String) {
        let clean = Redaction.sanitized(message)
        switch LogRoute.effective {
        case .errorLog:
            Task {
                await ErrorLog.shared.note(
                    ContentEntryRecord(area: area, severity: severity, message: clean))
            }
        case .trace:
            if let entry = LogRoute.traceEntry(
                area, severity, clean, verbose: DebugMode.current.isOn)
            {
                Task { @MainActor in Diagnostics.Trace.record(entry) }
            }
        }

        let logger = area == .playback ? Diagnostics.playback : Diagnostics.network
        if severity >= .error {
            logger.error("\(area.tag) \(clean, privacy: .public)")
        } else {
            logger.info("\(area.tag) \(clean, privacy: .public)")
        }
    }
}
