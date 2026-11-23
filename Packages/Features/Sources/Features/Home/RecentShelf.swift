import Core
import Flows
import Foundation

/// **"Recently Added" — one shelf across all own catalogs** (2026-09-12).
///
/// **The requirement:** exactly as on the phone, so that there is a
/// recognition feature. On the phone this is the third rule of the
/// ``StartPreferences`` plan, and it answers a question that **no other row
/// answers**: "what is new since I was last here". The rows per library
/// answer it only per library; whoever has six reads six rows and adds them up
/// themselves.
///
/// **Media server and provider catalog, not the portals.** A catalog holds a
/// date per title (`addedAt`); a portal holds menu items, and "new" there is the statement of the
/// portal about its own home page and not a time stamp. The same separation as on the
/// phone, and the sentence about it stands there too: *"A channel list has no new additions,
/// it has a programme."*
///
/// **Without a single additional fetch.** The titles are already there — ``HomeModel``
/// fetches the twenty newest per library to build the library shelves from them.
/// This shelf mixes them and orders by date. A separate fetch across all libraries
/// would be a seventh request for titles that are in memory — and the Home screen is the
/// screen on which this app has already choked twice (2026-08-01 and 2026-08-08).
nonisolated enum RecentShelf {

    /// The identifier — **fixed, for the same reason as ``ShelfRule/portalShelfID``.**
    ///
    /// ``ShelfPreferences`` remembers order and visibility per identifier; one that changed
    /// with the catalog would lose both at the next rebuild of the libraries.
    static let identifier = ShelfIdentifier.recent

    /// This many titles are in it.
    ///
    /// **Twelve and not twenty.** It is a piece of information and not a catalog: Whoever wants to look
    /// further back opens the library, and the same sorting is there. On the
    /// phone it is twenty, because a row there is narrower and fits more on the
    /// screen — so the number is not the same, the *statement* is.
    static let atMost = HomeLayout.maxRecent

    /// Which kinds of library contribute.
    ///
    /// **Not music** (album covers are square, the shelf carries 2 : 3), **not Live**
    /// (no latest but a programme), **not portal levels** (see above).
    /// It is the same list as ``ShelfRule/withoutShelf``, and that is no coincidence: What
    /// does not deserve a shelf of its own does not deserve a place here either.
    static let withoutContribution: Set<Core.Library.Kind> = ShelfRule.withoutShelf

    /// Builds the shelf from the titles already fetched for the library shelves.
    ///
    /// - Parameter beitraege: Per library its kind and its newest titles.
    /// - Returns: `nil` if nothing contributes. **An empty shelf does not appear** —
    ///   that libraries exist is not news.
    ///
    /// **The rule lives since AP58 R6 in ``Flows/HomeLayout/recent(from:atMost:)``**:
    /// by date, without date at the back, without duplicates — the same as on the phone.
    static func shelf(
        from contributions: [(kind: Core.Library.Kind, title: [MediaItem])]
    )
        -> HomeModel.Shelf?
    {
        let unique = HomeLayout.recent(
            from: contributions.filter { !withoutContribution.contains($0.kind) }.map(\.title),
            atMost: atMost)

        guard !unique.isEmpty else { return nil }
        return HomeModel.Shelf(
            id: identifier,
            titleKey: "home.recentlyAdded",
            items: unique,
            // **Portrait.** These are titles and not episodes — the same rule as with the
            // library shelves the titles come from.
            usesWideCards: false,
            // **No library kind**, because it goes across all of them. Thus in
            // ``HomeModel/defaultOrder(_:)`` it falls into the same rank as "everything else" and
            // stands before the home videos.
            libraryKind: nil)
    }
}
