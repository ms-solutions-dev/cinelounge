import Core
import Foundation
import Testing

@testable import Features

/// Which shelves are on offer — **and that they are the same ones that are built.**
///
/// **The finding of 2026-09-12, from the client on the device:** the TV's Home screen
/// shows "From the Portals" and "Collections", and under "Appearance" neither could
/// be moved or switched off. Instead, **every portal level individually** was listed there —
/// a dozen entry points —, and a checkmark had no effect, because the Home screen merges them into
/// *one* shelf.
///
/// Neither page was built wrongly. They were **two lists for one question**, and those
/// have drifted apart. The requirement was: *the TV should be exactly like the phone, so
/// that there is something recognizable* — on the phone `ShelfPlan` is the single
/// source for Home and the arrange screen, and now here too.
///
/// **These tests are the clamp.** They record what the plan promises; without
/// them the next row someone adds to Home would again be one that is missing
/// in management.
@Suite("The shelf plan")
struct ShelfPlanTests {

    private func makeLibrary(_ id: String, _ name: String, _ kind: Core.Library.Kind) -> Core.Library {
        Core.Library(id: id, name: name, kind: kind)
    }

    /// The situation that really exists in this household: media server, one provider,
    /// two portals with several entry points, one channel list.
    private var allLibraries: [Core.Library] {
        [
            makeLibrary("1", "Serien", .series),
            makeLibrary("2", "Filme", .movies),
            makeLibrary("3", "Heimvideos", .homeVideos),
            makeLibrary("4", "Musik", .music),
            makeLibrary("5", "Sender", .liveTV),
            makeLibrary("serieshub|beliebte|", "Beliebte Serien", .portalLevel),
            makeLibrary("serieshub|alle|", "Alle Serien", .portalLevel),
            makeLibrary("animehub|neu|", "Neue Folgen", .portalLevel),
        ]
    }

    /// **"Continue Watching" is always there and in first place** — the same decision as
    /// on the phone, and the most frequent reason to open the app.
    @Test("Continue Watching is always selectable and cannot be moved")
    func continueWatchingAlways() {
        let plan = ShelfPlan.shelves(libraries: [], collections: false, channelList: false)
        #expect(plan.map(\.id) == [ShelfPreferences.resumeID])
        #expect(plan[0].immovable)
    }

    /// **One shelf for all portals, not one per entry point.** That was exactly the finding:
    /// three entry points yield one row to choose from, not three.
    @Test("Three portal levels make a single portal shelf")
    func portalsAsOneShelf() {
        let plan = ShelfPlan.shelves(libraries: allLibraries, collections: false, channelList: true)
        let portalRows = plan.filter { $0.kind == .portalLevel }
        #expect(portalRows.count == 1)
        #expect(portalRows.first?.id == ShelfRule.portalShelfID)
    }

    /// And without a portal the row does not exist — **gone instead of empty**, the same rule as
    /// for the tabs.
    @Test("Without a portal no portal shelf is selectable")
    func noPortalNoShelf() {
        let plan = ShelfPlan.shelves(
            libraries: [makeLibrary("1", "Serien", .series)], collections: false, channelList: false)
        #expect(!plan.contains { $0.id == ShelfRule.portalShelfID })
    }

    @Test("Collections and channel list appear only if they exist")
    func onlyWhatExists() {
        let without = ShelfPlan.shelves(libraries: allLibraries, collections: false, channelList: false)
        #expect(!without.contains { $0.id == HomeModel.collectionsID })
        #expect(!without.contains { $0.id == LiveShelf.identifier })

        let using = ShelfPlan.shelves(libraries: allLibraries, collections: true, channelList: true)
        #expect(using.contains { $0.id == HomeModel.collectionsID })
        #expect(using.contains { $0.id == LiveShelf.identifier })
    }

