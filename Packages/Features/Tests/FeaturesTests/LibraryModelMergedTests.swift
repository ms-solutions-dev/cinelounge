import Core
import Testing

@testable import Features

/// **2026-10-12, on the device:** PortHollow showed genres and cast from TMDb in the column for
/// half a second — then the single fetch put the slim portal row over it. What the list
/// already knows, the single fetch must not delete; what it knows more wins.
@Suite("Library: merging single fetch and enrichment")
struct LibraryModelMergedTests {

    private func title(
        genres: [String] = [], cast: [Person] = [], directors: [String]? = nil,
        overview: String? = nil, community: Double? = nil
    ) -> MediaItem {
        var m = MediaItem(id: "portal:porthollow", kind: .series, title: "PortHollow")
        m.genres = genres
        m.cast = cast
        m.directors = directors
        m.overview = overview
        m.ratings.community = community
        return m
    }

    private var pierce: Person {
        Person(
            id: "tmdb:Conrad Ashby", name: "Conrad Ashby", role: .actor, character: nil, hasImage: true)
    }

    @Test("The slim server copy deletes nothing that TMDb filled in")
    func slimCopyLosesNothing() {
        let enriched = title(
            genres: ["Drama", "Krimi"], cast: [pierce], overview: "London.", community: 8.4)
        let merged = LibraryModel.merged(title(), using: enriched)
        #expect(merged.genres == ["Drama", "Krimi"])
        #expect(merged.cast == [pierce])
        #expect(merged.overview == "London.")
        #expect(merged.ratings.community == 8.4)
    }

    @Test("The full Jellyfin title wins where it knows more")
    func fullTitleWins() {
        let list = title(genres: ["Drama"], overview: "kurz")
        let full = title(
            genres: ["Drama", "Thriller"], cast: [pierce], directors: ["Gil Rourke"], overview: "lang")
        let merged = LibraryModel.merged(full, using: list)
        #expect(merged.genres == ["Drama", "Thriller"])
        #expect(merged.directors == ["Gil Rourke"])
        #expect(merged.overview == "lang")
    }

    @Test("An empty director list counts as missing")
    func emptyDirector() {
        let merged = LibraryModel.merged(title(directors: []), using: title(directors: ["Gil Rourke"]))
        #expect(merged.directors == ["Gil Rourke"])
    }
}
