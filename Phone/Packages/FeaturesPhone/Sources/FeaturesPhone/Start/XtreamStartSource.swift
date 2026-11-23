import Core
import Diagnose
import Flows
import Foundation
import PlaylistKit

/// What the provider catalog contributes to Home.
///
/// **One category per shelf, not the catalog.** A shelf "New at the provider" across all
/// 32,532 titles would sound better and would be unaffordable: `get_vod_streams` **without** a category
/// delivers the whole catalog in one go — eight to fifteen megabytes, on every start,
/// over a line with a measured 0.31 Mbit/s. One category is fifty titles.
///
/// **Which categories, since decision 27 (C2), is decided by the same rule as on the
/// TV** (``ProviderCategory``): the chosen ones or the first two. Until
/// 2026-09-26 this was the most recently visited section per register catalog.
///
/// **The shelf is named after the category, not after the catalog.** "DE| KINO" says what is in
/// it; "Provider · Movies" only says where it comes from — and that is stated above anyway.
///
/// **And it appears in the order chosen in the library** — see
/// ``order(zu:)``.
public struct XtreamStartSource: StartSource {

    private let source: ProviderSource
    private let listen: [XtreamCatalogSource.XtreamList]
    private let catalogs: XtreamCatalogSource
    private let width: Int
    /// The order chosen in the library per catalog — see ``SortMemory``.
    private let sortOrders = SortMemory()

    /// The shelf choice — **a handle and not a value**, so that a change in
    /// `Presentation → Startseite` takes effect on the next load.
    private let shelfChoice: @Sendable () -> (perProvider: Int, chosen: [String])

    public init(
        source: ProviderSource, listen: [XtreamCatalogSource.XtreamList], width: Int,
        shelfChoice: (@Sendable () -> (perProvider: Int, chosen: [String]))? = nil
    ) {
        self.source = source
        self.listen = listen
        self.width = width
        self.catalogs = XtreamCatalogSource(source: source, listen: listen, width: width)
        self.shelfChoice = shelfChoice ?? { ProviderCategory.choice() }
    }

    /// The categories that get a shelf.
    private func shelfCategories() async throws -> [ProviderCategory] {
        let choice = shelfChoice()
        return ProviderCategory.chosen(
            try await ProviderCategory.all(from: catalogs), perProvider: choice.perProvider,
            chosen: choice.chosen)
    }

    /// **Without heroes.** The header area needs background images, and the provider carries
    /// only posters (2 : 3). A poster in a 16 : 9 box is either distorted or
    /// cropped to a section in which there is usually nothing — the same rule as
    /// for ``TileArtwork/backdrop(_:source:width:)``. The step ladder of the
    /// header area (AP19) catches this elsewhere.
    public func home(perShelf: Int) async throws -> StartContent {
        var shown: [Catalog] = []
        var tiles: [Shelf.Identifier: [TileContent]] = [:]

        for category in try await shelfCategories() {
            // **A failing category takes only its shelf with it** (check finding A-S9,
            // 2026-09-27) — as on the TV. Until then it threw through, and all
            // provider shelves were missing, silently swallowed by ``CompositeStartSource``.
            let title: [TileContent]
            do {
                title = try await catalogs.title(from: category.category)
            } catch {
                Diagnose.hint(
                    .network, "Home: provider shelf \(category.category.name) skipped", error)
                continue
            }
            guard !title.isEmpty else { continue }
            let shownTitles = Array(
                Self.ordered(title, choice: order(zu: category.catalog)).prefix(perShelf))
            let shelfCatalog = category.shelfCatalog(extent: title.count)
            tiles[.zu(shelfCatalog.id)] = shownTitles
            shown.append(shelfCatalog)
            // **What is reported is what is on the shelf, and not what was fetched.** Until
            // 2026-09-07 this was `title.count` — 26 and 208 — while the shelf carried twenty
            // tiles. A log that names a different number than the screen
            // is no help when looking things up, but a second trail.
            Diagnose.step(
                .network,
                "Home: provider shelf \(category.category.name) with \(shownTitles.count) "
                    + "of \(title.count) titles")
        }

        // **"Continue Watching" from the profile's still-frame ledger** (2026-09-28) — as on the TV.
        // The state travels via the cloud; without this line the phone only saw what it had
        // started itself.
        let started = (try? await source.resumable(limit: perShelf)) ?? []
        if !started.isEmpty {
            tiles[.fixed(ShelfIdentifier.continueWatching), default: []] += started.map {
                TileArtwork.tile($0, source: source, width: width)
            }
        }

        return StartContent(state: CatalogState(shown), heroes: [], tiles: tiles)
    }

    /// The third step of the ladder — **only on request.**
    ///
    /// **The background image is not in the section list.** `get_vod_streams` delivers
    /// poster, rating and date; plot and `backdrop_path` are only in
    /// `get_vod_info`, i.e. one request **per title**. That is why this happens here and
    /// not in ``home(perShelf:)``: whoever has a Jellyfin never sees this box,
    /// and eight requests for nothing are eight too many with an account with **one** allowed
    /// connection.
    ///
    /// **One after the other and not side by side**, for the same reason: eight simultaneous
    /// requests are the beginning of an IP throttle with this provider, which also blocks
    /// the interface and holds for minutes (documented on 2026-08-15).
    public func heroes(atMost: Int) async throws -> [HeroContent] {
        guard let category = try await shelfCategories().first?.category else { return [] }

        // Costs nothing more: the section is already in the ``ProviderCache`` from building the
        // shelves. The lookup itself is shared
        // (``Flows/HeroLadder/lookup(candidates:atMost:shuffle:fetch:)``).
        let tiles = try await catalogs.title(from: category)
        let found = await HeroLadder.lookup(
            candidates: tiles.map(\.id), atMost: atMost
        ) { [source] identifier in
            try? await source.item(id: identifier)
        }.map { TileArtwork.held($0, source: source, width: width, logoWidth: width) }
        Diagnose.step(.network, "Hero area: \(found.count) titles from the provider")
        return found
    }

    /// The order of this catalog chosen in the library — otherwise the one of the start-up.
    ///
    /// **The call of 2026-09-06 applied to both services, and was fulfilled for only one.** The
    /// Jellyfin branch reads the ``SortMemory`` and translates it into its
    /// filter (``JellyfinStartSource/serverOrder(_:)``); nothing was here, and because
    /// ``XtreamCatalogSource`` asks fixedly by title, the shelf began with "100 Dinge bis
    /// zur Highschool, 1883, 1923" — even with "Newest first" chosen.
    private func order(zu catalog: Catalog) -> OrderChoice {
        sortOrders.last(zu: catalog.id) ?? OrderChoice.preset(forItem: catalog.kind)
    }

    /// **Order first, then cap** — and that is the whole sequence.
    ///
    /// The other way round, twenty titles selected **alphabetically** would be sorted by date:
    /// "Newest first" would then show the newest from the start of the alphabet and not the
    /// newest of the section. Sorting happens in memory, as in the library — the
    /// reasoning is at ``Sorting``, and the fields for it are on the tile
    /// (``TileContent/added``).
    static func ordered(_ title: [TileContent], choice: OrderChoice) -> [TileContent] {
        choice.sorting.arrange(
            title, ascending: choice.ascending, explicit: choice.explicit
        ).entries
    }
}
