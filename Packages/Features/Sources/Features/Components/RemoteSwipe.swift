import Core
import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

/// A swipe on the remote — as a gesture, not as a move command.
///
/// **Why this exists at all.** So far the app reads sideways directions via
/// `onMoveCommand`. That arrives only if nobody has consumed the movement —
/// and on the **old Siri Remote with the smooth glass surface** it does not arise at all
/// when swiping: there a swipe is not a direction key but
/// a continuous gesture. It feeds the focus engine, and where that
/// cannot move anything, simply nothing happens. On the remote with a click ring,
/// every edge press is a separate, distinct event instead — that is why
/// the same app works on one device and not on the other
/// (finding of 2026-08-14, two TVs compared).
///
/// **Why not a focus target.** The obvious route — an invisible strip
/// that focus moves to — has already been built **twice** in this project
/// and discarded both times; the reasoning is at ``LiveView/rail``.
/// From the channel list tvOS does **not** move focus to the left
/// **at all**, and whatever stood there would be unreachable. A gesture recogniser is the
/// only way that does not ask the focus engine for permission.
///
/// **Complementary, not replacing.** `onMoveCommand` stays everywhere it
/// stands today. On the click-ring remote it still arrives first and
/// wins; on the old one this path takes over. So that the two do not both
/// trigger the same thing twice, ``MoveGate`` belongs in between — this project
/// already had the bug "I press once and
/// it jumps twice" on 2026-08-11.
public enum RemoteSwipeDirection: Equatable, Sendable {
    case left, right, up, down
}

extension RemoteSwipeDirection {
    /// The same direction as a move command names it.
    ///
    /// That keeps the evaluating code at **one** rule: both sources
    /// flow into the same function, and no view has to decide twice
    /// what "to the left" means.
    var asMove: MoveCommandDirection {
        switch self {
        case .left: .left
        case .right: .right
        case .up: .up
        case .down: .down
        }
    }
}

extension RemoteSwipeDirection {
    /// What a stroke across the glass surface means — as a calculation, not in the recogniser.
    ///
    /// **Why here and not there.** On 2026-08-14 four swipe recognisers hung
    /// side by side and decided the direction by whichever fired first. The
    /// log from the second household's TV then counted 35 reports of "down" and
    /// two of "left" — even though the swipe was to the left. As a calculation over two
    /// numbers the same question can be checked, without a TV and without a remote.
    ///
    /// **Horizontal always, vertical on request** (AP4 · K3).
    ///
    /// Up and down the focus engine handles reliably **where there
    /// are neighbours**: the same log counts 35 arrived down steps
    /// in a list. If they were reported there as well, the list would run
    /// two lines instead of one with every swipe.
    ///
    /// In the running picture, though, there are no such neighbours: above and below the
    /// picture area there is nothing, the focus engine moves nothing, and so
    /// **no** move command arises on the old remote —
    /// channel switching and the info area are simply unreachable there. That is exactly
    /// "works for me, does not work on the second household's TV".
    ///
    /// Hence on request and not always: anyone who sets ``vertical`` says
    /// by that that in their view nobody else operates up and down.
    static func fromDrag(
        dx: CGFloat,
        dy: CGFloat,
        minimumDistance: CGFloat = 120,
        overhang: CGFloat = 1.2,
        clearDistance: CGFloat = 700,
        vertical: Bool = false
    ) -> RemoteSwipeDirection? {
        let width = abs(dx)
        let height = abs(dy)

        // Vertical is answered only if the stroke is **unambiguously** vertical:
        // on the second household's TV all strokes carried a large
        // downward component (y between 1600 and 2200), including the
        // left swipes that were meant. Hence the inverted overhang here and no
        // shortcut via a clear distance — that belongs to the horizontal.
        if vertical, height >= minimumDistance, height > width * overhang,
            width < clearDistance
        {
            return dy < 0 ? .up : .down
        }

        // **Two ways, and the second is the more important** — measured on the
        // second household's TV, 2026-08-14 evening.
        //
        // The ratio alone was not enough: there ALL strokes carried a large
        // downward component, y was consistently between 1600 and 2200. The
        // left swipes were thereby all rejected, even though their leftward share
        // was 800 to 1500 — the intent was unmistakable, the rule
        // just did not recognise it.
        //
        // In the same measurement the two intents separate cleanly on a
        // different number: whoever wanted to go left reached 800 to 1500 horizontally;
        // whoever paged down, 76 to 350. A distance beyond 700
        // therefore counts as meant horizontally, however far the stroke
        // has sagged downward.
        //
        // The ratio stays alongside — for the short, clean swipe
        // that the click-ring remote produces.
        if width >= clearDistance {
            return dx < 0 ? .left : .right
        }
        guard width >= minimumDistance, width > height * overhang else { return nil }
        return dx < 0 ? .left : .right
    }
}

