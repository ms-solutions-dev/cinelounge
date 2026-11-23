import Core
import Foundation
import ParentalControls
import Testing

@testable import Features

/// **Detail page and library on the TV** — the findings of the check of 2026-09-27
/// (part C: D2, D3, D5; part D: S3, S4, S5), each shown red once against the old state.
@MainActor
@Suite("Detail and library: findings of 27.09.")
struct DetailAndLibraryFindingsTests {

    // MARK: - D2 · Season choice

    @Test("Episodes belong to the last selected season, even if the previous one answers later")
    func seasonRace() async throws {
        let series = MediaItem(id: "serie", kind: .series, title: "Serie")
        let model = DetailModel(source: SeasonDouble(), item: series)
        let a = MediaItem(id: "stA", kind: .season, title: "Staffel 1")
        let b = MediaItem(id: "stB", kind: .season, title: "Staffel 2")
        let first = Task { await model.selectSeason(a) }
        try await Task.sleep(for: .milliseconds(50))
        await model.selectSeason(b)
        await first.value
        #expect(model.selectedSeason?.id == "stB")
        #expect(model.episodes.map(\.id) == ["b1"])
    }

    // MARK: - D3 · Specials

    /// Jellyfin tracks the season number of a season as `IndexNumber`, the mapping puts it in
    /// `episodeNumber` — specials are season 0 and come first.
    static func season(_ number: Int, pending: Int) -> MediaItem {
        var season = MediaItem(id: "st\(number)", kind: .season, title: "Staffel \(number)")
        season.episodeNumber = number
        season.unplayedCount = pending
        return season
    }

    @Test("The page does not open on the specials as long as a season is open")
    func startSeasonWithoutSpecials() {
        let seasons = [Self.season(0, pending: 3), Self.season(1, pending: 0), Self.season(2, pending: 5)]
        #expect(DetailModel.startingSeason(in: seasons)?.id == "st2")
    }

    @Test("Everything watched, only specials open: the last season, not the specials")
    func startSeasonAllWatched() {
        let seasons = [Self.season(0, pending: 3), Self.season(1, pending: 0), Self.season(2, pending: 0)]
        #expect(DetailModel.startingSeason(in: seasons)?.id == "st2")
    }

    @Test("If there are only specials, they open")
    func onlySpecials() {
        #expect(DetailModel.startingSeason(in: [Self.season(0, pending: 2)])?.id == "st0")
    }

    // MARK: - D5 · Title profile of the filmography

    @Test("The profile belongs to the entry pressed last")
    func profileRace() async throws {
        let model = FilmographyModel(
            person: Person(id: "p", name: "Jemand", role: .actor), source: SlowDatabase(),
            library: { LibraryIndex() })
        let a = FilmographyEntry(id: "a", kind: .movie, title: "Langsam")
        let b = FilmographyEntry(id: "b", kind: .movie, title: "Schnell")
        let first = Task { await model.showProfile(for: a) }
        try await Task.sleep(for: .milliseconds(50))
        await model.showProfile(for: b)
        await first.value
        #expect(model.profile?.title == "Schnell")
        #expect(model.loadingProfileID == nil)
    }

    // MARK: - S3 · Sort change

    @Test("Two quick sort changes: the grid shows the order selected last")
    func raceSortSwitch() async throws {
        let store = InMemoryStore()
        let model = LibraryModel(
            source: SortingServer(), library: Core.Library(id: "a1b2c3", name: "Filme", kind: .movies),
            store: store, sortStore: store)
        await model.load()
        let first = Task { await model.choose(.rating) }
        try await Task.sleep(for: .milliseconds(50))
        await model.choose(.dateAdded)
        await first.value
        #expect(model.sorting == .dateAdded)
        guard case .ready(let title) = model.state else {
            Issue.record("no grid")
            return
        }
        #expect(title.map(\.id) == ["nachDatum"])
    }

    // MARK: - S4 · Account and profile switch

    @Test("Account switch: a remembered library does not stick to the source of the previous account")
    func libraryAfterAccountSwitch() {
        let models = ShellModels()
        let library = Core.Library(id: "a1b2c3", name: "Filme", kind: .movies)
        let accountA = SortingServer()
        let accountB = SortingServer()
        let previous = models.library(library, source: accountA, anime: nil, omdb: nil, rule: .pending)
        let after = models.library(library, source: accountB, anime: nil, omdb: nil, rule: .pending)
        let newModel = previous !== after
        let sourceOfB = (after.source as AnyObject) === (accountB as AnyObject)
        #expect(newModel)
        #expect(sourceOfB)
    }

    @Test("Same source, same profile: the remembered model stays")
    func libraryStays() {
        let models = ShellModels()
        let library = Core.Library(id: "a1b2c3", name: "Filme", kind: .movies)
        let account = SortingServer()
        let previous = models.library(library, source: account, anime: nil, omdb: nil, rule: .pending)
        let after = models.library(library, source: account, anime: nil, omdb: nil, rule: .pending)
        let same = previous === after
        #expect(same)
    }

    @Test("A newly built aggregate source over the same sources keeps the model")
    func aggregateSourceStays() {
        let models = ShellModels()
        let library = Core.Library(id: "a1b2c3", name: "Filme", kind: .movies)
        let account = SortingServer()
        let previous = models.library(
            library, source: AggregateSource([.jellyfin: account]), anime: nil, omdb: nil,
            rule: .pending)
        let after = models.library(
            library, source: AggregateSource([.jellyfin: account]), anime: nil, omdb: nil,
            rule: .pending)
        let same = previous === after
        #expect(same)
    }

