import Core
import Foundation
import Testing

@testable import ParentalControls

/// Episodes inherit the rating of their series — **checked across the whole chain** from the lookup to
/// the filter (thread K, 2026-09-25).
///
/// The lookup is a stub of the server that answers like the real one: one row per found
/// series, an unknown identifier is missing. The list resembles Continue Watching
/// on a real server — films with a rating, episodes without, a home video without.
@Suite("Series ratings")
struct SeriesApprovalsTests {

    /// The stub: counts lookups, remembers the identifiers, can fail.
    actor Server {
        var approvals: [String: String?]
        var fails: Bool
        private(set) var fetches: [[String]] = []

        init(approvals: [String: String?], fails: Bool) {
            self.approvals = approvals
            self.fails = fails
        }

        func respond(_ allSeries: [String]) throws -> [SeriesClearance] {
            fetches.append(allSeries)
            if fails { throw URLError(.notConnectedToInternet) }
            return allSeries.compactMap { series in
                approvals[series].map { SeriesClearance(series: series, approval: $0) }
            }
        }

        func reset() { fails = false }
    }

    static let series18 = "f8bae756f276a61acae318a522781457"
    static let series6 = "aa2e6a8077374a4b485a7304983238f1"
    static let seriesWithout = "528195500169cd22d15d157de71ab539"

    static func episode(_ id: String, series: String) -> MediaItem {
        MediaItem(id: id, kind: .episode, title: id, seriesID: series)
    }

    /// Like Continue Watching on a real server: a film with a rating, three episodes from
    /// two series without, a home video without.
    static var continueWatching: [MediaItem] {
        [
            MediaItem(id: "aa01", kind: .movie, title: "Film", ageRating: "FSK-12"),
            episode("bb01", series: series18),
            episode("bb02", series: series18),
            episode("cc01", series: series6),
            MediaItem(id: "dd01", kind: .homeVideo, title: "Video_010"),
        ]
    }

    /// A child with limit 12 and a stored PIN.
    static let kind = ProtectionRule(
        deviceLocked: true, accountKind: .adult, isPinSet: true, limit: .from12,
        blocksUnrecognized: true, assignments: [:])

    static func server(fails: Bool) -> Server {
        Server(
            approvals: [series18: "FSK-18", series6: "FSK-6", seriesWithout: nil],
            fails: fails)
    }

    static func completed(
        _ title: [MediaItem], _ server: Server, _ memory: SeriesClearances
    ) async -> [MediaItem] {
        await memory.complete(title) { allSeries in try await server.respond(allSeries) }
    }

    @Test("Episode of an FSK 18 series is gone for a child (12), episode of an FSK 6 series is there")
    func childSeesOnlyMatchingEpisodes() async {
        let server = Self.server(fails: false)
        let title = await Self.completed(Self.continueWatching, server, SeriesClearances())
        let isVisible = title.filter(Self.kind.shows).map(\.id)
        #expect(isVisible == ["aa01", "cc01", "dd01"])
        #expect(title.first { $0.id == "bb01" }?.ageRating == "FSK-18")
        #expect(title.first { $0.id == "cc01" }?.ageRating == "FSK-6")
    }

    @Test("All series of a list in one fetch, kept for the session")
    func singleFetch() async {
        let server = Self.server(fails: false)
        let memory = SeriesClearances()
        _ = await Self.completed(Self.continueWatching, server, memory)
        #expect(await server.fetches == [[Self.series6, Self.series18].sorted()])

        // The same list once more — no further lookup.
        _ = await Self.completed(Self.continueWatching, server, memory)
        #expect(await server.fetches.count == 1)
    }

    @Test("A list without episodes costs no fetch")
    func noEpisodesNoFetch() async {
        let server = Self.server(fails: false)
        let movies = [MediaItem(id: "aa01", kind: .movie, title: "Film", ageRating: "FSK-12")]
        #expect(await Self.completed(movies, server, SeriesClearances()) == movies)
        #expect(await server.fetches.isEmpty)
    }

    @Test("If the lookup fails, the episode is locked in child mode")
    func failureBlocks() async {
        let server = Self.server(fails: true)
        let memory = SeriesClearances()
        let title = await Self.completed(Self.continueWatching, server, memory)
        #expect(title.filter(Self.kind.shows).map(\.id) == ["aa01", "dd01"])
        // Outside child mode nothing changes.
        #expect(title.filter(ProtectionRule.pending.shows).count == 5)

        // Failures are not kept: On the next build it asks again.
        await server.reset()
        let following = await Self.completed(Self.continueWatching, server, memory)
        #expect(following.filter(Self.kind.shows).map(\.id) == ["aa01", "cc01", "dd01"])
        #expect(await server.fetches.count == 2)
    }

