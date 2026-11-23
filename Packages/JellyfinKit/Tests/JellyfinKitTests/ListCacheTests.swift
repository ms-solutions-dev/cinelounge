import Core
import Foundation
import Testing

@testable import JellyfinKit

/// The list cache: keys, order, deduplication, snapshots.
///
/// The network stays outside — what is checked is the mechanics on which the cache-first
/// idea hangs. Each of these checks stands for an error that would be silent: a key that
/// misses loads twice without anything failing; a deviating sort shows a different order
/// than the server did before; a broken snapshot makes the cold start slow again — all
/// without a single error message.
@Suite("List cache")
struct ListCacheTests {

    static func makeSource(lifetime: Duration = .seconds(3600)) -> JellyfinSource {
        JellyfinSource(
            credentials: ServerCredentials(
                serverURL: URL(string: "https://example.invalid")!,
                userID: "pruefnutzer",
                username: "pruefnutzer",
                accessToken: "not-a-real-key"
            ),
            deviceID: "check-device",
            cacheLifetime: lifetime
        )
    }

    static func item(
        _ id: String,
        title: String? = nil,
        sortTitle: String? = nil,
        addedAt: Date? = nil,
        recordedAt: Date? = nil,
        rating: Double? = nil
    ) -> MediaItem {
        MediaItem(
            id: id,
            kind: .movie,
            title: title ?? id,
            sortTitle: sortTitle,
            recordedAt: recordedAt,
            addedAt: addedAt,
            ratings: Ratings(community: rating)
        )
    }

    /// Counts calls across threads — the load function runs on the actor, the check does not.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    // MARK: - Keys

    @Test("Sort order, direction and upper limit do not change the key")
    func keyIgnoresSorting() {
        // That is exactly what the first download ledger failed on: the home video view asked
        // descending by recording date, the ledger ascending by title — a different key, and the
        // ledger was never read.
        let base = JellyfinSource.listCacheKey(
            library: "lib1",
            filter: Core.ItemFilter(kinds: [.homeVideo], sortBy: .title, ascending: true)
        )
        let byDate = JellyfinSource.listCacheKey(
            library: "lib1",
            filter: Core.ItemFilter(kinds: [.homeVideo], sortBy: .dateCreated, ascending: false)
        )
        let shelf = JellyfinSource.listCacheKey(
            library: "lib1",
            filter: Core.ItemFilter(
                kinds: [.homeVideo], sortBy: .dateAdded, ascending: false, limit: 20
            )
        )
        #expect(base == byDate)
        #expect(base == shelf)
    }

    @Test("Library, kinds and search term separate the keys")
    func keySeparatesWhatMustBeSeparate() {
        let movies = JellyfinSource.listCacheKey(
            library: "lib1", filter: Core.ItemFilter(kinds: [.movie])
        )
        let series = JellyfinSource.listCacheKey(
            library: "lib1", filter: Core.ItemFilter(kinds: [.series])
        )
        let otherLibrary = JellyfinSource.listCacheKey(
            library: "lib2", filter: Core.ItemFilter(kinds: [.movie])
        )
        let search = JellyfinSource.listCacheKey(
            library: "lib1", filter: Core.ItemFilter(searchTerm: "hollowmark", kinds: [.movie])
        )
        #expect(movies != series)
        #expect(movies != otherLibrary)
        #expect(movies != search, "a result list is not a library")
    }

    @Test("The order of the kinds does not matter")
    func keyNormalizesKindOrder() {
        // `mixed` names series and films — in which sequence, the caller decides. Two keys for
        // the same set would be a double fetch.
        let one = JellyfinSource.listCacheKey(
            library: "lib1", filter: Core.ItemFilter(kinds: [.series, .movie])
        )
        let other = JellyfinSource.listCacheKey(
            library: "lib1", filter: Core.ItemFilter(kinds: [.movie, .series])
        )
        #expect(one == other)
    }

    // MARK: - Client-side ordering

