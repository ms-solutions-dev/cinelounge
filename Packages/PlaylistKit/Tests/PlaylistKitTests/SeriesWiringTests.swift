import Foundation
import Testing

@testable import Core
@testable import PlaylistKit

/// **The series wiring.**
///
/// The parsers for series had been ready for a long time, tests included — but until 2026-08-22.
/// **only the test suite** called them. `XtreamVODSource.libraries()`
/// asked only `get_vod_categories`, `children(of:)` returned an empty list,
/// and `item(id:)` threw on a series. That is why the interface
/// showed no series: not because they were missing, but because nobody fetched them.
///
/// What is tested here are responses in the provider's real shape, written by
/// `intern/fixtures-synth/iptv.py` with invented names.
@Suite("Series at the provider")
struct SeriesWiringTests {

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
        return try Data(contentsOf: url)
    }

    // MARK: - The identifier carries the kind

    /// **Films and series have their own number ranges.** At the test provider there is
    /// category 427 twice — once "STREAMING SERIES", once something
    /// else among the films. Without the kind in the ID, it could not be told from
    /// `xyz|vod|427` which fetch is meant.
    @Test("The library identifier distinguishes movies from series")
    func libraryIDCarriesTheKind() throws {
        let movies = XtreamVODSource.libraryID(playlistID: "abc", categoryID: "427", kind: .movies)
        let series = XtreamVODSource.libraryID(playlistID: "abc", categoryID: "427", kind: .series)
        #expect(movies != series)

        let m = try #require(XtreamVODSource.parseLibraryID(movies))
        #expect(m.playlistID == "abc")
        #expect(m.categoryID == "427")
        #expect(m.kind == .movies)

        let s = try #require(XtreamVODSource.parseLibraryID(series))
        #expect(s.playlistID == "abc")
        #expect(s.categoryID == "427")
        #expect(s.kind == .series)
    }

    /// Without a statement it stays with films — the IDs that were stored before 2026-08-22
    /// carry no kind and all mean films.
    @Test("Old identifiers without a kind still count as movies")
    func oldIDsStillParseAsMovies() throws {
        let parsed = try #require(XtreamVODSource.parseLibraryID("abc|vod|117"))
        #expect(parsed.kind == .movies)
        #expect(parsed.categoryID == "117")
    }

    /// Nonsense stays nonsense — and must not pass as half an ID.
    @Test("What is not an identifier is rejected")
    func nonsenseIsRefused() {
        #expect(XtreamVODSource.parseLibraryID("") == nil)
        #expect(XtreamVODSource.parseLibraryID("abc") == nil)
        #expect(XtreamVODSource.parseLibraryID("|vod|427") == nil, "without list")
        #expect(XtreamVODSource.parseLibraryID("abc|vod|") == nil, "without category")
        #expect(XtreamVODSource.parseLibraryID("abc|series|") == nil)
    }

    // MARK: - Die Serie selbst

    /// The detail page needs plot, genre, rating and **cast** —
    /// all of it is in the head of `get_series_info`.
    @Test("The series with its cast arises from get_series_info")
    func seriesDetailFromRealAnswer() throws {
        let item = try #require(
            try XtreamVOD.seriesDetail(
                from: try fixture("series_info.json"), seriesID: "4711", playlistID: "y"))

        #expect(item.kind == .series)
        #expect(item.title == "Das Kieselhaus", "prefix and brackets cut")
        #expect(item.year == 2026)
        #expect(item.genres == ["Reality"])
        #expect(item.overview?.hasPrefix("Zwölf Fremde, ein altes Haus") == true)
        #expect(item.cast.map(\.name) == ["Femke Ardelt", "Lasse Dornbusch"])
        #expect(item.artwork.posterID != nil, "the series poster")

        // The ID must lead back to the series — otherwise
        // ``children(of:)`` does not find its episodes again.
        let reference = try #require(XtreamVOD.Reference(itemID: item.id))
        #expect(reference.role == .series)
        #expect(reference.id == "4711")
        #expect(reference.playlistID == "y")
    }

    /// **The runtime stays deliberately empty.** `episode_run_time` is the length
    /// of one episode; shown on the series it would read as the total length.
    @Test("The series carries no runtime")
    func seriesHasNoRuntime() throws {
        let item = try #require(
            try XtreamVOD.seriesDetail(
                from: try fixture("series_info.json"), seriesID: "4711"))
        #expect(item.runtime == nil)
    }

    /// If the panel does not know the series, it answers with empty lists instead of
    /// an error — no half entry may arise from that.
    @Test("An unknown series yields nothing")
    func unknownSeriesYieldsNil() throws {
        let empty = Data(#"{"seasons":[],"info":[],"episodes":[]}"#.utf8)
        #expect(try XtreamVOD.seriesDetail(from: empty, seriesID: "1") == nil)
    }

    // MARK: - Die Folgen

    /// The same response carries the episodes — and they must be traceable
    /// to their series.
    @Test("The episodes of the series come from the same response")
    func episodesComeFromTheSameAnswer() throws {
        let data = try fixture("series_info.json")
        let series = try #require(
            try XtreamVOD.seriesDetail(from: data, seriesID: "4711", playlistID: "y"))
        let episodes = try XtreamVOD.episodes(from: data, seriesID: "4711", playlistID: "y")

        #expect(episodes.count == 20)
        #expect(episodes.allSatisfy { $0.kind == .episode })
        #expect(
            episodes.allSatisfy { $0.seriesID == series.id },
            "every episode must point to its series")
        #expect(episodes.first?.episodeNumber == 1)
        #expect(episodes.first?.seasonNumber == 1)
    }

    // MARK: - The three shapes of `episodes`

    /// **Panels write `episodes` in three ways**, and which depends on
    /// their PHP version, not on the series (finding 2026-08-22: "Glimmerwood"
    /// returned 70 013 bytes, and the parser found not a single episode — it
    /// knew only the first form).
    @Test("Keyed by season — the shape of the test template")
    func keyedBySeason() {
        let groups = XtreamVOD.seasonGroups(
            in: ["2": [["id": "b"]], "1": [["id": "a"]], "10": [["id": "c"]]])

        #expect(groups.map(\.key) == ["1", "2", "10"], "by number, not by text")
        #expect(groups.first?.entries.count == 1)
    }

    /// A list **of seasons** — the position is the number.
    @Test("List of seasons: the position becomes the season number")
    func listOfSeasons() {
        let groups = XtreamVOD.seasonGroups(
            in: [[["id": "a"], ["id": "b"]], [["id": "c"]]])

        #expect(groups.map(\.key) == ["1", "2"], "position 0 is season 1")
        #expect(groups.first?.entries.count == 2)
        #expect(groups.last?.entries.count == 1)
    }

    /// A **flat** list of episodes. Only here does the episode's `season` field
    /// count — everywhere else the key wins, because quite a few panels write
    /// `0` there throughout (see `seasonKeyWins` in `XtreamVODTests`).
    @Test("A flat episode list is split by its season field")
    func flatEpisodeList() {
        let groups = XtreamVOD.seasonGroups(
            in: [
                ["id": "a", "season": "2"],
                ["id": "b", "season": "1"],
                ["id": "c", "season": "2"],
            ])

        #expect(groups.map(\.key) == ["1", "2"])
        #expect(groups.first?.entries.count == 1)
        #expect(groups.last?.entries.count == 2)
    }

    /// Without `season` everything lands in season 1 — nobody would have a season 0.
    @Test("A flat list without a season field becomes season 1")
    func flatListWithoutSeason() {
        let groups = XtreamVOD.seasonGroups(in: [["id": "a"], ["id": "b"]])
        #expect(groups.map(\.key) == ["1"])
        #expect(groups.first?.entries.count == 2)
    }

    /// Empty stays empty — and must not produce a ghost season.
    @Test("Empty and unknown shapes yield nothing")
    func emptyStaysEmpty() {
        #expect(XtreamVOD.seasonGroups(in: nil).isEmpty)
        #expect(XtreamVOD.seasonGroups(in: [String: Any]()).isEmpty)
        #expect(XtreamVOD.seasonGroups(in: [Any]()).isEmpty)
        #expect(XtreamVOD.seasonGroups(in: "Unsinn").isEmpty)
        // A list of empty seasons does not count as a season.
        #expect(XtreamVOD.seasonGroups(in: [[Any](), [Any]()]).isEmpty)
    }

    /// **The template must still run through** — it carries form 1, and the
    /// switch must not tip it over.
    @Test("The real response yields its 20 episodes unchanged")
    func realAnswerStillWorks() throws {
        let episodes = try XtreamVOD.episodes(
            from: try fixture("series_info.json"), seriesID: "4711", playlistID: "y")
        #expect(episodes.count == 20)
        #expect(episodes.first?.seasonNumber == 1)
    }

    // MARK: - When the provider itself has nothing

    /// **The gap lies with the provider, not in the parser.**
    ///
    /// Re-measured on 2026-08-22 on 50 series across a provider's catalog:
    /// ten of them — a fifth — come back without the field `episodes`.
    /// `series_info_ohne_folgen.json` has the shape of the response where it was
    /// noticed, a film series filed as a series.
    @Test("If the episodes field is missing carriesEpisodeField says so")
    func providerWithoutEpisodeField() throws {
        let data = try fixture("series_info_ohne_folgen.json")
        #expect(XtreamVOD.carriesEpisodeField(in: data) == false)
        #expect(try XtreamVOD.episodes(from: data, seriesID: "718").isEmpty)
    }

    /// **Seasons without episodes are the same case.** "The Brindlewood Papers"
    /// (series 3050) reports four seasons with episode counts and still carries
    /// not a single episode; `season_id`, `get_series_episodes` and
    /// `get_simple_data_table` return nothing there either.
    @Test("Season entries without episodes remain a gap of the provider")
    func providerWithSeasonsButNoEpisodes() throws {
        let data = try fixture("series_info_nur_staffeln.json")
        #expect(XtreamVOD.carriesEpisodeField(in: data) == false)
        #expect(try XtreamVOD.episodes(from: data, seriesID: "3050").isEmpty)
    }

    /// The counter-check: where episodes arrive, the test reports the field too.
    @Test("With episodes present carriesEpisodeField reports true")
    func realAnswerCarriesTheField() throws {
        #expect(XtreamVOD.carriesEpisodeField(in: try fixture("series_info.json")))
    }
}
