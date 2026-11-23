import Core
import Foundation
import PlaylistKit
import Testing

@testable import FeaturesPhone

/// **A series from the provider catalog shows its seasons and episodes.**
///
/// **The finding from 2026-09-09, with a screenshot:** opening an item in Series showed
/// no content. Path: Library → Series → "DE|
/// MAGENTA SERIEN" → "Cublaispa|CA". The page showed header image, title, year and
/// genres, the rating, four header buttons, the description, **four faces** and "About
/// the title" — and neither season picker nor episode list nor play button. No empty
/// screen, no error message: **everything loaded, only the episodes were missing.**
///
/// **Two causes, both recorded here:**
/// 1. `XtreamVODSource` did not answer `episodes(of:)` at all — the contract's default
///    applied, and that is `[]`. Zero episodes became zero seasons and no
///    next step.
/// 2. `children(of:)` returns **episodes** for the provider and not seasons. Unfiltered,
///    the season picker would have been named after the first episode.
///
/// **The test material is the provider's responses** (iptvhost, measured on
/// 2026-09-09), shortened to three episodes per season — shape, keys and nesting
/// untouched; names, texts, people and image addresses are invented. "Torvelden" is the reported case, "Pater Lorenzin" the proof for more than
/// one season.
@Suite("Series from the provider catalog")
struct ProviderSeriesTests {

    private func template(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
        return try Data(contentsOf: url)
    }

    /// The identifier under which the detail page opens the series.
    private func seriesID(_ id: String) -> String {
        XtreamVOD.Reference(playlistID: "list", role: .series, id: id).itemID
    }

    /// A source that can do only one thing: **pass finished image addresses through.**
    ///
    /// That is exactly what `XtreamVODSource.imageURL(itemID:kind:width:tag:)` does too — a panel
    /// delivers foreign, finished addresses (here: TMDb), and the identifier **is** the address.
    /// A stand-in that returned `nil` instead would make the check "the still frame comes
    /// along" fail even though the provider carries it — and that would be a statement about the
    /// stand-in, not about the page.
    private struct SilentSource: ContentSource {
        var displayName: String { "Sample" }
        nonisolated var canStartAtOffset: Bool { false }
        nonisolated var tracksStateItself: Bool { true }
        nonisolated func imageURL(
            itemID: String, kind: ImageKind, width: Int, tag: String?
        )
            -> URL?
        {
            guard let url = URL(string: itemID), url.scheme?.hasPrefix("http") == true else {
                return nil
            }
            return url
        }
        func libraries() async throws -> [Library] { [] }
        func items(in library: Library.ID, filter: ItemFilter) async throws -> [MediaItem] { [] }
        func item(id: String) async throws -> MediaItem {
            MediaItem(id: id, kind: .movie, title: "")
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

    /// Builds the page exactly as ``JellyfinDetailSource/detailInfo(zu:)`` does:
    /// the same response once as episodes and once as "children".
    ///
    /// **And that is no imitation but the real case.** For the provider
    /// `episodes(of:)` and `children(of:)` answer with the same bytes — whoever supplied only the episodes here
    /// would test the half that was not at fault.
    private func seasons(from data: Data, series: String) throws -> [Season] {
        let episodes = try XtreamVOD.episodes(
            from: data, seriesID: series, playlistID: "list")
        return JellyfinDetailSource.grouped(
            episodes, seasons: episodes, source: SilentSource(), width: 300)
    }

    /// `info.duration_secs` of the first episode, as the template carries it. Read from the file
    /// and not written down: the public export moves the recorded runtimes (pseudonyms.py,
    /// `numbers`), and what is checked is that the runtime is carried over, not its value.
    private func recordedSeconds(of name: String) throws -> TimeInterval {
        struct Reply: Decodable {
            struct Episode: Decodable {
                struct Info: Decodable {
                    let seconds: Double
                    enum CodingKeys: String, CodingKey { case seconds = "duration_secs" }
                }
                let info: Info
            }
            let episodes: [String: [Episode]]
        }
        let reply = try JSONDecoder().decode(Reply.self, from: try template(name))
        return try #require(reply.episodes["1"]?.first?.info.seconds)
    }

    // MARK: - The reported case

    /// **The page that was empty is empty no more.**
    @Test("Torvelden brings its season with its episodes")
    func torveldenHasEpisodes() throws {
        let grouped = try seasons(from: try template("torvelden_series_info.json"), series: "7295")

        #expect(grouped.count == 1, "the provider lists one season")
        let season = try #require(grouped.first)
        #expect(season.id == 1)
        #expect(season.episodes.count == 3)
        #expect(season.episodes.map(\.number) == [1, 2, 3])
    }

    /// **The play button that did not exist on this page at all.**
    ///
    /// It stands and falls with ``DetailContent/next``; without episodes that was `nil`, and
    /// `DetailModel.buttonLabel` consequently returned `nil` as well — the bar
    /// was never drawn.
    @Test("The next step is the first unwatched episode")
    func nextStep() throws {
        let episodes = try XtreamVOD.episodes(
            from: try template("torvelden_series_info.json"), seriesID: "7295", playlistID: "list")

        let next = try #require(JellyfinDetailSource.next(from: episodes))
        #expect(next.episodeNumber == 1)
        #expect(next.kind == .episode)
        // Without this link back, the tile in the history would later lead to the episode
        // instead of to the series — the chain from E38.
        #expect(next.seriesID == seriesID("7295"))
    }

    // MARK: - More than one season

    /// **Two seasons in the template** — the bundling has to keep them
    /// apart and order them in sequence.
    @Test("Pater Lorenzin brings its seasons in the provider's order")
    func cefeibremKlimumaHasTwoSeasons() throws {
        let grouped = try seasons(
            from: try template("pater_lorenzin_series_info.json"), series: "6613")

        #expect(grouped.map(\.id) == [1, 2])
        #expect(grouped.map { $0.episodes.count } == [3, 3])
        #expect(grouped[1].episodes.allSatisfy { $0.id != grouped[0].episodes[0].id })
    }

    // MARK: - An episode is not a season

    /// **The second error, and it would have been visible.**
    ///
    /// `children(of:)` returns episodes for the provider. Had these been read as a season response,
    /// every season would have carried the title of its first episode — the picker would have
    /// been called "Cublaispa - S01E01 - Jeglo 1" and would have carried its plot as the season description.
    @Test("The season is not named after its first episode")
    func seasonNameDoesNotComeFromEpisode() throws {
        let season = try #require(
            try seasons(from: try template("torvelden_series_info.json"), series: "7295").first)

        #expect(season.name == nil, "the provider lists no season names")
        #expect(season.description == nil)
        #expect(season.label.contains("1"), "then the number counts")
    }

