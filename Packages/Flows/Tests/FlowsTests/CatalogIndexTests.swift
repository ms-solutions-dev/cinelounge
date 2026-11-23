import Core
import Flows
import Foundation
import ParentalControls
import Testing

/// **The one catalog index** (AP58 R6, St6) — filtered on asking, full in the count.
struct CatalogIndexTests {

    static func title(approval: String) -> MediaItem {
        MediaItem(id: "t1", kind: .movie, title: "Der Pakuro", year: 1974, ageRating: approval)
    }

    @Test("A blocked title is not in the index, but counts in the approvals")
    func filtered() async {
        let source = ChildProtectionBoard.Source(Self.title(approval: "FSK-18"))
        let index = CatalogIndex()
        let strict = ProtectionRule(deviceLocked: true, isPinSet: true, limit: .from12)

        #expect(await index.index(from: source, rule: strict).isEmpty)
        #expect(
            await index.index(from: source, rule: .pending).itemID(forTitle: "Der Pakuro", year: 1974) == "t1"
        )
        #expect(await index.countedRatings()?.values.reduce(0, +) == 1)
    }

    @Test("Marking records the identifier, an empty index leaves everything in place")
    func mark() {
        let entry = FilmographyEntry(id: "1", kind: .movie, title: "Der Pakuro", year: 1974)
        let index = LibraryIndex([Self.title(approval: "FSK-16")])
        #expect(CatalogIndex.mark([entry], against: index).first?.libraryItemID == "t1")
        #expect(CatalogIndex.mark([entry], against: LibraryIndex()) == [entry])
    }

    // MARK: - Check 27.09.2026, D4: the catalog belongs to source and profile

    @Test("The index belongs to the requested source, not to the first one")
    func indexFollowsSource() async {
        let parents = CountingSource(
            MediaItem(id: "e1", kind: .movie, title: "Elternfilm", year: 2000, ageRating: "FSK-0"))
        let kind = CountingSource(
            MediaItem(id: "k1", kind: .movie, title: "Kinderfilm", year: 2001, ageRating: "FSK-0"))
        let index = CatalogIndex()
        _ = await index.index(from: parents, rule: .pending)
        let following = await index.index(from: kind, rule: .pending)
        #expect(following.itemID(forTitle: "Elternfilm", year: 2000) == nil)
        #expect(following.itemID(forTitle: "Kinderfilm", year: 2001) == "k1")
    }

    @Test("Same source, same profile: collected once")
    func collectedOnce() async {
        let source = CountingSource(Self.title(approval: "FSK-0"))
        let index = CatalogIndex()
        _ = await index.survey(from: source)
        _ = await index.survey(from: source)
        #expect(source.fetches.value == 1)
    }

    @Test("A profile switch collects anew, and the count belongs to the profile")
    func profileSwitch() async {
        let source = CountingSource(Self.title(approval: "FSK-0"))
        let index = CatalogIndex()
        await ProfilePointer.als("parents") { _ = await index.survey(from: source) }
        let foreign = await ProfilePointer.als("kind") { await index.countedRatings() }
        await ProfilePointer.als("kind") { _ = await index.survey(from: source) }
        #expect(foreign == nil)
        #expect(source.fetches.value == 2)
    }

    @Test("After the lifetime it is collected anew — new titles appear")
    func lifetime() async {
        let source = CountingSource(Self.title(approval: "FSK-0"))
        let clock = PositionClock()
        let index = CatalogIndex(lifetime: 60, clock: { clock.now })
        _ = await index.survey(from: source)
        clock.now = clock.now.addingTimeInterval(59)
        _ = await index.survey(from: source)
        #expect(source.fetches.value == 1)
        clock.now = clock.now.addingTimeInterval(2)
        _ = await index.survey(from: source)
        #expect(source.fetches.value == 2)
    }
}

/// A counter shared by a source and a test.
final class TallyCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var state = 0
    var value: Int { lock.withLock { state } }
    func increment() { lock.withLock { state += 1 } }
}

/// An adjustable clock for the lifetime.
final class PositionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var state = Date(timeIntervalSince1970: 1_000_000)
    var now: Date {
        get { lock.withLock { state } }
        set { lock.withLock { state = newValue } }
    }
}

/// A source **as a reference type** that counts how often the catalog was collected.
final class CountingSource: ContentSource {
    let board: ChildProtectionBoard.Source
    let fetches = TallyCounter()

    init(_ title: MediaItem) { board = ChildProtectionBoard.Source(title) }

    var displayName: String { "Counter" }
    nonisolated var canStartAtOffset: Bool { true }
    nonisolated var tracksStateItself: Bool { true }
    func libraries() async throws -> [Library] {
        fetches.increment()
        return try await board.libraries()
    }
    func items(in library: Library.ID, filter: ItemFilter) async throws -> [MediaItem] {
        try await board.items(in: library, filter: filter)
    }
    func item(id: String) async throws -> MediaItem { try await board.item(id: id) }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func resumable(limit: Int) async throws -> [MediaItem] { [] }
    func segments(for itemID: String) async throws -> [MediaSegment] { [] }
    func streamURL(for itemID: String, decision: PlaybackDecision) async throws -> URL {
        URL(string: "https://zaehler.invalid/\(itemID)")!
    }
    func report(progress: PlaybackProgress, for itemID: String, isPaused: Bool) async throws {}
    func setPlayed(_ isPlayed: Bool, for itemID: String) async throws {}
    func setFavorite(_ isFavorite: Bool, for itemID: String) async throws {}
    func favorites() async throws -> [MediaItem] { [] }
    func listChanges() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}
