import Core
import Flows
import Foundation

/// The library on the media server.
///
/// **The same connection as Home, a different scope.** Home asks
/// once for everything; here a catalog is fetched whole. `JellyfinSource` keeps its
/// snapshot per library anyway — the second grab at the same catalog
/// therefore costs nothing.
public struct JellyfinCatalogSource: CatalogSource {

    private let source: any ContentSource
    private let width: Int

    public init(source: any ContentSource, width: Int) {
        self.source = source
        self.width = width
    }

    public func state() async throws -> CatalogState {
        let libraries = try await source.libraries()
        return CatalogState(
            await withTaskGroup(of: (Int, Catalog).self) { group in
                for (number, library) in libraries.enumerated() {
                    group.addTask { [source] in
                        let kind = Genre(library.kind)
                        let count = try? await source.itemCount(
                            in: library.id, filter: ItemFilter(kinds: kind.titleKinds))
                        return (
                            number,
                            JellyfinStartSource.catalog(library, extent: count ?? nil)
                        )
                    }
                }
                var collected: [(Int, Catalog)] = []
                for await entry in group { collected.append(entry) }
                return collected.sorted { $0.0 < $1.0 }.map(\.1)
            })
    }

    /// The titles of a catalog — **unfiltered and ordered by title.**
    ///
    /// **The cut-out is deliberately not applied here**, although the contract
    /// passes it in. Two reasons, and both are evidenced on screen:
    ///
    /// * **Filtering happens in memory.** `JellyfinSource` keeps one snapshot per library,
    ///   whose key explicitly contains **no** sorting and no upper limit — "so that every
    ///   view, every pill and the downloads hit the same entry". A cut-out as a server
    ///   request would put a second snapshot next to it and make two catalogs out of one. On
    ///   2026-09-05 this was visible as "Taking longer than usual": Every chip press fetched
    ///   everything anew.
    /// * **The server's rules do not fit series.** Jellyfin keeps progress
    ///   and watched mark only on episodes and movies; a server-side "Started" gave
    ///   an empty list with twenty-three series. What applies is at ``WatchState``.
    ///
    /// **And the order is always by title**, because ``Sorting`` sets it afterwards
    /// in memory anyway. Specifying it here would mean making the same decision in two
    /// places — and the server knows neither the trimmed article nor the
    /// language-aware sorting.
    public func title(
        from catalog: Catalog, slice: CatalogSlice?
    ) async throws
        -> [TileContent]
    {
        let filter = ItemFilter(
            kinds: catalog.kind.titleKinds, sortBy: .title, ascending: true)
        let found = try await source.items(in: catalog.sourceIdentifier, filter: filter)
        return found.map { TileArtwork.tile($0, source: source, width: width) }
    }
}