    @Test("Titles sort by the server's sort title")
    func titleSortUsesServerSortName() {
        let items = [
            Self.item("m", title: "The Mornfield", sortTitle: "Mornfield"),
            Self.item("a", title: "Aveluna"),
            Self.item("w", title: "The Wandle"),  // without a sort title: strip the articles yourself
            Self.item("b", title: "Brindo"),
        ]
        let sorted = JellyfinSource.arrange(
            items, by: Core.ItemFilter(sortBy: .title, ascending: true)
        )
        #expect(sorted.map(\.id) == ["a", "b", "m", "w"])

        let reversed = JellyfinSource.arrange(
            items, by: Core.ItemFilter(sortBy: .title, ascending: false)
        )
        #expect(reversed.map(\.id) == ["w", "m", "b", "a"])
    }

    @Test("Recently added orders descending by creation date, unknown at the end")
    func dateAddedSort() {
        let items = [
            Self.item("old", addedAt: Date(timeIntervalSince1970: 1000)),
            Self.item("none"),
            Self.item("new", addedAt: Date(timeIntervalSince1970: 9000)),
        ]
        let sorted = JellyfinSource.arrange(
            items, by: Core.ItemFilter(sortBy: .dateAdded, ascending: false)
        )
        #expect(sorted.map(\.id) == ["new", "old", "none"])
    }

    @Test("Recording date and rating are ordered by the server as before")
    func recordedAndRatingSort() {
        let byRecorded = JellyfinSource.arrange(
            [
                Self.item("old", recordedAt: Date(timeIntervalSince1970: 1000)),
                Self.item("new", recordedAt: Date(timeIntervalSince1970: 9000)),
            ],
            by: Core.ItemFilter(sortBy: .dateCreated, ascending: false)
        )
        #expect(byRecorded.map(\.id) == ["new", "old"])

        let byRating = JellyfinSource.arrange(
            [
                Self.item("medium", rating: 6.4),
                Self.item("unrated"),
                Self.item("good", rating: 8.9),
            ],
            by: Core.ItemFilter(sortBy: .rating, ascending: false)
        )
        // Unrated to the end — not to the front, as a naive optional sort would do.
        #expect(byRating.map(\.id) == ["good", "medium", "unrated"])
    }

    @Test("The upper limit truncates after ordering, not before")
    func limitAppliesAfterSorting() {
        let items = [
            Self.item("c", addedAt: Date(timeIntervalSince1970: 1)),
            Self.item("a", addedAt: Date(timeIntervalSince1970: 3)),
            Self.item("b", addedAt: Date(timeIntervalSince1970: 2)),
        ]
        let top = JellyfinSource.arrange(
            items, by: Core.ItemFilter(sortBy: .dateAdded, ascending: false, limit: 2)
        )
        // The newest first — if it were truncated before ordering, what happened to lie at the
        // front of the catalog would stand here.
        #expect(top.map(\.id) == ["a", "b"])
    }

    // MARK: - Deduplication and expiry

    @Test("Concurrent requests for the same key load only once")
    func simultaneousRequestsShareOneLoad() async throws {
        let source = Self.makeSource()
        let counter = Counter()
        let load: @Sendable () async throws -> [MediaItem] = {
            counter.increment()
            // Long enough that the second request surely comes during the first.
            try await Task.sleep(for: .milliseconds(100))
            return [Self.item("a")]
        }

        async let first = source.cachedItems(key: "k", persisted: false, load: load)
        async let second = source.cachedItems(key: "k", persisted: false, load: load)
        let (one, two) = try await (first, second)

        #expect(one == two)
        #expect(counter.value == 1, "the second request must attach instead of loading itself")
    }

