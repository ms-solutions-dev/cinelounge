import DesignSystemPhone
import ParentalControls
import ProfileKit
import SwiftUI

/// What happens when you reach a locked door.
///
/// **The question is asked at the door, not at every step behind it.** Both would be wrong: asking at
/// every step means a parent taps three times on the way into Settings —
/// whoever experiences that switches the lock off. Asking once and leaving it
/// open means the child gets the app after the parent and finds everything
/// open. That was exactly the most serious finding. The ``Pass`` solves both: **one
/// action, one door, two minutes.**
///
/// **The sheet hangs on two levels and still opens only once.** An overlay is on
/// iOS a `fullScreenCover`; a sheet hanging on the tab bar would lie underneath
/// and be invisible. That is why every level carries this overlay, and
/// ``isResponsible`` says which one is currently the topmost — exactly one.
struct LockedDoor: ViewModifier {

    let navigator: Navigator
    let state: ParentalControlsState

    /// Whether **this** level is currently the topmost.
    let isResponsible: Bool

    func body(content: Content) -> some View {
        content.sheet(isPresented: pending) {
            if let job = navigator.waiting {
                PinSheet(
                    job: job,
                    verifies: { state.verify($0, forItem: job) },
                    sets: { state.setPin($0) },
                    // **The escape is missing as long as there is nothing to forget.** On
                    // first setting it pointed to a screen that resets a PIN
                    // that does not exist.
                    //
                    // **And without an Apple account** (G3, finding B8): both ways — confirm on the other device,
                    // reset after 24 hours — run through the
                    // household zone in iCloud; as on the TV there is none without it.
                    forgotten: state.isPinSet && ProfileCloud.attached != nil
                        ? { navigator.showFallback() } : nil,
                    succeeded: {
                        navigator.letPass()
                        // **After the action the door is closed again.** Explicitly here and
                        // not in checking: a check that consumes on the side would be a
                        // trap in every place, asking twice — and views
                        // ask twice, because SwiftUI evaluates them several times.
                        state.consume()
                    }
                )
                .presentationDetents([.fraction(0.78), .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(MetricsBoard.phone.sheetRadius)
                .presentationBackground(ColorRole.surfaceHigh.color)
            }
        }
    }

    private var pending: Binding<Bool> {
        Binding(
            get: { isResponsible && navigator.asksForPin },
            // Tapping beside is a No and not a slip: whoever does not have the PIN should
            // get rid of the sheet without having it.
            set: { if !$0 { navigator.giveUp() } })
    }
}

extension View {

    /// Puts the PIN sheet over this level if it is the topmost.
    func lockedDoor(
        _ navigator: Navigator, state: ParentalControlsState, isResponsible: Bool
    ) -> some View {
        modifier(LockedDoor(navigator: navigator, state: state, isResponsible: isResponsible))
    }
}
