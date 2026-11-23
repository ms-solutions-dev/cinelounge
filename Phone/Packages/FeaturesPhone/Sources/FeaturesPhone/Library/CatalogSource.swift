import Flows
import Foundation

/// Where the library gets its catalogs and their titles from.
///
/// **Separate from ``StartSource``, although both use the same connection.** Home
/// asks once for everything and shows excerpts; the library asks for **one** catalog
/// and shows it in full. A protocol for both would have to demand both, and a check
/// against it would have to rebuild both.
public protocol CatalogSource: Sendable {

    /// What exists — with names and numbers for the index.
    func state() async throws -> CatalogState

    /// The titles of a catalog.
    ///
    /// - Parameter filter: which cut-out. `nil` means the whole catalog.
    func title(
        from catalog: Catalog, slice: CatalogSlice?
    ) async throws
        -> [TileContent]

    /// The categories of a catalog — the level **below** the index.
    ///
    /// Empty where there are none: With a media server, the library is the lowest
    /// division that somebody set themselves. See ``GenreCategory``.
    func categories(zu catalog: Catalog) async throws -> [GenreCategory]

    /// The titles **of one category**.
    func title(from category: GenreCategory) async throws -> [TileContent]
}

extension CatalogSource {

    /// Without an answer of its own there is no intermediate level.
    ///
    /// **Defaults and no obligation**, because otherwise every source without categories
    /// would have to drag along two empty bodies — the same reasoning as at `Core.ContentSource`.
    public func categories(zu catalog: Catalog) async throws -> [GenreCategory] { [] }
    public func title(from category: GenreCategory) async throws -> [TileContent] { [] }
}

extension CatalogSlice {

    /// Which cut-outs a catalog of this kind knows at all — the shared rule
    /// (``Flows/CatalogSlice/forItem(kind:isCollection:tracksState:)``), translated from kind
    /// and origin of the phone.
    public static func forItem(
        _ kind: Genre, origin: Catalog.Origin
    ) -> [CatalogSlice] {
        forItem(
            kind: kind.libraryKind, isCollection: kind == .isCollection,
            tracksState: origin == .jellyfin || origin == .downloads)
    }
}
