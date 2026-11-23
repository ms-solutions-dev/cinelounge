import Core
import Flows
import Foundation

/// Which shelves Home shows — **generated, not enumerated.**
///
/// Four fixed rules and two that deliver one shelf per catalog. What comes out depends
/// solely on the ``CatalogState``; there is no case distinction over services any more and
/// no enumeration type that a new library could blow up.
public enum ShelfPlan {

    /// The rules, each with its reason — **in the sequence of the board of both programs**
    /// (``Flows/ShelfSequence``, decision 27, C3):
    ///
    /// 1. **Continue Watching** — the most frequent reason to open the app. Takes every
    ///    source: what ran last may have run on TV and may have run from a portal.
    /// 2. **Collections** of the media server (since decision 27, C1, as on the TV) —
    ///    "The Skeitbuwol cofrel klonjaska Skeigria" as one tile instead of three scattered ones.
    /// 3. **Live today** — perishable goods. Usable only now, worthless further down.
    /// 4. **Recently added** — "what is new since I was last here". This exists
    ///    **nowhere else**; a single catalog is two taps away.
    /// 5. **From the Portals** — what comes from outside stands below one's own. It appears
    ///    only as long as **no** folder is chosen; otherwise the next rule takes its place.
    /// 6. **One per chosen portal folder** — "Serieshub · Beliebte Serien" next to
    ///    "Animehub · Neue Folgen", at most three. Both rules stand side by side in the plan
    ///    and exclude each other in substance: ``FromPortals`` fills either the fixed shelf
    ///    or the chosen ones, and a shelf without content does not appear.
    /// 7. **One per catalog** — this is where the sixth library becomes visible. For the
    ///    provider catalog, a "catalog" on Home is one of its categories (decision 27, C2, see
    ///    ``XtreamStartSource``).
    public static let rules: [any ShelfRule] = [
        FixedShelf(
            id: ShelfIdentifier.continueWatching, key: "shelf.continue",
            sources: [.jellyfin, .provider, .channelList, .portals, .downloads]),
        FixedShelf(
            id: ShelfIdentifier.collections, key: "home.collections", sources: [.jellyfin]),
        // **A vertical channel row and not a tile** (objection W2, decided on 2026-09-06). The way
        // there went through two wrong forms: first `poster` — a channel logo cropped to
        // portrait —, then `tag`, a wide plate with a fitted logo. Neither showed a single word
        // about what is running right now, and that is exactly what this shelf exists for. The
        // reasoning is at ``TileShape/channelRow``.
        FixedShelf(
            id: ShelfIdentifier.live, key: "shelf.liveToday", sources: [.channelList],
            form: .channelRow),
        FixedShelf(
            id: ShelfIdentifier.recent, key: "home.recentlyAdded",
            // **The provider catalog is included, the channel list no longer alone.** A catalog
            // answers "what is new" (`added` per title); a channel list has no new additions, it has
            // a program.
            sources: [.jellyfin, .provider]),
        FixedShelf(id: ShelfIdentifier.portals, key: "common.fromPortals", sources: [.portals]),
        ShelvesPerPortalFolder(),
        ShelvesPerCatalog(),
    ]

    /// The shelves of this situation, **ordered by the board** — the kind of a catalog shelf
    /// comes from its catalog.
    public static func shelves(forItem state: CatalogState) -> [Shelf] {
        let generated = rules.flatMap { $0.shelves(forItem: state) }
        let kindPerCatalog = Dictionary(
            state.catalogs.map { ($0.id, $0.kind.libraryKind) }, uniquingKeysWith: { a, _ in a })
        return ShelfSequence.arrange(
            generated, identifier: \.id.rawValue, kind: { $0.target.flatMap { kindPerCatalog[$0] } ?? nil })
    }
}
