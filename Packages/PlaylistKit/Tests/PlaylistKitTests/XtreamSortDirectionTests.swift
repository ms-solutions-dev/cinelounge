import Core
import Foundation
import Testing

@testable import PlaylistKit

/// **What "ascending" means is a matter of contract** — and the contract is the media
/// server's: `ascending: false` for date and rating means **newest and best first**
/// (`SortOrder: Descending`). ``LibraryModel`` sends exactly that as the natural
/// direction of these two orderings. A source that reads it the other way round shows
/// the oldest under "New" — and nobody notices from the label.
@Suite("Sort direction of the provider catalog")
struct XtreamSortDirectionTests {

    private func film(_ title: String, tag: Int, rating: Double) -> MediaItem {
        MediaItem(
            id: title, kind: .movie, title: title,
            recordedAt: Date(timeIntervalSince1970: Double(tag) * 86_400),
            ratings: Ratings(community: rating))
    }

    private var catalog: [MediaItem] {
        [
            film("Alt", tag: 1, rating: 9.0), film("Neu", tag: 3, rating: 5.0),
            film("Mittel", tag: 2, rating: 7.0),
        ]
    }

    @Test("Descending by date the newest is on top")
    func dateDescending() {
        let result = XtreamVODSource.sorted(catalog, by: ItemFilter(sortBy: .dateAdded, ascending: false))
        #expect(result.map(\.title) == ["Neu", "Mittel", "Alt"])
    }

    @Test("Ascending by date the oldest is on top")
    func dateAscending() {
        let result = XtreamVODSource.sorted(catalog, by: ItemFilter(sortBy: .dateAdded, ascending: true))
        #expect(result.map(\.title) == ["Alt", "Mittel", "Neu"])
    }

    @Test("Descending by rating the best is on top")
    func ratingDescending() {
        let result = XtreamVODSource.sorted(catalog, by: ItemFilter(sortBy: .rating, ascending: false))
        #expect(result.map(\.title) == ["Alt", "Mittel", "Neu"])
    }

    @Test("Ascending by title A stays before Z")
    func titleAscending() {
        let result = XtreamVODSource.sorted(catalog, by: ItemFilter(sortBy: .title, ascending: true))
        #expect(result.map(\.title) == ["Alt", "Mittel", "Neu"])
    }
}