    /// **Music and Live get no library shelf of their own** — their reasons are at
    /// ``ShelfRule/withoutShelf``: album covers are square, and a channel list has
    /// no newest but a program. The channel list therefore appears as a
    /// **live shelf** and not as a library.
    @Test("Music gets no shelf, the channel list only its own")
    func withoutShelfStaysWithout() {
        let plan = ShelfPlan.shelves(libraries: allLibraries, collections: false, channelList: true)
        #expect(!plan.contains { $0.id == "4" })
        #expect(!plan.contains { $0.id == "5" })
        #expect(plan.contains { $0.id == LiveShelf.identifier })
    }

    /// **The clamp:** what the plan offers, the Home screen must also be able to build — and
    /// vice versa. Checked on the identifiers, because ``ShelfPreferences`` hangs on them.
    ///
    /// **The default order calculates with the same data.** ``HomeModel/defaultOrder(_:)``
    /// decides by ``HomeModel/Shelf/libraryKind``; if the plan did not carry the kind along,
    /// the shelves in management would stand differently than on Home — and that is
    /// exactly the sort of difference that nobody recognizes as a bug.
    @Test("Every plan row carries the kind the Home screen sorts by")
    func planCarriesTheKind() {
        let plan = ShelfPlan.shelves(libraries: allLibraries, collections: true, channelList: true)
        // The fixed three carry no library kind — they cut across everything.
        for row in plan
        where [ShelfPreferences.resumeID, HomeModel.collectionsID, LiveShelf.identifier]
            .contains(row.id)
        {
            #expect(row.kind == nil, "\(row.id) should not carry a library kind")
        }
        // And every library row carries its own.
        #expect(plan.first { $0.id == "1" }?.kind == .series)
        #expect(plan.first { $0.id == "2" }?.kind == .movies)
        #expect(plan.first { $0.id == "3" }?.kind == .homeVideos)
    }

    /// **One board for both programs** (decision 27, C3). Until 2026-09-26 here it said
    /// "Portals before Recently Added", and the Home screen sorted the libraries
    /// by their kind **before** collections, Live and portals — unlike this list.
    @Test("Plan and Home screen follow the same board as on the phone")
    @MainActor
    func sharedBoard() {
        let plan = ShelfPlan.shelves(libraries: allLibraries, collections: true, channelList: true)
        let expected = [
            ShelfPreferences.resumeID, HomeModel.collectionsID, LiveShelf.identifier,
            RecentShelf.identifier, ShelfRule.portalShelfID, "1", "2", "3",
        ]
        #expect(plan.map(\.id) == expected)

        let shelves = plan.reversed().map {
            HomeModel.Shelf(
                id: $0.id, titleKey: $0.name, items: [], usesWideCards: false, libraryKind: $0.kind)
        }
        #expect(HomeModel.defaultOrder(shelves) == expected)
    }

    /// **The cap per origin applies here too.** Otherwise Serieshub alone would get a
    /// dozen rows to choose from — the reason ``ShelfRule/perOrigin`` exists.
    @Test("At most eight library shelves per origin")
    func cappingPerOrigin() {
        let many = (1...12).map { makeLibrary("\($0)", "Bibliothek \($0)", .movies) }
        let plan = ShelfPlan.shelves(libraries: many, collections: false, channelList: false)
        #expect(plan.filter { $0.kind == .movies }.count == ShelfRule.perOrigin)
    }
}

/// "Continue Watching" takes every origin — **and none displaces another.**
///
/// **The finding of 2026-09-12, from the client:** ``AggregateSource/resumable(limit:)``
/// asked every origin with the same limit, concatenated the answers and cut them off
/// **afterwards** at `limit`. A media server with twelve started titles thereby filled
/// all twelve slots, and none from the portal got through — exactly the case "started
/// on the phone, continue on the TV".
///
/// The same type of bug is written down twice in this project
/// (``ShelfRule/perOrigin``) and was fixed on the phone on 2026-09-05. There
/// ``CompositeStartSource`` appends the contributions without a shared cut — and here now too.
@Suite("Continue Watching across all origins")
struct ContinueWatchingAggregateTests {

    private func title(_ prefix: String, _ howMany: Int) -> [MediaItem] {
        (1...howMany).map {
            MediaItem(id: "\(prefix)-\($0)", kind: .movie, title: "\(prefix) \($0)")
        }
    }

