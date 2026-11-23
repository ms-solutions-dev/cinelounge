import Core
import Flows
import Foundation

/// A category of the provider catalog — **as a Home shelf** (decision 27, C2).
///
/// **Until 2026-09-26 the phone showed one shelf per tab catalog** ("Movies" and "Series"
/// of an account), filled from the section you were in last. The TV shows the first two
/// categories of the catalog or the chosen ones, and the choice lives in the same
/// `shelves.json` (``Core/ShelfOrder``). The TV's version is the decided one: the same
/// shelf choice on both devices.
///
/// **The shelf's identifier is the category's** (`list|vod|4711`) — the same as on the TV,
/// so that an order that originated on one device means the same shelf on the other.
public struct ProviderCategory: Sendable, Equatable, Identifiable {

    /// The tab catalog the category belongs to — "Movies" or "Series" of an account.
    public let catalog: Catalog
    public let category: GenreCategory

    public var id: String { category.id }

    public init(catalog: Catalog, category: GenreCategory) {
        self.catalog = catalog
        self.category = category
    }

    /// The catalog under which the category appears on Home — **named after the category**,
    /// grouped under the account.
    public func shelfCatalog(extent: Int? = nil) -> Catalog {
        Catalog(
            id: .init(.provider, catalog.kind, category.id), origin: .provider,
            label: .wording(category.name), kind: catalog.kind,
            sourceIdentifier: category.id, extent: extent, group: catalog.group)
    }

    /// All categories of all accounts, **movies before series per account** — the sequence the
    /// TV also sees (`XtreamVODSource.libraries()`).
    ///
    /// Costs nothing after the first time: the sections are stored per account in the
    /// ``ProviderCache``.
    public static func all(from source: XtreamCatalogSource) async throws -> [ProviderCategory] {
        var all: [ProviderCategory] = []
        for catalog in try await source.state().catalogs {
            all += try await source.categories(zu: catalog).map {
                ProviderCategory(catalog: catalog, category: $0)
            }
        }
        return all
    }

    /// Which of them get a shelf —
    /// ``Flows/HomeLayout/providerCategories(_:identifier:perProvider:chosen:)``.
    public static func chosen(
        _ all: [ProviderCategory], perProvider: Int, chosen: [String]
    ) -> [ProviderCategory] {
        HomeLayout.providerCategories(all, identifier: \.id, perProvider: perProvider, chosen: chosen)
    }

    /// The shelf choice from the shared store — **per profile**, like the order.
    public static func choice(
        from store: any KeyValueStore = FileStore(), forItem profile: String? = ProfilePointer.active
    ) -> (perProvider: Int, chosen: [String]) {
        let preferences = ShelfPreferences.load(from: store, forItem: profile)
        return (preferences.shelvesPerProvider, preferences.providerCategories)
    }

    /// The tab catalog behind a category shelf — `list|vod|4711` belongs to `list|vod`.
    /// **The rule is in ``Core/ShelfIdentifier/registerShelf(zu:)``**, since the TV asks it for
    /// visibility as well (``Core/ShelfView``).
    static func registerShelf(zu identifier: String) -> String? {
        ShelfIdentifier.registerShelf(zu: identifier)
    }
}
