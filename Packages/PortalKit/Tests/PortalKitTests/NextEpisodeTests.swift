import Core
import Foundation
import Testing

@testable import PortalKit

/// **The next episode from the CL server** (AP85 #82, 2026-11-09).
///
/// Series from the CL server never jumped on: `PortalSource` did not answer
/// `nextEpisode(after:)`, and the default says "none".
@Suite("Next episode from the CL server")
struct NextEpisodeTests {

    private func episode(_ key: String, season: Int, address: String = "a") -> MediaItem {
        var item = MediaItem(
            id: PortalItemID(portal: "animehub", key: key, address: address).identifier,
            kind: .episode, title: key)
        item.seasonNumber = season
        return item
    }

    private var list: [MediaItem] {
        [episode("s1e1", season: 1), episode("s1e2", season: 1), episode("s2e1", season: 2)]
    }

    @Test("Within a season: the following episode")
    func withinSeason() {
        #expect(PortalSource.episode(after: list[0].id, in: list)?.title == "s1e2")
    }

    @Test("Across the season boundary, as with Jellyfin")
    func acrossSeasons() {
        #expect(PortalSource.episode(after: list[1].id, in: list)?.title == "s2e1")
    }

    @Test("After the last episode: nothing, not the same one again")
    func afterTheLast() {
        #expect(PortalSource.episode(after: list[2].id, in: list) == nil)
    }

    /// From Continue Watching the same episode can carry a different portal address.
    @Test("Found by its key when the address differs")
    func byKey() {
        let fromContinueWatching = episode("s1e1", season: 1, address: "other").id
        #expect(PortalSource.episode(after: fromContinueWatching, in: list)?.title == "s1e2")
    }

    @Test("An episode not in the list: nothing to offer")
    func unknown() {
        #expect(PortalSource.episode(after: episode("x", season: 9).id, in: list) == nil)
    }
}
