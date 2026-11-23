import Core
import Flows
import Foundation
import Testing

/// **One ordering of the favorites for both programs** (AP58 R6, St3).
struct FavoritesOrderTests {

    @Test("Movies and series separate, episodes under the series, by title")
    func split() {
        let shared = FavoritesOrder.split([
            MediaItem(id: "m2", kind: .movie, title: "Zimtwald"),
            MediaItem(id: "e1", kind: .episode, title: "F1", parentTitle: "Nachtfalter", seriesID: "s1"),
            MediaItem(id: "e2", kind: .episode, title: "F2", parentTitle: "Nachtfalter", seriesID: "s1"),
            MediaItem(id: "e3", kind: .episode, title: "Lindgrau"),
            MediaItem(id: "b1", kind: .series, title: "Kaltwasser"),
            MediaItem(id: "h1", kind: .homeVideo, title: "Almbrunn"),
            MediaItem(id: "st", kind: .season, title: "Staffel 1"),
        ])
        #expect(shared.movies.map(\.id) == ["h1", "e3", "m2"])
        #expect(shared.allSeries.map(\.id) == ["b1", "s1"])
        #expect(shared.allSeries[1].episodes == 2)
        #expect(!shared.allSeries[1].isMarkedItself)
        #expect(shared.allSeries[0].isMarkedItself)
    }

    @Test("A series marked itself with marked episodes is one entry")
    func singleEntry() {
        let shared = FavoritesOrder.split([
            MediaItem(id: "e1", kind: .episode, title: "F1", parentTitle: "Nachtfalter", seriesID: "s1"),
            MediaItem(id: "s1", kind: .series, title: "Nachtfalter"),
        ])
        #expect(shared.allSeries.count == 1)
        #expect(shared.allSeries[0].representative.id == "s1")
        #expect(shared.allSeries[0].episodes == 1)
    }

    struct Declined: Error {}

    @MainActor
    @Test("Display first, then the service, back on error")
    func toggle() async {
        var shown: [Bool] = []
        let error = await MarkToggle.setEnabled(
            to: true, previous: false, show: { shown.append($0) }
        ) { throw Declined() }
        #expect(shown == [true, false])
        #expect(error is Declined)

        shown = []
        #expect(
            await MarkToggle.setEnabled(to: true, previous: false, show: { shown.append($0) }) {} == nil)
        #expect(shown == [true])
    }
}
