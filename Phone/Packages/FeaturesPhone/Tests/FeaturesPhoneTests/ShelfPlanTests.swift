import Core
import Testing

@testable import FeaturesPhone

/// Shelves are generated, not enumerated — and three libraries deliberately get none.
@Suite("Shelf plan")
struct ShelfPlanTests {

    private static func library(
        _ name: String, _ kind: Genre, _ extent: Int = 10
    )
        -> Catalog
    {
        Catalog(
            id: .init(.jellyfin, kind, name), origin: .jellyfin,
            label: .wording(name), kind: kind, sourceIdentifier: name,
            extent: extent)
    }

    private static let six = CatalogState([
        library("Filme", .movies, 103), library("Serien", .allSeries, 24),
        library("Heimvideos und -bilder", .homeVideos, 23),
        library("Sammlungen", .isCollection, 16), library("Musik", .music, 1),
        library("Verzeichnisse", .directory, 0),
    ])

    /// **The gain of this rebuild.** Before, `Regalart` knew six fixed names, and four
    /// of these libraries did not appear in it.
    ///
    /// **Collections have stood as a fixed shelf since decision 27 (C1)**, as on the
    /// TV — a second catalog shelf with the same name could not be told apart
    /// from a distance.
    @Test("Every showable library gets its own shelf, the collections their fixed one")
    func shelvesPerCatalog() {
        let shelves = ShelvesPerCatalog().shelves(forItem: Self.six)
        let names = shelves.map { $0.label.raw }
        #expect(names.contains("Heimvideos und -bilder"))
        #expect(!names.contains("Sammlungen"))
        #expect(
            ShelfPlan.shelves(forItem: Self.six).contains { $0.id == .fixed(ShelfIdentifier.collections) })
    }

    /// **One board for both programs** (decision 27, C3): Continue Watching · Collections ·
    /// Live · Recently added · Portals · Catalogs — and within the catalogs series before
    /// movies, home videos last, as on the TV.
    @Test("Home follows the shared board")
    func sharedBoard() {
        let state = CatalogState(
            Self.six.catalogs + [
                Catalog(
                    id: .init(.channelList, .live, "l"), origin: .channelList,
                    label: .wording("Sender"), kind: .live, sourceIdentifier: ""),
                Catalog(
                    id: .init(.portals, .portalLevel, ""), origin: .portals,
                    label: .wording("Portale"), kind: .portalLevel, sourceIdentifier: ""),
            ])
        let ordering = ShelfPlan.shelves(forItem: state).map(\.id.rawValue)
        #expect(
            ordering == [
                ShelfIdentifier.continueWatching, ShelfIdentifier.collections, ShelfIdentifier.live,
                ShelfIdentifier.recent, ShelfIdentifier.portals, "Serien", "Filme",
                "Heimvideos und -bilder",
            ])
    }

    /// Music not, because album covers are 1 : 1 and every shelf carries 2 : 3. Directories
    /// not, because a folder library has no meaningful "Latest".
    @Test("Music and directories get none")
    func threeWithoutShelf() {
        let names = ShelvesPerCatalog().shelves(forItem: Self.six).map { $0.label.raw }
        #expect(!names.contains("Musik"))
        #expect(!names.contains("Verzeichnisse"))
    }

    /// A home video has no poster but a still frame — brought into a 2 : 3 frame
    /// that is the crop of a crop.
    @Test("Home videos carry wide tiles, all others posters")
    func homeVideosAreWide() {
        for shelf in ShelvesPerCatalog().shelves(forItem: Self.six) {
            let expected: TileShape =
                shelf.label.raw.hasPrefix("Heimvideos") ? .wide : .poster
            #expect(shelf.form == expected)
        }
    }

    /// **Filter first, then cap.** The other way round an empty library gives away one
    /// of the four places — and which one is empty is only known after loading. Generation
    /// is therefore with a buffer; the four is set by `StartModel.visibleShelves`.
    @Test("Generation uses a buffer, four are shown")
    func createdWithBuffer() {
        let many = CatalogState((1...20).map { Self.library("Bestand \($0)", .movies) })
        let generated = ShelvesPerCatalog().shelves(forItem: many)
        #expect(generated.count == ShelvesPerCatalog.maxLoaded)
        #expect(ShelvesPerCatalog.maxLoaded > ShelvesPerCatalog.atMost)
    }

    /// The limit is a loading question: Ten shelves of twenty tiles are 200 images through
    /// a tunnel with 0.31 Mbit/s.
    @Test("Of eight generated, four filled ones remain")
    func fourFilled() async {
        let many = CatalogState((1...20).map { Self.library("Bestand \($0)", .movies) })
        let generated = ShelvesPerCatalog().shelves(forItem: many)
        // Only every second one brings content — as with empty libraries.
        var tiles: [Shelf.Identifier: [TileContent]] = [:]
        for (number, shelf) in generated.enumerated() where number.isMultiple(of: 2) {
            tiles[shelf.id] = [TileContent(id: "\(number)", title: "x")]
        }
        let model = await StartModel(source: nil, catalogs: many)
        await model.setTilesForCheck(tiles)
        let shown = await model.visibleShelves
        #expect(shown.count == 4, "four filled, not four generated")
    }

    /// What played last may have played on TV and may have come from a portal.
    @Test("Continue Watching appears for every origin, downloads included")
    func continueWatchingTakesAll() {
        for origin in Catalog.Origin.allCases {
            let state = CatalogState([
                Catalog(
                    id: .init(origin, .movies, "x"), origin: origin,
                    label: .key("stock.mediaServer"), kind: .movies,
                    sourceIdentifier: "x")
            ])
            let identifiers = ShelfPlan.shelves(forItem: state).map(\.id)
            #expect(identifiers.contains(.fixed("resume")))
        }
    }

    /// Without a channel list no "Live today", without portals no "From the portals" — a
    /// heading above nothing is no information.
    @Test("A fixed shelf without its source does not appear")
    func fixedShelvesFollowSource() {
        let identifiers = ShelfPlan.shelves(forItem: Self.six).map(\.id)
        #expect(!identifiers.contains(.fixed("live")))
        #expect(!identifiers.contains(.fixed("portale")))
        #expect(identifiers.contains(.fixed("zuletztHinzugefuegt")))
    }

    /// **The promise that was empty before.** With `Regalart` a saved order
    /// could not *not* know a new shelf — each needed a retranslation.
    @Test("Whatever the stored order does not know is appended at the end")
    func newShelfLandsAtEnd() {
        let shelves = ShelfPlan.shelves(forItem: Self.six)
        let preferences = StartPreferences(
            order: [.fixed("zuletztHinzugefuegt"), StartPreferences.immovable])
        let ordered = preferences.arrange(shelves)

        // **„Weiter schauen" steht vorn, wo immer es gespeichert war** — Entscheidung 1.
        #expect(ordered.first?.id == StartPreferences.immovable)
        #expect(ordered.dropFirst().first?.id == .fixed("zuletztHinzugefuegt"))
        #expect(ordered.count == shelves.count, "No shelf may disappear")
        // The unknown ones keep their generation order, so they do not wander elsewhere at
        // every start.
        let known: Set<Shelf.Identifier> = [
            .fixed("zuletztHinzugefuegt"), StartPreferences.immovable,
        ]
        let unknown = shelves.filter { !known.contains($0.id) }.map(\.id)
        #expect(Array(ordered.dropFirst(2)).map(\.id) == unknown)
    }

    /// An empty order means "as generated" and not "nothing".
    @Test("Without a stored order the generation order stays")
    func withoutOrder() {
        let shelves = ShelfPlan.shelves(forItem: Self.six)
        #expect(StartPreferences.preset.arrange(shelves).map(\.id) == shelves.map(\.id))
    }

    /// **A hidden shelf disappears, "Continue Watching" does not.**
    ///
    /// It answers the most common reason to open the app; whoever switched it off by accident
    /// would have worsened their Home screen without noticing.
    @Test("Hiding takes effect — except for Continue Watching")
    func hide() {
        let shelves = ShelfPlan.shelves(forItem: Self.six)
        var preferences = StartPreferences.preset
        preferences.show(.fixed("zuletztHinzugefuegt"), false)
        preferences.show(StartPreferences.immovable, false)

        let identifiers = preferences.arrange(shelves).map(\.id)
        #expect(!identifiers.contains(.fixed("zuletztHinzugefuegt")))
        #expect(identifiers.contains(StartPreferences.immovable))
    }

    /// **Empty means "all" — and that is why the last one cannot be deselected.**
    ///
    /// Whoever could would, by deselecting, get all again: a switch that flips to the
    /// opposite.
    @Test("The hero takes all shelves without a choice, and the last one stays")
    func heroShelves() {
        var preferences = StartPreferences.preset
        let allIdentifiers: [Shelf.Identifier] = [.fixed("a"), .fixed("b")]
        #expect(preferences.fillsHeroes(.fixed("a")))

        preferences.fillHeroes(.fixed("a"), false, from: allIdentifiers)
        #expect(!preferences.fillsHeroes(.fixed("a")))
        #expect(preferences.fillsHeroes(.fixed("b")))

        preferences.fillHeroes(.fixed("b"), false, from: allIdentifiers)
        #expect(preferences.fillsHeroes(.fixed("b")), "The last one stays")
    }

    /// What is saved comes back — **and empty stays empty.**
    @Test("The preferences survive the trip through the store")
    func store() {
        let bucket = InMemoryStore()
        var preferences = StartPreferences.preset
        preferences.set(order: [Shelf.Identifier.fixed("b"), .fixed("a")])
        preferences.show(.fixed("c"), false)
        preferences.set(liveChannel: ["Das Nordlicht HD", "ZINNE"])
        preferences.save(to: bucket)

        let back = StartPreferences.load(from: bucket)
        #expect(back.order == [.fixed("b"), .fixed("a")])
        #expect(!back.shows(.fixed("c")))
        #expect(back.liveChannel == ["Das Nordlicht HD", "ZINNE"])
        // Nothing remembered means nothing remembered — no list with an empty entry.
        #expect(back.heroShelves.isEmpty)
        #expect(StartPreferences.load(from: InMemoryStore()).liveChannel.isEmpty)
    }
}

