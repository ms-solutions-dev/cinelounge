import Core
import Flows
import Foundation
import Testing

@testable import Features

/// **The TV's Home screen asks the shared rules** (AP58 R6, St1/St2).
@MainActor
struct StartupBuildTVTests {

    static func title(_ id: String, kind: MediaItem.Kind = .movie) -> MediaItem {
        var image = Artwork()
        image.backdropID = "b-\(id)"
        return MediaItem(id: id, kind: kind, title: id, artwork: image)
    }

    /// **A home video in a movie library** — the library's kind does not
    /// stop it, the rule on the title does.
    @Test("A home video in a movie library does not reach the header area")
    func homeVideoInFilmShelf() {
        let homeShelf = HomeModel.Shelf(
            id: "f", titleKey: "f", items: [Self.title("urlaub", kind: .homeVideo), Self.title("m1")],
            usesWideCards: false, libraryKind: .movies)
        let heroes = HomeModel.heroCandidates(shelves: [homeShelf], shuffle: false)
        #expect(heroes.map(\.id) == ["m1"])
    }

    @Test("Home screen limits come from the startup build")
    func limits() {
        #expect(ShelfRule.perOrigin == HomeLayout.librariesPerOrigin)
        #expect(RecentShelf.atMost == HomeLayout.maxRecent)
        #expect(ShelfRule.withoutShelf == HomeLayout.withoutShelf)
        #expect(HomeModel.collectionsID == ShelfIdentifier.collections)
    }

    @Test("All watched: the series opens in the last season")
    func lastSeason() {
        let seasons = (1...3).map { number -> MediaItem in
            var seasonItem = MediaItem(id: "s\(number)", kind: .season, title: "")
            seasonItem.unplayedCount = 0
            return seasonItem
        }
        #expect(DetailModel.startingSeason(in: seasons)?.id == "s3")
    }
}
