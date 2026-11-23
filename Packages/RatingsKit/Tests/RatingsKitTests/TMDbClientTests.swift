import Core
import Foundation
import Testing

@testable import RatingsKit

/// How a response from the movie database becomes a row.
///
/// What is tested is the parsing, not the network: The quirks are in the
/// format, and they are documented by real responses — TMDb names the same thing
/// differently for films and series, and a missing rating comes as
/// zero instead of as a gap.
@Suite("Response of the movie database")
struct TMDbEntryTests {

    private let base = "https://image.tmdb.org/t/p/"

    private func credit(
        id: Int = 1,
        mediaType: String? = "movie",
        title: String? = nil,
        name: String? = nil,
        releaseDate: String? = nil,
        firstAirDate: String? = nil,
        character: String? = nil,
        voteAverage: Double? = nil,
        voteCount: Int? = nil,
        posterPath: String? = nil
    ) -> TMDbClient.CreditEntry {
        TMDbClient.CreditEntry(
            id: id,
            mediaType: mediaType,
            title: title,
            name: name,
            releaseDate: releaseDate,
            firstAirDate: firstAirDate,
            character: character,
            voteAverage: voteAverage,
            voteCount: voteCount,
            posterPath: posterPath
        )
    }

    @Test("A movie with everything")
    func fullMovie() throws {
        let entry = try #require(
            TMDbClient.entry(
                from: credit(
                    id: 51874,
                    title: "The Glass Orchard",
                    releaseDate: "2013-03-08",
                    character: "Ines",
                    voteAverage: 7.6,
                    voteCount: 21000,
                    posterPath: "/abc.jpg"
                ),
                posterBase: base
            )
        )

        #expect(entry.kind == .movie)
        #expect(entry.title == "The Glass Orchard")
        #expect(entry.year == 2013)
        #expect(entry.role == "Ines")
        #expect(entry.rating == 7.6)
        #expect(entry.posterURL?.absoluteString == base + "w342/abc.jpg")
    }

    /// TMDb calls a series' title `name` and its start `first_air_date`.
    /// Whoever reads only the film fields gets an empty row for every series.
    @Test("A series carries its details in other fields")
    func seriesUsesOtherFields() throws {
        let entry = try #require(
            TMDbClient.entry(
                from: credit(
                    id: 64219,
                    mediaType: "tv",
                    name: "Salt Road",
                    firstAirDate: "2011-09-04",
                    character: "Mara Lind"
                ),
                posterBase: base
            )
        )

        #expect(entry.kind == .series)
        #expect(entry.title == "Salt Road")
        #expect(entry.year == 2011)
    }

    /// **A zero would be a claim.** Without votes TMDb returns 0.0, and
    /// that would stand as a devastating verdict where merely nobody voted.
    @Test("Without votes no rating")
    func noVotesMeansNoRating() throws {
        let entry = try #require(
            TMDbClient.entry(
                from: credit(title: "Unbekannt", voteAverage: 0, voteCount: 0),
                posterBase: base
            )
        )
        #expect(entry.rating == nil)
    }

    /// Announced titles have an empty date at TMDb. They are not thrown out —
    /// whoever wants to know what someone is working on would find it nowhere else.
    @Test("Without a date the entry stays, but without a year")
    func emptyDateKeepsTheEntry() throws {
        let entry = try #require(
            TMDbClient.entry(from: credit(title: "Coming soon", releaseDate: ""), posterBase: base)
        )
        #expect(entry.year == nil)
        #expect(entry.title == "Coming soon")
    }

    /// TMDb occasionally keeps records without names. An empty row in the
    /// list looks like an app error.
    @Test("Without a title no row")
    func withoutTitleThereIsNoRow() {
        #expect(TMDbClient.entry(from: credit(title: nil, name: nil), posterBase: base) == nil)
        #expect(TMDbClient.entry(from: credit(title: ""), posterBase: base) == nil)
    }

    @Test("Without a poster no address")
    func withoutPosterThereIsNoURL() throws {
        let entry = try #require(
            TMDbClient.entry(from: credit(title: "No picture"), posterBase: base))
        #expect(entry.posterURL == nil)
    }

    /// A film and a series can carry the same number — they are separate
    /// number ranges. Without the kind in the key, merging the
    /// roles would throw them into one row.
    @Test("Movie and series with the same number stay separate")
    func kindIsPartOfTheKey() throws {
        let movie = try #require(
            TMDbClient.entry(from: credit(id: 42, title: "Film"), posterBase: base))
        let series = try #require(
            TMDbClient.entry(
                from: credit(id: 42, mediaType: "tv", name: "Serie"), posterBase: base))

        #expect(movie.id != series.id)
    }
}

/// **The short profile for titles one does not have** (roadmap P17).
@Suite("TMDb · short profile")
struct TMDbProfileTests {

    @Test("The row's identifier carries its kind and is taken apart again")
    func idCarriesItsKind() {
        #expect(TMDbClient.split("movie-603")?.kind == "movie")
        #expect(TMDbClient.split("movie-603")?.number == 603)
        #expect(TMDbClient.split("tv-1399")?.kind == "tv")
        // Anything else is none — better no profile than a request into the void.
        #expect(TMDbClient.split("person-42") == nil)
        #expect(TMDbClient.split("603") == nil)
        #expect(TMDbClient.split("movie-abc") == nil)
    }

    @Test("The profile takes the title of the row, not that of the second response")
    func rowTitleWins() throws {
        // A differing name in the profile would look as if something else had been
        // opened — the row comes from the same database and is authoritative.
        let json = """
            {"overview": "Eine Kartografin sucht eine verschwundene Insel.",
             "poster_path": "/p.jpg", "release_date": "1987-10-02",
             "vote_average": 7.3, "vote_count": 9800,
             "genres": [{"name": "Science Fiction"}, {"name": "Thriller"}],
             "credits": {"cast": [{"name": "Lena Vos"}, {"name": "Tom Arden"}]}}
            """
        let dto = try JSONDecoder().decode(
            TMDbClient.TitleDetail.self, from: Data(json.utf8))
        let row = FilmographyEntry(
            id: "movie-4512", kind: .movie, title: "Paper Coast", year: 1987, role: "Iris")

        let profile = TMDbClient.profile(
            from: dto, fallback: row, posterBase: "https://x/")
        #expect(profile.title == "Paper Coast")
        #expect(profile.year == 1987)
        #expect(profile.genres == ["Science Fiction", "Thriller"])
        #expect(profile.cast == ["Lena Vos", "Tom Arden"])
        #expect(profile.overview.hasPrefix("Eine Kartografin"))
        #expect(profile.rating == 7.3)
    }

    @Test("A rating without votes is none")
    func noVotesNoRating() throws {
        // The same rule as in the list: TMDb returns 0.0, and that would stand as a
        // devastating verdict where merely nobody voted.
        let json = """
            {"overview": "", "vote_average": 0.0, "vote_count": 0}
            """
        let dto = try JSONDecoder().decode(
            TMDbClient.TitleDetail.self, from: Data(json.utf8))
        let row = FilmographyEntry(id: "tv-9", kind: .series, title: "Neu", year: nil)
        let profile = TMDbClient.profile(from: dto, fallback: row, posterBase: "https://x/")
        #expect(profile.rating == nil)
        #expect(profile.overview.isEmpty)
    }
}
