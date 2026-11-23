import Foundation

/// Decides which frame rate is registered with the TV — and above all **when not any
/// more**.
///
/// **The finding** (AP2 · U5, expert review 2026-08-24): "The Kretfi Norern", 61 seconds, **46
/// registrations** between 23.976 / 24.0 / 25.0. The previous rule "two equal ticks"
/// prevents outliers but not oscillation: Two values that alternately repeat twice each both
/// get through. Harmless today, because the adjustment on the TV is off — after U2 that would
/// be 46 mode switches in a minute, each with an HDMI negotiation and a black screen.
///
/// **Three rules, and each catches a different case.**
///
/// 1. **The same mode is not registered twice.** 23.976 and 24.0 are the same output for the
///    TV; switching it in between costs a black screen and changes nothing.
/// 2. **A better source is always allowed.** The player's estimate is "half the truth" at
///    startup (on-device finding 2026-08-22: 24 Hz measured on a 50 Hz channel). If a counted
///    number arrives later, it must be able to overthrow the estimate — otherwise the TV
///    would stay on the error.
/// 3. **A source of equal rank may correct exactly once.** That is the per-element lock that
///    was missing against oscillation. It is the generalization of what the source already
///    wanted ("the first registration may have been off at startup") — only with a limit.
public struct FrameRateRegistration: Sendable, Equatable {

    /// Where a frame rate comes from — the higher, the more reliable.
    public enum Source: Int, Sendable, Comparable {
        /// The player has queried its own render rate. Often wrong at startup.
        case estimated = 0
        /// From the container header (`DefaultDuration`) — a claim of the file, not of the stream.
        case header = 1
        /// From counted frame intervals of the real stream.
        case measured = 2

        public static func < (left: Source, right: Source) -> Bool {
            left.rawValue < right.rawValue
        }
    }

    /// The rates a TV knows.
    public static let standardRates: [Float] = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60]

    /// How far off a measurement may be and still count as a standard rate.
    public static let maxInterval: Float = 1

    /// The standard rate for a measured number — or `nil`.
    ///
    /// **No number is better than a wrong one.** Three times 58.82 Hz was registered (1000/17,
    /// the millisecond resolution of the remuxer on a 59.94 Hz channel) — a frame rate that does
    /// not exist.
    public static func standardRate(forItem value: Double) -> Float? {
        let target = Float(value)
        guard let nearest = standardRates.min(by: { abs($0 - target) < abs($1 - target) }),
            abs(nearest - target) <= maxInterval
        else { return nil }
        return nearest
    }

    /// Whether two rates are the same output for the TV.
    ///
    /// 23.976 and 24.0 differ by a thousandth — the same refresh rate, the same HDMI negotiation.
    /// The same holds for 29.97/30 and 59.94/60.
    public static func sameMode(_ left: Float, _ right: Float) -> Bool {
        abs(left - right) < 0.5
    }

    /// Whether the TV's output fits this rate **without** switching.
    ///
    /// A TV is set to 60 Hz out of the box. If the frame rate divides this number evenly, every
    /// frame is shown equally often and nobody sees anything: 30 Hz → each twice, 60 Hz → each
    /// once. If it does not divide, the uneven cadence arises that a viewer described on 2026-08-23.
    /// (the picture felt dragged, the individual frames could be told apart one after another):
    /// 25 on 60 gives 2-2-3-2-3, that is, an even slight stutter with zero dropouts and zero
    /// dropped frames.
    ///
    /// **59.94 does not divide.** 60/59.94 is 1.001 — the TV would have to go into the 59.94
    /// mode, otherwise one second in every 1000 seconds runs out of step.
    public static func dividesSixty(_ rate: Float) -> Bool {
        guard rate > 0 else { return false }
        let portion = 60 / rate
        return abs(portion - portion.rounded()) < 0.001
    }

    /// Whether the viewer should be pointed to the system setting.
    ///
    /// **The app cannot set the switch** — there is no interface for it. It can, however, stop
    /// pretending that its registration had an effect: If *Match Content → Frame Rate* is off and
    /// the registered rate does not divide 60, the registration changes **nothing**, and the
    /// picture keeps stuttering.
    public static func needsSystemNotice(rate: Float, adjustmentAllowed: Bool) -> Bool {
        !adjustmentAllowed && !dividesSixty(rate)
    }

    /// What is currently registered.
    public private(set) var rate: Float?
    /// From which source.
    public private(set) var source: Source?
    /// How often a source of equal rank has already changed the mode.
    public private(set) var corrections = 0

    public init() {}

    /// Whether this rate is to be registered — and notes it if so.
    public mutating func accepts(_ fresh: Float, from newSource: Source) -> Bool {
        guard let rate, let source else {
            set(fresh, newSource)
            return true
        }
        // Regel 1: derselbe Modus sagt nichts Neues.
        if Self.sameMode(fresh, rate) { return false }
        // Rule 2: a better source overthrows every worse one.
        if newSource > source {
            set(fresh, newSource)
            return true
        }
        // A worse source never overthrows a better one: Otherwise the player's estimate would
        // overwrite the remuxer's counted number, and precisely at startup, where it is least
        // reliable.
        if newSource < source { return false }
        // Regel 3: gleichrangig genau einmal.
        guard corrections < 1 else { return false }
        corrections += 1
        set(fresh, newSource)
        return true
    }

    private mutating func set(_ fresh: Float, _ newSource: Source) {
        rate = fresh
        source = newSource
    }
}
