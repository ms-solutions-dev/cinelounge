import Foundation
import Testing

@testable import Core

/// The sorting of the career and the merging of duplicate rows.
@Suite("A person's career")
struct FilmographySortingTests {

    private func entry(
        _ id: String, _ title: String, year: Int?, role: String? = nil
    )
        -> FilmographyEntry
    {
        FilmographyEntry(id: id, kind: .movie, title: title, year: year, role: role)
    }

    @Test("Newest to oldest")
    func newestFirst() {
        let sorted = Filmography.sorted([
            entry("a", "Alt", year: 1994),
            entry("b", "Neu", year: 2021),
            entry("c", "Mittel", year: 2008),
        ])
        #expect(sorted.map(\.title) == ["Neu", "Mittel", "Alt"])
    }

    /// **Announced titles go last — since 2026-09-08, and the reversal came from the
    /// screen.** A title without a date has no poster and usually no role either;
    /// it is the weakest row of the list. Before, Calder Price opened with five empty
    /// boxes without a year, where "Agents in Grey" and "Last Light Avenue" belong.
    @Test("Announced titles go to the very bottom")
    func announcedLast() {
        let sorted = Filmography.sorted([
            FilmographyEntry(id: "b", kind: .movie, title: "Kommt noch"),
            FilmographyEntry(id: "a", kind: .movie, title: "Erschienen", year: 2001),
        ])
        #expect(sorted.first?.title == "Erschienen")
        #expect(sorted.last?.title == "Kommt noch")
    }

    /// The film database keeps an entry **per role**. Someone who played two characters
    /// in one series would appear twice one below the other without this merging
    /// — that looks like a bug in the app.
    @Test("Two roles in the same title become one row")
    func doubleRolesMerge() {
        let sorted = Filmography.sorted([
            entry("x", "Zwei Gesichter", year: 2010, role: "Der Gute"),
            entry("x", "Zwei Gesichter", year: 2010, role: "Der Böse"),
        ])

        #expect(sorted.count == 1)
        #expect(sorted.first?.role == "Der Gute, Der Böse")
    }

    @Test("The same role twice still appears only once")
    func identicalRolesAreNotRepeated() {
        let sorted = Filmography.sorted([
            entry("x", "Titel", year: 2010, role: "Er selbst"),
            entry("x", "Titel", year: 2010, role: "Er selbst"),
        ])
        #expect(sorted.first?.role == "Er selbst")
    }

    @Test("Same year: by title, so the order does not wobble")
    func sameYearIsStable() {
        let sorted = Filmography.sorted([
            entry("b", "Zebra", year: 2010),
            entry("a", "Ameise", year: 2010),
        ])
        #expect(sorted.map(\.title) == ["Ameise", "Zebra"])
    }
}

/// Whether a title from the film database is found again in the own shelf.
///
/// **These tests decide the marker on every row.** If the
/// comparison is too strict, it says "don't have it" everywhere although the film
/// is on the shelf — and nobody notices because nothing fails. If it is too loose, a
/// tap opens the wrong film.
@Suite("Matching against your own library")
struct LibraryIndexTests {

    private func item(_ id: String, _ title: String, year: Int?) -> MediaItem {
        var made = MediaItem(id: id, kind: .movie, title: title)
        made.year = year
        return made
    }

    @Test("The same title in the same year")
    func exactMatch() {
        let index = LibraryIndex([item("j1", "Driftwake", year: 2008)])
        #expect(index.itemID(forTitle: "Driftwake", year: 2008) == "j1")
    }

    @Test("Letter case does not matter")
    func caseDoesNotMatter() {
        let index = LibraryIndex([item("j1", "DRIFTWAKE", year: 2008)])
        #expect(index.itemID(forTitle: "driftwake", year: 2008) == "j1")
    }

    /// Proven on real catalogs: The same film is spelled once with and once
    /// without a hyphen.
    @Test("Punctuation does not matter")
    func punctuationDoesNotMatter() {
        let index = LibraryIndex([item("j1", "Wire-Dancer: Tide Without Shore", year: 2018)])
        #expect(index.itemID(forTitle: "Wire Dancer Tide Without Shore", year: 2018) == "j1")
    }

    /// Libraries like to sort by "title, article" or leave the article out.
    @Test("A leading article does not matter")
    func leadingArticleDoesNotMatter() {
        let index = LibraryIndex([item("j1", "The Lattice", year: 1997)])
        #expect(index.itemID(forTitle: "Lattice", year: 1997) == "j1")
    }

