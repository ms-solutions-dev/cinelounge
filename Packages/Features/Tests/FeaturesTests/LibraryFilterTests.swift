import Core
import Foundation
import JellyfinKit
import Testing

@testable import Features

/// Multiple filtering: category **next to** sorting and jump markers.
///
/// The point is that none of the settings cancels another. Whoever chooses "Anime" wants the
/// anime — and still wants to decide for themselves whether they are ordered by title or by
/// access, and to keep the jump markers. A filter that resets the sorting is not a second
/// filter but a replacement for the first.
@Suite("Filtering categories")
@MainActor
struct LibraryFilterTests {

    @Test("The most frequent category comes first")
    func categoriesAreSortedByFrequency() {
        // On the remote every position further right is one more key press. Alphabetically
        // "Western" with two titles would come before "Anime" with twenty, and the most frequent
        // choice would be the farthest.
        let items =
            (1...5).map { item("a\($0)", genres: ["Anime"]) }
            + (1...3).map { item("d\($0)", genres: ["Drama"]) }
            + (1...2).map { item("w\($0)", genres: ["Western"]) }

        #expect(LibraryModel.categories(in: items) == ["Anime", "Drama", "Western"])
    }

    @Test("With equal frequency the name decides")
    func tiesAreStable() {
        // Without a second key the sequence would come from a dictionary — that is, a different one
        // on every call. The row would then look different at every opening, and whoever had
        // memorized where something is would have memorized it in vain.
        let items = [
            item("1", genres: ["Zombie"]), item("2", genres: ["Zombie"]),
            item("3", genres: ["Action"]), item("4", genres: ["Action"]),
        ]

        #expect(LibraryModel.categories(in: items) == ["Action", "Zombie"])
    }

    @Test("A category with a single title is not offered")
    func singletonsAreLeftOut() {
        // It is not an order but a second way to the same title — and exactly these make the row
        // long and useless. In the catalog here many titles carry half a dozen genres, half of them
        // unique.
        let items = [
            item("1", genres: ["Anime", "Einmalig"]),
            item("2", genres: ["Anime"]),
        ]

        #expect(LibraryModel.categories(in: items) == ["Anime"])
    }

    @Test("Without a choice everything stays")
    func noCategoryShowsEverything() {
        let model = model()
        let items = [item("1", genres: ["Anime"]), item("2", genres: ["Drama"])]

        #expect(model.visible(items).count == 2)
    }

    @Test("With a choice only what belongs stays")
    func categoryNarrows() {
        let model = model()
        let items = [
            item("1", genres: ["Anime", "Drama"]),
            item("2", genres: ["Drama"]),
            item("3", genres: []),
        ]

        model.choose(category: "Anime")
        #expect(model.visible(items).map(\.id) == ["1"])

        // A title with several genres belongs to each of them.
        model.choose(category: "Drama")
        #expect(model.visible(items).map(\.id) == ["1", "2"])
    }

    @Test("Pressing the same category again clears it")
    func togglingResets() {
        // Otherwise the way back to "Alle" would lead across the whole row — the longest way for the
        // most frequent undo.
        let model = model()

        model.toggle(category: "Anime")
        #expect(model.category == "Anime")

        model.toggle(category: "Anime")
        #expect(model.category == nil)

        // Another category switches instead of canceling.
        model.toggle(category: "Anime")
        model.toggle(category: "Drama")
        #expect(model.category == "Drama")
    }

    @Test("The jump marks follow what is left")
    func initialsFollowTheFilter() {
        // **This is the actual promise of multiple filtering.** If the letter bar stayed on the
        // unfiltered catalog, it would offer jumps to titles that are no longer in the grid at all
        // — a jump into nothing, and that is worse than no jump.
        let model = model()
        let items = [
            item("Ashen Harbor", genres: ["Anime"]),
            item("Bramble Court", genres: ["Drama"]),
            item("Copper Wells", genres: ["Anime"]),
        ]

        #expect(model.initials(for: items) == ["A", "B", "C"])

        model.choose(category: "Anime")
        #expect(model.initials(for: model.visible(items)) == ["A", "C"])
    }

    // MARK: - Helpers

    /// A model with a made-up access.
    ///
    /// Nothing is fetched — the category filtering computes solely with what is already there.
    /// That is exactly the promise that is checked along with it: Switching a category must cost
    /// **no** server call, otherwise every trying-out would be a wait.
    private func model() -> LibraryModel {
        LibraryModel(
            source: JellyfinSource(
                credentials: ServerCredentials(
                    serverURL: URL(string: "http://192.0.2.1")!,
                    userID: "u",
                    username: "u",
                    accessToken: "t"
                ),
                deviceID: "test"
            ),
            library: Core.Library(id: "lib", name: "Serien", kind: .series)
        )
    }

    private func item(_ id: String, genres: [String]) -> MediaItem {
        MediaItem(id: id, kind: .series, title: id, genres: genres)
    }
}
