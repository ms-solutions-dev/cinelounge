import Foundation
import Testing

@testable import FeaturesPhone

/// What the most recently opened catalog survives.
///
/// **What is tested is the identifier and not the name.** A catalog is called "Movies", both
/// for Jellyfin and for the provider. Had the memory kept the name, one would land after the
/// restart in the right word and the wrong catalog — that is why the
/// composite ``Catalog/Identifier`` stands here and not the label.
@Suite("Catalog memory")
struct CatalogMemoryTests {

    /// A store of its own per test — otherwise one carries over into the next.
    private static func fresh() -> CatalogMemory {
        let name = "check.catalog.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        return CatalogMemory(store: store)
    }

    @Test("Without a remembered choice there is no answer")
    func empty() {
        #expect(Self.fresh().last == nil)
    }

    @Test("What was remembered comes back")
    func remember() {
        let memory = Self.fresh()
        let allSeries = Catalog.Identifier(.jellyfin, .allSeries, "a1b2")
        memory.memorize(allSeries)
        #expect(memory.last == allSeries)
    }

    /// **The second choice wins.** There is only one answer to "which catalog?"; an
    /// append would be a list, and from a list someone would have to choose again.
    @Test("The newer choice replaces the older one")
    func replace() {
        let memory = Self.fresh()
        memory.memorize(Catalog.Identifier(.jellyfin, .movies, "a1b2"))
        memory.memorize(Catalog.Identifier(.provider, .movies, "17"))
        #expect(memory.last == Catalog.Identifier(.provider, .movies, "17"))
    }

    /// **The same raw number from two origins is not the same catalog.** Xtream
    /// keeps separate number ranges for movies and series, and the media server knows neither
    /// — the identifier carries origin and kind along for exactly that reason.
    @Test("Origin and genre are part of the answer")
    func identifierCarriesOrigin() {
        let memory = Self.fresh()
        memory.memorize(Catalog.Identifier(.provider, .allSeries, "17"))
        #expect(memory.last != Catalog.Identifier(.provider, .movies, "17"))
        #expect(memory.last != Catalog.Identifier(.jellyfin, .allSeries, "17"))
    }
}
