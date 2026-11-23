import Foundation

/// A passed PIN is valid for **exactly one action.**
///
/// It does not outlast the session. The question is asked **at the door**, not at every
/// step behind it — otherwise the lock is either annoying or leaky:
///
/// * **Asking at every step** means a parent taps three times on the way into the
///   settings. Anyone who experiences that turns the lock off.
/// * **Asking once and leaving it open** means the child gets the app after the parent
///   and finds everything open. That was exactly the most serious finding.
///
/// **A pass is valid for one door and not for all.** Whoever releases the account switch
/// has not released the settings. Two doors are two questions.
///
/// **And it expires with time, not only with use.** A parent who enters the PIN and then
/// puts the phone down has not left a door open — after two minutes it asks again. The
/// span is short enough that nobody exploits it, and long enough for the one action it is
/// meant for.
public struct Pass: Sendable, Equatable {

    /// How long a pass is valid when it is not used.
    ///
    /// **Two minutes**, and the number is a decision: shorter and a parent who is interrupted
    /// by a call enters it twice; longer and the phone lies open on the table.
    public static let lifetime: TimeInterval = 120

    private var openDoor: String?
    private var until: Date?

    public init() {}

    /// Opens **one** door.
    public mutating func open(_ door: String, um now: Date = Date()) {
        openDoor = door
        until = now.addingTimeInterval(Self.lifetime)
    }

    /// Whether this door is currently open.
    public func applies(forItem door: String, um now: Date = Date()) -> Bool {
        guard let openDoor, let until else { return false }
        return openDoor == door && now < until
    }

    /// **Consumes the pass** — after the action the door is shut again.
    ///
    /// Deliberately separate from ``applies(forItem:um:)``: a check that consumes on the side would
    /// be a trap at every place that asks twice — and views do ask twice, because SwiftUI
    /// evaluates them several times.
    public mutating func consume() {
        openDoor = nil
        until = nil
    }
}