/// The cap at four catalog shelves — **per origin, not across all.**
@Suite("Shelves per service")
struct ShelvesPerServiceTests {

    private func catalog(_ name: String, _ origin: Catalog.Origin) -> Catalog {
        Catalog(
            id: .init(origin, .movies, name), origin: origin,
            label: .wording(name), kind: .movies, sourceIdentifier: name)
    }

    /// **The finding of 2026-09-05, on screen:** The media server filled the four places
    /// alone, and of the provider catalog **nothing** was to be seen on the Home screen —
    /// although it was set up and its shelves had content. A service of which one sees
    /// nothing is as good as not set up.
    @Test("The second service does not vanish behind the first")
    @MainActor
    func cappedPerOrigin() {
        let state = CatalogState(
            (1...6).map { catalog("jf\($0)", .jellyfin) }
                + (1...2).map { catalog("ip\($0)", .provider) })

        let model = StartModel(source: nil, catalogs: state)
        // All filled — the cap is then the only rule that still applies.
        var tiles: [Shelf.Identifier: [TileContent]] = [:]
        for shelf in ShelfPlan.shelves(forItem: state) {
            tiles[shelf.id] = [TileContent(id: shelf.id.rawValue, title: "x")]
        }
        model.setTilesForCheck(tiles)

        let catalogShelves = model.visibleShelves.filter { $0.target != nil }
        let fromProvider = catalogShelves.filter { $0.sources.contains(.provider) }
        let fromServer = catalogShelves.filter { $0.sources.contains(.jellyfin) }

        #expect(fromServer.count == ShelvesPerCatalog.atMost)
        // **And the two provider rows still stand there.** Counted across all they
        // would have dropped out, because one's own comes before the foreign.
        #expect(fromProvider.count == 2)
    }
}