    /// Two databases surprisingly often disagree on the release year —
    /// theatrical release here, festival premiere there.
    @Test("One year of deviation is forgiven")
    func oneYearOffStillMatches() {
        let index = LibraryIndex([item("j1", "Hollowmere", year: 2016)])
        #expect(index.itemID(forTitle: "Hollowmere", year: 2017) == "j1")
    }

    @Test("Two years of deviation are not")
    func twoYearsOffDoesNotMatch() {
        let index = LibraryIndex([item("j1", "Hollowmere", year: 2016)])
        #expect(index.itemID(forTitle: "Hollowmere", year: 2019) == nil)
    }

    /// A remake is a different film. Without this distinction a tap on the
    /// 2013 version would open the 1986 one.
    @Test("Remakes stay apart")
    func remakesStayApart() {
        let index = LibraryIndex([
            item("alt", "Lantern Kid", year: 1986),
            item("neu", "Lantern Kid", year: 2013),
        ])
        #expect(index.itemID(forTitle: "Lantern Kid", year: 1986) == "alt")
        #expect(index.itemID(forTitle: "Lantern Kid", year: 2013) == "neu")
    }

    /// An exact match must never lose against an approximate one, even if
    /// the approximate one comes first on the shelf.
    @Test("The exact match beats the approximate one")
    func exactBeatsNear() {
        let index = LibraryIndex([
            item("nah", "Titel", year: 2009),
            item("genau", "Titel", year: 2010),
        ])
        #expect(index.itemID(forTitle: "Titel", year: 2010) == "genau")
    }

    @Test("What is not on the shelf is not found")
    func missingTitleIsNil() {
        let index = LibraryIndex([item("j1", "Driftwake", year: 2008)])
        #expect(index.itemID(forTitle: "Farlight", year: 2011) == nil)
    }

    /// Without a year only the title remains. That is the weaker statement, but still
    /// better than "don't have it" for something that is on the shelf.
    @Test("Without a year the title alone decides")
    func withoutYearTheTitleDecides() {
        let index = LibraryIndex([item("j1", "Sandmere", year: 2017)])
        #expect(index.itemID(forTitle: "Sandmere", year: nil) == "j1")
    }

    @Test("An empty shelf finds nothing")
    func emptyIndexFindsNothing() {
        let index = LibraryIndex()
        #expect(index.isEmpty)
        #expect(index.itemID(forTitle: "Irgendwas", year: 2010) == nil)
    }
}

/// **Appearances as oneself are not roles** (test report 2026-08-08).
///
/// Many entries say "Self" — talk shows, award ceremonies,
/// interviews. The film database keeps them in the same field as the roles, and
/// for a well-known actor the actual career drowns between
/// appearances with Rory Dalton.
@Suite("Career · appearances as oneself")
struct SelfAppearanceTests {

    private func entry(_ role: String?, id: String = "1", title: String = "T") -> FilmographyEntry {
        FilmographyEntry(id: id, kind: .movie, title: title, year: 2020, role: role)
    }

    @Test("What starts with Self is an appearance, not a role")
    func selfIsNotARole() {
        #expect(entry("Self").isSelfAppearance)
        #expect(entry("Self - Host").isSelfAppearance)
        #expect(entry("Self (archive footage)").isSelfAppearance)
        #expect(entry("Himself").isSelfAppearance)
        #expect(entry("Herself - Guest").isSelfAppearance)
        #expect(entry("Themselves").isSelfAppearance)
    }

    /// **The start is checked, not containment** — otherwise roles that really are roles
    /// get thrown out.
    @Test("A role name that contains self stays a role")
    func rolesSurvive() {
        #expect(!entry("Self-Spun Korvin").isSelfAppearance)
        #expect(!entry("Mr. Selfwick").isSelfAppearance)
        #expect(!entry("Myself and Orlena").isSelfAppearance)
        #expect(!entry(nil).isSelfAppearance)
        #expect(!entry("Stobl Graizaus").isSelfAppearance)
    }

    @Test("Sorting drops them")
    func sortingDropsThem() {
        let list = [
            entry("Self", id: "a", title: "Talkshow"),
            entry("Jonah Vexley", id: "b", title: "Neon Courier"),
        ]
        #expect(Filmography.sorted(list).map(\.title) == ["Neon Courier"])
    }

    /// **Unless nothing would be left.** Whoever mainly sits on talk shows
    /// would otherwise have an empty career — and an empty list is the
    /// worse answer compared with one that contains too much.
    @Test("A career made only of appearances stays")
    func nothingLeftKeepsThem() {
        let list = [
            entry("Self", id: "a", title: "Talkshow"),
            entry("Himself", id: "b", title: "Preisverleihung"),
        ]
        #expect(Filmography.sorted(list).count == 2)
    }
}
