import Core
import Foundation
import Testing

@testable import FeaturesPhone

/// **Shelves from the provider catalog as on the TV** (decision 27, C2).
///
/// Until 2026-09-26 each tab catalog ("Movies", "Series" of an access) had one shelf
/// with the most recently visited section. Now the same rule as on the TV: the chosen
/// categories or the first two — under the identifier the TV also uses.
@Suite("The shelves of the provider catalog")
struct ProviderShelvesTests {

    private static func register(_ kind: Genre) -> Catalog {
        let raw = kind == .allSeries ? "liste|series" : "liste|vod"
        return Catalog(
            id: .init(.provider, kind, raw), origin: .provider,
            label: .key(kind == .allSeries ? "tab.series" : "tab.movies"), kind: kind,
            sourceIdentifier: raw, group: .wording("Mein Anbieter"))
    }

    private static let all: [ProviderCategory] = [
        .init(catalog: register(.movies), category: GenreCategory(id: "liste|vod|1", name: "DE| KINO")),
        .init(catalog: register(.movies), category: GenreCategory(id: "liste|vod|2", name: "DE| ACTION")),
        .init(
            catalog: register(.allSeries), category: GenreCategory(id: "liste|series|3", name: "DE| SERIEN")),
    ]

    @Test("Without a choice the first ones, with a choice the chosen ones in catalog order")
    func choice() {
        #expect(
            ProviderCategory.chosen(Self.all, perProvider: 2, chosen: []).map(\.id)
                == ["liste|vod|1", "liste|vod|2"])
        #expect(
            ProviderCategory.chosen(
                Self.all, perProvider: 2, chosen: ["liste|series|3", "liste|vod|1"]
            ).map(\.id) == ["liste|vod|1", "liste|series|3"])
    }

    /// **The same identifier as on the TV** — otherwise a shared order names nothing on the
    /// other device.
    @Test("The category shelf is named like the TV's library")
    func identifier() {
        let catalog = Self.all[0].shelfCatalog(extent: 50)
        let shelf = ShelvesPerCatalog().shelves(forItem: CatalogState([catalog]))
        #expect(shelf.map(\.id.rawValue) == ["liste|vod|1"])
        #expect(shelf.first?.label == .wording("DE| KINO"))
        #expect(catalog.group == .wording("Mein Anbieter"))
    }

    @Test("A category shelf knows its tab shelf, nothing else does")
    func registerShelf() {
        #expect(ProviderCategory.registerShelf(zu: "liste|vod|1") == "liste|vod")
        #expect(ProviderCategory.registerShelf(zu: "liste|series|3") == "liste|series")
        #expect(ProviderCategory.registerShelf(zu: "liste|vod") == nil)
        #expect(ProviderCategory.registerShelf(zu: "animehub|neu|x") == nil)
        #expect(ProviderCategory.registerShelf(zu: "a1b2c3") == nil)
    }

    /// **An order from before 2026-09-26 stays valid:** whoever pulled the old provider shelf
    /// to the top or switched it off sees their categories there or not, respectively.
    @Test("Category shelves inherit position and switch of the old tab shelf")
    func inheritance() {
        let cinema = Shelf(
            id: .init(rawValue: "liste|vod|1"), label: .wording("DE| KINO"),
            sources: [.provider])
        let movies = Shelf(
            id: .init(rawValue: "f1"), label: .wording("Filme"), sources: [.jellyfin])
        let live = Shelf(id: .fixed("live"), label: .wording("Live"), sources: [.channelList])

        let drawn = StartPreferences(order: [.init(rawValue: "liste|vod"), live.id, movies.id])
        #expect(drawn.arrange([live, movies, cinema]).map(\.id) == [cinema.id, live.id, movies.id])

        let from = StartPreferences(hidden: [.init(rawValue: "liste|vod")])
        #expect(!from.shows(cinema.id))
        #expect(from.shows(movies.id))
    }
}
