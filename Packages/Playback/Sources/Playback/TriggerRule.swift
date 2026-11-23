import Foundation

/// **When the engine kicks the clock itself instead of waiting for AVPlayer's estimate**
/// (AP69, 2026-10-11).
///
/// Diagnostics F-051/F-017 and the probe on the Mac (`diagnose/BEFUNDE-2026-10-11-motor.md`
/// §1.1): iptvhost delivered 0.5 MB/s, the episode needed 0.5 MB/s at the start. The buffer grew
/// only 0.95 s per second, `isPlaybackLikelyToKeepUp` stayed false, and
/// `automaticallyWaitsToMinimizeStalling` waited **without limit** — 50 s on the TV with
/// a frozen picture, in the probe not yet even at 41 s of buffer. With a buffer, the clock only
/// started at 34 s, when the 30 s buffer target was full.
///
/// **The rule is deliberately small:** only files (with HLS and Live AVPlayer is supposed to
/// be allowed to judge the level), only if after readiness it is really waiting, only with a few
/// seconds of look-ahead, and only **once per startup** — after that the stall protection stays on and
/// buffers as usual if the line does not carry after all. Better to buffer briefly than not
/// to play at all.
///
/// **A jump is a new startup** (on-device test 2026-10-11 evening, sample film): After
/// fast-forwarding AVPlayer faced the same empty buffer as at the start and again waited
/// without limit — but the help was used up, and after twelve seconds the board
/// "Connection to the provider tight" came instead of the film. Counting is therefore done since the last
/// jump, not since readiness (``readySince(ready:jump:now:)``).
enum TriggerRule {
    /// This long AVPlayer may estimate after readiness before it is helped along.
    static let minimumWaitTime: TimeInterval = 2
    /// This much material must be there — two seconds below that would be an immediate stall.
    static let minimumLeadTime: TimeInterval = 3

    /// - Parameters:
    ///   - bereitSeit: Seconds since `readyToPlay`; `nil` as long as the item is not ready.
    ///   - vorlauf: Seconds of material before the current position, `nil` without a loaded range.
    ///   - wartet: whether AVPlayer is currently waiting (`timeControlStatus == .waitingToPlayAtSpecifiedRate`).
    ///   - istDatei: whether the target is a file (``NativePlaybackEngine/isFile(_:)``).
    ///   - schonAngestossen: whether this help has already been given for this target.
    static func shouldTrigger(
        readySince: TimeInterval?, leadTime: TimeInterval?, waiting: Bool, isFile: Bool,
        alreadyTriggered: Bool
    ) -> Bool {
        guard isFile, waiting, !alreadyTriggered, let readySince, let leadTime else { return false }
        return readySince >= minimumWaitTime && leadTime >= minimumLeadTime
    }

    /// Since when AVPlayer may estimate: since readiness — or since the last
    /// jump, if that came later. `nil` as long as the item is not ready.
    static func readySince(ready: Date?, jump: Date?, now: Date = Date()) -> TimeInterval? {
        guard let ready else { return nil }
        let startup = jump.map { max($0, ready) } ?? ready
        return now.timeIntervalSince(startup)
    }

    /// The line for the diagnostics while the clock is stopped — the same one that the probe had to
    /// deliver on 2026-10-11 because the report did not have it.
    static func row(
        readySince: TimeInterval?, leadTime: TimeInterval?, waitReason: String?, carries: Bool,
        full: Bool
    ) -> String {
        let ready = readySince.map { String(format: "ready for %.0f s", $0) } ?? "not ready"
        let material = leadTime.map { String(format: "%.1f s lead", $0) } ?? "nothing loaded"
        let reason = waitReason?.replacingOccurrences(of: "AVPlayerWaiting", with: "") ?? "—"
        return "Clock stands: \(ready), \(material), reason \(reason), carries \(carries ? "yes" : "no")"
            + (full ? ", buffer full" : "")
    }
}
