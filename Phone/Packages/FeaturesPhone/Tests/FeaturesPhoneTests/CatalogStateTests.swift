import Testing

@testable import FeaturesPhone

/// Catalogs instead of bits — and the question of whether everything really stays reachable.
@Suite("Catalog state")
struct CatalogStateTests {

    /// The server's six libraries, with their real numbers from 2026-09-05.
    private static let six: [Catalog] = [
        library("Filme", .movies, 103),
        library("Serien", .allSeries, 24),
        library("Heimvideos und -bilder", .homeVideos, 23),
        library("Sammlungen", .isCollection, 16),
        library("Musik", .music, 1),
        library("Verzeichnisse", .directory, 0),
    ]

    private static func library(_ name: String, _ kind: Genre, _ extent: Int) -> Catalog {
        Catalog(
            id: .init(.jellyfin, kind, name), origin: .jellyfin,
            label: .wording(name), kind: kind, sourceIdentifier: name,
            extent: extent)
    }

    /// **The error on which the ladder of tiers failed.** A rule that fans
    /// "library" out into "Movies · Series" throws away what it does not name —
    /// on this server four of six.
    @Test("No catalog is lost, not even the sixth")
    func nothingDisappears() {
        let state = CatalogState(Self.six)
        // "Directories" has zero titles and therefore does not appear at all.
        #expect(state.catalogs.count == 5)
        #expect(state.tabs.contains(.library))
        for catalog in state.catalogs {
            #expect(catalog.origin == .jellyfin)
        }
    }

    /// A library with zero titles is not information but a construction site —
    /// the same rule as for the empty shelf, only one level higher.
    @Test("A catalog without titles does not appear")
    func emptyCatalogDropsOut() {
        let state = CatalogState(Self.six)
        #expect(!state.catalogs.contains { $0.label.raw == "Verzeichnisse" })
        // `nil` means "not counted" and not "zero" — that one stays.
        let uncounted = Self.library("Unbekannt", .movies, 7)
        #expect(CatalogState([uncounted]).catalogs.count == 1)
    }

    /// **What is determined is the bar, not the order of the catalogs.** Which tabs
    /// appear depends only on the origins — so the interface cannot
    /// change because one service answered faster. The order of the catalogs,
    /// on the other hand, stays the server's: in Jellyfin the user orders them themselves.
    @Test("The bar is deterministic, the catalog order comes from the server")
    func determined() {
        #expect(CatalogState(Self.six).tabs == CatalogState(Self.six.shuffled()).tabs)
        #expect(CatalogState(Self.six).catalogs.first?.label.raw == "Filme")
        #expect(CatalogState(Self.six.reversed()).catalogs.first?.label.raw == "Musik")
    }

    /// **The finding from 2026-09-05** Sorted by identifier, a random
    /// character string decided which of the two `unknown` libraries got a shelf — on
    /// this server "Directories" won with zero titles, and the sixteen collections
    /// were nowhere to be seen.
    ///
    /// **Since decision 27 (C1) the collections stand as a fixed shelf** and get
    /// no catalog shelf any more — see `ShelfPlanTests.shelvesPerCatalog`.
    @Test("The catalog shelves follow the server order, not a GUID")
    func serverOrderDecides() {
        let shelves = ShelvesPerCatalog().shelves(forItem: CatalogState(Self.six))
        #expect(
            shelves.map { $0.label.raw } == [
                "Filme", "Serien", "Heimvideos und -bilder",
            ])
    }

    /// "Set up" now means "there is content", not "there is an access".
    @Test("A server without a shared library is empty")
    func serverWithoutLibraries() {
        let empty = CatalogState([])
        #expect(!empty.isSetUp)
        #expect(empty.tabs.isEmpty)
    }

    @Test("Each tab appears exactly when its origin is present")
    func tabsFollowOrigin() {
        for scenario in CatalogState.allCases where scenario.isSetUp {
            #expect(scenario.tabs.contains(.live) == scenario.hasKey(.channelList))
            #expect(scenario.tabs.contains(.portals) == scenario.hasKey(.portals))
            // **The provider catalog carries the library, the channel list does not.**
            // Finding from 2026-09-05: the register showed "Provider · Movies" under the
            // heading LIVE. Both come from the same access and are still not
            // the same — channels run by programme, a catalog is searched.
            #expect(
                scenario.tabs.contains(.library)
                    == (scenario.hasKey(.jellyfin) || scenario.hasKey(.provider)
                        || scenario.hasKey(.downloads)))
            #expect(scenario.tabs.first == .start)
            #expect(scenario.tabs.last == .search)
            #expect(scenario.tabs.count >= 3 && scenario.tabs.count <= 5)
        }
    }

    /// Where something lies on the device, there is the tab that shows it — otherwise
    /// downloaded items would lie on the device with no way to get there.
    @Test("Downloads bring the Library tab with them")
    func downloadsStayReachable() {
        let withDownloads = CatalogState.fromAccesses(portals: true, downloads: true)
        #expect(withDownloads.tabs.contains(.library))
        #expect(withDownloads.reached(.downloads))
        #expect(withDownloads.reached(.storage))
        #expect(!CatalogState.fromAccesses(portals: true).reached(.downloads))
    }

    /// Sources and play targets hang on no tab: the set-up must be reachable precisely
    /// when nothing is set up.
    @Test("Whatever hangs on no tab always stays reachable")
    func attachmentsStay() {
        for identifier in [ViewID.setup, .settings, .player, .diagnose] {
            #expect(CatalogState.empty.reached(identifier))
        }
    }

    /// **Monotonicity:** adding a service must not make any **catalog** unreachable.
    /// That is exactly the damage the discarded ladder of tiers would have done.
    ///
    /// **The favorites are exempt from this, and that is a decision.** They
    /// migrate: if a slot is free, they sit at the bottom; otherwise as a heart in the header.
    /// So when a third service is set up, a *tab* disappears — but no
    /// *path*, and the invariant applies to paths. The price is real: whoever has
    /// learned the heart at the bottom looks for it at the top after the set-up. It is the reason why the
    /// favorites are the only place that may migrate — any other would be either tied to
    /// a service or filler, and neither tolerates migration.
    @Test("A further service removes no catalog path")
    func unambiguous() {
        for smaller in CatalogState.allCases {
            for larger in CatalogState.allCases
            where Set(smaller.origins).isSubset(of: larger.origins) {
                for tabs in smaller.tabs where tabs != .favorites {
                    #expect(
                        larger.tabs.contains(tabs),
                        "\(tabs) disappeared when a service was added")
                }
            }
        }
    }

    /// The favorites are **always** reachable — at the bottom or at the top, but never nowhere.
    @Test("Favorites sit at the bottom or in the header")
    func favoritesMove() {
        for state in CatalogState.allCases where state.isSetUp {
            // Exactly one of the two places carries them.
            #expect(state.favoritesAtBottom == state.tabs.contains(.favorites))
        }
        // Media server only: four tabs, the heart at the bottom.
        #expect(CatalogState.fromAccesses(jellyfin: true).favoritesAtBottom)
        // All three: five tabs, the heart in the header.
        #expect(
            !CatalogState.fromAccesses(jellyfin: true, channelList: true, portals: true)
                .favoritesAtBottom)
    }
}
