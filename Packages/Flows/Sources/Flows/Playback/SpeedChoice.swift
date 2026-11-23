import Core
import Foundation

/// The playback speed — **the same steps on both devices** (AP58 G1, A6).
///
/// On the TV a choice in the track board (AP31), on the phone until then only the long
/// press for double speed. Now both carry the steps in the track choice; the phone's
/// gesture stays in addition.
nonisolated public enum SpeedChoice {

    /// The speed steps that are up for choice.
    ///
    /// **Six and not ten.** On the TV every step costs a press; whoever offers 1.1x
    /// answers no question. The steps are those for which there are reasons:
    /// slower for a hard-to-understand passage, faster for an intro one already
    /// knows. **Without 0.25 and without 3** — below half, speech becomes unintelligible,
    /// above that too, and the system's pitch correction holds only in between.
    public static let slots: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    /// The speed while the phone's hold gesture is pressed.
    public static let holdSpeed: Double = 2

    /// Whether the speed is offered at all.
    ///
    /// **The information about the engine comes from the engine** (``Core/PlaybackController/supportsSpeed``).
    /// **And never for a channel:** faster there means a run toward the live edge, after
    /// which the stream stalls. Until AP58 G1 the TV also offered the steps for a channel.
    public static func isOffered(supportsSpeed: Bool, kind: PlaybackTarget.Kind) -> Bool {
        supportsSpeed && kind != .live
    }

    /// The speed after a title change.
    ///
    /// **It applies to this title and not to the next** — a speed that carries over silently
    /// is a switch nobody flipped deliberately and nobody finds again.
    public static func afterSwitch(_ rate: Double, sameTitle: Bool) -> Double {
        sameTitle ? rate : 1
    }

    /// The speed after releasing the hold gesture — **the chosen one, not 1.**
    ///
    /// Whoever chose 1.5x and briefly holds for double wants 1.5 again afterwards.
    public static func afterHold(chosen: Double) -> Double { chosen }

    /// The label of a step — "1.5×", in the number notation of the language.
    public static func caption(_ tier: Double) -> String {
        tier.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
}
