import Foundation
import Testing

@testable import Core
@testable import PlaylistKit

/// **Which series have episodes at all.**
///
/// At a provider examined, about one series in five carries not a single
/// episode — counted on a complete M3U, not estimated. So that one
/// sees this before opening a title, the list is parsed once.
///
/// The fixture `playlist_ausschnitt.m3u` has the shape of an excerpt of a real
/// list, with invented names and addresses (written by `intern/fixtures-synth/iptv.py`):
/// channels, films and 46 episodes from three series — among them one with a
/// **comma in the name**, on which the first version of this parser failed.
@Suite("Episode index")
struct SeriesEpisodeIndexTests {

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
        return try Data(contentsOf: url)
    }

    // MARK: - Auswertung

    @Test("Exactly the three series titles come from the excerpt")
    func realExcerpt() throws {
        let titles = SeriesEpisodeIndex.titles(inPlaylist: try fixture("playlist_ausschnitt.m3u"))
        #expect(
            titles == [
                "Sarnıç |TR",
                "Halit Kömürcü |TR",
                "Marta, la relojera del puerto | TR",
            ])
    }

    /// **The bug the template caught.** At first this said "everything
    /// after the last comma" — from "Marta, la relojera del puerto | TR S01 E01"
    /// that would have become "la relojera del puerto | TR", and no index entry
    /// would ever have matched a title.
    @Test("A comma in the series name survives")
    func commaInTitle() {
        let list = """
            #EXTM3U
            #EXTINF:-1,Marta, la relojera del puerto | TR S01 E01
            http://h/series/u/p/1.mkv
            """
        #expect(
            SeriesEpisodeIndex.titles(inPlaylist: Data(list.utf8))
                == ["Marta, la relojera del puerto | TR"])
    }

    /// The same path must cope with `m3u_plus`: there the name additionally appears in
    /// `tvg-name`, and the attributes before it contain commas in quotation marks.
    @Test("m3u_plus with attributes in front yields the same title")
    func extendedFormat() {
        let list = """
            #EXTM3U
            #EXTINF:-1 tvg-id="" tvg-name="Serie, die |DE S01 E01" group-title="A, B",Serie, die |DE S01 E01
            http://h/series/u/p/1.mkv
            """
        #expect(SeriesEpisodeIndex.titles(inPlaylist: Data(list.utf8)) == ["Serie, die |DE"])
    }

    @Test("Channels and movies do not count as a series")
    func onlySeriesCount() {
        let list = """
            #EXTM3U
            #EXTINF:-1,TR: TELVE 1 UHD
            http://h/u/p/2
            #EXTINF:-1,Der Film [2019]
            http://h/movie/u/p/3.mp4
            #EXTINF:-1,Die Serie S01 E01
            http://h/series/u/p/4.mkv
            """
        #expect(SeriesEpisodeIndex.titles(inPlaylist: Data(list.utf8)) == ["Die Serie"])
    }

    /// Without a season marker the name stays as it is — there are series that carry none,
    /// and a truncated title would match nothing.
    @Test("Without a season marker the name stays unchanged")
    func withoutSeasonMarker() {
        let list = """
            #EXTM3U
            #EXTINF:-1,Eine Dokumentation
            http://h/series/u/p/9.mkv
            """
        #expect(SeriesEpisodeIndex.titles(inPlaylist: Data(list.utf8)) == ["Eine Dokumentation"])
    }

    /// The cut sits at the **rear** season marker: a title may itself
    /// look like that.
    @Test("A season marker in the title does not take effect")
    func seasonMarkerInsideTitle() {
        let list = """
            #EXTM3U
            #EXTINF:-1,Starhold Meridian S1 Remastered S02 E05
            http://h/series/u/p/9.mkv
            """
        #expect(
            SeriesEpisodeIndex.titles(inPlaylist: Data(list.utf8))
                == ["Starhold Meridian S1 Remastered"])
    }

    @Test("Empty and nonsense yield nothing without crashing")
    func rubbishStaysEmpty() {
        #expect(SeriesEpisodeIndex.titles(inPlaylist: Data()).isEmpty)
        #expect(SeriesEpisodeIndex.titles(inPlaylist: Data("#EXTM3U\n".utf8)).isEmpty)
        #expect(SeriesEpisodeIndex.titles(inPlaylist: Data("<html>Fehler</html>".utf8)).isEmpty)
        // Beschriftung ohne Adresse darunter.
        #expect(SeriesEpisodeIndex.titles(inPlaylist: Data("#EXTINF:-1,Serie S01 E01".utf8)).isEmpty)
    }

    // MARK: - Die Sicherungen

    private func index(_ titles: Set<String>) -> SeriesEpisodeIndex {
        SeriesEpisodeIndex(titles: titles, builtAt: Date())
    }

    private func series(_ titles: [String]) -> [MediaItem] {
        titles.map { MediaItem(id: $0, kind: .series, title: $0) }
    }

    /// **First safeguard.** An error page instead of the list yields a handful of
    /// titles — and without a threshold the whole catalog would be "without
    /// episodes" in one stroke.
    @Test("An index that is too thin marks nothing")
    func tooFewTitlesChangeNothing() {
        let thin = index(["A", "B"])
        #expect(thin.isUsable == false)
        let marked = thin.marking(series(["A", "X"]))
        #expect(marked.allSatisfy { $0.hasNoEpisodes == nil })
    }

    /// **Second safeguard.** If not a single title matches in a category, a
    /// deviating spelling of names is more likely than nothing but dead titles — and
    /// the whole category would be grey.
    @Test("Not a single hit in the category marks nothing")
    func noMatchAtAllChangesNothing() {
        let full = index(Set((0..<200).map { "Serie \($0)" }))
        #expect(full.isUsable)
        let marked = full.marking(series(["Ganz anders", "Auch anders"]))
        #expect(marked.allSatisfy { $0.hasNoEpisodes == nil })
    }

    @Test("With hits marking is done separately")
    func marksOnlyTheEmptyOnes() {
        let full = index(Set((0..<200).map { "Serie \($0)" }))
        let marked = full.marking(series(["Serie 7", "Nicht dabei"]))
        #expect(marked.first { $0.title == "Serie 7" }?.hasNoEpisodes == false)
        #expect(marked.first { $0.title == "Nicht dabei" }?.hasNoEpisodes == true)
    }

    /// Films are none of the index's business — it knows only series.
    @Test("Movies stay untouched")
    func moviesUntouched() {
        let full = index(Set((0..<200).map { "Serie \($0)" }))
        let items =
            series(["Serie 3"]) + [MediaItem(id: "f", kind: .movie, title: "Irgendein Film")]
        let marked = full.marking(items)
        #expect(marked.first { $0.kind == .movie }?.hasNoEpisodes == nil)
    }
}