    /// **The core:** a full media server must not push the portal out.
    @Test("A full media server does not crowd out the portal entries")
    func noDisplacement() async throws {
        let media = AggregateSourceTests.TestDouble("Medienserver", title: title("jf", 12))
        let portalSource = AggregateSourceTests.TestDouble("Portale", title: title("portal", 3))
        let aggregateSource = AggregateSource([.jellyfin: media, .portals: portalSource])

        let found = try await aggregateSource.resumable(limit: 12)
        let identifiers = Set(found.map(\.id))

        #expect(
            identifiers.contains("portal-1"),
            """
            The portal entry is missing. That silently drops “started on the phone, continue \
            on the TV” as soon as the media server fills the limit alone.
            """)
        #expect(found.count == 15, "Every origin contributes its limit, none is capped.")
    }

    /// **The limit still applies — only per origin.** Dropping it entirely would be the
    /// other bug: then every origin would fetch everything.
    @Test("The limit is passed on to every origin")
    func limitPerOrigin() async throws {
        let media = AggregateSourceTests.TestDouble("Medienserver", title: title("jf", 2))
        let aggregateSource = AggregateSource([.jellyfin: media])
        _ = try await aggregateSource.resumable(limit: 5)
        #expect(await media.asked.contains("resumable"))
    }

    /// **A silent origin does not take the other along** — the same rule as for the
    /// libraries, and tested once more here because the cut was removed.
    @Test("A failed secondary source costs nothing")
    func failureCostsNothing() async throws {
        let media = AggregateSourceTests.TestDouble("Medienserver", title: title("jf", 2))
        let portalSource = AggregateSourceTests.TestDouble("Portale", fails: true)
        let aggregateSource = AggregateSource([.jellyfin: media, .portals: portalSource])

        let found = try await aggregateSource.resumable(limit: 12)
        #expect(found.count == 2)
    }
}

/// The three rows that the TV lacked compared with the phone — **2026-09-12.**
///
/// **The request:** *"please build everything that is still missing."* What was meant was "Recently
/// Added", the shelves per portal folder and the channel choice for the live shelf. On the phone
/// they have stood as rules in `ShelfPlan` since 2026-09-05; on the TV the rows
/// did not exist at all.
@Suite("The rebuilt shelves")
struct RebuiltShelvesTests {

    private func makeLibrary(_ id: String, _ name: String, _ kind: Core.Library.Kind) -> Core.Library {
        Core.Library(id: id, name: name, kind: kind)
    }

    private func title(_ id: String, days: Int?) -> MediaItem {
        MediaItem(
            id: id, kind: .movie, title: id,
            addedAt: days.map { Date(timeIntervalSince1970: 1_700_000_000 - Double($0) * 86400) })
    }

    // MARK: - Recently added

