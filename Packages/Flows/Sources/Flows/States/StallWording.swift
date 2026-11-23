import Core

/// The one sentence of the "the picture is frozen" board per finding — **in one place for both
/// devices.**
///
/// Until 2026-09-26 the same mapping existed twice, on the TV in
/// `PlayerScreen.stillstandKey(_:)` and on the phone in `StallBoard.key(_:)`,
/// and both catalogs carried the five keys (report A, finding S5). The sentences now live
/// in the shared catalog.
///
/// **None promises an action that does not exist** (decision 12, "a sentence
/// without jargon"). With the silent provider "the app keeps trying" is true — the
/// session reconnects by itself; with a stalled cutter the app restarts nothing
/// in stage 2, and that is why it is not stated there. **Without a finding** — without an own remuxer
/// there are no counters — the indeterminate sentence applies.
public nonisolated enum StallWording {

    /// The key in the shared catalog.
    public static func key(_ finding: StallInterpretation.Finding?) -> String {
        switch finding {
        case .cutterStalled: "player.stillstandSchneider"
        case .sourceSilent: "player.stillstandQuelle"
        case .tooSlow: "player.stillstandLangsam"
        case .engineRefuses: "player.stillstandMotor"
        case .undetermined, nil: "player.stillstandUnbestimmt"
        }
    }

    /// **A tight line with a file** (AP69 on the TV, AP75 on the phone): the engine has
    /// measured that the provider delivers hardly more than the movie needs — then the
    /// picture is frozen not because of an error but because it is reloading. A finding of the own
    /// remuxer takes precedence; it is the more precise information. One rule for both devices.
    public static func lineTight(_ target: PlaybackTarget?, _ line: LineFinding?) -> Bool {
        guard let target else { return false }
        return target.kind != .live && target.decision.delivery == .directPlay && line?.tight == true
    }

    /// The key with regard to the line: without a finding, but with a tight line, the
    /// board says so — otherwise as ``key(_:)``.
    public static func key(
        _ finding: StallInterpretation.Finding?, target: PlaybackTarget?, line: LineFinding?
    ) -> String {
        if finding == nil, lineTight(target, line) { return "player.stillstandLeitungKnapp" }
        return key(finding)
    }
}
