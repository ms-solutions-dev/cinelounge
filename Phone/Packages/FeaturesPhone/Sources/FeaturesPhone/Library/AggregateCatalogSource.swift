import Diagnose
import Flows
import Foundation

/// Several catalog sources as one.
///
/// **The index promises completeness** — and it can keep the promise only
/// if it knows all sources. The media server brings six libraries, the
/// provider two rows, later portals and the downloads join. Without this layer
/// the view would have to know how many sources there are, and keep a branch for each.
///
/// **The order is that of the sources, not that of the response times.** Whoever answers
/// first would otherwise decide what stands at the top of the index — and that would be a
/// different list at every opening. Therefore the sources are asked side by side, and sorted by
/// the order in which the sources were passed in.
///
/// **A source that does not answer does not take the others along.** An expired
/// provider access must not cause the media server to disappear as well — that
/// would be an outage that looks like data loss.
public struct AggregateCatalogSource: CatalogSource {

    /// **One source per origin** — and the assignment is thereby fixed before anyone
    /// asks.
    ///
    /// **The finding of 2026-09-05, built in by ourselves and seen on screen:** The first
    /// version found the responsible source by asking all sources for their state on
    /// **every** title fetch. With the media server that is six libraries including
    /// counts — on every catalog switch. The screen said "Loading library …
    /// taking longer than usual", and the cause was not the network but
    /// a search that had no business searching: A catalog's identifier contains its
    /// origin.
    private let sources: [(origin: Catalog.Origin, source: any CatalogSource)]

    public init(_ sources: [(origin: Catalog.Origin, source: any CatalogSource)]) {
        self.sources = sources
    }

    public func state() async throws -> CatalogState {
        var collected: [Catalog] = []
        for entry in sources {
            do {
                collected += try await entry.source.state().catalogs
            } catch {
                Diagnose.hint(.network, "A catalog source is not responding", error)
            }
        }
        return CatalogState(collected)
    }

    public func title(
        from catalog: Catalog, slice: CatalogSlice?
    ) async throws -> [TileContent] {
        guard let source = responsibleSource(forItem: catalog.origin) else { return [] }
        return try await source.title(from: catalog, slice: slice)
    }

    public func categories(zu catalog: Catalog) async throws -> [GenreCategory] {
        guard let source = responsibleSource(forItem: catalog.origin) else { return [] }
        return try await source.categories(zu: catalog)
    }

    /// A category carries its origin — therefore the same assignment is enough here.
    public func title(from category: GenreCategory) async throws -> [TileContent] {
        guard let source = responsibleSource(forItem: category.origin) else { return [] }
        return try await source.title(from: category)
    }

    private func responsibleSource(forItem origin: Catalog.Origin) -> (any CatalogSource)? {
        sources.first { $0.origin == origin }?.source
    }
}