    /// **The question that no other row answers:** "what is new since I was last
    /// here". One row per library answers it per library.
    @Test("Recently Added merges the catalogs and sorts by date")
    func lastMixes() throws {
        let shelf = try #require(
            RecentShelf.shelf(from: [
                (kind: .movies, title: [title("alt", days: 30), title("neu", days: 1)]),
                (kind: .series, title: [title("mittel", days: 10)]),
            ]))
        #expect(shelf.items.map(\.id) == ["neu", "mittel", "alt"])
        #expect(shelf.id == RecentShelf.identifier)
    }

    /// **Music, Live and portal levels contribute nothing** — the same list as
    /// ``ShelfRule/withoutShelf``, and for the same reasons: a portal leads menu items,
    /// and "new" there is the portal's statement and not a time.
    @Test("Portal levels and music contribute nothing")
    func foreignKindsContributeNothing() {
        #expect(
            RecentShelf.shelf(from: [
                (kind: .portalLevel, title: [title("portal", days: 1)]),
                (kind: .music, title: [title("album", days: 1)]),
            ]) == nil)
    }

    /// **A title without a date is not a novelty but a gap** — it stands at the back
    /// and is not counted forward.
    @Test("A title without a date goes last")
    func withoutDateAtTheEnd() throws {
        let shelf = try #require(
            RecentShelf.shelf(from: [
                (kind: .movies, title: [title("ohne", days: nil), title("mit", days: 5)])
            ]))
        #expect(shelf.items.map(\.id) == ["mit", "ohne"])
    }

    /// **The same movie in two services is one tile.** The same thing twice side by side
    /// looks like a bug.
    @Test("The same identifier appears once")
    func noDuplicates() throws {
        let shelf = try #require(
            RecentShelf.shelf(from: [
                (kind: .movies, title: [title("film", days: 2)]),
                (kind: .movies, title: [title("film", days: 2)]),
            ]))
        #expect(shelf.items.count == 1)
    }

    // MARK: - Shelves per portal folder

    /// **Either the collective shelf or the chosen ones — never both.** Otherwise
    /// the same content would stand twice.
    @Test("With folders chosen the collective shelf disappears")
    func eitherOr() {
        let layers = [
            makeLibrary("animehub|beliebte|", "Animehub · Beliebte Serien", .portalLevel),
            makeLibrary("serieshub|meist|", "Serieshub · Meistgesehen", .portalLevel),
        ]
        let without = ShelfPlan.shelves(libraries: layers, collections: false, channelList: false)
        #expect(without.contains { $0.id == ShelfRule.portalShelfID })

        let using = ShelfPlan.shelves(
            libraries: layers, collections: false, channelList: false,
            portalFolders: [.init(identifier: "animehub|beliebte|", name: "Animehub · Beliebte")])
        #expect(!using.contains { $0.id == ShelfRule.portalShelfID })
        #expect(using.contains { $0.id == "animehub|beliebte|" })
    }

    /// **At most three**, as on the phone — below that the catalogs carry the page.
    @Test("At most three portal shelves")
    func atMostThree() {
        let layers = (1...5).map { makeLibrary("p|o\($0)|", "Ordner \($0)", .portalLevel) }
        let choice = (1...5).map {
            ShelfPreferences.PortalChoice(identifier: "p|o\($0)|", name: "Ordner \($0)")
        }
        let plan = ShelfPlan.shelves(
            libraries: layers, collections: false, channelList: false, portalFolders: choice)
        #expect(
            plan.filter { $0.kind == .portalLevel }.count
                == ShelfPreferences.maximumPortalFolders)
    }

    /// **A choice whose portal is currently missing is skipped and not deleted.** A
    /// portal can be silent temporarily; removing a setting for it would be
    /// wrong.
    @Test("A vanished portal is not in the list but stays selected")
    func vanishedPortal() {
        var preferences = ShelfPreferences()
        preferences.select(.init(identifier: "weg|einstieg|", name: "Weg"), on: true)
        let plan = ShelfPlan.shelves(
            libraries: [makeLibrary("da|einstieg|", "Da", .portalLevel)], collections: false,
            channelList: false, portalFolders: preferences.portalFolders)
        #expect(!plan.contains { $0.id == "weg|einstieg|" })
        #expect(preferences.selects("weg|einstieg|"))
    }

    /// **The finding of 2026-09-13:** *"2 selected … currently only one."* Only
    /// the entry points of a portal are reported; whoever chooses a folder below chooses
    /// something that can stand in no list. The check applies to the portal, not to the
    /// level — otherwise every deep choice silently falls through, and that was exactly the case.
    @Test("A deeply chosen folder of a reported portal is in the list")
    func deepFolderStays() {
        let entries = [
            makeLibrary("serieshub||/serien", "Alle Serien", .portalLevel),
            makeLibrary("serieshub||/beliebt", "Beliebte Serien", .portalLevel),
        ]
        let choice: [ShelfPreferences.PortalChoice] = [
            .init(identifier: "serieshub||/beliebt", name: "SERIESHUB · Beliebte Serien"),
            .init(identifier: "serieshub||/beliebt/action", name: "SERIESHUB · Beliebte · Action"),
        ]
        let plan = ShelfPlan.shelves(
            libraries: entries, collections: false, channelList: false, portalFolders: choice)
        #expect(plan.filter { $0.kind == .portalLevel }.map(\.id) == choice.map(\.identifier))

        #expect(ShelfRule.portalReported(forItem: "serieshub||/x/y/z", under: entries))
        #expect(!ShelfRule.portalReported(forItem: "animehub||/x", under: entries))
        #expect(!ShelfRule.portalReported(forItem: "keine-portalkennung", under: entries))
    }

    /// **The fourth pushes the oldest out** — a choice that does nothing and says nothing
    /// cannot be explained on the remote.
    @Test("The fourth folder pushes the first out")
    func fourthPushes() {
        var preferences = ShelfPreferences()
        for number in 1...4 {
            preferences.select(.init(identifier: "p|o\(number)|", name: "O\(number)"), on: true)
        }
        #expect(preferences.portalFolders.map(\.identifier) == ["p|o2|", "p|o3|", "p|o4|"])
    }

    // MARK: - Store

    /// **Identifier and name survive saving** — and the identifier itself carries
    /// vertical bars, so the separator must not be one.
    @Test("Portal folders and channels survive saving and loading")
    func storeHolds() {
        let store = InMemoryStore()
        var preferences = ShelfPreferences()
        preferences.select(
            .init(identifier: "serieshub|beliebte serien|xyz", name: "Serieshub · Beliebte"),
            on: true)
        preferences.selectChannel("tr-telve1", on: true)
        preferences.selectChannel("de-sola", on: true)
        preferences.save(to: store)

        let read = ShelfPreferences.load(from: store)
        #expect(read.portalFolders.count == 1)
        #expect(read.portalFolders.first?.identifier == "serieshub|beliebte serien|xyz")
        #expect(read.portalFolders.first?.name == "Serieshub · Beliebte")
        #expect(read.liveChannel == ["tr-telve1", "de-sola"])
    }

    // MARK: - Channel choice in the live shelf

    private func channels(_ id: String, favorite: Bool = false) -> Channel {
        Channel(
            id: id, name: id, streamURL: URL(fileURLWithPath: "/x"), playlistID: "l1",
            isFavorite: favorite)
    }

    /// **A choice beats favorite and recently watched.** Whoever names four channels wants
    /// to see those four.
    @Test("The channel choice beats favorite and recently watched")
    func choiceWins() {
        let catalog = [channels("a", favorite: true), channels("b"), channels("c")]
        let ordered = LiveShelf.order(
            from: catalog, recent: [channels("a").channelName], chosen: ["c", "b"])
        #expect(ordered.map(\.id) == ["c", "b"])
    }

    /// **The choice is names** (decision 21) — the same as on the phone, and per name
    /// the first channel of the list.
    @Test("The channel choice finds its channels by name")
    func choiceByName() {
        let catalog = [
            Channel(
                id: "101", name: "DE: Das Nordlicht HD", streamURL: URL(fileURLWithPath: "/x"),
                playlistID: "l1"),
            Channel(
                id: "102", name: "DE: Das Nordlicht SD", streamURL: URL(fileURLWithPath: "/x"),
                playlistID: "l1"),
            Channel(id: "7", name: "ZINNE", streamURL: URL(fileURLWithPath: "/x"), playlistID: "l1"),
        ]
        let ordered = LiveShelf.order(
            from: catalog, recent: [], chosen: ["ZINNE", catalog[1].channelName])
        #expect(ordered.map(\.id) == ["7", "101"])
    }

    /// **Without a choice "automatic" applies** — recently watched first, then favorites.
    @Test("Without a choice the recently watched comes first")
    func withoutChoiceLast() {
        let catalog = [channels("a"), channels("b", favorite: true), channels("c")]
        let ordered = LiveShelf.order(from: catalog, recent: [channels("c").channelName])
        #expect(ordered.first?.id == "c")
    }

    /// **If every chosen channel is missing, "automatic" applies again** — an empty shelf would be
    /// the worse answer than "nothing chosen".
    @Test("A choice of vanished channels falls back by itself")
    func emptyChoiceFallsBack() {
        let catalog = [channels("a"), channels("b")]
        let ordered = LiveShelf.order(
            from: catalog, recent: [channels("b").channelName], chosen: ["weg"])
        #expect(ordered.first?.id == "b")
        #expect(ordered.count == 2)
    }
}

