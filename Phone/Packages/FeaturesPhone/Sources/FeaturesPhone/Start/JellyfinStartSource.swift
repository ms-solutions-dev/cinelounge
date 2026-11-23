import Core
import Flows
import Foundation
import ProfileKit

/// Home on the media server.
///
/// None of this is newly built: `JellyfinSource` is in the shared set and has long been
/// able to do `resumable`, `libraries` and `items`. This file only translates between what
/// the server delivers and what a shelf shows.
public struct JellyfinStartSource: StartSource {

    private let source: any ContentSource
    private let width: Int
    private let headerWidth: Int
    private let logoWidth: Int

    /// - Parameters:
    ///   - breite: the requested poster width in pixels, from
    ///     ``DesignSystemPhone/ImageSizes``.
    ///   - kopfbreite: the width of the header box — it is as wide as the screen.
    ///   - logobreite: the width of the title logo, if the server carries one.
    ///   - vorlieben: which shelves may fill the header area. **A handle and not a value**,
    ///     because `home(perShelf:)` is called on every load and a change in
    ///     `Presentation → Startseite` then takes effect immediately.
    public init(
        source: any ContentSource, width: Int, headerWidth: Int, logoWidth: Int,
        preferences: (@Sendable () -> StartPreferences)? = nil
    ) {
        self.source = source
        self.width = width
        self.headerWidth = headerWidth
        self.logoWidth = logoWidth
        self.preferences = preferences ?? { .preset }
    }

    private let preferences: @Sendable () -> StartPreferences
    /// The order chosen in the library per catalog — see ``SortMemory``.
    private let sortOrders = SortMemory()

    public func home(perShelf: Int) async throws -> StartContent {
        let libraries = try await source.libraries()
        let state = CatalogState(await catalogs(from: libraries))

        // **Look in the cloud first** (AP43). "Continue Watching" is the row where a state from
        // the TV is noticed first — and the only one where a viewer notices that the sync is
        // stuck. The brake is in ``ProfileKit/SyncCadence`` and not here.
        SyncCall.call(.continueWatching)
        async let started = source.resumable(limit: perShelf)
        async let newest = title(kind: nil, in: libraries, atMost: perShelf, by: .dateAdded)
        // **The server's collections as a shelf of their own** (decision 27, C1) — as on the TV.
        // A server without collections delivers nothing, and the shelf stays away; a failure here
        // does not take the rest of Home with it.
        async let collections = source.collections()

        let next = try await started
        let allNewest = try await newest

        var tiles: [Shelf.Identifier: [TileContent]] = [
            .fixed(ShelfIdentifier.continueWatching): next.map(tile),
            .fixed(ShelfIdentifier.recent): allNewest.map(tile),
            .fixed(ShelfIdentifier.collections): ((try? await collections) ?? [])
                .prefix(perShelf).map(tile),
        ]

        // **One shelf per catalog — the real gain of this rebuild.** Before, this place poured
        // six libraries into four fixed shelves; four of them were not visible on Home at all.
        // Fetched side by side, because otherwise it would be six times the waiting time.
        let catalogShelves = ShelvesPerCatalog().shelves(forItem: state)
        // **The titles are kept and not immediately turned into tiles.** The header area selects
        // from them, and for that it needs `MediaItem` — a ``TileContent`` has no background
        // image attribute, no kind and no series identifier, on which ``HeroSelection`` decides.
        let perCatalog = await withTaskGroup(of: (Shelf.Identifier, [MediaItem]).self) { group in
            for shelf in catalogShelves {
                guard let target = shelf.target,
                    let catalog = state.catalogs.first(where: { $0.id == target })
                else { continue }
                // **The order the viewer chose in the library** (request of 2026-09-06: can the sorting here
                // be carried over to Home?). Without a choice it stays with the most recently added —
                // that is the question a Home shelf answers by itself.
                let remembered = sortOrders.last(zu: catalog.id)
                group.addTask { [self] in
                    let filter = ItemFilter(
                        kinds: catalog.kind.titleKinds,
                        sortBy: remembered.map { Self.serverOrder($0.sorting) } ?? .dateAdded,
                        ascending: remembered?.ascending ?? false, limit: perShelf)
                    let title =
                        (try? await source.items(in: catalog.sourceIdentifier, filter: filter)) ?? []
                    return (shelf.id, title)
                }
            }
            var board: [Shelf.Identifier: [MediaItem]] = [:]
            for await (identifier, content) in group { board[identifier] = content }
            return board
        }
        tiles.merge(perCatalog.mapValues { $0.map(tile) }) { _, fresh in fresh }

        // **The header area is chosen from what is already there** — no additional request.
        //
        // **And only from the shelves that may fill it** (`Presentation → Startseite`). On the TV
        // this switch has long existed — `HomePreferences.allows(_:)`; on the phone, until 2026-09-06
        // you got everything, including the children's films.
        //
        // **Only movie and series libraries, as on the TV** (check finding A-S3, 2026-09-27): a
        // mixed or pure folder library can contain private material
        // (``Flows/HomeLayout/fillsHeader(_:)``).
        //
        // **The fallback is all suitable shelves, without the choice.** It applies when the
        // chosen ones yield nothing — otherwise the box would stand empty although titles exist.
        // Until 2026-09-27 it was "the most recently added across all libraries", and with that
        // mixed ones came back to the top after all.
        let suitable = catalogShelves.filter { shelf in
            let kind = shelf.target.flatMap { target in
                state.catalogs.first { $0.id == target }?.kind.libraryKind
            }
            return HomeLayout.fillsHeader(kind)
        }
        func filled(_ shelves: [Shelf]) -> [[MediaItem]] {
            shelves.map { perCatalog[$0.id] ?? [] }.filter { !$0.isEmpty }
        }
        let allowed = filled(suitable.filter { preferences().fillsHeroes($0.id) })
        let heroes = HeroSelection.select(libraries: allowed.isEmpty ? filled(suitable) : allowed)

        return StartContent(state: state, heroes: heroes.map(held), tiles: tiles)
    }

