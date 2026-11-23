import Core
import Foundation
import RatingsKit
import Testing

@testable import FeaturesPhone

/// What the detail page makes of a server response — and what it **leaves out**.
@Suite("Detail source")
struct DetailSourceTests {

    /// A source that can do nothing but build addresses — no more is needed by any of these
    /// checks, and more would be a re-creation of Jellyfin.
    private struct SilentSource: ContentSource {
        var displayName: String { "Stub" }
        nonisolated var canStartAtOffset: Bool { false }
        nonisolated var tracksStateItself: Bool { true }
        func libraries() async throws -> [Library] { [] }
        func items(in library: Library.ID, filter: ItemFilter) async throws -> [MediaItem] { [] }
        func item(id: String) async throws -> MediaItem { MediaItem(id: id, kind: .movie, title: "") }
        func children(of itemID: String) async throws -> [MediaItem] { [] }
        func resumable(limit: Int) async throws -> [MediaItem] { [] }
        func segments(for itemID: String) async throws -> [MediaSegment] { [] }
        func streamURL(for itemID: String, decision: PlaybackDecision) async throws -> URL {
            URL(string: "https://example.invalid")!
        }
        func report(progress: PlaybackProgress, for itemID: String, isPaused: Bool) async throws {}
        func setPlayed(_ isPlayed: Bool, for itemID: String) async throws {}
        func setFavorite(_ isFavorite: Bool, for itemID: String) async throws {}
        func favorites() async throws -> [MediaItem] { [] }
        func listChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    }

    private func episode(_ number: Int, season: Int, watched: Bool = false) -> MediaItem {
        var entry = MediaItem(id: "s\(season)f\(number)", kind: .episode, title: "Episode \(number)")
        entry.seasonNumber = season
        entry.episodeNumber = number
        if watched { entry.progress = PlaybackProgress(position: 100, duration: 100, isWatched: true) }
        return entry
    }

    /// A source with one series: ten episodes of 30 minutes each, four of them open.
    private struct SeriesSource: ContentSource {
        var displayName: String { "Stub" }
        nonisolated var canStartAtOffset: Bool { false }
        nonisolated var tracksStateItself: Bool { true }
        func libraries() async throws -> [Library] { [] }
        func items(in library: Library.ID, filter: ItemFilter) async throws -> [MediaItem] { [] }
        func item(id: String) async throws -> MediaItem {
            var series = MediaItem(id: id, kind: .series, title: "Series")
            series.episodeCount = 10
            series.unplayedCount = 4
            series.runtime = 1800
            return series
        }
        func children(of itemID: String) async throws -> [MediaItem] { [] }
        func resumable(limit: Int) async throws -> [MediaItem] { [] }
        func segments(for itemID: String) async throws -> [MediaSegment] { [] }
        func streamURL(for itemID: String, decision: PlaybackDecision) async throws -> URL {
            URL(string: "https://example.invalid")!
        }
        func report(progress: PlaybackProgress, for itemID: String, isPaused: Bool) async throws {}
        func setPlayed(_ isPlayed: Bool, for itemID: String) async throws {}
        func setFavorite(_ isFavorite: Bool, for itemID: String) async throws {}
        func favorites() async throws -> [MediaItem] { [] }
        func listChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    }

    /// **The viewing time of a series as on the TV** (decision 27, C7): total,
    /// still open, watched share — from episode count times runtime.
    @Test("A series brings its viewing time along, a movie does not")
    func watchDuration() async throws {
        let page = try await JellyfinDetailSource(
            source: SeriesSource(), width: 100, headerWidth: 100, logoWidth: 100
        ).detailInfo(zu: "s")
        let duration = try #require(page.watchDuration)
        #expect(duration.total == 18_000)
        #expect(duration.remaining == 7_200)
        #expect(abs(duration.watchedFraction - 0.6) < 0.001)
        #expect(WatchEstimate.durationText(duration.total, roundedValue: true) == "5 h")

        let film = try await JellyfinDetailSource(
            source: SilentSource(), width: 100, headerWidth: 100, logoWidth: 100
        ).detailInfo(zu: "f")
        #expect(film.watchDuration == nil)
    }