/// Three findings from the device, all on the evening of 2026-09-12 — **and all in my work.**
///
/// *"although portals are set up I cannot choose anything here … also I
/// tried selecting a channel, it is still not shown in Home."*
@Suite("The three findings from the device")
struct ThreeFindingsTests {

    private func channels(_ id: String, favorite: Bool = false) -> Channel {
        Channel(
            id: id, name: id, streamURL: URL(fileURLWithPath: "/x"), playlistID: "l1",
            isFavorite: favorite)
    }

    private func broadcast(_ from: Double, _ until: Double) -> Programme {
        Programme(
            id: "p", channelID: "a", title: "läuft",
            start: Date(timeIntervalSince1970: from), end: Date(timeIntervalSince1970: until))
    }

    /// **The worst of the three:** `tiles` reordered itself and did not get the choice.
    /// The choice was read — and only used to query the program guide.
    @Test("The channel choice reaches the tiles")
    func choiceArrives() {
        let now = Date(timeIntervalSince1970: 1000)
        let tiles = LiveShelf.tiles(
            channels: [channels("a", favorite: true), channels("b")],
            isVisible: LivePreferences(), recent: [channels("a").channelName],
            program: ["a": [broadcast(0, 2000)], "b": [broadcast(0, 2000)]],
            now: now, chosen: ["b"])
        #expect(tiles.map(\.id) == ["b"])
    }

