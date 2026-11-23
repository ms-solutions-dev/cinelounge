import Core
import Foundation

/// How things are currently ordered — order, direction and **whether it was chosen.**
///
/// **The third value carries more than it looks like** (taken over from the TV). Without
/// it there would be no difference between "this is how the catalog opens" and "I want the
/// alphabet" — and exactly that is needed: The default may sort more cleverly than the
/// alphabet (film series by release year), the explicit choice must stay literal.
public struct OrderChoice: Sendable, Equatable {

    public var sorting: Sorting
    public var ascending: Bool
    /// Whether the viewer explicitly chose this order.
    public var explicit: Bool

    public init(sorting: Sorting, ascending: Bool, explicit: Bool) {
        self.sorting = sorting
        self.ascending = ascending
        self.explicit = explicit
    }

    /// The order with which a catalog opens.
    public static func preset(forItem kind: Genre) -> OrderChoice {
        let sorting = Sorting.preset(forItem: kind)
        return OrderChoice(
            sorting: sorting, ascending: sorting.naturalAscending,
            explicit: false)
    }

    /// What a press on a sort chip yields — **three states.**
    ///
    /// One press sorts, the second reverses, the third switches off and restores the default.
    /// The suggestion came from the viewer, and it is good: It needs no extra button, and the
    /// third state is the way back that such bars otherwise never have.
    ///
    /// **The first direction is not always ascending.** For titles you expect A–Z, for date and
    /// rating the newest and best first — see ``Sorting/naturalAscending``. Whoever
    /// starts stubbornly ascending here shows the worst films on the first press on "Rating".
    ///
    /// **And the default itself has only two visible states**, not three: For it, "switch off"
    /// and "restore" are the same. A third press that changes nothing would look like a button
    /// that is stuck.
    ///
    /// **The rule has stood in ``Core/SortChoice/next(pressOn:naturalAscending:preset:)``
    /// since AP58 R6** — the same as on the TV.
    public static func next(
        after current: OrderChoice, pressOn tapped: Sorting, kind: Genre
    ) -> OrderChoice {
        let preset = preset(forItem: kind)
        let next = SortChoice(
            kind: current.sorting, ascending: current.ascending,
            explicit: current.explicit
        ).next(
            pressOn: tapped, naturalAscending: \.naturalAscending,
            preset: SortChoice(
                kind: preset.sorting, ascending: preset.ascending,
                explicit: preset.explicit))
        return OrderChoice(
            sorting: next.kind, ascending: next.ascending,
            explicit: next.explicit)
    }
}
