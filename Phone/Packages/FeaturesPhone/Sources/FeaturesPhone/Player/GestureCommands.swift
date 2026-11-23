import Playback
import SwiftUI

/// Every gesture of the player as a row under "More commands".
///
/// **A gesture without a twin does not exist for part of the viewers.** Swiping,
/// pinching and long pressing cannot be performed with the screen reader and with switch control
/// — not harder, but not at all. What stands here is therefore
/// no extra for emergencies, but the second path to the same actions (E66,
/// AP5). The same build as ``SwipeCommands`` and ``TileCommands``, only for one
/// surface instead of one row.
///
/// **Only what no control can already do.** Seeking has the timeline, pause the
/// big button, and a jump of ten seconds stands as a button in the
/// ``TransportRow``. **Filling the picture has stood here since 2026-09-27** (on-device
/// test build 1332): its key in the header bar took the title's room and is gone; the
/// pinch is the visible way, this row the one for everyone who cannot pinch.
/// Listing the others twice would be a longer list without a single
/// additional path — and the longer the list, the less one finds in it.
///
/// **The speed is a switch here and a hold there.** A "while pressed" cannot
/// be expressed via this path; the screen reader knows commands, not durations.
/// So on and off again, with a label that says what the next press does.
struct GestureCommands: ViewModifier {

    /// Whether the speed is available at all — `nil` for a channel and for the repackager.
    let rate: ((Double) -> Void)?
    let close: () -> Void
    /// The applicable picture state — `nil` where there is nothing to fill (see ``PinchGesture``).
    var pictureState: ImageLayout?
    /// Switches the picture state — the same path as the snapping of the gesture.
    var setPictureState: (ImageLayout) -> Void = { _ in }

    /// Whether it is currently running at double speed. **Held here and not with the ``SwipeZones``:** the
    /// long press ends with the finger, this switch only with the next press.
    @State private var fast = false

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(app: "player.picture"))
            // **The gesture is named where it exists.** Whoever swipes over the picture
            // with the screen reader learns that two fingers fill it — and that
            // the same action stands as a command below.
            .accessibilityHint(pictureState == nil ? Text(verbatim: "") : Text(app: "player.pinchHint"))
            .accessibilityAction(named: Text(app: "player.brighter")) { Brightness.step(1) }
            .accessibilityAction(named: Text(app: "player.darker")) { Brightness.step(-1) }
            .accessibilityAction(named: Text(app: "player.louder")) { Volume.step(1) }
            .accessibilityAction(named: Text(app: "player.quieter")) { Volume.step(-1) }
            // **The exit belongs in this list**, although the button exists: it stands
            // in the bar, and that hides after four seconds. Whoever does not bring it back with the
            // screen reader has no way out otherwise.
            .accessibilityAction(named: Text(app: "action.close")) { close() }
            .accessibilityActions {
                // **The label names what the command DOES**, not what applies —
                // the same rule the earlier button had.
                if let pictureState {
                    Button {
                        setPictureState(pictureState.other)
                    } label: {
                        Text(appKey: pictureState.other.label)
                    }
                }
                if let rate {
                    Button {
                        fast.toggle()
                        rate(fast ? SwipeZones.fastSpeed : 1)
                    } label: {
                        Text(appKey: fast ? "player.normalSpeed" : "player.doubleSpeed")
                    }
                }
            }
            // **Put back when the surface goes.** A switch that stays on "double"
            // while the film is already over causes mischief at the next
            // title — there the row would then read "Normal speed" without
            // anything running at double speed.
            .onDisappear {
                guard fast else { return }
                fast = false
                rate?(1)
            }
    }
}

extension View {

    /// Siehe ``GestureCommands``.
    func withGestureCommands(
        rate: ((Double) -> Void)?, close: @escaping () -> Void,
        pictureState: ImageLayout? = nil, setPictureState: @escaping (ImageLayout) -> Void = { _ in }
    ) -> some View {
        modifier(
            GestureCommands(
                rate: rate, close: close, pictureState: pictureState,
                setPictureState: setPictureState))
    }
}
