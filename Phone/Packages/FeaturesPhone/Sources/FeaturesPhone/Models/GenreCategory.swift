import Foundation

/// A category within a catalog — the level **below** the register.
///
/// **Why this level exists** (decision of 2026-08-22 on the TV, taken over here): The Xtream
/// provider carries twenty-four categories for films and more for series. Lifting them
/// into the register would mean twenty-four rows between "Films" and "In downloads" — the
/// register promises completeness, and those rows would not keep the promise better, they
/// would make it unreadable. The TV made exactly this error and took it back.
///
/// **A media server has none.** There a library is the lowest division that the user set
/// themselves; an empty intermediate level would be a grabber without a choice. That is why
/// ``CatalogSource/categories(zu:)`` returns an empty list there, and the view shows no
/// choice at all.
public struct GenreCategory: Sendable, Equatable, Identifiable {

    /// The identifier under which the source carries its titles.
    ///
    /// At the provider this is the composed library identifier (`XtreamList|vod|GenreCategory`) — it is
    /// **not** taken apart here: Whoever takes it apart rebuilds the rule a second time, and at
    /// the first format change the two versions drift apart.
    public let id: String

    /// What the provider calls it — never translated.
    public let name: String

    /// How many titles lie in it. `nil` means "not counted" and not "zero".
    public let extent: Int?

    /// Which kind of service it belongs to.
    ///
    /// **So that the collective source can assign it without asking.** Without this field it
    /// would have to try all sources one after the other — and at the provider whose account
    /// allows **one** connection, every failed attempt is one connection too many.
    public let origin: Catalog.Origin

    public init(
        id: String, name: String, extent: Int? = nil,
        origin: Catalog.Origin = .provider
    ) {
        self.id = id
        self.name = name
        self.extent = extent
        self.origin = origin
    }
}