    @Test("A series the server does not know locks its episodes in child mode")
    func unknownSeriesBlocks() async {
        let server = Self.server(fails: false)
        let foreign = [Self.episode("ee01", series: "ffffffffffffffffffffffffffffffff")]
        let title = await Self.completed(foreign, server, SeriesClearances())
        #expect(title.filter(Self.kind.shows).isEmpty)
    }

    @Test("A series verifiably without a rating: no rating, passes")
    func seriesWithoutApproval() async {
        let server = Self.server(fails: false)
        let title = await Self.completed(
            [Self.episode("gg01", series: Self.seriesWithout)], server, SeriesClearances())
        #expect(title.first?.seriesClearanceChecked == true)
        #expect(title.first?.ageRating == nil)
        #expect(title.filter(Self.kind.shows).count == 1)
    }

    @Test("An episode never looked up (old snapshot) is locked in child mode")
    func neverLookedUp() {
        let old = Self.episode("bb01", series: Self.series18)
        #expect(old.awaitsSeriesClearance)
        #expect(!Self.kind.shows(old))
        #expect(ProtectionRule.pending.shows(old))
    }

    @Test("Adults see everything, including the episode of the FSK 18 series")
    func adultsSeeEverything() async {
        let server = Self.server(fails: false)
        let title = await Self.completed(Self.continueWatching, server, SeriesClearances())
        #expect(title.filter(ProtectionRule.pending.shows).count == 5)
        // Even an adult with a PIN but without a limit: no lock ordered.
        let withoutLimit = ProtectionRule(
            deviceLocked: true, accountKind: .adult, isPinSet: true, limit: nil,
            blocksUnrecognized: true, assignments: [:])
        let pending = Self.continueWatching
        #expect(pending.filter(withoutLimit.shows).count == 5)
    }

    @Test("Seasons inherit like episodes")
    func seasons() async {
        let server = Self.server(fails: false)
        let season = MediaItem(id: "ss01", kind: .season, title: "Staffel 1", seriesID: Self.series18)
        let title = await Self.completed([season], server, SeriesClearances())
        #expect(title.first?.ageRating == "FSK-18")
        #expect(!Self.kind.shows(title[0]))
    }

    // MARK: - The episode's own rating (check 25.09.2026, finding 6)

    @Test("Own FSK 0 on an episode of an FSK 18 series: the stricter applies, the child does not see it")
    func stricterApplies() async {
        let server = Self.server(fails: false)
        var episode = Self.episode("0123456789abcdef0123456789abcdef", series: Self.series18)
        episode.ageRating = "FSK-0"
        let title = await Self.completed([episode], server, SeriesClearances())
        #expect(title.first?.ageRating == "FSK-0")
        #expect(title.first?.seriesClearance == "FSK-18")
        #expect(!Self.kind.shows(title[0]))
        #expect(!Self.childShelf.allows(title[0]))
        #expect(ProtectionRule.pending.shows(title[0]))
    }

    @Test("Own FSK 16 on an episode of an FSK 6 series: the own one is the stricter")
    func ownStricter() async {
        let server = Self.server(fails: false)
        var episode = Self.episode("hh02", series: Self.series6)
        episode.ageRating = "FSK-16"
        let title = await Self.completed([episode], server, SeriesClearances())
        #expect(!Self.kind.shows(title[0]))
    }

    @Test("Own rating and series without a rating or unreachable: the own one applies as before")
    func ownWithoutSeries() async {
        var without = Self.episode("hh03", series: Self.seriesWithout)
        without.ageRating = "FSK-6"
        let title = await Self.completed([without], Self.server(fails: false), SeriesClearances())
        #expect(Self.kind.shows(title[0]))

        var route = Self.episode("hh04", series: Self.series18)
        route.ageRating = "FSK-6"
        let failed = await Self.completed([route], Self.server(fails: true), SeriesClearances())
        #expect(!failed[0].awaitsSeriesClearance)
        #expect(Self.kind.shows(failed[0]))
    }

    // MARK: - Top Shelf

    /// A child's shelf, as the app stores it for the extension.
    static let childShelf = ShelfFilter(rule: kind, childMode: true)

    @Test("Top Shelf filters episodes likewise")
    func topShelf() async {
        let server = Self.server(fails: false)
        let title = await Self.completed(Self.continueWatching, server, SeriesClearances())
        #expect(title.filter(Self.childShelf.allows).map(\.id) == ["aa01", "cc01", "dd01"])
        #expect(title.filter(ShelfFilter.pending.allows).count == 5)
    }

    @Test("Top Shelf: if the lookup fails, the episode drops out")
    func topShelfFailure() async {
        let server = Self.server(fails: true)
        let title = await Self.completed(Self.continueWatching, server, SeriesClearances())
        #expect(title.filter(Self.childShelf.allows).map(\.id) == ["aa01", "dd01"])
    }
}