/// Where a sideways movement comes from — the question on which ``MoveGate`` hangs.
enum MoveSource {
    /// A move command (`onMoveCommand`). On the remote with a
    /// click ring **every** physical input produces one — it is the
    /// reliable voice of these devices.
    case command
    /// A second observer of the same hand movement: the gesture recogniser —
    /// or a focus catcher like ``HomeView/pageBackCatcher``, which fires
    /// because the movement shifted focus. Both exist for the
    /// old remote, on which no command arises.
    case gesture
}

/// Keeps the two reports of the **same** hand movement apart.
///
/// **What for.** On the remote with a click ring both sources report the same
/// swipe — the move command and the gesture recogniser. Without this gate every
/// movement would run twice: two channels forward instead of one, two titles in the hero
/// instead of one. This very bug was already in the roadmap on 2026-08-11.
/// ("I press down once and it jumps twice").
///
/// **Why the gate knows the sources, and that is the correction of 2026-08-15**
/// The first version only asked *when* — one report per direction and 250 ms.
/// But the window was tight in the wrong place: the command arrives on
/// press down, the gesture only when the thumb lifts — and that gap
/// depends on the hand, not on the technology. Whoever lingered briefly while clicking
/// pushed the echo past the 250 ms, and every sixth or seventh click
/// jumped twice. A longer window for everyone would not be a solution: it
/// would swallow brisk paging.
///
/// With the source the dilemma resolves:
///
/// - A **command** always counts — every click is a separate, intended
///   step, however fast it comes. Only the rare reverse echo
///   (gesture first, command right after) stays out.
/// - A **gesture** counts only if no command in the same direction
///   arrived for a longer time. On the click ring there is a command for every hand movement — a
///   gesture there is always an echo. On the old glass surface none
///   ever arises, and the shadow is never cast there: every gesture counts.
///
/// The shadow is cast per direction, not globally — otherwise paging
/// down would block the swipe to the left, the bug of 2026-08-14 evening.
struct MoveGate {
    private var lastCommand: [MoveCommandDirection: Date] = [:]
    private var lastGesture: [MoveCommandDirection: Date] = [:]

    /// How long a gesture covers a trailing command of the same movement.
    /// Tight, because the command practically never trails the gesture for long.
    ///
    /// Package-internal instead of `private`, so that a test can pin down the
    /// boundary without copying the number — a copied number silently goes along
    /// with the next change.
    let window: TimeInterval