    /// **Name and story arc come from the season response**, not from the episodes.
    /// An episode knows which season it is in, but not what the season
    /// is about.
    @Test("The plot arc moves to the season")
    func seasonDescription() throws {
        var season = MediaItem(id: "s1", kind: .season, title: "Die Stille Wacht")
        season.seasonNumber = 1
        season.overview = "Daiki bricht in die Stille Wacht ein."

        let grouped = JellyfinDetailSource.grouped(
            [episode(1, season: 1), episode(2, season: 1)], seasons: [season],
            source: SilentSource(), width: 100)

        #expect(grouped.count == 1)
        #expect(grouped[0].name == "Die Stille Wacht")
        #expect(grouped[0].description == "Daiki bricht in die Stille Wacht ein.")
    }

    /// If the season response is missing, the bundling is still complete — it is then
    /// labeled by number instead of by name.
    @Test("Without a season reply it still groups")
    func withoutSeasons() {
        let grouped = JellyfinDetailSource.grouped(
            [episode(1, season: 2), episode(1, season: 1)], seasons: [],
            source: SilentSource(), width: 100)
        #expect(grouped.map(\.id) == [1, 2])
        #expect(grouped[0].name == nil)
    }

    /// **Two cases drop out, and both would look like an error.** "Chapter 3"
    /// is the number in another language, and a file with a mark at 0:00
    /// has no chapters — it has a beginning.
    @Test("Chapters without information are dropped")
    func chapters() {
        var single = MediaItem(id: "1", kind: .movie, title: "Kriosf")
        single.chapters = [Chapter(title: "Chapter 1", start: 0)]
        #expect(JellyfinDetailSource.chapters(zu: single, source: SilentSource()).isEmpty)

        var hasMultiple = MediaItem(id: "2", kind: .movie, title: "Kriosf")
        hasMultiple.chapters = [
            Chapter(title: "Chapter 1", start: 0),
            Chapter(title: "Der Fund", start: 724),
            Chapter(title: "", start: 1500),
        ]
        let marks = JellyfinDetailSource.chapters(zu: hasMultiple, source: SilentSource())
        #expect(marks.count == 3)
        #expect(marks[0].name == nil)
        #expect(marks[1].name == "Der Fund")
        #expect(marks[2].name == nil)
    }

    /// The time is the button's promise — and the hour appears only when there is
    /// one. "0:12:04" on a short film reads as an error.
    @Test("The hour appears only when there is one")
    func timeText() {
        #expect(ChapterDetail(id: 0, name: nil, start: 0).timeText == "0:00")
        #expect(ChapterDetail(id: 1, name: nil, start: 724).timeText == "12:04")
        #expect(ChapterDetail(id: 2, name: nil, start: 4324).timeText == "1:12:04")
    }

    /// **Production and music rarely interest anyone in the living room** — the same rule as on the
    /// TV, except that here it decides the task.
    @Test("Only actors, director and writer make the cast")
    func cast() {
        var title = MediaItem(id: "1", kind: .movie, title: "Kriosf")
        title.cast = [
            Person(id: "a", name: "Elias Varn", role: .actor, character: "Haddon"),
            Person(id: "b", name: "Lorenz Kemp", role: .director),
            Person(id: "c", name: "Andreas Jonas Wittke", role: .writer),
            Person(id: "d", name: "Bernd Kalisch", role: .producer),
            Person(id: "e", name: "Henrik Strand", role: .composer),
        ]
        let cast = JellyfinDetailSource.cast(from: title, source: SilentSource())
        #expect(cast.map(\.task) == [.cast, .directors, .ledger])
        #expect(cast[0].characterName == "Haddon")
    }

