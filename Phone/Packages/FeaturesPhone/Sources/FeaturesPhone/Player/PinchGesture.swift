import Playback
import SwiftUI

/// Pinching switches between the whole picture and screen-filling — **the finger leads,
/// the direction decides.**
///
/// **Why not simply a switch.** Because the gesture is the one everybody brings along:
/// From Photos, from Maps, from mobile browsers (requirement of 2026-09-08: the gestures there
/// are the ideal). Since the on-device test of build 1332 (2026-09-27) it is the **only**
/// visible path: The zoom button in the header bar took space from the title, and whoever
/// cannot see it finds the same action under "More commands" (``GestureCommands``).
///
/// **Why not freely scaled.** A zoom that stays is a photo gesture. In video it creates a
/// state nobody can name and therefore nobody can undo, and it pushes the subtitles out of
/// the picture. There are two sensible ends here and nothing in between.
///
/// **Why it follows anyway.** A gesture that only does something on release feels broken —
/// you pinch and nothing happens. So the picture follows while the fingers are down
/// (``metrics``, a pure display via `scaleEffect`), and snaps on release in the direction it
/// was pulled (``PictureFill/snaps(magnification:from:factor:)``). Only the snapping sets
/// the layer's gravity and makes the engine actually lay things out differently.
///
/// **The gesture hangs on the whole player and not on the picture** (on-device test, build
/// 1332). Until 2026-09-27 it sat on the ``Playback/VideoSurface`` — and over that lie the
/// ``SwipeZones``, a surface over the whole screen with its own hit shape. Every touch
/// landed there; a pinch never reached the picture below. Now it is a **simultaneous**
/// gesture on the shared stack: It gets the fingers even if a swipe zone or a button has
/// them first, and reports via ``isPinching`` that the swipe zone should release its begun
/// drag — otherwise every pinch would also change the brightness on the side.
struct PinchGesture: ViewModifier {

    /// The aspect ratio of the running picture, width over height.
    let image: Double
    /// The aspect ratio of the area it lies in.
    let screen: Double
    /// The layout that currently applies.
    @Binding var state: ImageLayout
    /// The scale the picture shows during the gesture — **drawn at the picture**, not here.
    /// Different from 1 only during the gesture.
    @Binding var metrics: Double
    /// Whether two fingers are pinching right now — for the ``SwipeZones``.
    @Binding var isPinching: Bool
    /// Whether the film plays in the small window — **then the system determines the area.**
    ///
    /// Picture-in-picture is a window of the system: It has its own size, its own aspect
    /// ratio and its own gestures. A pinch gesture that switches the layer's gravity there
    /// changes something on an area that is no longer on screen — and the viewer would see the
    /// effect only on return, without suspecting the connection.
    var inWindow = false
    /// What should be shown after snapping.
    var didSnap: (ImageLayout) -> Void = { _ in }

    /// Whether the gesture is currently running — **a gesture state, because it resets
    /// itself.**
    ///
    /// If the system cancels the gesture (a call, Control Center), `onEnded` never comes; an
    /// ordinary flag would then stay on "pinching", and the swipe zones would accept no drag
    /// any more. The same finding as B3 on the ``SwipeZones``.
    @GestureState private var isRunning = false

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(pinch, isEnabled: !inWindow && factor > 1)
            .onChange(of: isRunning) { _, fresh in
                isPinching = fresh
                // The picture is back in its layout even after a cancellation.
                if !fresh { metrics = 1 }
            }
    }

    private var factor: Double { PictureFill.fillFactor(image: image, screen: screen) }

    private var pinch: some Gesture {
        MagnifyGesture()
            .updating($isRunning) { _, state, _ in state = true }
            .onChanged { value in
                // **The anchor is the layout that applies and not always 1.** Whoever pinches together
                // from the filled state must come downward — otherwise the display would go in only one
                // direction.
                let anchor = state == .fullImage ? 1 : factor
                let between = min(max(anchor * value.magnification, 1), factor)
                // **Drawing is relative to the layout that applies.** The filled layer is already
                // enlarged by the factor; a second factor on top would make the picture jump on first
                // touch.
                metrics = state == .fullImage ? between : between / factor
            }
            .onEnded { value in
                let fresh = PictureFill.snaps(
                    magnification: value.magnification, from: state, factor: factor)
                // **Reset before the layout changes.** The scale is only the display during the gesture;
                // if it stayed, it would add to the layer's new gravity, and the picture would be
                // enlarged twice.
                metrics = 1
                guard fresh != state else { return }
                state = fresh
                didSnap(fresh)
            }
    }
}

extension View {

    /// Siehe ``PinchGesture``.
    func withPinch(
        image: Double, screen: Double, state: Binding<ImageLayout>, metrics: Binding<Double>,
        isPinching: Binding<Bool>, inWindow: Bool = false,
        didSnap: @escaping (ImageLayout) -> Void = { _ in }
    ) -> some View {
        modifier(
            PinchGesture(
                image: image, screen: screen, state: state, metrics: metrics, isPinching: isPinching,
                inWindow: inWindow, didSnap: didSnap))
    }
}
