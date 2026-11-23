import Core
import Foundation
import ProfileKit
import Testing

@testable import Features

/// **Top Shelf with CL-Server** (2026-09-28): The shelf shows what the profile last
/// watched, regardless of where from — the CL-Server's state lives on the server, not in the profile.
@MainActor
@Suite("Top Shelf: CL-Server on the shelf")
struct StartShelfCLServerTests {

    private let pending = ShelfFilter(
        childMode: false, applies: false, limit: nil, blocksUnrecognized: false, assignments: [:])

    private func entry(_ id: String, forward seconds: TimeInterval?) -> TopShelfEntry {
        TopShelfEntry(
            id: id, title: id, image: nil, recent: seconds.map { Date().addingTimeInterval(-$0) })
    }

    @Test("CL-Server and IPTV are mixed by “recently watched”")
    func mixed() {
        let profile = Profile(name: "A")
        let cl = [entry("zinne|a|/1", forward: 10), entry("zinne|b|/2", forward: 1000)]
        let extras = HomeShelf.extras(
            forItem: profile, filter: pending, mode: .resume, store: InMemoryStore(), clServer: cl)
        #expect(extras.map(\.id) == ["zinne|a|/1", "zinne|b|/2"])
    }

    @Test("If a rule applies, the CL-Server stays out too")
    func filterTakesEffect() {
        let filter = ShelfFilter(
            childMode: true, applies: true, limit: 6, blocksUnrecognized: true, assignments: [:])
        let extras = HomeShelf.extras(
            forItem: Profile(name: "Kind"), filter: filter, mode: .resume, store: InMemoryStore(),
            clServer: [entry("zinne|a|/1", forward: 1)])
        #expect(extras.isEmpty)
    }

    /// 2026-09-29: Under "Favorites" the CL-Server's watchlist was missing. That no
    /// *history* ends up there is ensured by the mode with which the contribution was fetched
    /// (``HomeShelf/clServerContribution(forItem:)``).
    @Test("For favorites the CL-Server watchlist comes along")
    func favorites() {
        let extras = HomeShelf.extras(
            forItem: Profile(name: "A"), filter: pending, mode: .favorites, store: InMemoryStore(),
            clServer: [entry("zinne|a|/1", forward: 1)])
        #expect(extras.map(\.id) == ["zinne|a|/1"])
    }

    @Test("Another profile's contribution does not count")
    func otherProfile() {
        #expect(HomeShelf.clServerContribution(forItem: Profile(name: "Fremd")).isEmpty)
    }
}

@MainActor
@Suite("Top Shelf: exactly the Home screen row")
struct StartShelfSeriesTests {

    private let pending = ShelfFilter(
        childMode: false, applies: false, limit: nil, blocksUnrecognized: false, assignments: [:])

    @Test("If the row is set it applies literally — channels included")
    func seriesApplies() {
        let row = [
            TopShelfEntry(id: "liste#live#1", title: "Sender", image: nil, recent: Date()),
            TopShelfEntry(id: "abc123", title: "Marder", image: nil, recent: nil),
        ]
        let extras = HomeShelf.extras(
            forItem: Profile(name: "A"), filter: pending, mode: .resume, store: InMemoryStore(),
            clServer: [TopShelfEntry(id: "zinne|a|/1", title: "x", image: nil, recent: Date())],
            row: row)
        #expect(extras == row)
    }

    @Test("Another profile's row does not count")
    func otherProfile() {
        #expect(HomeShelf.row(forItem: Profile(name: "Fremd")) == nil)
    }
}