    /// **Ask only where the server has a picture.** `hasImage` saves a 404 request
    /// per face — exactly the finding from 2026-08-22, which produced one per tile
    /// on the Home screen.
    @Test("Without a stored image no address is built")
    func noImageAddressWithoutImage() {
        var title = MediaItem(id: "1", kind: .movie, title: "Kriosf")
        title.cast = [Person(id: "a", name: "Elias Varn", role: .actor, hasImage: false)]
        let cast = JellyfinDetailSource.cast(from: title, source: SilentSource())
        #expect(cast[0].image == nil)
    }

    /// **It does not repeat the attribute row** — and an empty entry is not even
    /// created. A row with a dash fills height with "nothing here".
    @Test("Empty details are not created at all")
    func details() {
        var title = MediaItem(id: "1", kind: .movie, title: "Kriosf", year: 1993)
        title.directors = ["Lorenz Kemp"]
        title.genres = ["Thriller", "Krimi"]
        let details = JellyfinDetailSource.details(zu: title)
        let keys = details.map(\.key)
        #expect(keys.contains("fact.director"))
        #expect(keys.contains("fact.genres"))
        #expect(keys.contains("fact.year"))
        // No studio, no runtime, no rating stored — so no rows.
        #expect(!keys.contains("fact.studio"))
        #expect(!keys.contains("fact.runtime"))
        #expect(!keys.contains("fact.rated"))
        #expect(Detail.when("fact.studio", "   ") == nil)
    }

    /// **The next episode is the one in progress, not the first unwatched.** Finishing a half-watched
    /// episode is the nearer step.
    @Test("The episode in progress goes first")
    func next() throws {
        var started = episode(5, season: 1)
        started.progress = PlaybackProgress(position: 42, duration: 100)
        let episodes = [episode(1, season: 1, watched: true), episode(2, season: 1), started]
        #expect(JellyfinDetailSource.next(from: episodes)?.id == started.id)
    }

    /// From the foreign evaluator to the own value — the translation lives in the source and
    /// not in the view.
    @Test("The OMDb award becomes a badge")
    func award() throws {
        #expect(ExternalRatingsSource.award(from: nil) == nil)
        #expect(ExternalRatingsSource.award(from: Awards()) == nil)
        let award = try #require(
            ExternalRatingsSource.award(from: Awards(oscarsWon: 4, totalWins: 160)))
        #expect(award.award == .oscar)
        #expect(award.count == 4)
    }
}

/// The choice in the sources sheet is the **upper limit**, not the file.
@Suite("Source choice")
struct SourceChoiceTests {

    /// **Every tier needs a word of its own.** If one were missing, the bare key name would
    /// appear on the device — an error that breaks neither build nor test and that one only sees on the
    /// screen. That is why this walks over all tiers and not over a
    /// selection.
    ///
    /// **What is checked is the key, not the translation.** In the package run there is no
    /// catalog — `String(localized:)` returns the key there, and a check
    /// on that compared a string with itself. Whether the key is in the catalog is checked by
    /// `scripts/strings.py`; that is the place for it.
    @Test("Every tier has a word and a number", arguments: StreamQuality.allCases)
    func slots(tier: StreamQuality) {
        let key = SourcesSheet.name(tier)
        #expect(key.hasPrefix("quality."))
        // No key twice — otherwise two tiers would be called the same, and the choice would be
        // none.
        #expect(StreamQuality.allCases.filter { SourcesSheet.name($0) == key }.count == 1)

        // **For "unlimited" there is no number**, because there is no limit there — an
        // invented number would be a claim about something that is not limited.
        if tier == .unlimited {
            #expect(SourcesSheet.bitrateText(tier) == nil)
        } else {
            #expect(SourcesSheet.bitrateText(tier) != nil)
        }
    }

    /// Six tiers from 0.5 to 20 Mbit/s — the number stands in the roadmap and here.
    @Test("Six tiers, and the smallest plays everywhere")
    func count() {
        #expect(StreamQuality.allCases.count == 6)
        #expect(StreamQuality.minimal.bitrate == 500_000)
    }
}
