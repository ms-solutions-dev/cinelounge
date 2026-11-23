import Foundation
import Testing

@testable import FeaturesPhone

/// 2026-09-29: IPTV and CL-Server titles get from TMDb what they lack — nothing more.
@Suite("TMDb supplements the detail view")
struct TMDbSupplementTests {

    private let tmdb = ExternalInfo(
        backdrop: URL(string: "https://image.tmdb.org/t/p/w1280/b.jpg"),
        description: "From TMDb.", genres: ["Drama"])

    @Test("What is missing comes from TMDb")
    func fillsGaps() {
        let bare = HeroContent(tile: TileContent(id: "x", title: "Stepbrook"))
        let completed = bare.completed(um: tmdb)
        #expect(completed.description == "From TMDb.")
        #expect(completed.attributes == ["Drama"])
        #expect(completed.tile.backdrop?.lastPathComponent == "b.jpg")
    }

    @Test("What is there stays")
    func overwritesNothing() {
        let own = HeroContent(
            tile: TileContent(id: "x", title: "Stepbrook"), description: "Eigene.",
            attributes: ["2026"])
        let completed = own.completed(um: tmdb)
        #expect(completed.description == "Eigene.")
        #expect(completed.attributes == ["2026"])
    }
}