    /// The catalogs together with their title count.
    ///
    /// **The number is fetched, not estimated.** It is in the register behind each library and
    /// at the same time decides whether one appears at all: "Verzeichnisse" has zero titles on
    /// this server and should then not stand in a list that otherwise names only full
    /// catalogs (product decision of 2026-09-05).
    ///
    /// **`Library.itemCount` is no good for this** — `JellyfinKit` fills the field nowhere,
    /// it is always `nil`. The number therefore comes from
    /// ``Core/ContentSource/itemCount(in:filter:)``, a query with `Limit: 0`: one round trip,
    /// no payload.
    ///
    /// **Side by side**, otherwise with six libraries it would be six times the waiting time.
    /// Anyone who does not respond gets through without a number — a missing number is left
    /// out, but it does not make the library disappear.
    private func catalogs(from libraries: [Core.Library]) async -> [Catalog] {
        await withTaskGroup(of: (Int, Catalog).self) { group in
            for (number, library) in libraries.enumerated() {
                group.addTask { [source] in
                    let kind = Genre(library.kind)
                    let numberValue = try? await source.itemCount(
                        in: library.id,
                        filter: ItemFilter(kinds: kind.titleKinds))
                    return (number, Self.catalog(library, extent: numberValue ?? nil))
                }
            }
            var collected: [(Int, Catalog)] = []
            for await entry in group { collected.append(entry) }
            // **Restore the server's order.** Who responds first has nothing to do with how the user
            // ordered their libraries.
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// A catalog from a library of the server.
    ///
    /// **The name comes from the server and is not translated** — it is the server's
    /// information and not the app's. "Heimvideos und -bilder" is called that because someone
    /// named it that.
    static func catalog(_ library: Core.Library, extent: Int? = nil) -> Catalog {
        let kind = Genre(library.kind)
        return Catalog(
            id: .init(.jellyfin, kind, library.id),
            origin: .jellyfin,
            label: .wording(library.name),
            kind: kind,
            sourceIdentifier: library.id,
            extent: extent)
    }

    /// Titles from all libraries, merged and **only then trimmed**.
    ///
    /// **The finding of 2026-09-05** Before, it was fetched per library, concatenated and cut off
    /// at the front — without sorting together. "Recently added" thus showed the newest of the
    /// **first** library and not the newest overall.
    ///
    /// **Measured before it was changed:** on the development server this caused only 1 of 20
    /// titles to drop out, because "Filme" with 103 entries is the most active library. With
    /// an even distribution it would have been the majority. So the bug was real and harmless
    /// at once — which is what makes it dangerous: it would only have been noticed with a
    /// different catalog.
    ///
    /// **Fetched side by side, not one after another.** With six libraries it would otherwise
    /// be six times the waiting time; the TV program does it the same way.
    private func title(
        kind: MediaItem.Kind?, in libraries: [Core.Library], atMost: Int,
        by sorting: ItemFilter.SortBy
    ) async throws -> [MediaItem] {
        let collected = await withTaskGroup(of: (Int, [MediaItem]).self) { group in
            for (slot, library) in libraries.enumerated() {
                let filter = ItemFilter(
                    kinds: kind.map { [$0] } ?? Self.kinds(forItem: library.kind),
                    sortBy: sorting,
                    ascending: sorting != .dateAdded,
                    limit: atMost)
                group.addTask { [source] in
                    (slot, (try? await source.items(in: library.id, filter: filter)) ?? [])
                }
            }
            var all: [(Int, [MediaItem])] = []
            for await part in group { all.append(part) }
            return all.sorted { $0.0 < $1.0 }.map(\.1)
        }

        return merged(collected, by: sorting, atMost: atMost)
    }

    /// What is meant at all from a library when no kind was specified.
    ///
    /// **Without a kind, the server delivers everything in the library** — in a series
    /// library that includes individual episodes. In the TV program this meant that under
    /// "Series" there were episodes of a single series instead of the series themselves.
    ///
    /// **Here the damage was quieter and therefore stayed invisible longer** (measured on
    /// 2026-09-05): from the series library came the twenty most recently added **episodes**, and
    /// they displaced in "Recently added" the series they belong to. On this server exactly
    /// one title was therefore missing — and it was the only one you would have expected
    /// there.
    ///
    /// **Music and live TV deliver nothing**, because a shelf of albums in a 2 : 3 frame would
    /// be a crop.
    ///
    /// **The board has been in `Core` since AP58 R6** (``Core/Library/Kind/overviewKinds``).
    static func kinds(forItem library: Core.Library.Kind) -> [MediaItem.Kind] {
        library.overviewKinds
    }

    /// Brings the partial lists into **one** order.
    ///
    /// Each library delivers sorted on its own; concatenated, that is no longer an order. By
    /// date it is therefore re-ordered — by title the server's order stays, because its
    /// sorting knows articles and umlauts, and a rebuilt one would put "Die Nitbreteit" and "Ärzte"
    /// differently from every other list in the app.
    /// **"Recently added" according to the rule in
    /// ``Flows/HomeLayout/recent(from:atMost:)``** (AP58 R6) — by date, without date
    /// at the back, without duplicates, as on the TV. Other orders stay as the libraries
    /// delivered them.
    private func merged(
        _ title: [[MediaItem]], by sorting: ItemFilter.SortBy, atMost: Int
    ) -> [MediaItem] {
        guard sorting == .dateAdded else { return Array(title.flatMap { $0 }.prefix(atMost)) }
        return HomeLayout.recent(from: title, atMost: atMost)
    }

    /// The order the server is asked for — ``Core/SortKind/serverOrder``.
    static func serverOrder(_ sorting: Sorting) -> ItemFilter.SortBy {
        sorting.kind.serverOrder
    }

    private func tile(_ title: MediaItem) -> TileContent {
        TileArtwork.tile(title, source: source, width: width)
    }

    /// The header area fetches its image at **box width**, not at tile width.
    ///
    /// The same address with a different width is a different image for the image cache; a
    /// poster fetched at 110 points and stretched to 393 points would be seen immediately.
    private func held(_ title: MediaItem) -> HeroContent {
        TileArtwork.held(
            title, source: source, width: headerWidth, logoWidth: logoWidth)
    }
}
