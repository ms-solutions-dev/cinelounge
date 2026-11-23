import DesignSystemPhone
import Diagnose
import SwiftUI

extension View {

    /// Shows a half-height sheet from the bottom.
    ///
    /// The height is a **fraction**, not a number — `.fraction` instead of `.height`. A fixed
    /// height of 536 points would, at Dynamic Type XXL, not bound a tile but the whole screen.
    /// The content scrolls; the sheet gets longer instead of fuller. `.large` is offered as a
    /// second detent next to it, so that a sheet that is too long can be pulled open instead of
    /// searching in it.
    ///
    /// The grabber comes from the system and is thus also touchable, not just visible: iOS
    /// creates a 44-point-tall strip for it, which one easily forgets oneself.
    public func sheet(
        _ state: SheetState,
        @ViewBuilder content: @escaping (SheetID) -> some View
    ) -> some View {
        sheet(item: Binding(get: { state.pending }, set: { if $0 == nil { state.close() } })) {
            identifier in
            content(identifier)
                .presentationDetents([.fraction(identifier.portion), .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(MetricsBoard.phone.sheetRadius)
                .presentationBackground(ColorRole.surfaceHigh.color)
        }
    }
}

extension View {

    /// Hides the system's navigation bar.
    ///
    /// **With a platform switch, because `navigationBar` does not exist on macOS** — and macOS is
    /// built here only so that `swift test` runs on the Mac instead of in the simulator. The
    /// switch lives in this one place; every view that writes `#if os` itself is one more place
    /// where the branches drift apart.
    public func withoutNavigationBar() -> some View {
        #if os(iOS)
            toolbar(.hidden, for: .navigationBar)
        #else
            self
        #endif
    }

    /// Hides the tab bar — **only the player does that.**
    ///
    /// A tab switch in the middle of a film is not a way out but a slip: the bar lies under the
    /// thumb that is just reaching across for the timeline.
    public func withoutTabBar() -> some View {
        #if os(iOS)
            toolbar(.hidden, for: .tabBar)
        #else
            self
        #endif
    }
}

#if canImport(UIKit)
    import UIKit

    /// Brings back the swipe-back gesture that a hidden navigation bar switches off.
    ///
    /// **The finding of 2026-09-05, twice.** The detail page hides the system bar because it carries
    /// its own way back in the header image — and with that, dragging from the left was gone too.
    /// UIKit attaches the gesture to the bar's back button: if there is none, its own delegate
    /// stops it.
    ///
    /// **The first attempt set `delegate = nil` in `updateUIViewController` — and that takes
    /// effect too early.** SwiftUI builds the proxy controller before it hangs in the navigation
    /// tree; `navigationController` is then `nil`, the assignment goes nowhere, and a second pass
    /// does not come because nothing has changed. Now it is additionally set in `viewDidAppear`,
    /// where the controller is certainly attached.
    ///
    /// **And `nil` was the wrong means anyway.** Without a delegate nobody checks any more
    /// whether there is anything to close: on the root view the gesture begins anyway, finds
    /// nothing to go back to and leaves the bar in a state in which it no longer reacts to any
    /// touch. The own guard answers exactly this one question.
    ///
    /// **On iOS the gesture is not a convenience but the way back** that most people use. A
    /// button at top left does not replace it: it sits at y ≈ 80 and thus far above the thumb
    /// limit.
    final class SwipeGuard: NSObject, UIGestureRecognizerDelegate {

        /// **The controller is remembered, not searched for** — and the third failed attempt hinged
        /// on that.
        ///
        /// The previous guard looked for it at the start of the gesture via the window's root
        /// controller. With a tab bar that is **wrong**: the root is a `UITabBarController`, and the
        /// search over its children yields the navigation controller of the **first** tab, not the
        /// visible one. Its stack is one view deep, `count > 1` was therefore false, and the gesture
        /// did not begin at all. In the log it looked like a success — it *was* hooked in.
        weak var navigation: UINavigationController?

        /// **The wide edge zone** (user finding 2026-09-05: swiping has to start too precisely at the
        /// edge).
        ///
        /// Apple's zone is about twenty points wide and **not adjustable**:
        /// `interactivePopGestureRecognizer` is a `UIScreenEdgePanGestureRecognizer`, and the system
        /// does not release its hit width. What works is a second recognizer next to it — it takes
        /// over where the built-in one no longer does.
        ///
        /// **Forty-four and not a hundred.** It is the same number as the smallest hit area, and it
        /// has the same reason here: that is how far a thumb reaches that starts at the edge. Wider,
        /// the zone would become an ambush for everything that stands on the left.
        static let edgeZone: CGFloat = 44

        /// This far must be dragged for it to be a way back and not a slip.
        static let minimumDistance: CGFloat = 60

        private var wideEdge: UIPanGestureRecognizer?

        func append(_ controller: UINavigationController) {
            navigation = controller
            controller.interactivePopGestureRecognizer?.delegate = self
            controller.interactivePopGestureRecognizer?.isEnabled = true

            guard wideEdge == nil else { return }
            let gesture = UIPanGestureRecognizer(target: self, action: #selector(drawn))
            gesture.delegate = self
            // **The built-in one takes precedence.** In the first twenty points the page is dragged
            // along — that is the better gesture, and it should not be displaced by a coarser one lying
            // next to it. Only when it does not engage does this one get its turn.
            if let builtIn = controller.interactivePopGestureRecognizer {
                gesture.require(toFail: builtIn)
            }
            controller.view.addGestureRecognizer(gesture)
            wideEdge = gesture
        }

        @objc private func drawn(_ gesture: UIPanGestureRecognizer) {
            guard gesture.state == .ended, let navigation,
                navigation.viewControllers.count > 1
            else { return }
            let route = gesture.translation(in: gesture.view)
            // To the right, far enough and not diagonal — otherwise it is a slip while scrolling and not
            // a way back.
            guard route.x > Self.minimumDistance, abs(route.y) < abs(route.x) else { return }
            navigation.popViewController(animated: true)
        }

        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let navigation else { return true }
            guard navigation.viewControllers.count > 1 else { return false }
            guard let pan = gesture as? UIPanGestureRecognizer, pan === wideEdge else {
                return true
            }
            // **Only at the left edge and only horizontal.** Measured by velocity and not by distance:
            // at the start the distance is still zero, and a decision about zero points falls out
            // randomly.
            let start = pan.location(in: navigation.view)
            let rate = pan.velocity(in: navigation.view)
            return start.x <= Self.edgeZone && rate.x > abs(rate.y)
        }

        /// **Not over a horizontally scrolling area.**
        ///
        /// On the detail page the chapter, cast and similar rows begin at x = 20 and thus lie in the
        /// middle of the edge zone. Without this check the way back would intercept every swipe on
        /// the first tile — and the viewer would go back a level by accident while wanting to browse
        /// a row.
        func gestureRecognizer(
            _ gesture: UIGestureRecognizer, shouldReceive touch: UITouch
        ) -> Bool {
            guard gesture === wideEdge else { return true }
            var run: UIView? = touch.view
            while let view = run {
                if let scrollView = view as? UIScrollView,
                    scrollView.contentSize.width > scrollView.bounds.width + 1
                {
                    return false
                }
                run = view.superview
            }
            return true
        }

        /// **Not simultaneously with scrolling.** The detail page is a scroll area; allowing both at
        /// once would mean that a diagonal drag moves the page **and** the way back.
        func gestureRecognizer(
            _ gesture: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            false
        }
    }

    /// The proxy that hooks in the guard.
    struct SwipeBack: UIViewControllerRepresentable {

        func makeCoordinator() -> SwipeGuard { SwipeGuard() }

        func makeUIViewController(context: Context) -> UIViewController {
            let empty = AttachHook()
            empty.swipeGuard = context.coordinator
            empty.view.backgroundColor = .clear
            empty.view.isUserInteractionEnabled = false
            return empty
        }

        func updateUIViewController(_ controller: UIViewController, context: Context) {
            (controller as? AttachHook)?.attach()
        }

        /// Sets the guard as soon as the controller really hangs in the tree.
        final class AttachHook: UIViewController {

            weak var swipeGuard: SwipeGuard?

            override func viewDidAppear(_ animated: Bool) {
                super.viewDidAppear(animated)
                attach()
            }

            override func didMove(toParent parent: UIViewController?) {
                super.didMove(toParent: parent)
                attach()
            }

            /// **Writes a line to the log — both outcomes.** Whether the gesture hangs can only be tested
            /// on screen by swiping, and a failed swipe looks just like one that is too short. The line
            /// says whether a navigation controller was found at all — that is the difference between
            /// "set too early" and "set, but the guard says no".
            func attach() {
                guard let swipeGuard else { return }
                guard let navigation = navigationController else {
                    // **A hint and not a step.** If the hook-in finds no controller, the way back is gone — and
                    // on the device that looks exactly like a swipe that is too short. Without this line one
                    // searches from scratch next time.
                    Diagnose.hint(.surface, "Swipe-back: no navigation controller")
                    return
                }
                swipeGuard.append(navigation)
                Diagnose.step(
                    .surface,
                    "Swipe-back hooked in, depth \(navigation.viewControllers.count)")
            }
        }
    }
#endif

extension View {

    /// Allows pulling back from the left, even without a visible navigation bar.
    public func withSwipeBack() -> some View {
        #if canImport(UIKit)
            // **One point in size and not zero.** With `frame(width: 0, height: 0)` SwiftUI did not
            // create the proxy — the error log contained not a single line, although both outcomes write
            // one. An element without area is not built, and a proxy that is not built hooks nothing in.
            background(
                SwipeBack()
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true))
        #else
            self
        #endif
    }
}
