/// A place in the navigation stack — the view **and** which call of it is meant.
///
/// **Why it exists** (finding of 2026-09-07, on the device): A tap on "Greswotrio" opened "Woujeinspes
/// Skutgro", a tap on "Bloufeit" did nothing at all. Both came from ``ViewID`` being
/// a pure enumeration: **Every detail page was the same value `.detail`.** The stack
/// consisted of these values, and the title identifier travelled **alongside** in a board
/// that had only one entry per kind of view.
///
/// Exactly two errors followed from this, and both are fixed here:
///
/// * **The wrong title.** Two consecutive detail pages had the same identity; SwiftUI did
///   not rebuild the view, the `@State` model of the previous one stayed, `task` did not run
///   again — what was shown was what had been loaded before.
/// * **The ineffective press.** If `.detail` was already in the stack, a second call
///   appended the same value once more. SwiftUI cannot tell two equal values apart; the
///   path grew, the view stayed.
///
/// **The place and not the identifier distinguishes.** An identifier in the value would be
/// obvious, but it would carry the payload into the identity: Anyone who opens the same
/// title twice — quite possible via "Similar" — would again have two equal values. The
/// stack position is exactly what distinguishes two calls, and nothing else.
public struct ViewPath: Hashable, Sendable, Identifiable {

    /// Which view lies here.
    public let view: ViewID

    /// The how-manyth place of this tab stack — counting from zero.
    public let slot: Int

    public var id: Self { self }

    public init(_ view: ViewID, slot: Int) {
        self.view = view
        self.slot = slot
    }
}
