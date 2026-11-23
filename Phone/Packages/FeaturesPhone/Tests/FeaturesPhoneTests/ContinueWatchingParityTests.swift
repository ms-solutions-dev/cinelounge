import Core
import Flows
import Foundation
import Testing

@testable import FeaturesPhone

/// **On-device test 2026-09-28:** Phone and TV showed different "Continue Watching" rows.
@Suite("Continue Watching on the phone as on the TV")
struct ContinueWatchingParityTests {

    /// 2026-09-29: The phone's own history no longer mixes in — the same row as on the TV,
    /// from the same sources.
    @Test("The row orders by last watched, across the sources")
    func ordersByMostRecent() {
        func tile(_ id: String, _ seconds: TimeInterval?) -> TileContent {
            var k = TileContent(id: id, title: id)
            k.recent = seconds.map(Date.init(timeIntervalSince1970:))
            return k
        }
        let shelf =
            StartModel.ordered([
                .fixed(ShelfIdentifier.continueWatching): [
                    tile("clock-ward", 1000), tile("osaka-ledger", 3000),
                    tile("without-time", nil), tile("a-haber", 4000),
                ]
            ])[.fixed(ShelfIdentifier.continueWatching)] ?? []
        #expect(shelf.map(\.id) == ["a-haber", "osaka-ledger", "clock-ward", "without-time"])
    }

    @Test("Three versions of a channel make one tile")
    func perStation() {
        let store = InMemoryStore()
        let history = ChannelHistory(store: store, profile: { "p" }, legacy: nil)
        let now = Date()
        history.memorize("TR: AYAZ HQ", um: now)
        history.memorize("TR: AYAZ", um: now.addingTimeInterval(-60))
        func channel(_ id: String, _ name: String) -> Channel {
            Channel(
                id: id, name: name, streamURL: URL(string: "http://a/\(id).ts")!, playlistID: "l",
                epgID: "ayaz.tr")
        }
        let tiles = TodayLive.continueWatching(
            isVisible: [channel("1", "TR: AYAZ"), channel("3", "TR: AYAZ HQ")], history: history,
            programs: [:], now: now)
        #expect(tiles.count == 1)
        #expect(tiles.first?.recent != nil)
    }
}
