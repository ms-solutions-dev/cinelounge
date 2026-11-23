import Core
import Flows
import Foundation
import Testing

@testable import FeaturesPhone

/// Check agent `start`: Home and "Arrange shelves" on the phone.
@MainActor
struct CheckStartPhoneTests {

    /// A media server with a movie library and a **mixed** (folder) library.
    struct Mixed: ContentSource {
        var displayName: String { "Probe" }
        nonisolated var canStartAtOffset: Bool { true }
        nonisolated var tracksStateItself: Bool { true }
        func libraries() async throws -> [Library] {
            [
                Library(id: "aa01", name: "Filme", kind: .movies),
                Library(id: "bb02", name: "Privat", kind: .mixed),
            ]
        }
        func items(in library: Library.ID, filter: ItemFilter) async throws -> [MediaItem] {
            guard library == "bb02" else { return [] }
            return [
                MediaItem(
                    id: "cc03", kind: .movie, title: "Urlaub 2019",
                    artwork: Artwork(backdropID: "bd"))
            ]
        }
        func item(id: String) async throws -> MediaItem { throw CancellationError() }
        func children(of itemID: String) async throws -> [MediaItem] { [] }
        func resumable(limit: Int) async throws -> [MediaItem] { [] }
        func favorites() async throws -> [MediaItem] { [] }
        func segments(for itemID: String) async throws -> [MediaSegment] { [] }
        func streamURL(for itemID: String, decision: PlaybackDecision) async throws -> URL {
            URL(string: "https://probe.invalid")!
        }
        func report(progress: PlaybackProgress, for itemID: String, isPaused: Bool) async throws {}
        func setPlayed(_ isPlayed: Bool, for itemID: String) async throws {}
        func setFavorite(_ isFavorite: Bool, for itemID: String) async throws {}
        func listChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    }

    /// The TV admits only movie and series libraries at the top (`HomeModel.heroEligible`,
    /// allow list — "a mixed or pure folder library … can contain anything,
    /// including private content").
    @Test("A mixed library does not fill the hero area — same as on the TV")
    func mixedLibraryNotInHeader() async throws {
        let source = JellyfinStartSource(
            source: Mixed(), width: 100, headerWidth: 100, logoWidth: 100)
        let content = try await source.home(perShelf: 20)
        #expect(content.heroes.isEmpty, "in the hero area: \(content.heroes.map(\.tile.title))")
    }

    /// "Arrange shelves" gets the placeholder situation from `SourceAssembly.state()`. With
    /// media server and provider, both placeholders carry the same shelf ID since R6.
    @Test("The shelves in Arrange Shelves carry unique identifiers")
    func shelvesUnique() {
        ProfilePointer.als(nil) {
            let model = HomeViewModel(
                state: .fromAccesses(jellyfin: true, provider: true),
                store: InMemoryStore(), shelfStore: InMemoryStore())
            let identifiers = model.shelves.map(\.id.rawValue)
            #expect(Set(identifiers).count == identifiers.count, "identifiers: \(identifiers)")
        }
    }

    /// The real catalogs of the media server — a movie and a mixed library.
    struct RealCatalog: CatalogSource {
        func state() async throws -> CatalogState {
            CatalogState([
                JellyfinStartSource.catalog(Library(id: "aa01", name: "Filme", kind: .movies)),
                JellyfinStartSource.catalog(Library(id: "bb02", name: "Privat", kind: .mixed)),
            ])
        }
        func title(
            from catalog: Catalog, slice: CatalogSlice?
        ) async throws
            -> [TileContent]
        { [] }
    }

    /// Check finding A-S2 (b): "Arrange shelves" shows the real library shelves, under the
    /// IDs that the Home screen also carries — and the header choice only those that may
    /// fill the header (A-S3).
    @Test("Arrange Shelves offers the real libraries, and the hero area only for movies and series")
    func realLibraries() async {
        await ProfilePointer.als(nil) {
            let model = HomeViewModel(
                state: .fromAccesses(jellyfin: true), catalogSource: RealCatalog(),
                store: InMemoryStore(), shelfStore: InMemoryStore())
            await model.load()
            let identifiers = model.shelves.map(\.id.rawValue)
            #expect(identifiers.contains("aa01"), "identifiers: \(identifiers)")
            #expect(identifiers.contains("bb02"), "identifiers: \(identifiers)")
            #expect(model.heroShelves.map(\.id.rawValue) == ["aa01"])
        }
    }

    /// Check finding A-S2 (a): An order with a duplicate ID does not crash.
    @Test("A duplicate identifier in the order does not crash when arranging")
    func duplicateIdentifierWithoutCrash() {
        let shelf = Shelf(
            id: .fixed(ShelfIdentifier.recent), label: .wording("Z"), sources: [.jellyfin])
        let ordered = StartPreferences(order: [
            .fixed("alle"), .fixed(ShelfIdentifier.recent), .fixed("alle"),
        ])
        .arrange([shelf])
        #expect(ordered.map(\.id) == [shelf.id])
    }
}
