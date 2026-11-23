import Core
import Foundation
import Testing

@testable import Features

/// **All catalogs as one source** — AP29, 2026-09-11.
///
/// Tested are the three rules that ``AggregateSource`` carries: fixed assignment,
/// failure protection, fixed order. Each has a finding behind it, and each is,
/// without a test, exactly the sort of rule that quietly falls at the next refactor.
struct AggregateSourceTests {

    /// A source that keeps a fixed list — or throws.
    ///
    /// **It counts who asked it.** The most expensive of the three rules is "the
    /// assignment is fixed before anyone asks", and it can only be tested like this: not
    /// by the result, but by **who was not asked**.
    actor TestDouble: ContentSource {
        let name: String
        let libraryList: [Core.Library]
        let title: [String: MediaItem]
        let fails: Bool

        private(set) var asked: [String] = []

        init(
            _ name: String, libraryList: [Core.Library] = [], title: [MediaItem] = [],
            fails: Bool = false
        ) {
            self.name = name
            self.libraryList = libraryList
            self.title = Dictionary(title.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            self.fails = fails
        }

        enum OutageError: Error { case noResponse }

        nonisolated var displayName: String { name }
        nonisolated var canStartAtOffset: Bool { false }
        /// **A test double keeps its own state** — nobody should wrap it.
        nonisolated var tracksStateItself: Bool { true }

        func libraries() async throws -> [Core.Library] {
            asked.append("libraries")
            if fails { throw OutageError.noResponse }
            return libraryList
        }

        func items(in library: Core.Library.ID, filter: ItemFilter) async throws -> [MediaItem] {
            asked.append("items(\(library))")
            if fails { throw OutageError.noResponse }
            return Array(title.values)
        }

        func item(id: String) async throws -> MediaItem {
            asked.append("item(\(id))")
            if fails { throw OutageError.noResponse }
            guard let found = title[id] else { throw OutageError.noResponse }
            return found
        }

        func children(of itemID: String) async throws -> [MediaItem] { [] }
        func resumable(limit: Int) async throws -> [MediaItem] {
            asked.append("resumable")
            if fails { throw OutageError.noResponse }
            return Array(title.values)
        }
        func segments(for itemID: String) async throws -> [MediaSegment] { [] }
        func streamURL(for itemID: String, decision: PlaybackDecision) async throws -> URL {
            throw OutageError.noResponse
        }
        func report(progress: PlaybackProgress, for itemID: String, isPaused: Bool) async throws {}
        func setPlayed(_ isPlayed: Bool, for itemID: String) async throws {}
        func setFavorite(_ isFavorite: Bool, for itemID: String) async throws {}
        func favorites() async throws -> [MediaItem] { [] }
        func listChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    }

    static func title(_ id: String, _ name: String) -> MediaItem {
        MediaItem(id: id, kind: .movie, title: name)
    }

    /// Identifiers whose **shape** reveals the origin — real examples.
    static let jellyfinIdentifier = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4"
    static let providerIdentifier = "liste-1|vod|4711"
    static let portalIdentifier = "serieshub||serie/die-pettigrews"

    /// **The assignment is fixed before anyone asks.**
    ///
    /// The finding of 2026-09-05 on the phone: the first version looked for the responsible
    /// source on every title fetch by asking **all** of them about their situation. For the
    /// media server that was six libraries including counts, and the screen
    /// said "takes longer than usual".
    ///
    /// What is tested is therefore not that the right title comes out — a round of
    /// asking would do that too —, but that the **other two sources are not asked
    /// at all.**
    @Test("Who is responsible is in the identifier — the others are not asked")
    func assignmentWithoutPolling() async throws {
        let media = TestDouble("medien", title: [Self.title(Self.jellyfinIdentifier, "Stille")])
        let provider = TestDouble("anbieter", title: [Self.title(Self.providerIdentifier, "Fremd")])
        let portals = TestDouble("portale", title: [Self.title(Self.portalIdentifier, "Pettigrews")])

        let aggregate = AggregateSource([
            .jellyfin: media, .provider: provider, .portals: portals,
        ])

        let found = try await aggregate.item(id: Self.portalIdentifier)
        #expect(found.title == "Pettigrews")

        #expect(await portals.asked == ["item(\(Self.portalIdentifier))"])
        #expect(await media.asked.isEmpty)
        #expect(await provider.asked.isEmpty)
    }

    /// **A source that does not answer does not take the others along.**
    ///
    /// An expired provider access must not make the media server disappear —
    /// that would look like data loss.
    @Test("A failed origin costs only its own entries")
    func failedOrigin() async throws {
        let media = TestDouble("medien", libraryList: [Core.Library(id: "m1", name: "Filme", kind: .movies)])
        let provider = TestDouble("anbieter", fails: true)

        let aggregate = AggregateSource([.jellyfin: media, .provider: provider])
        let found = try await aggregate.libraries()

        #expect(found.map(\.id) == ["m1"])
        // It was asked anyway — otherwise it would not be failure protection but a
        // source that is never used.
        #expect(await provider.asked == ["libraries"])
    }

    /// **The media server reports its failure when nothing else comes.**
    ///
    /// Its failure is not an empty list but a fault — and a fault that passes as an
    /// empty list looks like "Your library is empty". **Since the
    /// check finding A-S9 (2026-09-27) it no longer takes the others along, though:** the phone
    /// kept showing providers and portals, the TV only the fault. Now both
    /// the same — the remaining catalogs are shown, and only without them does the fault throw through.
    @Test("The Jellyfin server only passes errors through if nothing else comes")
    func mediaServerThrowsThrough() async throws {
        let withPortal = AggregateSource([
            .jellyfin: TestDouble("medien", fails: true),
            .portals: TestDouble(
                "portale", libraryList: [Core.Library(id: "p1", name: "Neu", kind: .portalLevel)]),
        ])
        #expect(try await withPortal.libraries().map(\.id) == ["p1"])
        #expect(try await withPortal.resumable(limit: 5).isEmpty)

        let withoutOthers = AggregateSource([
            .jellyfin: TestDouble("medien", fails: true),
            .portals: TestDouble("portale"),
        ])
        await #expect(throws: TestDouble.OutageError.self) { try await withoutOthers.libraries() }

        let alone = AggregateSource([.jellyfin: TestDouble("medien", fails: true)])
        await #expect(throws: TestDouble.OutageError.self) { try await alone.libraries() }
        await #expect(throws: TestDouble.OutageError.self) { try await alone.resumable(limit: 5) }
    }

    /// **The order is that of the origins, not that of the response times.**
    ///
    /// Whoever answers first would otherwise decide anew on every opening what stands at the top.
    @Test("The order is that of the origins")
    func orderOfOrigins() async throws {
        let aggregate = AggregateSource([
            .portals: TestDouble(
                "portale", libraryList: [Core.Library(id: "p1", name: "Portal", kind: .portalLevel)]),
            .provider: TestDouble(
                "anbieter", libraryList: [Core.Library(id: "a1", name: "Anbieter", kind: .movies)]),
            .jellyfin: TestDouble(
                "medien", libraryList: [Core.Library(id: "m1", name: "Medien", kind: .movies)]),
        ])
        #expect(try await aggregate.libraries().map(\.id) == ["m1", "a1", "p1"])
    }

    /// **Two origins with same-named titles stay two titles.**
    ///
    /// The same movie is at the provider and on the media server — that is the
    /// normal case and not a bug. Merged, it would appear only once, and
    /// which of the two then opened would be decided by response time. **The identifier is
    /// the identity, not the name.**
    @Test("Titles with the same name from two origins stay two")
    func sameNamedTitles() async throws {
        let aggregate = AggregateSource([
            .jellyfin: TestDouble("medien", title: [Self.title(Self.jellyfinIdentifier, "Stille")]),
            .provider: TestDouble("anbieter", title: [Self.title(Self.providerIdentifier, "Stille")]),
        ])
        let found = try await aggregate.resumable(limit: 12)
        #expect(found.count == 2)
        #expect(Set(found.map(\.id)) == [Self.jellyfinIdentifier, Self.providerIdentifier])
    }

    /// **An empty origin is not an error.**
    ///
    /// Whoever has set up no portal gets no portal row — and no message
    /// about it. That the bridge is not running is not news.
    @Test("An origin without a source is skipped")
    func emptyOrigin() async throws {
        let aggregate = AggregateSource([.jellyfin: TestDouble("medien")])
        #expect(try await aggregate.libraries().isEmpty)
        #expect(try await aggregate.children(of: Self.portalIdentifier).isEmpty)
    }

    /// **What points to a missing source gets an answer and not nothing.**
    ///
    /// A portal title in the history after the bridge was removed: there the
    /// answer is "this source does not exist here" and not "the title does not exist".
    @Test("A title without a source reports that the source is missing")
    func missingSource() async {
        let aggregate = AggregateSource([.jellyfin: TestDouble("medien")])
        await #expect(throws: AggregateSource.Missing.self) {
            try await aggregate.item(id: Self.portalIdentifier)
        }
    }
}