    @Test("Expired data is served immediately and replaced in the background")
    func staleEntriesServeOldAndRefreshBehind() async throws {
        // Lifetime zero: everything is expired at once — the hard case.
        let source = Self.makeSource(lifetime: .zero)
        let old = [Self.item("old")]
        let fresh = [Self.item("new")]

        _ = try await source.cachedItems(key: "k", persisted: false) { old }

        let changes = await source.listChanges()

        // The second access gets the old one without waiting …
        let served = try await source.cachedItems(key: "k", persisted: false) { fresh }
        #expect(served == old, "expired does not mean worthless — show first, then swap")

        // … and the background fetch reports the swap.
        //
        // The `#expect` belongs here and is no decoration: without it this check ran **empty**
        // for months. A stream that ends immediately returns `nil` here — and that was exactly
        // the state the finding of 2026-08-13 uncovered (see "The stream comes from the source").
        var iterator = changes.makeAsyncIterator()
        #expect(await iterator.next() != nil, "the swap must be reported")

        let after = try await source.cachedItems(key: "k", persisted: false) { fresh }
        #expect(after == fresh)
    }

    // MARK: - Snapshots

    @Test("A title survives the trip to disk completely")
    func snapshotRoundtripKeepsEverything() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "cinelounge-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ListSnapshotStore(directory: directory)

        // Deliberately loaded with everything a list ever carries — a field that is lost when
        // encoding would only be noticed on the device when exactly this value is missing after
        // a cold start.
        let items = [
            MediaItem(
                id: "voll",
                kind: .episode,
                title: "Die Nacht der Laternenwache",
                sortTitle: "Nacht der Laternenwache",
                parentTitle: "Hiske bl Tedren",
                seriesID: "serie1",
                seasonNumber: 1,
                episodeNumber: 4,
                overview: "A retrospective.",
                year: 2013,
                genres: ["Anime", "Action"],
                studio: "Kestrel Studio",
                ageRating: "16",
                runtime: 1452,
                recordedAt: Date(timeIntervalSince1970: 1_360_000_000),
                addedAt: Date(timeIntervalSince1970: 1_700_000_000),
                seasonCount: 4,
                episodeCount: 87,
                unplayedCount: 3,
                ratings: Ratings(community: 7.9, critic: 87, imdbID: "tt9074896"),
                artwork: Artwork(
                    posterID: "p1", backdropID: "b1", posterTag: "tagP", backdropTag: "tagB",
                    palette: AccentPalette(hue: 28, saturation: 0.7)
                ),
                progress: PlaybackProgress(position: 300, duration: 1452, isWatched: false),
                isFavorite: true,
                source: MediaSource(
                    container: .mkv,
                    videoCodec: "hevc",
                    videoRange: .hdr10,
                    audioTracks: [
                        MediaTrack(id: "1", kind: .audio, title: "Deutsch", language: "deu")
                    ],
                    subtitleTracks: [
                        MediaTrack(
                            id: "5", kind: .subtitle, title: "Forced",
                            subtitleFormat: .pgs
                        )
                    ],
                    supportsDirectPlay: true,
                    bitrate: 40_000_000
                ),
                cast: [Person(id: "p", name: "Kenta Morishiba", role: .actor, character: "Halvo")]
            )
        ]

        store.write(items, key: "items:lib1:episode")
        let loaded = store.load([MediaItem].self, key: "items:lib1:episode")
        #expect(loaded == items)

        // Bibliotheken gehen denselben Weg.
        let libraries = [Core.Library(id: "lib1", name: "Serien", kind: .series)]
        store.write(libraries, key: "libraries")
        #expect(store.load([Core.Library].self, key: "libraries") == libraries)

