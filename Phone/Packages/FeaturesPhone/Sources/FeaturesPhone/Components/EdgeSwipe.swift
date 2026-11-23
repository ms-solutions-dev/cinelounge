import DesignSystemPhone
import SwiftUI

/// A swipe from the **left edge** to the right — the door to what lies to the left of
/// Home.
///
/// **Why from the edge and not anywhere** (the reason is Home itself): There the
/// shelves scroll horizontally, and the header box pages through its heroes with the
/// same thumb. A gesture across the whole area would mean that a swipe back to the
/// start of a shelf opens the downloads — so it does something different exactly when
/// you least expect it. None of those movements begins at the edge.
///
/// **And it is not an invented gesture.** iOS has always navigated back at the left
/// edge; whoever drags there expects something to come in. On Home there is nothing to
/// go back to — the spot is free and is assigned here.
///
/// **The rule is a calculation and not buried in a gesture body**, so that it can be
/// tested: Thresholds that can only be judged on the device are, by experience, never
/// touched again.
public enum EdgeSwipe {

    /// How close to the left edge the thumb has to land.
    ///
    /// **Twenty-four points, and they cost nothing:** The gesture runs as
    /// `simultaneousGesture`, so it takes the grip away from no shelf and no tile.
    /// A strip that intercepts touches would be the 2026-09-07 defect all over again — there an
    /// invisible hit area lay over the neighbor.
    public static let edgeWidth: CGFloat = 24

    /// How far it has to be dragged.
    ///
    /// **Eighty points instead of the twenty that trigger a gesture.** A swipe that
    /// switches a view should be intentional; the short distance belongs to scrolling.
    public static let span: CGFloat = 80

    /// How much more horizontal than vertical the movement has to be.
    ///
    /// Without this number, every diagonal scroll at the left edge would open the
    /// downloads.
    public static let slant: CGFloat = 2

    /// Whether this drag opens the door.
    public static func opens(start: CGPoint, drag: CGSize) -> Bool {
        guard start.x <= edgeWidth else { return false }
        guard drag.width >= span else { return false }
        return drag.width >= abs(drag.height) * slant
    }

    /// Whether this drag closes it again — **from anywhere and not only from the edge.**
    ///
    /// **The finding of 2026-09-09, on the device:** *Swiping from Home, I can open the
    /// downloads, but I cannot close them again by swiping the opposite way.* The gesture
    /// was not broken but unreachable: It required the thumb to land again in the
    /// 24-point strip at the left edge — and exactly this strip is fully covered by the
    /// download rows. They carry their commands as a `highPriorityGesture` from twenty
    /// points (``SwipeCommands``), the drawer its own as a `simultaneousGesture` from
    /// forty. The drag was taken before it arrived here.
    ///
    /// **The client's decision (2026-09-09), explicitly and after weighing: close from
    /// anywhere.** A swipe to the left closes the drawer, no matter where it starts.
    /// **The price is paid deliberately:** The download row loses its delete swipe.
    /// Deleting remains available via long press and via "Select" at the top right —
    /// one movement, one meaning.
    ///
    /// **Distance and slant remain, and they are now the only safeguard.** Without them,
    /// every diagonal scroll in the list would close the screen; eighty points
    /// horizontally with twice the lead over the vertical are not a movement that arises
    /// while scrolling.
    ///
    /// **The parameter `start` stays in the contract** — the opening direction needs it,
    /// and two differently shaped rules side by side would be the next confusion at the
    /// call site.
    public static func closes(start: CGPoint, drag: CGSize) -> Bool {
        guard -drag.width >= span else { return false }
        return -drag.width >= abs(drag.height) * slant
    }
}

extension View {

    /// Opens `action` on a swipe from the left edge to the right.
    ///
    /// `nil` turns the gesture off — the same rule as for the button in the ``HeaderRow``:
    /// Where there are no downloads, no swipe leads there either.
    @ViewBuilder
    public func edgeSwipe(_ action: (() -> Void)?) -> some View {
        if let action {
            // **`simultaneousGesture` and not `gesture`.** Home scrolls vertically and its
            // shelves horizontally; a gesture that claims the grip for itself would take exactly
            // that away.
            simultaneousGesture(
                DragGesture(minimumDistance: EdgeSwipe.span / 2)
                    .onEnded { drag in
                        guard
                            EdgeSwipe.opens(start: drag.startLocation, drag: drag.translation)
                        else { return }
                        action()
                    }
            )
        } else {
            self
        }
    }
}
