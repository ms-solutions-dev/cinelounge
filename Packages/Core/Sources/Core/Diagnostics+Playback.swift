import Foundation
import OSLog

/// The playback side of the diagnostics — what ``Diagnostics`` in `Grundstock`
/// must not know, because there is no film there.
///
/// **The cut** (Grundstock, 2026-09-17): the trace itself, the ring buffer and
/// the profile sheet live in the foundation. Here are only the names under which the
/// TV and the phone have always called them — `playbackStep`,
/// `playbackProblem`, `reportHeader()` — and the two lines in the profile sheet that
/// name engine and decoder. The call sites in remuxers, players and
/// probes stay untouched.
extension Diagnostics {

    /// The course of a playback — a trace of its own, not with the network calls.
    ///
    /// **Why separate:** a playback rarely fails with an error. It
    /// fails by something not happening — a state that does not arrive, a
    /// seek that expires, a buffer that does not fill. Such things can only be recognised by
    /// **order and intervals**, and these get lost between
    /// server calls. Together in the same trace, the sequence reads like
    /// a log; scattered, it is unreadable.
    public static var playback: Logger { flow }

    /// Records a step of the playback, with the time since loading.
    ///
    /// The time is the actual information here and not an extra: that a seek
    /// went out 0.6 seconds after loading was the whole error — the message
    /// alone showed nothing, only the interval to the line above it.
    public static func playbackStep(_ stepName: String, since start: Date?) {
        step(stepName, since: start, area: "Wiedergabe")
    }

    /// Like ``playbackStep(_:since:)``, but as an error — so that it is visible without `--info`.
    ///
    /// The difference matters in practice: `log show` shows only
    /// errors without further action. An anomaly stored as `info` is found only by whoever
    /// is already looking for it.
    public static func playbackProblem(_ step: String, since start: Date?) {
        defect(step, since: start, area: "Wiedergabe")
    }

    /// Records a step only with verbose recording — as a
    /// playback step. Reasoning at ``verbose(_:since:area:)``.
    public static func verbose(_ step: @autoclosure () -> String, since start: Date? = nil) {
        guard DebugMode.current.isOn else { return }
        playbackStep(step(), since: start)
    }

    /// The two lines in the profile sheet that only the TV knows.
    ///
    /// **The switches belong in the header** (F-009, 2026-09-03): the viewer
    /// switched engine and decoder between two channels, and which finding belonged to
    /// which state could only be reconstructed from the switch lines in
    /// between.
    static var playbackLines: [String] {
        [
            "Live engine: \(LiveEngineChoice.load(from: SecureStore()).rawValue), "
                + "own decoder: \(HardwareVideoDecoder.enabled ? "on" : "off")",
            "iCloud environment: \(icloudEnvironment ?? "unknown")",
        ]
    }

    /// The CloudKit environment of this build — set when the cloud is connected.
    ///
    /// **In the header because it has to be the same on both devices** (2026-09-28): the
    /// TV from the cable talked to "Development", the phone from TestFlight to
    /// "Production", and no report said so — a profile share simply arrived empty.
    nonisolated(unsafe) public static var icloudEnvironment: String?

    /// The profile sheet including engine and decoder — see ``reportHeader(extras:)``.
    public static func reportHeader() -> [String] {
        reportHeader(extras: playbackLines)
    }

    /// The state marker including engine and decoder — see ``noteLaunch(extras:)``.
    public static func noteLaunch() {
        noteLaunch(extras: playbackLines)
    }
}
