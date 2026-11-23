import Testing

@testable import PlaylistKit

/// **A movie that is an episode** (diagnostics F-056, 2026-10-01): "Kumlu Fincan 5.Bölüm" is
/// listed at the provider as a movie, the series next to it is called "Kumlu Fincan |TR".
@Suite("Episode film: the way to the series via the name")
struct EpisodeFilmTests {

    @Test(
        "The episode marker at the end is dropped",
        arguments: [
            ("Kumlu Fincan 5.Bölüm", "Kumlu Fincan"),
            ("Kerem: Dalgalar Sultanı 86.Bölüm", "Kerem: Dalgalar Sultanı"),
            ("Nachtfalter - Folge 3", "Nachtfalter"),
            ("Nachtfalter Episode 12", "Nachtfalter"),
            ("Nachtfalter S01E05", "Nachtfalter"),
        ])
    func seriesName(_ pair: (String, String)) {
        #expect(SequelFilm.seriesName(from: pair.0) == pair.1)
    }

    @Test(
        "A film without an episode marker is not an episode film",
        arguments: ["Driftwake", "2012", "Kessel's 11"])
    func notEpisodeFilm(_ title: String) {
        #expect(SequelFilm.seriesName(from: title) == nil)
    }

    @Test("Language, year, punctuation and ı do not disturb the comparison")
    func key() {
        #expect(SequelFilm.key("Kumlu Fincan |TR") == SequelFilm.key("Kumlu Fincan"))
        #expect(
            SequelFilm.key("Kerem - Dalgalar Sultani |TR")
                == SequelFilm.key("Kerem: Dalgalar Sultanı"))
        #expect(SequelFilm.key("TR| Köşkaltı (2024)") == SequelFilm.key("Köşkaltı"))
        #expect(SequelFilm.key("Kumlu Fincan") != SequelFilm.key("Kumlu"))
    }

    /// Two entries with the same key are two series at the provider — the match
    /// then takes none (``XtreamVODSource/seriesReference(zu:)``).
    @Test("“Köşkaltı |TR” and “Köşkaltı | TR” are the same key")
    func duplicate() {
        #expect(SequelFilm.key("Köşkaltı |TR") == SequelFilm.key("Köşkaltı | TR"))
    }
}