        // Removing works — otherwise old progress would survive the invalidation.
        store.remove(key: "items:lib1:episode")
        #expect(store.load([MediaItem].self, key: "items:lib1:episode") == nil)
    }

    @Test("Signing out clears the account's snapshots")
    func signOutWipesAccountSnapshots() throws {
        // Exactly the path the app takes when signing out: the holder is REBUILT from the
        // account data — so it must end up in the same folder as the one the source wrote with.
        // If this assertion breaks (say because someone changes the hash ingredients), the files
        // would stay behind, and nobody would see it: deleting what is not there reports no
        // error.
        let serverURL = URL(string: "https://example.invalid:8096")!
        let userID = "wipe-pruefnutzer-\(UUID().uuidString)"
        let store = ListSnapshotStore(serverURL: serverURL, userID: userID)
        defer { store.removeAll() }

        store.write(["an entry"], key: "list")
        #expect(store.load([String].self, key: "list") == ["an entry"])

        ListSnapshotStore(serverURL: serverURL, userID: userID).removeAll()

        #expect(store.load([String].self, key: "list") == nil)
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
    }

    @Test("An unreadable snapshot is none — no error, just nothing")
    func unreadableSnapshotIsSilentlyIgnored() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "cinelounge-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ListSnapshotStore(directory: directory)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("no json".utf8).write(to: store.fileURL(for: "broken"))

        #expect(store.load([MediaItem].self, key: "broken") == nil)
    }
}

/// The catalog count — **the fetch that until 2026-09-13 was the only one without
/// memory.** The phone's Home screen waits for it before it shows anything; in a bad cell
/// that was the entire wait.
@Suite("Count cache")
struct CountCacheTests {

    @Test("Sort order and upper limit do not change the count's key")
    func keyIgnoresSorting() {
        let base = JellyfinSource.countCacheKey(
            library: "lib1",
            filter: Core.ItemFilter(kinds: [.movie], sortBy: .title, ascending: true))
        let limited = JellyfinSource.countCacheKey(
            library: "lib1",
            filter: Core.ItemFilter(kinds: [.movie], sortBy: .dateAdded, ascending: false, limit: 12))
        #expect(base == limited)
        #expect(
            base
                != JellyfinSource.countCacheKey(
                    library: "lib1", filter: Core.ItemFilter(kinds: [.series])))
    }

    @Test("Concurrent counts of the same catalog load only once")
    func simultaneousCountsShareOneLoad() async throws {
        let source = ListCacheTests.makeSource()
        let counter = ListCacheTests.Counter()
        let load: @Sendable () async throws -> Int? = {
            counter.increment()
            try await Task.sleep(for: .milliseconds(100))
            return 102
        }
        async let first = source.cachedCount(key: "count:k", persisted: false, load: load)
        async let second = source.cachedCount(key: "count:k", persisted: false, load: load)
        let (one, two) = try await (first, second)
        #expect(one == 102 && two == 102)
        #expect(counter.value == 1)
    }

    @Test("An expired count is served immediately and replaced in the background")
    func staleCountServesOldAndRefreshesBehind() async throws {
        let source = ListCacheTests.makeSource(lifetime: .zero)
        _ = try await source.cachedCount(key: "count:k", persisted: false) { 100 }
        let changes = await source.listChanges()

        let served = try await source.cachedCount(key: "count:k", persisted: false) { 101 }
        #expect(served == 100, "expired does not mean worthless — show first, then swap")

        var iterator = changes.makeAsyncIterator()
        #expect(await iterator.next() != nil, "the swap must be reported")
        #expect(try await source.cachedCount(key: "count:k", persisted: false) { 101 } == 101)
    }

    @Test("“No number” is an answer and is kept")
    func nilIsAnAnswer() async throws {
        let source = ListCacheTests.makeSource()
        let counter = ListCacheTests.Counter()
        let load: @Sendable () async throws -> Int? = {
            counter.increment()
            return nil
        }
        #expect(try await source.cachedCount(key: "count:k", persisted: false, load: load) == nil)
        #expect(try await source.cachedCount(key: "count:k", persisted: false, load: load) == nil)
        #expect(counter.value == 1, "nil must not look like a miss")
    }

    @Test("A number survives the trip to disk")
    func countSnapshotRoundtrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "cinelounge-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ListSnapshotStore(directory: directory)
        store.write(3497, key: "count:k")
        #expect(store.load(Int.self, key: "count:k") == 3497)
    }
}
