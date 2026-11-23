import Core
import Testing

@testable import Features

/// Tests the suggestions of the search empty state.
///
/// The empty state shows the newest from the catalog, mixed in rotation from all
/// libraries. The mixing is the actual statement: it
/// decides whether the screen says "there are movies and series here" or only
/// repeats the first library.
@Suite("Search suggestions")
@MainActor
struct SearchSuggestionTests {

    private func item(_ id: String, kind: MediaItem.Kind = .movie) -> MediaItem {
        MediaItem(id: id, kind: kind, title: id)
    }

    @Test("The libraries alternate, the newest of each first")
    func poolsAreMixedInRounds() {
        // Appended one after the other, the first library would fill all slots, and whoever
        // searches for series would see only movies. In rotation, something from each stands in front — in the
        // order in which the libraries were loaded.
        let movies = [item("film-1"), item("film-2"), item("film-3")]
        let series = [item("serie-1", kind: .series), item("serie-2", kind: .series)]

        let mixed = SearchModel.mixed([movies, series], limit: 12)

        #expect(mixed.map(\.id) == ["film-1", "serie-1", "film-2", "serie-2", "film-3"])
    }

    @Test("The limit also holds when the libraries offer more")
    func limitCapsTheResult() {
        // More suggestions would be a second library to page through — that is what
        // the Library is for. Without the cap the empty state would grow with the
        // catalog, and the limit in ``SearchModel/suggestionLimit`` would be a mere
        // claim.
        let many = (1...20).map { item("film-\($0)") }

        let mixed = SearchModel.mixed([many], limit: SearchModel.suggestionLimit)

        #expect(mixed.count == SearchModel.suggestionLimit)
    }

    @Test("Empty libraries upset nothing")
    func emptyPoolsAreHarmless() {
        // The edge where rotation loops tip over: no catalog, or an empty
        // list between two full ones. Both must run through silently — the
        // empty state is the wrong place for an error.
        #expect(SearchModel.mixed([], limit: 12).isEmpty)
        #expect(
            SearchModel.mixed([[], [item("einzig")], []], limit: 12).map(\.id) == ["einzig"]
        )
    }
}
