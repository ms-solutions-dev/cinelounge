import Core
import Downloads
import Flows
import Foundation
import ParentalControls
import SourceProbe
import Testing

@testable import FeaturesPhone

/// **Detail page and Library on the phone** — the findings of the review of 2026-09-27
/// (part C: D1, D3, D5; part D: S1, S2, S5), each shown red once against the old state.
@MainActor
@Suite("Detail and library on the phone: findings of 27.09.")
struct DetailAndLibraryFindingsPhoneTests {

    static let childRule = ProtectionRule(
        deviceLocked: true, accountKind: .kind, isPinSet: true, limit: .from12,
        blocksUnrecognized: true, assignments: [:])

    private static func folder() throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: - D1 · Child protection via downloads

    @Test("A blocked title does not open via the fallback to downloads")
    func downloadsFallbackBypassesFilter() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        DescriptionLedger(folder: folder).create(
            DownloadDescription(id: "sechzehn", title: "C", ageRating: "FSK 16"))
        let server = JellyfinDetailSource(
            source: Self.childRule.about(ApprovalProbe()), width: 300, headerWidth: 300,
            logoWidth: 300)
        let source = AggregateDetailSource(
            jellyfin: server, provider: nil, portals: nil,
            downloads: DownloadsDetailSource(folder: folder, rule: Self.childRule))
        await #expect(throws: ChildProtectionError.locked) {
            _ = try await source.detailInfo(zu: "sechzehn")
        }
    }

    @Test("A loaded provider title does not open for a child via downloads")
    func downloadsFallbackProvider() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let identifier = "liste#movie#99"
        DescriptionLedger(folder: folder).create(
            DownloadDescription(id: identifier, title: "Film", ageRating: "FSK 0"))
        let source = AggregateDetailSource(
            jellyfin: nil, provider: nil, portals: nil,
            downloads: DownloadsDetailSource(folder: folder, rule: Self.childRule))
        await #expect(throws: ChildProtectionError.locked) {
            _ = try await source.detailInfo(zu: identifier)
        }
    }

    @Test("A blocked title does not open from downloads either")
    func downloadsIdentifierBlocked() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        DescriptionLedger(folder: folder).create(
            DownloadDescription(id: "sechzehn", title: "C", ageRating: "FSK 16"))
        let kind = DownloadsDetailSource(folder: folder, rule: Self.childRule)
        await #expect(throws: ChildProtectionError.locked) {
            _ = try await kind.detailInfo(zu: DownloadsDetailSource.identifier(forItem: "sechzehn"))
        }
        let pending = DownloadsDetailSource(folder: folder, rule: .pending)
        let content = try await pending.detailInfo(zu: DownloadsDetailSource.identifier(forItem: "sechzehn"))
        #expect(content.title.tile.title == "C")
    }

    @Test("A series from downloads shows the child only the episodes it may watch")
    func downloadsSeriesFiltered() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ledger = DescriptionLedger(folder: folder)
        let unrestricted = DownloadDescription(
            id: "f1", title: "Episode 1", series: "morrowfeld", season: 1, episode: 1,
            ageRating: "FSK 6", seriesClearance: "FSK 6", seriesClearanceChecked: true)
        let unchecked = DownloadDescription(
            id: "f2", title: "Episode 2", series: "morrowfeld", season: 1, episode: 2,
            ageRating: "FSK 6")
        ledger.create(unrestricted)
        ledger.create(unchecked)
        let content = try await DownloadsDetailSource(folder: folder, rule: Self.childRule)
            .detailInfo(zu: DownloadsDetailSource.identifier(forItem: "morrowfeld"))
        #expect(content.seasons.flatMap(\.episodes).map(\.id) == ["f1"])
    }

    // MARK: - D3 · Specials

    @Test("Next episode does not jump into the specials")
    func nextNotSpecials() {
        func episode(_ season: Int, _ number: Int, watched: Bool) -> MediaItem {
            var title = MediaItem(id: "s\(season)e\(number)", kind: .episode, title: "S\(season)E\(number)")
            title.seasonNumber = season
            title.episodeNumber = number
            title.progress = PlaybackProgress(position: 0, duration: 1200, isWatched: watched)
            return title
        }
        let episodes = [
            episode(0, 1, watched: false), episode(1, 1, watched: true), episode(1, 2, watched: true),
            episode(2, 1, watched: false), episode(2, 2, watched: false),
        ]
        #expect(JellyfinDetailSource.next(from: episodes)?.id == "s2e1")
    }

    // MARK: - D5 · Filmography

    @Test("The filmography belongs to the most recently chosen person")
    func careerRace() async throws {
        let model = DetailModel(
            identifier: "x", source: nil, people: SlowCareer(), rule: .pending)
        let a = PersonDetail(id: "a", name: "Slow")
        let b = PersonDetail(id: "b", name: "Fast")
        let first = Task { await model.openFilmography(a) }
        try await Task.sleep(for: .milliseconds(50))
        await model.openFilmography(b)
        await first.value
        #expect(model.selectedPerson?.id == "b")
        #expect(model.filmography?.movies.first?.title == "Film by Fast")
        #expect(!model.isFilmographyLoading)
    }

    // MARK: - S1, S2 · Library

    static func catalog(_ raw: String, _ kind: Genre) -> Catalog {
        Catalog(
            id: .init(.jellyfin, kind, raw), origin: .jellyfin,
            label: .wording(raw), kind: kind, sourceIdentifier: raw)
    }

    @Test("Cold start: without a choice the default of the opened catalog applies")
    func coldStartDefault() async {
        let model = LibraryViewModel(
            source: CatalogStub(catalogs: [Self.catalog("hv-vorgabe", .homeVideos)]),
            sortOrders: SortMemory(store: InMemoryStore()))
        await model.load()
        #expect(model.chosen?.kind == .homeVideos)
        #expect(model.choice == OrderChoice.preset(forItem: .homeVideos))
    }

    @Test("Cold start: the remembered order of the opened catalog applies immediately")
    func coldStartRemembered() async {
        let movies = Self.catalog("movies-remembered", .movies)
        let memory = SortMemory(store: InMemoryStore())
        let rating = OrderChoice(sorting: .rating, ascending: false, explicit: true)
        memory.memorize(rating, zu: movies.id)
        let model = LibraryViewModel(
            source: CatalogStub(catalogs: [movies]), sortOrders: memory)
        await model.load()
        #expect(model.choice == rating)
    }

    @Test("Race: a slow old catalog does not overwrite the newly chosen one")
    func raceCatalogSwitch() async throws {
        let slow = Self.catalog("slow", .movies)
        let fast = Self.catalog("fast", .allSeries)
        let model = LibraryViewModel(
            source: CatalogStub(catalogs: [fast, slow]),
            sortOrders: SortMemory(store: InMemoryStore()))
        await model.load()
        let first = Task { await model.select(slow) }
        try await Task.sleep(for: .milliseconds(50))
        await model.select(fast)
        await first.value
        #expect(model.chosen?.id == fast.id)
        #expect(model.title.map(\.id) == ["title-fast"])
    }

    @Test("The library is rebuilt on an account, profile or rule change")
    func libraryRebuild() throws {
        let alice = LibraryScreen.Rebuild(rule: .pending, account: "alice", profile: "p1")
        #expect(alice != LibraryScreen.Rebuild(rule: .pending, account: "bob", profile: "p1"))
        #expect(alice != LibraryScreen.Rebuild(rule: .pending, account: "alice", profile: "p2"))
        #expect(alice != LibraryScreen.Rebuild(rule: Self.childRule, account: "alice", profile: "p1"))
        let switchPoint = try SourceText.read("TabPlaceholder.swift", in: .featuresPhone)
        #expect(
            switchPoint.contains(
                ".id(LibraryScreen.Rebuild(rule: model.parentalControls.rule, account: model.accountName))"))
    }

    // MARK: - S5 · Sort store

    @Test("Home videos: \"Recording\" from the TV counts as \"Newest\" on the phone")
    func homeVideosFromTV() {
        let store = InMemoryStore()
        let homeVideos = Self.catalog("hv1", .homeVideos)
        SortStore(store: store).memorize(
            .init(kind: .recording, ascending: true), area: "hv1")
        let choice = SortMemory(store: store).last(zu: homeVideos.id)
        #expect(choice?.sorting == .fresh)
        #expect(choice?.ascending == true)
    }

    @Test("Provider series: the choice on the phone is stored where the TV reads it per section")
    func providerSeriesSameSection() {
        let allSeries = Catalog.Identifier(.provider, .allSeries, "l1|series")
        #expect(SortMemory.area(allSeries) == SortRule.area(forLibrary: "l1|series|9"))
    }
}

/// A catalog source whose catalog "slow" answers only after 400 ms.
struct CatalogStub: CatalogSource {
    let catalogs: [Catalog]
    func state() async throws -> CatalogState { CatalogState(catalogs) }
    func title(
        from catalog: Catalog, slice: CatalogSlice?
    ) async throws
        -> [TileContent]
    {
        if catalog.sourceIdentifier == "slow" {
            try? await Task.sleep(for: .milliseconds(400))
        }
        return [TileContent(id: "title-" + catalog.sourceIdentifier, title: catalog.sourceIdentifier)]
    }
}

/// The career for "Slow" arrives after 400 ms, the one for "Fast" immediately.
struct SlowCareer: CareerSource {
    var entered: Bool { true }
    func portraits(zu names: [String]) async -> [String: URL] { [:] }
    func filmography(zu name: String) async -> Filmography? {
        if name == "Slow" { try? await Task.sleep(for: .milliseconds(400)) }
        return Filmography(movies: [FilmographyEntry(id: name, kind: .movie, title: "Film by \(name)")])
    }
    func profile(zu entry: FilmographyEntry) async -> TitleProfile? { nil }
}