    @Test("Profile switch over the same source: a new model")
    func libraryAfterProfileSwitch() {
        let models = ShellModels()
        let library = Core.Library(id: "a1b2c3", name: "Filme", kind: .movies)
        let account = SortingServer()
        let previous = ProfilePointer.als("anna") {
            models.library(library, source: account, anime: nil, omdb: nil, rule: .pending)
        }
        let after = ProfilePointer.als("ben") {
            models.library(library, source: account, anime: nil, omdb: nil, rule: .pending)
        }
        let newModel = previous !== after
        #expect(newModel)
    }

    // MARK: - S5 · Sort store

    @Test("Home videos: \"Newest\" from the phone counts as the recording date on the TV")
    func homeVideosFromPhone() {
        let store = InMemoryStore()
        let library = Core.Library(id: "hv1", name: "Heimvideos", kind: .homeVideos)
        SortStore(store: store).memorize(
            .init(kind: .added, ascending: true), area: "hv1")
        let order = LibraryModel.loadOrder(for: library, from: store)
        #expect(order.sorting == .recorded)
        #expect(order.ascending)
        #expect(order.isExplicit)
    }

    @Test("Provider series: one choice applies to all categories of the same list")
    func seriesCategoriesShare() {
        let store = InMemoryStore()
        let categoryA = Core.Library(id: "l1|series|9", name: "Krimi", kind: .series)
        let categoryB = Core.Library(id: "l1|series|12", name: "Komödie", kind: .series)
        LibraryModel.saveOrder(
            LibraryModel.SortOrder(sorting: .rating, ascending: false, isExplicit: true), for: categoryA,
            to: store)
        #expect(LibraryModel.loadOrder(for: categoryB, from: store).sorting == .rating)
    }
}

/// Staffel 1 antwortet langsam, Staffel 2 sofort.
final class SeasonDouble: ContentSource {
    func listChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    nonisolated var displayName: String { "Doppel" }
    nonisolated var canStartAtOffset: Bool { false }
    nonisolated var tracksStateItself: Bool { true }
    nonisolated func imageURL(itemID: String, kind: ImageKind, width: Int, tag: String?) -> URL? { nil }
    func libraries() async throws -> [Core.Library] { [] }
    func items(in library: Core.Library.ID, filter: ItemFilter) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { MediaItem(id: id, kind: .series, title: "S") }
    func children(of itemID: String) async throws -> [MediaItem] {
        if itemID == "stA" {
            try await Task.sleep(for: .milliseconds(400))
            return [MediaItem(id: "a1", kind: .episode, title: "A1")]
        }
        return [MediaItem(id: "b1", kind: .episode, title: "B1")]
    }
    func resumable(limit: Int) async throws -> [MediaItem] { [] }
    func segments(for itemID: String) async throws -> [MediaSegment] { [] }
    func report(progress: PlaybackProgress, for itemID: String, isPaused: Bool) async throws {}
    func setPlayed(_ isPlayed: Bool, for itemID: String) async throws {}
    func setFavorite(_ isFavorite: Bool, for itemID: String) async throws {}
    func favorites() async throws -> [MediaItem] { [] }
    func streamURL(for itemID: String, decision: PlaybackDecision) async throws -> URL {
        URL(string: "https://server/\(itemID)")!
    }
}

/// By rating the server answers slowly, by date immediately.
final class SortingServer: ContentSource, @unchecked Sendable {
    nonisolated var displayName: String { "Server" }
    nonisolated var canStartAtOffset: Bool { false }
    nonisolated var tracksStateItself: Bool { true }
    nonisolated func imageURL(itemID: String, kind: ImageKind, width: Int, tag: String?) -> URL? { nil }
    func libraries() async throws -> [Core.Library] { [] }
    func items(in library: Core.Library.ID, filter: ItemFilter) async throws -> [MediaItem] {
        if filter.sortBy == .rating {
            try? await Task.sleep(for: .milliseconds(400))
            return [MediaItem(id: "nachBewertung", kind: .movie, title: "B")]
        }
        return [MediaItem(id: "nachDatum", kind: .movie, title: "D")]
    }
    func item(id: String) async throws -> MediaItem { throw URLError(.badURL) }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func resumable(limit: Int) async throws -> [MediaItem] { [] }
    func segments(for itemID: String) async throws -> [MediaSegment] { [] }
    func streamURL(for itemID: String, decision: PlaybackDecision) async throws -> URL {
        throw URLError(.badURL)
    }
    func report(progress: PlaybackProgress, for itemID: String, isPaused: Bool) async throws {}
    func setPlayed(_ isPlayed: Bool, for itemID: String) async throws {}
    func setFavorite(_ isFavorite: Bool, for itemID: String) async throws {}
    func favorites() async throws -> [MediaItem] { [] }
    func listChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

/// The profile for "Langsam" arrives after 400 ms, the one for "Schnell" immediately.
struct SlowDatabase: FilmographySource {
    func filmography(forPersonNamed name: String) async throws -> Filmography { Filmography() }
    func profile(for entry: FilmographyEntry) async throws -> TitleProfile? {
        if entry.title == "Langsam" { try await Task.sleep(for: .milliseconds(400)) }
        return TitleProfile(title: entry.title)
    }
}
