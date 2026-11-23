import Foundation
import OSLog
import Synchronization

/// The focus trace — remote, focus changes, commands. Knows the Siri Remote
/// and therefore does not belong in the foundation (`Grundstock`) but here.
extension Diagnostics {

    // MARK: - The focus trace

    /// Where the cursor is, and what moved it.
    ///
    /// **The reason for a trace of its own is a pattern that can otherwise only be seen
    /// by splitting the picture into individual frames** (user suggestion 2026-08-12):
    ///
    /// ```
    /// [Key]  Detailseite  ↓
    /// [Focus]  Detailseite  play → season-s2        (+12 ms)
    /// [Focus]  Detailseite  season-s2 → season-s6   (+4 ms)
    /// ```
    ///
    /// **One press, two focus lines close together — that is a
    /// correction**, and exactly that is what the viewer sees as a flash. The
    /// pattern is unambiguous enough to search for: it finds not the one
    /// spot where someone looked, but all of them. It is evaluated
    /// by `scripts/focus_trace.py`.
    ///
    /// No switch in the system log — a focus change comes once per key press
    /// and drowns nothing. It goes into the trace on the TV only
    /// with verbose recording, otherwise it would crowd out the network errors there.
    public static let cursor = Logger(
        subsystem: AppBundleIdentifiers.bundles,
        category: "focus"
    )

    /// When something was last in the focus trace — for the interval, which is the
    /// actual information.
    private static let lastCursorEvent = Mutex(Date())

    /// When focus last **changed** — separate from the key cadence.
    ///
    /// The interval between two changes gives how long the element that was left
    /// held focus. Exactly this number separates a real step
    /// (focus rested for hundreds of milliseconds) from a phantom jump that
    /// hops on after milliseconds — on screen both are long gone,
    /// in the trace they stay distinguishable.
    private static let lastFocusChange = Mutex(Date())

    /// Records a focus change.
    ///
    /// `area` is the area in which the focus lives ("Detailseite",
    /// "Seitenleiste") — without it the identifiers of two views would sit
    /// side by side, and nobody would know which belongs where.
    // MARK: The key log
    //
    // **One press, one line — and every effect names its press** (requirement
    // 2026-09-04, F-008: key press and focus must coincide, so that
    // phantom clicks become visible). The press itself comes from UIKit
    // (``keyPressed(_:)``, one `UIPress` per press), command and focus change
    // measure their interval to it. What happens without a press says so: "no
    // key" — that is the view, not the viewer.

    private struct Press: Sendable {
        let key: String
        let at: Date
    }

    private static let lastPress = Mutex<Press?>(nil)

    /// How long after a press an effect still counts as its own.
    public static let pressWindow: TimeInterval = 0.4

    /// A press on the remote — the one source of truth.
    public static func keyPressed(_ key: String) {
        let now = Date()
        lastPress.withLock { $0 = Press(key: key, at: now) }
        let gap = spacing(lastCursorEvent, until: now)
        cursor.info("[Key] Remote  \(key, privacy: .public)  (+\(gap, privacy: .public) ms)")
        guard DebugMode.current.isOn else { return }
        let entry = Trace.Entry(
            at: now, step: "Key", target: "Remote", outcome: .succeeded("\(key)  +\(gap) ms"))
        Task { @MainActor in Trace.record(entry) }
    }

    /// "+37 ms after ↑" — or "no key" if no press lies within the window.
    static func sincePress(_ now: Date) -> String {
        let press = lastPress.withLock { $0 }
        guard let press, now >= press.at, now.timeIntervalSince(press.at) <= pressWindow else {
            return "no key"
        }
        return "+\(Int((now.timeIntervalSince(press.at) * 1000).rounded())) ms after \(press.key)"
    }

    public static func cursorMoved(_ area: String, from previous: String?, to current: String?) {
        let now = Date()
        let gap = spacing(lastCursorEvent, until: now)
        let dwell = spacing(lastFocusChange, until: now)
        let reference = sincePress(now)
        cursor.info(
            "[Focus] \(area, privacy: .public)  \(previous ?? "—", privacy: .public) → \(current ?? "—", privacy: .public)  (+\(gap, privacy: .public) ms, dwelled \(dwell, privacy: .public) ms, \(reference, privacy: .public))"
        )
        guard DebugMode.current.isOn else { return }
        let entry = Trace.Entry(
            at: now,
            step: "Focus",
            target: area,
            outcome: .succeeded(
                "\(previous ?? "—") → \(current ?? "—")  \(reference), dwelled \(dwell) ms")
        )
        Task { @MainActor in Trace.record(entry) }
    }

    /// A command that arrived in a view (`onMoveCommand`, a catcher,
    /// a correction) — with its interval to the press.
    public static func cursorKey(_ area: String, _ key: String) {
        let now = Date()
        let gap = spacing(lastCursorEvent, until: now)
        let reference = sincePress(now)
        cursor.info(
            "[Command] \(area, privacy: .public)  \(key, privacy: .public)  (+\(gap, privacy: .public) ms, \(reference, privacy: .public))"
        )
        guard DebugMode.current.isOn else { return }
        let entry = Trace.Entry(
            at: now,
            step: "Command",
            target: area,
            outcome: .succeeded("\(key)  \(reference)")
        )
        Task { @MainActor in Trace.record(entry) }
    }

    /// Resets the timestamp and returns the interval to the previous one in
    /// milliseconds.
    ///
    /// **A hand-written lock stood here** (AP15, 2026-09-02): a
    /// class with `NSLock`, `@unchecked Sendable` and a `value` that only
    /// the convention protected, never to touch it outside the lock.
    /// `Mutex` has existed since tvOS 18 — exactly our lower bound —, is
    /// `Sendable` by itself, and the protected state is **reachable only inside
    /// `withLock`**. An assurance becomes a
    /// compiler check.
    ///
    /// **The large remuxers deliberately stay with `NSLock`:** there one
    /// lock protects several related fields; that could be modeled with a single
    /// `Mutex` only through a state aggregate.
    private static func spacing(_ clock: borrowing Mutex<Date>, until fresh: Date) -> Int {
        clock.withLock { value in
            let gap = fresh.timeIntervalSince(value)
            value = fresh
            return Int((gap * 1000).rounded())
        }
    }
}
