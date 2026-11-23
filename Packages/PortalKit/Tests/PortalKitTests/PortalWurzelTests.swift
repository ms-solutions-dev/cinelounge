import Core
import Foundation
import Testing

@testable import PortalKit

/// The root level of a portal and the order in which a level arrives.
///
/// **Two findings of 2026-08-27 in one check.** "Most watched right now" arrived on the TV
/// in alphabetical order, although the bridge delivers Ironbell, Hollins, Geissabrel
/// Zari — and every level made of episodes or films was empty, because the kind filter
/// `[.series]` sat over everything. Both are fixed here as statements about values, so the
/// next change does not undo them.
@Suite("Portals: root and order")
struct PortalRootTests {

    private func entry(_ id: String, _ name: String) -> BridgeReply.EntryPoint {
        BridgeReply.EntryPoint(id: id, name: name, character: nil, count: nil, group: "")
    }

    // MARK: - The root is a level like any other

    /// An empty entry point means "the portal itself" — the same identifier form as every
    /// level below it, so that the navigation path needs no special case.
    @Test("The root identifier carries the portal and no entry point")
    func rootIdentifier() throws {
        let identifier = PortalSource.rootID(portal: "serieshub")
        let decomposed = try #require(PortalLibraryID(identifier))

        #expect(decomposed.portal == "serieshub")
        #expect(decomposed.entry.isEmpty)
    }

    /// **The way back depends on it.** An entry point must be a folder, otherwise
    /// ``PortalSource/levelID(forItem:)`` finds no level below it — and a `NavigationLink` to a
    /// value the path does not know simply does nothing, with no error and no hint.
    @Test("An entry point is a folder that leads to its own level")
    func entryLeadsDeeper() throws {
        let folder = PortalSource.entriesAsFolders(
            portal: "serieshub",
            [entry("beliebte", "Meistgesehen gerade"), entry("alle", "Alle Serien")]
        )

        #expect(folder.map(\.title) == ["Meistgesehen gerade", "Alle Serien"])
        #expect(folder.allSatisfy { $0.kind == .folder })

        let level = try #require(PortalSource.levelID(forItem: folder[0]))
        #expect(level == PortalLibraryID(portal: "serieshub", entry: "beliebte").identifier)
    }

    /// The bridge's order stays the list's order — here too.
    @Test("The entry points are in the order of the bridge")
    func orderOfEntries() {
        let folder = PortalSource.entriesAsFolders(
            portal: "animehub",
            [entry("c", "Kalender"), entry("a", "Neue Folgen"), entry("b", "Alle Animes")]
        )
        #expect(folder.map(\.title) == ["Kalender", "Neue Folgen", "Alle Animes"])
    }

    // MARK: - Recently used

    /// **The long press applies only under "Recently used"** (2026-10-12). The app reads which
    /// rows are there from the separators — in the server's order, which sends the newest
    /// first.
    @Test("Recently used: the rows between their separator and \"Alle\", in server order")
    func recentlyUsed() {
        func e(_ id: String, _ group: String) -> BridgeReply.EntryPoint {
            BridgeReply.EntryPoint(id: id, name: id, character: nil, count: nil, group: group)
        }
        let folder = PortalSource.entriesAsFolders(
            portal: "flatone",
            [e("b", "recent"), e("a", "recent"), e("x", "curated"), e("v", "mine"), e("t", "tools")]
        )
        let recent = PortalSource.recentlyUsed(in: folder.map(\.id))
        let title = folder.filter { recent.contains($0.id) }.map(\.title)
        #expect(title == ["b", "a"])

        let without = PortalSource.entriesAsFolders(
            portal: "ahorn", [e("x", "curated"), e("v", "mine")])
        #expect(PortalSource.recentlyUsed(in: without.map(\.id)).isEmpty)
    }

    // MARK: - The order of the source

    /// **The finding in its wording** (2026-08-27): The bridge delivers Lantervo, Ravelin Row,
    /// Prefect Oduya; the app showed Sturmopfer, Club der stillen Fenster, Lantervo. A list
    /// called "most watched" loses its meaning when sorted alphabetically.
    @Test("Most watched right now arrives as the bridge delivers it")
    func naturalOrder() {
        let delivered = [
            MediaItem(id: "p|a|1", kind: .series, title: "Lantervo"),
            MediaItem(id: "p|b|2", kind: .series, title: "Ravelin Row"),
            MediaItem(id: "p|c|3", kind: .series, title: "Prefect Oduya"),
        ]

        let result = PortalSource.filtered(delivered, after: ItemFilter(sortBy: .natural))

        #expect(result.map(\.title) == ["Lantervo", "Ravelin Row", "Prefect Oduya"])
    }

    /// And the explicit choice stays possible — otherwise the default would not be a default
    /// but a rule.
    @Test("An explicit tap on title still sorts")
    func titleStillSorts() {
        let delivered = [
            MediaItem(id: "p|a|1", kind: .series, title: "Lantervo"),
            MediaItem(id: "p|b|2", kind: .series, title: "Ravelin Row"),
            MediaItem(id: "p|c|3", kind: .series, title: "Prefect Oduya"),
        ]

        let result = PortalSource.filtered(delivered, after: ItemFilter(sortBy: .title))

        #expect(result.map(\.title) == ["Lantervo", "Prefect Oduya", "Ravelin Row"])
    }

    // MARK: - The kind filter

    /// **The most expensive of the two findings:** As long as every level was `.series`, the
    /// kind filter threw away episodes, films and seasons — and the view reported "Library is
    /// empty" for a list that contained everything.
    @Test("Without a kind specification every level stays complete")
    func emptyKindFilterDiscardsNothing() {
        let mixed = [
            MediaItem(id: "p|a|1", kind: .episode, title: "Folge 1"),
            MediaItem(id: "p|b|2", kind: .movie, title: "Ein Film"),
            MediaItem(id: "p|c|3", kind: .season, title: "Staffel 2"),
            MediaItem(id: "p|d|4", kind: .series, title: "Eine Serie"),
        ]

        let result = PortalSource.filtered(mixed, after: ItemFilter(sortBy: .natural))

        #expect(result.count == 4)
    }

    /// And the counter-proof, so that the check above says something: with `[.series]` exactly
    /// what was seen on the TV remains — one of four.
    @Test("With the old kind filter almost nothing is left")
    func oldKindFilterEmptiesList() {
        let mixed = [
            MediaItem(id: "p|a|1", kind: .episode, title: "Folge 1"),
            MediaItem(id: "p|b|2", kind: .movie, title: "Ein Film"),
            MediaItem(id: "p|c|3", kind: .season, title: "Staffel 2"),
            MediaItem(id: "p|d|4", kind: .series, title: "Eine Serie"),
        ]

        let result = PortalSource.filtered(
            mixed, after: ItemFilter(kinds: [.series], sortBy: .natural))

        #expect(result.map(\.title) == ["Eine Serie"])
    }
}