    /// How long a command stamps subsequent gestures of the same direction as echo.
    ///
    /// **What it covers:** the echo of the same press — measured 100 to 370 ms
    /// after the command, see ``RemoteSwipeTests/lateGestureEcho()``.
    ///
    /// **What it costs:** every real gesture of the same direction within the window. Here
    /// it said for three rounds "generous, because it costs almost nothing" — the
    /// sentence holds only under one condition: where commands arrive, the
    /// command path carries every input, and the gesture there is always an echo. On the
    /// old glass surface a command never arises, and the shadow is never
    /// cast there. A real press is therefore swallowed only in **mixed
    /// operation**: when something else reports alongside the old Siri Remote —
    /// click-ring remote, universal remote, iPhone remote
    /// or HDMI-CEC. That is the second household's living room.
    ///
    /// **What the 1.2 s are sized against.** The expert review counts 13 of 54
    /// **select presses** that were repeated within two seconds
    /// (`ROADMAP.md`, AP4). Those are not direction presses and therefore not a
    /// measurement of this window — they measure the viewer's patience, and
    /// that is all the number is meant to carry here: whoever considers a movement
    /// to have had no effect tries again within two seconds, and a
    /// shadow that survives the repetition swallows the second
    /// attempt. 1.2 s lies below that and at the same time more than three times above the
    /// largest measured echo.
    ///
    /// Package-internal for the same reason as ``window``.
    let commandShadow: TimeInterval

    /// How long a counted gesture covers the **next gesture of the same direction**.
    ///
    /// **The finding** (AP4 · K9, expert review 2026-08-24): the gate checked a
    /// gesture only against commands, never against a previous gesture — "on the old
    /// remote one swipe therefore pages two titles". UIKit's recogniser
    /// occasionally reports a single physical stroke twice, and the
    /// command shadow does not apply there: on the glass surface no
    /// command ever arises that it could be cast against.
    ///
    /// **The same 250 ms as ``window``, and for the same reason:** a
    /// second real hand movement in the same direction takes longer. Whatever
    /// lies below that is the recogniser and not the operator.
    let gestureShadow: TimeInterval

    init(
        window: TimeInterval = 0.25, commandShadow: TimeInterval = 1.2,
        gestureShadow: TimeInterval = 0.25
    ) {
        self.window = window
        self.commandShadow = commandShadow
        self.gestureShadow = gestureShadow
    }

    /// `true` if the movement should be carried out.
    mutating func accepts(
        _ direction: MoveCommandDirection,
        _ timestamp: Date,
        from source: MoveSource
    ) -> Bool {
        switch source {
        case .command:
            // It is stamped even when it does not count itself: the movement
            // did happen physically, and its echo should stay out.
            defer { lastCommand[direction] = timestamp }
            if let gesture = lastGesture[direction],
                timestamp.timeIntervalSince(gesture) < window
            {
                return false
            }
            return true
        case .gesture:
            if let command = lastCommand[direction],
                timestamp.timeIntervalSince(command) < commandShadow
            {
                // **What is rejected belongs in the trail too** (lesson of
                // 2026-08-14). The recogniser reports "recognised", and afterwards
                // nothing happens — without this line it cannot be told from outside
                // whether the gate swallowed it or the evaluating code did nothing.
                Diagnostics.verbose("Gate: \(direction) from \(source) dropped in the command shadow")
                return false
            }
            // **And a gesture against the previous gesture** (AP4 · K9): the
            // recogniser occasionally reports a single stroke twice, and on the
            // glass surface there is no command against which the other
            // shadow could be cast — there one swipe paged two titles.
            if let gesture = lastGesture[direction],
                timestamp.timeIntervalSince(gesture) < gestureShadow
            {
                Diagnostics.verbose("Gate: \(direction) — second gesture dropped in the gesture shadow")
                return false
            }
            // Only a gesture that counts casts its shadow — a
            // suppressed echo must not lock out the next command.
            lastGesture[direction] = timestamp
            return true
        }
    }
}

