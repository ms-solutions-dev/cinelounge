import Foundation
import Testing

@testable import RatingsKit

/// The TMDb information for titles without an IMDb identifier (2026-09-29).
@Suite("TMDb: title information")
struct TitleInfoTests {

    @Test("A movie carries the IMDb identifier itself")
    func film() throws {
        let raw = #"""
            {"id":48213,"imdb_id":"tt5643670","overview":"Eine Programmiererin erfährt die Wahrheit.",
             "backdrop_path":"/hintergrund.jpg","poster_path":"/plakat.jpg",
             "genres":[{"id":28,"name":"Action"}],"vote_average":7.4,"vote_count":18500}
            """#
        let dto = try JSONDecoder().decode(TMDbClient.TitleDTO.self, from: Data(raw.utf8))
        let info = TMDbClient.info(from: dto)
        #expect(info.imdbID == "tt5643670")
        #expect(info.backdrop?.absoluteString == "https://image.tmdb.org/t/p/w1280/hintergrund.jpg")
        #expect(info.genres == ["Action"])
        #expect(info.rating == 7.4)
    }

    @Test("A series carries it under external_ids")
    func series() throws {
        let raw = #"""
            {"id":77781,"overview":"","backdrop_path":null,"vote_average":7.7,"vote_count":0,
             "external_ids":{"imdb_id":"tt6031097","tvdb_id":348019}}
            """#
        let dto = try JSONDecoder().decode(TMDbClient.TitleDTO.self, from: Data(raw.utf8))
        let info = TMDbClient.info(from: dto)
        #expect(info.imdbID == "tt6031097")
        #expect(info.description == nil, "empty is no description")
        #expect(info.backdrop == nil)
        #expect(info.rating == nil, "no rating without votes")
    }

    @Test("Only movie/<number> and tv/<number> go into a path")
    func identifier() {
        #expect(TMDbClient.isTitleID("movie/8604"))
        #expect(TMDbClient.isTitleID("tv/7401"))
        #expect(!TMDbClient.isTitleID("tv/0"))
        #expect(!TMDbClient.isTitleID("person/1"))
        #expect(!TMDbClient.isTitleID("movie/8604/../../x"))
    }

    // MARK: - Cast

    @Test("Director first, then cast in TMDb order, with picture")
    func cast() throws {
        let raw = #"""
            {"id":1,"credits":{
              "cast":[{"name":"B","character":"Zwei","profile_path":"/b.jpg","order":1},
                      {"name":"A","character":"Eins","profile_path":null,"order":0}],
              "crew":[{"name":"R","job":"Director","profile_path":"/r.jpg"},
                      {"name":"K","job":"Composer"}]}}
            """#
        let dto = try JSONDecoder().decode(TMDbClient.TitleDTO.self, from: Data(raw.utf8))
        let cast = TMDbClient.info(from: dto).cast
        #expect(cast.map(\.name) == ["R", "A", "B"])
        #expect(cast.first?.role == .director)
        #expect(cast[1].characterName == "Eins")
        #expect(cast[1].image == nil)
        #expect(cast[2].image?.absoluteString == "https://image.tmdb.org/t/p/w185/b.jpg")
    }

    // MARK: - Search

    private func match(_ id: Int, _ title: String, _ datum: String) -> TMDbClient.SearchResponse.Match {
        let raw = #"{"id":\#(id),"title":"\#(title)","release_date":"\#(datum)"}"#
        return try! JSONDecoder().decode(TMDbClient.SearchResponse.Match.self, from: Data(raw.utf8))
    }

    @Test("A unique hit with the same title and year counts")
    func unique() {
        let list = [match(1, "The Quiet Ferry", "2025-05-01"), match(2, "The Quiet Ferry", "2015-01-01")]
        #expect(TMDbClient.unique(list, title: "the quiet ferry", year: 2025) == 1)
    }

    @Test("Two matching hits — better none")
    func ambiguous() {
        let list = [match(1, "Stepbrook", "2026-01-01"), match(2, "Stepbrook", "2026-06-01")]
        #expect(TMDbClient.unique(list, title: "Stepbrook", year: 2026) == nil)
    }

    @Test("A different title or a different year does not count")
    func wrong() {
        #expect(
            TMDbClient.unique(
                [match(1, "The Quiet Ferry 2", "2025-01-01")], title: "The Quiet Ferry", year: 2025)
                == nil)
        #expect(
            TMDbClient.unique(
                [match(1, "The Quiet Ferry", "2024-12-31")], title: "The Quiet Ferry", year: 2025)
                == nil)
    }

    @Test("Spelling, accents and punctuation do not count")
    func comparisonForm() {
        #expect(TMDbClient.comparisonForm("Émeline") == TMDbClient.comparisonForm("emeline"))
        #expect(
            TMDbClient.comparisonForm("Wire-Dancer: Tide Without Shore") == "wire dancer tide without shore")
    }
}
