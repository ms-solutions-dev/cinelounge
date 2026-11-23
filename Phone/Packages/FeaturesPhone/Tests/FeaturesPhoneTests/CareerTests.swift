import Core
import DesignSystemPhone
import Flows
import Foundation
import Testing

@testable import FeaturesPhone

/// A person's career — **posters for all, a path for one's own.**
@Suite("Career")
struct CareerTests {

    private func entry(
        _ title: String, inCatalog: Bool, withImage: Bool = true
    )
        -> FilmographyEntry
    {
        FilmographyEntry(
            id: title, kind: .movie, title: title, year: 1999, role: "Rolle",
            posterURL: withImage ? URL(string: "https://example.invalid/\(title).jpg") : nil,
            libraryItemID: inCatalog ? "jf-\(title)" : nil)
    }

    /// **Someone else's title leads nowhere — one's own certainly does.** Until 2026-09-08
    /// neither led anywhere: The reasoning applied to others' titles, and for
    /// one's own nothing was therefore built at all.
    @Test("Only titles from the own catalog have a path")
    func onlyOwnContinue() {
        #expect(entry("Asil", inCatalog: true).isInLibrary)
        #expect(!entry("Fremd", inCatalog: false).isInLibrary)
        #expect(entry("Asil", inCatalog: true).libraryItemID == "jf-Asil")
    }

    /// **The poster carries every row, also the foreign one.** It is the information "that is the
    /// movie" and not a control; an image only on one's own titles would turn the
    /// list into two lists.
    @Test("The poster does not depend on the catalog")
    func posterForAll() {
        #expect(entry("Fremd", inCatalog: false).posterURL != nil)
    }

    /// **Where TMDb carries none, the area stays empty.** `nil` means "no image" and not
    /// "placeholder image" — the same rule as at ``EmptyTile``.
    @Test("No poster is invented when there is none")
    func withoutPoster() {
        #expect(entry("Ohne", inCatalog: true, withImage: false).posterURL == nil)
    }

    /// **"What you have opens; what you don't have explains itself."** The switch sits
    /// in the model and not in the row — otherwise every row would pose the question a second
    /// time, and the two answers would drift apart at the next refactoring.
    @Test("An own title leads on, a foreign one explains itself")
    @MainActor
    func softAtModel() async {
        let model = DetailModel(identifier: "x", source: nil, rule: .pending)
        var opened: String?
        await model.tapFilmography(entry("Asil", inCatalog: true)) { opened = $0 }
        #expect(opened == "jf-Asil")
        #expect(model.sheetState.pending == nil)

        await model.tapFilmography(entry("Fremd", inCatalog: false)) { opened = $0 }
        #expect(opened == "jf-Asil")  // unchanged — nothing was opened
        #expect(model.sheetState.pending == .titleProfile)
        #expect(model.profileTitle == "Fremd")
    }

    /// **The match itself — it did not exist until 2026-09-09**
    ///
    /// Both branches above check with a `libraryItemID` set **by hand**; nobody
    /// set it, and `isInLibrary` was therefore `false` on every row. Here is the question
    /// that matters: Does ``CatalogIndex/mark(_:against:)`` find a title again
    /// that the two catalogs spell differently — and does it leave one that does not exist
    /// alone?
    @Test("Matching works across spellings and invents nothing")
    func sync() {
        let catalog = LibraryIndex([
            MediaItem(id: "jf-1", kind: .movie, title: "The Ember Warden", year: 2006),
            MediaItem(id: "jf-2", kind: .movie, title: "ROLL·O", year: 2006),
        ])

        let marked = CatalogIndex.mark(
            [
                // Article in front, different capitalization.
                FilmographyEntry(id: "t1", kind: .movie, title: "Ember Warden", year: 2006),
                // Punctuation different — and a year off, as often happens between two
                // catalogs.
                FilmographyEntry(id: "t2", kind: .movie, title: "Roll-O", year: 2007),
                FilmographyEntry(id: "t3", kind: .movie, title: "Hat hier niemand", year: 1998),
            ], against: catalog)

        #expect(marked[0].libraryItemID == "jf-1")
        #expect(marked[1].libraryItemID == "jf-2")
        #expect(!marked[2].isInLibrary)
    }

    /// **An empty index does not deny, it stays silent.** "I could not look" and
    /// "you don't have that" look the same in the row — only one of the two causes
    /// can be fixed, and neither justifies deleting an existing checkmark.
    @Test("Without a catalog every entry stays as it was")
    func emptyCatalog() {
        let previous = [entry("Asil", inCatalog: true), entry("Fremd", inCatalog: false)]
        #expect(CatalogIndex.mark(previous, against: LibraryIndex()) == previous)
    }

    /// The row is two thirds of a shelf poster and keeps its ratio — a
    /// sheet row is not a shelf tile.
    @Test("The row poster keeps the 2 : 3 ratio")
    func posterRatio() {
        let p = FilmographyRow.poster
        #expect(
            abs(p.width / p.height - MetricsBoard.phone.poster.width / MetricsBoard.phone.poster.height)
                < 0.01)
    }
}