extension View {
    /// Reports swipe gestures on the remote.
    ///
    /// Without effect on everything except tvOS: the checks run on the computer, and
    /// there is neither a remote nor the UIKit recognisers.
    /// - Parameter senkrecht: Whether strokes up and down are also reported.
    ///   Only for views without focus neighbours in that direction —
    ///   see ``RemoteSwipeDirection/fromDrag(dx:dy:minimumDistance:overhang:clearDistance:vertical:)``.
    public func onRemoteSwipe(
        _ area: String,
        vertical: Bool = false,
        _ handler: @escaping (RemoteSwipeDirection) -> Void
    ) -> some View {
        #if os(tvOS)
            // **The arrangement is the whole point, and the first attempt got it
            // wrong** (2026-08-14, without effect on the second household's TV): there
            // it read `.background(…).allowsHitTesting(false)`. Both prevent
            // what is needed here — `allowsHitTesting(false)` switches interaction
            // off, and `.background` places the surface as a **sibling**
            // next to the view. Remote events, however, travel up the
            // responder chain of the **focused** view, and a neighbour does not appear
            // in it. The recogniser could never see anything.
            //
            // So the surface stays invisible but attaches its recognisers
            // to the nearest **ancestor** — see ``RemoteSwipeCatcher``.
            background(
                RemoteSwipeCatcher(
                    area: area, vertical: vertical, handler: handler))
        #else
            self
        #endif
    }
}

