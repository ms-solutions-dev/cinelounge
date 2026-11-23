import Core
import Foundation
import Testing

@testable import PortalKit

@Suite("Filtering and sorting in the app")
struct PortalFilterTests {

    private let catalog = [
        MediaItem(
            id: "p|a|x", kind: .series, title: "Dunmere", year: 2017,
            ratings: Ratings(community: 8.7)),
        MediaItem(
            id: "p|b|x", kind: .series, title: "Aldwyn", year: 2022,
            ratings: Ratings(community: 8.4)),
        MediaItem(
            id: "p|c|x", kind: .episode, title: "Corvelle", year: 2019,
            ratings: Ratings(community: 9.3)),
    ]

    @Test("Sorted by title, ascending")
    func byTitle() {
        let result = PortalSource.filtered(catalog, after: ItemFilter(sortBy: .title))
        #expect(result.map(\.title) == ["Aldwyn", "Corvelle", "Dunmere"])
    }

    @Test("Descending reverses")
    func descending() {
        let result = PortalSource.filtered(catalog, after: ItemFilter(sortBy: .title, ascending: false))
        #expect(result.map(\.title) == ["Dunmere", "Corvelle", "Aldwyn"])
    }

    /// `ascending: false` — the natural direction of the rating, as ``LibraryModel`` sends it and as the media
    /// server reads it.
    @Test("By rating the best is on top")
    func byRating() {
        let result = PortalSource.filtered(catalog, after: ItemFilter(sortBy: .rating, ascending: false))
        #expect(result.first?.title == "Corvelle")
    }

    /// A portal script does not give out a recording date. Its own order is exactly the one wanted for "New
    /// Episodes" — re-sorting it would make it worse.
    @Test("By date the portal's order stays")
    func byDate() {
        let result = PortalSource.filtered(catalog, after: ItemFilter(sortBy: .dateAdded))
        #expect(result.map(\.title) == ["Dunmere", "Aldwyn", "Corvelle"])
    }

    @Test("A search word works regardless of case")
    func searchTerm() {
        let result = PortalSource.filtered(catalog, after: ItemFilter(searchTerm: "dunmere"))
        #expect(result.map(\.title) == ["Dunmere"])
    }

    @Test("Filtered by kind")
    func byKind() {
        let result = PortalSource.filtered(catalog, after: ItemFilter(kinds: [.episode]))
        #expect(result.map(\.title) == ["Corvelle"])
    }

    @Test("The limit cuts off")
    func limit() {
        let result = PortalSource.filtered(catalog, after: ItemFilter(sortBy: .title, limit: 2))
        #expect(result.count == 2)
    }
}

/// The same contract question as in `XtreamSortDirectionTests`: `ascending: false` for the rating means
/// **best first**, and `true` reverses it — otherwise the second press on "Rating" is a button without
/// effect.
@Suite("Sort direction of the portals")
struct PortalSortDirectionTests {

    private let catalog = [
        MediaItem(id: "p|a|x", kind: .series, title: "Gut", ratings: Ratings(community: 8.0)),
        MediaItem(id: "p|b|y", kind: .series, title: "Ohne"),
        MediaItem(id: "p|c|z", kind: .series, title: "Besser", ratings: Ratings(community: 9.0)),
    ]

    @Test("Descending by rating: best first, unrated last")
    func descending() {
        let result = PortalSource.filtered(catalog, after: ItemFilter(sortBy: .rating, ascending: false))
        #expect(result.map(\.title) == ["Besser", "Gut", "Ohne"])
    }

    @Test("Ascending by rating reverses — unrated stays at the back")
    func ascending() {
        let result = PortalSource.filtered(catalog, after: ItemFilter(sortBy: .rating, ascending: true))
        #expect(result.map(\.title) == ["Gut", "Besser", "Ohne"])
    }
}
