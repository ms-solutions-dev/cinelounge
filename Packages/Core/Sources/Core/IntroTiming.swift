import Foundation

/// **When the intro comes: on every cold start** — as with Netflix (on-device test build 1332,
/// 2026-09-27) — and whether it comes at all.
///
/// **Cold start means: a new process.** Anyone who quits the app in the app switcher and reopens
/// it sees the clip; anyone returning from the background does not. This computation
/// does not hold that, but the lifetime of the decided value at the caller (a
/// static flag on the intro stage of both apps) — cold start and process start are
/// the same event.
///
/// **Until build 1332 the clip came only once per calendar day** (AP51, flag in the
/// default store). On the phone, which shows nothing at all without a due clip, that looked like
/// "the intro never comes again". The daily flag was therefore dropped, not moved.
public enum IntroTiming {

    /// What lies over the first view at start.
    public enum Kind: Equatable, Sendable {
        /// Nothing — straight to the target view.
        case none
        /// The fallback still frame (stage 1).
        case stillFrame
        /// The clip (stage 2).
        case clip
    }

    /// What is shown at this cold start.
    ///
    /// **VoiceOver beats everything**: For someone who does not see the picture, five
    /// seconds of clip are pure waiting time, and the first focus target is announced only afterwards.
    /// **"Reduce Motion"** gets the still frame — the same rule as at the
    /// `Streifen` in the DesignSystem: Nothing moves. **No clip in the bundle** likewise
    /// yields the still frame: That is stage 1, the start without black.
    public static func kind(voiceOver: Bool, reduceMotion: Bool, hasClip: Bool) -> Kind {
        if voiceOver { return .none }
        if reduceMotion || !hasClip { return .stillFrame }
        return .clip
    }

    /// **How long the intro fades out** when the cap opens (on-device test build 1332:
    /// the intro ended abruptly as soon as the figure was gone).
    ///
    /// **Opened by itself** (deadline or target view ready) it fades out over just under a
    /// second: The cards already lie underneath at `cardsAt`, the figure leaves the
    /// picture at `exitAt`, and the empty set still fades out instead of cutting off with it.
    /// **Skipped** it stays short — whoever taps wants it gone.
    public static func fadeOut(after reason: IntroCover.Reason) -> Double {
        reason == .skipped ? 0.3 : 0.9
    }
}