    // MARK: - Nothing is invented

    /// **What the provider delivers is there — and the rest is not.**
    ///
    /// Measured against the real response: `info.duration_secs` and `info.movie_image` are
    /// filled for every episode, `info.plot` is the empty string for **all** of them.
    /// That is exactly what ``Season/showsDescriptions`` exists for — a list shows texts
    /// either everywhere or nowhere.
    @Test("Runtime and still frame come along, there is no description")
    func onlyWhatTheProviderCarries() throws {
        let season = try #require(
            try seasons(from: try template("torvelden_series_info.json"), series: "7295").first)
        let first = try #require(season.episodes.first)

        #expect(
            first.duration == (try recordedSeconds(of: "torvelden_series_info.json")), "from duration_secs")
        // The episode's still frame from `info.movie_image` — not the series poster.
        #expect(first.image?.absoluteString.hasSuffix("5wIVi1EuAHeV2LInfnwi6Mv3vUd.jpg") == true)
        #expect(
            season.episodes.map(\.image).compactMap { $0 }.count == 3,
            "every episode has its own")
        #expect(Set(season.episodes.compactMap(\.image)).count == 3, "and not the same one three times")
        #expect(first.description == nil, "info.plot is empty — no placeholder")
        #expect(season.showsDescriptions == false)
        #expect(first.title.isEmpty == false)
        #expect(
            first.title.contains("S01E01") == false,
            "the provider's lead-in is not in every line")
    }

    // MARK: - And it plays

    /// **The play address lies under `/series/`, although an episode is meant.**
    ///
    /// That is the provider's spelling and no oversight: the series itself has
    /// no address, only its episodes do. Measured on 2026-09-09 against the real
    /// response — episode 339505, `container_extension` `mkv`.
    @Test("Every episode has a playback address")
    func episodesAddress() throws {
        let episodes = try XtreamVOD.episodes(
            from: try template("torvelden_series_info.json"), seriesID: "7295", playlistID: "list")
        let account = try #require(
            XtreamEndpoint(server: "http://panel.test:2086", username: "user", password: "pass"))

        let first = try #require(episodes.first)
        let address = try #require(XtreamVOD.playbackURL(for: first.id, account: account))
        #expect(address.absoluteString == "http://panel.test:2086/series/user/pass/339505.mkv")
    }

    /// The series itself gets none — it is a folder.
    @Test("The series itself has no playback address")
    func seriesHasNoAddress() throws {
        let account = try #require(
            XtreamEndpoint(server: "http://panel.test:2086", username: "user", password: "pass"))
        #expect(XtreamVOD.playbackURL(for: seriesID("7295"), account: account) == nil)
    }

    // MARK: - The switch before it

    /// **Without it the question would arrive at the media server.** A provider identifier sent
    /// there yields no hit, and the failure would look like a network outage.
    @Test("A provider identifier is assigned to the provider")
    func originOfIdentifier() {
        #expect(AggregateDetailSource.origin(seriesID("7295")) == .provider)
    }
}
