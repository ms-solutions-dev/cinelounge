import Core
import Foundation

/// Pause live, scrub in the buffer, return to the running program — **the same rule on
/// both devices** (AP58 G1, decision 27, A1).
///
/// **Why it exists.** The TV has been able to do this since AP9: the remuxer puts what falls out of
/// its buffer into a disk ring (``Core/TimeShiftRing``), and the system player
/// seeks in it by itself. The switch for this lived in the TV's `PlayerModel`, the phone
/// did not know it — there a channel had neither timeline nor skip buttons, and a
/// double tap said "no archive". Here the switch, window and limits exist once.
nonisolated public enum TimeShift {

    /// For which device the ring is sized.
    public enum Device: Sendable {
        case tv
        case phone
    }

    /// How long a pause should hold at least — **five minutes** (player audit, V1):
    /// a phone call, the door, a walk through the home.
    public static let retention: TimeInterval = 5 * 60

    /// The high bitrate the size is calculated from — **17 Mbit/s**, the measured
    /// peak of an HD channel at the provider (F-009, 2026-09-03, "DE: Rendal 2 HQ").
    public static let highBitrate: Double = 17_000_000

    /// What the ring must hold at minimum: ``retention`` at ``highBitrate``, with one
    /// seventh reserve for peaks and piece boundaries, rounded up to 50 MB — **750 MB**.
    public static var minimumSize: Int64 {
        // `/ 8 * 8` stood here until 2026-09-27 (remuxer audit, finding 9,
        // minor) — an idle operation that hid the one seventh of reserve that
        // actually counts. Arithmetically and in floating point no difference: `raw`
        // and the result of `minimumSize` stay the same numbers.
        let raw = retention * highBitrate / 7
        let step = 50_000_000.0
        return Int64((raw / step).rounded(.up) * step)
    }

    /// How large the ring may grow.
    ///
    /// **Calculated from the bitrate, not limited by time** (player audit, V1): until then
    /// the phone held 250 MB — at 17 Mbit/s barely two minutes; a longer pause let
    /// the pause position drop out of the list. A limit by time would be more precise, but
    /// still needs an upper limit in bytes (a 4K channel at 40 Mbit/s would otherwise eat the
    /// storage), nobody knows the bitrate when the ring is created, and the settings
    /// display a size. So one number that carries five minutes at a high bitrate.
    ///
    /// **Both devices hold at least that.** On the TV it was 500 MB (product requirement 2026-09-04:
    /// do not tie up 500 MB) — barely four minutes at 17 Mbit/s; the rule applies there just the same.
    /// The ring lives in the cache folder, which the system may clear itself when space is short, and
    /// is cleared with the session (``Core/LiveRemuxSession/stop()``).
    public static func capacity(_ device: Device) -> Int64 {
        switch device {
        case .tv: max(TimeShiftRing.defaultCapacity, minimumSize)
        case .phone: minimumSize
        }
    }

    /// How much ring is currently on the disk, across all sessions — for the display
    /// in the settings.
    public static func taken() -> Int64 { TimeShiftRing.usage() }

    /// Clears all rings — **at app start**, for whatever a crash left behind.
    public static func cleanUp() { TimeShiftRing.sweep() }

    /// **The switch:** whether the running channel can be rewound.
    ///
    /// Only a channel through the own playlist has a ring; the direct renderer
    /// reads packets as they come and holds nothing.
    public static func applies(
        kind: PlaybackTarget.Kind, deliveryRoute: Delivery, session: AnyObject?
    ) -> Bool {
        kind == .live && deliveryRoute == .remuxInApp
            && (session as? LiveRemuxSession)?.hasTimeShift == true
    }

    /// How close to the edge still counts as "live".
    ///
    /// The jump back lands one second before the edge (``Core/PlaybackController/seekToLiveEdge()``),
    /// and the system player itself keeps a few seconds of distance. Without a tolerance,
    /// "live" would never show after "Back to Live".
    public static let edgeTolerance: TimeInterval = 6

    /// The window in the buffer — from the oldest piece to the edge.
    public struct Window: Sendable, Equatable {
        public let start: TimeInterval
        public let margin: TimeInterval

        /// `nil` as long as there is no window worth a bar — under two seconds
        /// every timeline is a twitch.
        public init?(_ area: ClosedRange<TimeInterval>?) {
            guard let area, area.upperBound - area.lowerBound >= 2 else { return nil }
            start = area.lowerBound
            margin = area.upperBound
        }

        public var length: TimeInterval { margin - start }

        /// Where the position stands in the bar, 0…1.
        public func portion(at location: TimeInterval) -> Double {
            min(1, max(0, (location - start) / length))
        }

        /// How far the position lies behind the running program.
        public func lag(at location: TimeInterval) -> TimeInterval {
            max(0, margin - location)
        }

        /// Whether the position counts as "live" — see ``TimeShift/edgeTolerance``.
        public func atEdge(at location: TimeInterval) -> Bool {
            lag(at: location) <= TimeShift.edgeTolerance
        }

        /// A jump target, **clamped to the limits of the buffer.** Before the oldest piece
        /// there is nothing any more, and beyond the edge nothing yet.
        public func target(_ desired: TimeInterval) -> TimeInterval {
            min(margin, max(start, desired))
        }

        /// The position for a fraction of the bar — for dragging.
        public func location(portion: Double) -> TimeInterval {
            target(start + min(1, max(0, portion)) * length)
        }
    }
}
