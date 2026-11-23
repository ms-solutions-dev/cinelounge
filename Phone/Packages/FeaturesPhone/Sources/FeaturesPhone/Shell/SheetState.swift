import Observation

/// Exactly one sheet at a time — by construction, not by intention.
///
/// The prototype walkthrough checks this specifically, and for good reason: two open sheets
/// on top of each other cannot be closed any more at 393 points. Here it cannot
/// even come to that, because there is only one slot.
@MainActor
@Observable
public final class SheetState {

    /// The open sheet, or none.
    public private(set) var pending: SheetID?

    public init() {}

    /// Opens a sheet and **replaces** one that is already open.
    ///
    /// Replace and not stack: a sheet that opens a second one occurs in the design
    /// (from the cast into the career), but always as a switch and never as a
    /// layer. A way back from a sheet to the previous one will be built when it is needed for the first
    /// time — today it would be a stack, and exactly that is forbidden by the rule.
    public func open(_ sheet: SheetID) {
        pending = sheet
    }

    /// Closes the open sheet. Via handle, cross or tapping outside — all three ways
    /// end here.
    public func close() {
        pending = nil
    }

    /// Closes the sheet and carries on **afterwards**.
    ///
    /// **The finding of 2026-09-07, reported on the device:** tapping Settings anywhere
    /// always leads to this screen — a black screen. Two ways out of the
    /// account sheet lead into an overlay (settings and parental controls), and both
    /// wrote `close()` and `show(…)` **one after the other in the same pass**.
    ///
    /// **On iOS that is no matter of taste but a rule of the system.** A
    /// sheet is a `sheet`, an overlay a `fullScreenCover` — both are presented
    /// views of the same host. As long as the sheet is still closing, the host is busy;
    /// the overlay then does not come out at all. What remains is an empty surface, and
    /// it looks like a crash.
    ///
    /// **That is why the second step waits, and here and not at the call sites.**
    /// Whoever wrote the waiting time into every caller would have forgotten it by the third —
    /// the same consideration that puts the gatekeeper in **one** place.
    ///
    /// **Only for the way to full screen.** Whoever does something within the same screen
    /// from a sheet — toggle a favorite, choose a track — keeps using
    /// ``close()``: there is no second host there to wait for.
    public func close(following: @escaping @MainActor () -> Void) {
        pending = nil
        Task { @MainActor in
            try? await Task.sleep(for: Self.sheetTransition)
            following()
        }
    }

    /// How long a sheet takes to close.
    ///
    /// **Measured generously and not tightly.** Too early means a black screen; too late
    /// means that the next screen comes a blink later. The two
    /// errors are not worth the same.
    static let sheetTransition: Duration = .milliseconds(350)

    public var isOpen: Bool { pending != nil }
}