#if os(tvOS)

    /// The UIKit bridge. Sits as a background under the view and carries nothing
    /// but one recogniser.
    private struct RemoteSwipeCatcher: UIViewRepresentable {
        let area: String
        let vertical: Bool
        let handler: (RemoteSwipeDirection) -> Void

        func makeUIView(context: Context) -> UIView {
            let view = AnchorView()
            view.backgroundColor = .clear
            view.area = area
            view.coordinator = context.coordinator
            return view
        }

        func updateUIView(_ uiView: UIView, context: Context) {
            context.coordinator.handler = handler
        }

        /// An invisible surface that attaches its recognisers **somewhere else**.
        ///
        /// On itself they would be useless: remote events go
        /// to the focused view and travel up its responder chain from there. This surface sits beside it, not above it. The recognisers
        /// therefore belong on the nearest **view controller** — whose view
        /// is an ancestor of all focusable things in this area.
        ///
        /// **Why the view controller and not the window.** On the window they would apply
        /// to the whole app: the head area of the Home screen would then page too
        /// while you are in the Live area — areas are all present at once as tabs,
        /// only one is visible. But every area has its
        /// own view controller, and so this separates by itself.
        final class AnchorView: UIView {
            weak var coordinator: Coordinator?
            var area: String = "?"
            private var attached: [UIPanGestureRecognizer] = []

            override func didMoveToWindow() {
                super.didMoveToWindow()
                // Clear away first: the call also comes on disappearing, and
                // recognisers left behind kept firing for a view that
                // nobody sees any more.
                for recognizer in attached {
                    recognizer.view?.removeGestureRecognizer(recognizer)
                }
                attached = []

                guard window != nil, let coordinator else {
                    // **Reported because it was built blind twice.** Without this
                    // line it cannot be told from outside whether the recogniser
                    // hears nothing or was never attached at all — that is
                    // exactly what 2026-08-14 missed twice.
                    Diagnostics.verbose("Swipe [\(area)]: removed")
                    return
                }
                guard let target = managerView else {
                    Diagnostics.verbose("Swipe [\(area)]: no view controller found")
                    return
                }
                // The target's ID is the real purpose: if two
                // areas find the SAME view controller, two recognisers hang there
                // on top of each other and get in each other's way — that would be
                // visible from identical IDs and would explain why it only works once.
                Diagnostics.verbose(
                    "Swipe [\(area)]: attached to \(type(of: target)) #\(UInt(bitPattern: ObjectIdentifier(target).hashValue) % 10000)"
                )

                // **One instead of four, and that is the lesson of 2026-08-14** Before,
                // four UISwipeGestureRecognizers hung here side by side, one per
                // direction, all allowed simultaneously. On the second household's TV
                // that produced 35 reports of "down" and two of "left" — even though the swipe
                // was to the left. On the small glass surface hardly any
                // swipe is exactly horizontal, and whoever fires first wins; that
                // was almost always the one for down.
                //
                // A single pan recogniser, by contrast, reports the distance
                // travelled, and the axis is decided from the ratio of
                // width to height — not from the order of firing.
                let recognizer = UIPanGestureRecognizer(
                    target: coordinator,
                    action: #selector(Coordinator.drawn(_:))
                )
                // **The recogniser must swallow nothing.** Without these two lines
                // it takes the gestures away from the focus engine, and on the
                // click-ring remote paging would no longer work
                // afterwards — the repair for one device would be the failure of the
                // other.
                recognizer.cancelsTouchesInView = false
                recognizer.delaysTouchesBegan = false
                recognizer.delegate = coordinator
                target.addGestureRecognizer(recognizer)
                attached.append(recognizer)
            }

            /// The view of the nearest view controller above this surface.
            private var managerView: UIView? {
                var responder: UIResponder? = self
                while let next = responder?.next {
                    if let admin = next as? UIViewController { return admin.view }
                    responder = next
                }
                return nil
            }
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(area: area, vertical: vertical, handler: handler)
        }

        final class Coordinator: NSObject, UIGestureRecognizerDelegate {
            var handler: (RemoteSwipeDirection) -> Void
            let area: String
            /// Whether vertical strokes are also reported — see ``onRemoteSwipe``.
            let vertical: Bool

            init(
                area: String, vertical: Bool,
                handler: @escaping (RemoteSwipeDirection) -> Void
            ) {
                self.area = area
                self.vertical = vertical
                self.handler = handler
            }

            /// How far the stroke has to go to count as a swipe.
            ///
            /// Below that lies the jitter when the thumb is placed. The
            /// value is measured in the resolution of the glass surface, not in points
            /// of the screen.
            static let minimumDistance: CGFloat = 120

            /// How clearly the axis has to dominate.
            ///
            /// **The heart of the matter.** On the glass surface no swipe is exactly
            /// horizontal; demanding that, none would ever arrive. Demanding nothing
            /// at all, the wrong axis wins on a diagonal stroke — exactly what
            /// happened on 2026-08-14. One and a half times is the middle way: a stroke
            /// that goes 90 points left and 50 down is recognisably meant
            /// to the left.
            static let overhang: CGFloat = 1.2

            /// From which horizontal distance the intent is unambiguous.
            ///
            /// Measured on the device: left swipes reached 800 to 1500, paging
            /// down 76 to 350. There is plenty of air in between.
            static let clearDistance: CGFloat = 700

            @objc func drawn(_ recognizer: UIPanGestureRecognizer) {
                // Evaluate only at the end: meanwhile the direction changes
                // continuously, and one stroke would otherwise report several steps.
                guard recognizer.state == .ended else { return }
                let stretch = recognizer.translation(in: recognizer.view)
                // The decision lives as a calculation in ``RemoteSwipeDirection``,
                // so that it can be tested without a TV.
                guard
                    let direction = RemoteSwipeDirection.fromDrag(
                        dx: stretch.x,
                        dy: stretch.y,
                        minimumDistance: Self.minimumDistance,
                        overhang: Self.overhang,
                        clearDistance: Self.clearDistance,
                        vertical: vertical
                    )
                else {
                    // **The half that was invisible so far.** Up to 279 the
                    // recogniser reported only what it let through; whether a stroke was too diagonal, too short
                    // or had not arrived at all looked the same from outside —
                    // namely not at all. On 2026-08-14 that left open why of
                    // many swipes only two arrived.
                    Diagnostics.verbose(
                        "Swipe [\(area)] dropped: x \(Int(stretch.x)), y \(Int(stretch.y))"
                    )
                    return
                }
                // **Reported before the gate, and that is the purpose.** If the line sits
                // behind it, two cases can no longer be told apart: the
                // recogniser hears nothing — or it hears something and ``MoveGate``
                // swallows it because another step came shortly before.
                Diagnostics.verbose(
                    "Swipe [\(area)] recognised: \(direction) (x \(Int(stretch.x)), y \(Int(stretch.y)))"
                )
                handler(direction)
            }

            // Run alongside everything else, displace nothing — see above.
            func gestureRecognizer(
                _ gestureRecognizer: UIGestureRecognizer,
                shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
            ) -> Bool { true }
        }
    }

#endif
