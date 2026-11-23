import DesignSystemPhone
import SwiftUI

/// The downloads as a **drawer to the left of Home.**
///
/// **The on-device finding of 2026-09-08:** swiping right (that is, toward the left
/// of Home) brought the view in from the right, not from the left. The first build hung the
/// gesture on ``Navigator/show(_:)`` — that is, on the tab's stack, and a
/// stack pushes its view in from the right. The direction is no decoration here:
/// it is the **indication of place**. Whoever pulls to the right fetches something that lies to the left; if
/// it comes from the right, the gesture was a button with animation.
///
/// **Therefore no stack but a drawer.** It lies above Home and
/// moves with its own edge — in from the left, out to the left.
///
/// **It takes the full width** — the first build left 47 points of Home standing,
/// as a way back. Reported on screen (2026-09-08): downloads now opened only
/// halfway. And that is the right reading: a screen that sticks next to
/// another does not look like "I am here now" but like an error while
/// being pulled open. The strip was my invention and not the request.
///
/// **The way back therefore sits in the header of the drawer** (``DownloadsView/back``) and
/// additionally at the left edge as a swipe to the left. That way the rule from
/// usability finding 13 keeps applying and is not broken: the arrow appears **only**
/// here, where there actually is a place you came from — in the tab and without a network
/// the downloads still carry none.
struct DownloadsDrawer<Content: View, Auszug: View>: View {

    @Binding var pending: Bool

    @ViewBuilder let content: () -> Content
    @ViewBuilder let excerpt: () -> Auszug

    var body: some View {
        ZStack {
            content()

            if pending {
                excerpt()
                    .background(ColorRole.reason.color)
                    .transition(.move(edge: .leading))
                    // **Above Home and not below it.** Without the ordering
                    // the drawing order decides, and in a transition that is
                    // not the one you assume.
                    .zIndex(1)
                    // **Push back with a swipe to the left — from anywhere.**
                    //
                    // **The finding of 2026-09-09:** swiping from Home opened downloads, but
                    // swiping the opposite way did not close it again. The condition here was "only at the left edge", and
                    // exactly that strip was covered by the download rows with their
                    // `highPriorityGesture`. The gesture was not broken but
                    // unreachable.
                    //
                    // **The rows gave up their drag for this** (``SwipeCommands``,
                    // `movesAccount: false`) — one motion, one meaning. Deleting lives with the
                    // long press and with "Select"; the rationale including its price is at
                    // ``EdgeSwipe/closes(start:drag:)``.
                    .simultaneousGesture(
                        DragGesture(minimumDistance: EdgeSwipe.span / 2)
                            .onEnded { drag in
                                guard
                                    EdgeSwipe.closes(
                                        start: drag.startLocation, drag: drag.translation)
                                else { return }
                                close()
                            }
                    )
            }
        }
    }

    private func close() {
        withAnimation(Motion.sheet) { pending = false }
    }
}