    /// **A chosen channel without a running broadcast appears anyway.** Whoever names it
    /// wants to see it; whether a program is stored is the provider's decision.
    /// ``LiveShelf/tile(_:isRunning:)`` has always carried the case.
    @Test("A chosen channel without a programme does not drop out")
    func chosenWithoutProgram() {
        let tiles = LiveShelf.tiles(
            channels: [channels("a")], isVisible: LivePreferences(), recent: [],
            program: [:], now: Date(timeIntervalSince1970: 1000), chosen: ["a"])
        #expect(tiles.map(\.id) == ["a"])
    }

    /// **Without a choice the old promise remains:** "the recently watched ones that *are showing
    /// something right now*". A channel without a program continues to drop out there — otherwise a
    /// shelf full of channels without information would stand.
    @Test("Without a choice a channel without a programme still drops out")
    func withoutChoiceStillFiltered() {
        let tiles = LiveShelf.tiles(
            channels: [channels("a")], isVisible: LivePreferences(), recent: [],
            program: [:], now: Date(timeIntervalSince1970: 1000))
        #expect(tiles.isEmpty)
    }

    /// **And if the choice leads nowhere, the fallback applies again** — including its
    /// rule. Otherwise, with a choice of vanished channels, a shelf would stand that shows every
    /// channel without a program.
    @Test("A choice of vanished channels brings the fallback back")
    func emptyChoiceFallsBack() {
        let tiles = LiveShelf.tiles(
            channels: [channels("a")], isVisible: LivePreferences(), recent: [],
            program: [:], now: Date(timeIntervalSince1970: 1000), chosen: ["weg"])
        #expect(tiles.isEmpty)
    }

    /// **"No portal set up", while ten answered.** The plan got only the
    /// libraries of the media server; portal levels never arrive there.
    @Test("Portal levels from a second list make the portal shelf")
    func portalLevelsFromSecondList() {
        let jellyfin = [Core.Library(id: "1", name: "Filme", kind: .movies)]
        let layers = [
            Core.Library(id: "animehub|beliebte|", name: "Beliebte", kind: .portalLevel)
        ]
        #expect(
            !ShelfPlan.shelves(libraries: jellyfin, collections: false, channelList: false)
                .contains { $0.id == ShelfRule.portalShelfID })
        #expect(
            ShelfPlan.shelves(
                libraries: jellyfin + layers, collections: false, channelList: false
            ).contains { $0.id == ShelfRule.portalShelfID })
    }
}
