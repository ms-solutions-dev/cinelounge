import Foundation
import Testing

@testable import Flows

/// **Reloading before the end** (AP76): the last twelve tiles trigger it, not only the last.
@Suite("Loading more before the end (AP76)")
struct LoadMoreTests {

    struct Tile: Identifiable { let id: Int }

    @Test("The last twelve trigger, the ones before do not")
    func lastTwelve() {
        let tiles = (0..<40).map(Tile.init)
        #expect(LoadMore.applies(Tile(id: 39), in: tiles))
        #expect(LoadMore.applies(Tile(id: 28), in: tiles))
        #expect(!LoadMore.applies(Tile(id: 27), in: tiles))
        #expect(!LoadMore.applies(Tile(id: 0), in: tiles))
    }

    @Test("A short page triggers with every tile")
    func shortPage() {
        let tiles = (0..<5).map(Tile.init)
        #expect(tiles.allSatisfy { LoadMore.applies($0, in: tiles) })
        #expect(!LoadMore.applies(Tile(id: 1), in: [Tile]()))
    }
}
