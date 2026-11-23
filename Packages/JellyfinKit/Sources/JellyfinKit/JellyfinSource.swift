import Core
import Foundation
import JellyfinAPI

// Note: the server package ships its own types named `ItemFilter` and
// `Library`. Wherever these names appear, `Core.` is therefore prefixed —
// without it there is no telling which one is meant.

/// Jellyfin as a content source — the first implementation of ``ContentSource``.
///
/// Everything server-specific ends here. What sits above knows only the models
/// from ``Core`` and does not know where they come from. That is why another
/// source later costs a new implementation of this contract instead of a rebuild.
public actor JellyfinSource: ContentSource {

    public let displayName: String

    /// Jellyfin can do this: it repackages the stream and starts wherever you want.
    ///
    /// The implementation is `startTimeTicks` in ``streamQuery(for:accessToken:)``.
    /// Verified against the running server — the request with a start point answers
    /// with 200 and delivers from the given position.
    public nonisolated let canStartAtOffset = true

    /// **The media server owns it**, and that has to stay that way: Jellyfin knows what
    /// has been watched and where someone stopped. If the app kept its own copy on the
    /// side, two truths would drift apart as soon as someone watches something on a
    /// phone or in the web interface — see ``Core/ContentSource/setPlayed(_:for:)``.
    /// ``PlaylistKit/StateSource`` therefore passes this source through unchanged.
    public nonisolated let tracksStateItself = true

    private let credentials: ServerCredentials
    private let deviceID: String
    private let session: URLSession

    /// Whether ``close()`` has already been called.
    ///
    /// A finished `URLSession` accepts no more requests — and it does not say so with
    /// an error but with an Objective-C exception that terminates the app. That is
    /// exactly what happened on a profile switch: the old source was finished while
    /// the startup check of the main view still held it in its hands.
    private var closed = false
    private let decoder = JellyfinDecoder.make()

    /// Cache for lists.
    ///
    /// The most common complaint about comparable apps is that the library is reloaded
    /// in full on every launch. With a few thousand titles that takes noticeable time.
    /// That is why responses are kept — and since the snapshots (``ListSnapshotStore``)
    /// they also survive a restart.
    ///
    /// **Expired does not mean worthless.** An expired entry is served immediately
    /// anyway, and a background fetch replaces it as soon as the server has answered —
    /// anyone who listens through ``listChanges()`` then shows the new data. Before
    /// this, there was a wait in front of an empty screen at this point, for content
    /// that is 99 % the same.
    private var cache: [String: CachedList] = [:]
    private let cacheLifetime: Duration

    private struct CachedList {
        var items: [MediaItem]
        var stored: ContinuousClock.Instant
        /// From the snapshot of the last session — counts as expired until the server
        /// has confirmed it once.
        var fromSnapshot: Bool
    }

    /// In-flight list fetches, per key.
    ///
    /// The same pattern as in the image cache: whoever requests the same list while it
    /// is already on its way attaches to it instead of asking twice. Without this, the
    /// prewarm and the view loaded the same library at the same time on launch — on a
    /// connection that does not tolerate simultaneous fetches in the first place.
    ///
    /// The tasks are **detached from the waiter**: if the view cancels — area switch,
    /// TV falls asleep — the fetch runs to completion and fills the cache. The result
    /// is needed again shortly anyway.
    private var inFlightLists: [String: Task<[MediaItem], any Error>] = [:]

    /// The library list, separately — a different value type, same treatment.
    /// It used to be fetched **three times** on launch (prewarm, Home, library switch)
    /// because it was the only one that was not kept at all.
    private var libraryList: (libraries: [Core.Library], stored: ContinuousClock.Instant, fromSnapshot: Bool)?
    private var inFlightLibraries: Task<[Core.Library], any Error>?

    /// The catalog counts, separately — a third value type, same treatment.
    ///
    /// **Until 2026-09-13 the count was the only fetch without a memory**, and on the
    /// phone that cost the launch: Home waits for the count of every library before it
    /// shows anything (`JellyfinStartSource`), and the library does too. All other
    /// fetches had long come from the snapshot — the count went to the network every
    /// time, and on a poor cell connection that meant a twelve-second timeout times
    /// two attempts in front of an empty screen, for a number that is the same as last
    /// time. The report `F-021` shows exactly this: `Views` and nine `Items`
    /// fetches, all hitting the timeout.
    ///
    /// `nil` as a value is an answer ("the server gives no number") and is kept; only
    /// an actual number goes to disk.
    private var counts: [String: CachedCount] = [:]
    private var inFlightCounts: [String: Task<Int?, any Error>] = [:]

    private struct CachedCount {
        var value: Int?
        var stored: ContinuousClock.Instant
        var fromSnapshot: Bool
    }

    /// Snapshots on disk, per server and user.
    private let snapshots: ListSnapshotStore

    /// The ratings of the series, kept for this session — see
    /// ``mapped(_:)`` and ``Core/SeriesClearances``.
    private let seriesApprovals = SeriesClearances()

    /// For whoever wants to learn that a list was replaced in the background.
    private var listObservers: [UUID: AsyncStream<Void>.Continuation] = [:]

    /// "Continue Watching" expires faster than the rest: the list changes through
    /// the user's own watching, and progress an hour old would be wrong information.
    /// After a playback it is discarded anyway.
    static let resumableLifetime: Duration = .seconds(60)

    /// When a request last ran — see the reasoning in ``get(_:query:)``.
    private var lastCompleted: Date?

    /// The current playback session, as the server issued it.
    ///
    /// Exactly **one**, not one per title: this device only ever plays one, and the
    /// previous session is explicitly cleaned up on the next URL build.
    /// Readable from outside so that carrying it along can be tested.
    private(set) var activeSession: PlaybackSession?

    /// How much idle time makes an existing connection suspect.
    ///
    /// **Two seconds, and the number was lowered from twenty.**
    ///
    /// Twenty came from the assumption that connections only died after longer idle
    /// periods. The next report refuted that: at 6:20:53 it shows an answer after 5.8
    /// seconds and at 6:20:59 — six seconds later — none at all. Likewise at 6:23:20
    /// and 6:23:26. Six seconds of pause are therefore enough.
    ///
    /// Two seconds separate a burst of related fetches (a Home screen fires its
    /// fetches within milliseconds) from everything that comes after. The handshake costs
    /// nothing at a 6 ms response time; a dead line costs six seconds of waiting.
    static let idleLimit: TimeInterval = 2

    public init(
        credentials: ServerCredentials,
        deviceID: String,
        cacheLifetime: Duration = .seconds(3600),
        trustStore: CertificateTrustStore = CertificateTrustStore()
    ) {
        self.init(
            credentials: credentials, deviceID: deviceID, cacheLifetime: cacheLifetime,
            trustStore: trustStore, protocols: [])
    }

    /// - Parameter protokolle: For checks only — `URLProtocol` classes that supply
    ///   the server's responses (track K). **A parameter and not a global
    ///   `URLProtocol.registerClass`:** the global registration does not reach this
    ///   dedicated session — tried on 2026-09-25, the fetch bypassed the stub.
    ///   Not public, so that the shared interface stays as it is.
    init(
        credentials: ServerCredentials,
        deviceID: String,
        cacheLifetime: Duration,
        trustStore: CertificateTrustStore,
        protocols: [AnyClass]
    ) {
        self.credentials = credentials
        self.deviceID = deviceID
        self.cacheLifetime = cacheLifetime
        self.displayName = credentials.serverURL.host() ?? credentials.serverURL.absoluteString
        self.snapshots = ListSnapshotStore(
            serverURL: credentials.serverURL,
            userID: credentials.userID
        )

        let config = URLSessionConfiguration.default
        // **Six seconds, and the number is measured.** The server answers this
        // device in 6 milliseconds; the throughput is 120 Mbit/s. What has not arrived
        // after six seconds will not arrive — it is stuck on a connection that has
        // died. Twelve seconds was the right choice as long as the line was
        // suspect; it is not.
        //
        // Short is better here because the second attempt runs on a fresh connection,
        // which then answers in milliseconds. A wait of 24 seconds becomes one of a
        // good six.
        // Back to fifteen. Six came from the assumption that whatever takes longer will
        // not arrive anyway — yet the report contains answers after 5.4 and 5.8
        // seconds, which would have just made it through.
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        // Six, as the default already provides. Lowering it to three was
        // another attempt without evidence — it did not reduce the failures.
        config.httpMaximumConnectionsPerHost = 6
        if !protocols.isEmpty { config.protocolClasses = protocols }
        self.session = URLSession(
            configuration: config,
            delegate: TrustingSessionDelegate(trustStore: trustStore),
            delegateQueue: nil
        )
    }

    // MARK: - Bibliotheken

    /// The libraries — kept, deduplicated and secured as a snapshot.
    ///
    /// Previously not stored, although three places need them on launch: the
    /// prewarm, Home and the first library switch each asked on their own —
    /// two waits in a row for the same answer.
    public func libraries() async throws -> [Core.Library] {
        if let held = libraryList {
            if !held.fromSnapshot, held.stored.duration(to: .now) < cacheLifetime {
                return held.libraries
            }
            // The old data immediately, the fresh data in the background — as with the lists.
            refreshLibraries()
            return held.libraries
        }
        if let running = inFlightLibraries {
            return try await running.value
        }
        if let stored = snapshots.load([Core.Library].self, key: Self.librariesKey) {
            libraryList = (stored, .now, fromSnapshot: true)
            refreshLibraries()
            return stored
        }

        let task = Task { try await self.fetchLibraries() }
        inFlightLibraries = task
        defer { inFlightLibraries = nil }
        let libraries = try await task.value
        libraryList = (libraries, .now, fromSnapshot: false)
        snapshots.save(libraries, key: Self.librariesKey)
        return libraries
    }

    static let librariesKey = "libraries"

    private func fetchLibraries() async throws -> [Core.Library] {
        let response: BaseItemDtoQueryResult = try await get(
            "Users/\(credentials.userID)/Views"
        )
        return (response.items ?? []).compactMap(ItemMapping.library(from:))
    }

    /// Fetches the library list anew without anyone waiting for it.
    private func refreshLibraries() {
        guard inFlightLibraries == nil else { return }
        let task = Task { try await self.fetchLibraries() }
        inFlightLibraries = task
        Task {
            // Errors bewusst still: the old data is already on screen,
            // and the next access tries again.
            let libraries = try? await task.value
            inFlightLibraries = nil
            guard let libraries else { return }
            let changed = libraryList?.libraries != libraries
            libraryList = (libraries, .now, fromSnapshot: false)
            snapshots.save(libraries, key: Self.librariesKey)
            if changed { notifyListsChanged() }
        }
    }

    // MARK: - Titel

    /// The titles of a library — **the whole catalog is fetched once**,
    /// ordering happens here.
    ///
    /// Before, the complete request was part of the cache key.
    /// That sounded thorough and was the opposite: every sort pill, every
    /// Home shelf ("Recently added, 20 items") and the prewarm on
    /// launch asked with a different sort order — different key, guaranteed
    /// miss, complete refetch of the same library. With home videos
    /// the prewarm **never** hit the view, because the view asks
    /// descending by date added.
    ///
    /// Now there is **one** entry per library and kind list with the
    /// full catalog, and sort order and cap are a calculation on what
    /// is already there — as category and unwatched filter have long demonstrated.
    /// Only the search stays the server's business: it ranks hits by relevance, and
    /// that cannot be rebuilt from the catalog.
    public func items(in library: Core.Library.ID, filter: Core.ItemFilter) async throws -> [MediaItem] {
        if let term = filter.searchTerm, !term.isEmpty {
            var query: [String: String] = [
                "ParentId": library,
                "Recursive": "true",
                "Fields": Self.listFields,
                "SortBy": Self.sortField(filter.sortBy),
                "SortOrder": filter.ascending ? "Ascending" : "Descending",
                "SearchTerm": term,
            ]
            if !filter.kinds.isEmpty {
                let types = filter.kinds.compactMap(Self.itemType)
                if !types.isEmpty { query["IncludeItemTypes"] = types.joined(separator: ",") }
            }
            if let limit = filter.limit {
                query["Limit"] = String(limit)
            }
            // Search results without a snapshot: they are meant to be transient, and
            // yesterday's state for today's query helps nobody.
            return try await cachedItems(
                key: Self.listCacheKey(library: library, filter: filter),
                persisted: false
            ) { [query] in
                let response: BaseItemDtoQueryResult = try await self.get(
                    "Users/\(self.credentials.userID)/Items", query: query
                )
                return await self.mapped(
                    (response.items ?? []).filter { !Self.isPlainFolder($0) })
            }
        }

        var query: [String: String] = [
            "ParentId": library,
            "Recursive": "true",
            "Fields": Self.listFields,
            // Fixed by sort title: the key no longer depends on the
            // sort order, so the request must not either — otherwise
            // the luck of the first call would decide in which order the catalog lies.
            "SortBy": "SortName",
            "SortOrder": "Ascending",
        ]
        if !filter.kinds.isEmpty {
            let types = filter.kinds.compactMap(Self.itemType)
            if !types.isEmpty { query["IncludeItemTypes"] = types.joined(separator: ",") }
        }

        let stock = try await cachedItems(
            key: Self.listCacheKey(library: library, filter: filter)
        ) { [query] in
            let response: BaseItemDtoQueryResult = try await self.get(
                "Users/\(self.credentials.userID)/Items", query: query
            )
            // Filter out only real directories, not everything the
            // server lists as a folder: **series are folders too**, because
            // they contain seasons. A filter on `isFolder` therefore deleted all
            // series along with them — the row was simply empty.
            return await self.mapped(
                (response.items ?? []).filter { !Self.isPlainFolder($0) })
        }
        return Self.arrange(stock, by: filter)
    }

    /// How many titles a library holds.
    ///
    /// **`Limit: 0` and not `1`.** The server then answers with an empty list and
    /// the total count — the request costs one round trip and no payload. With `1`
    /// a complete entry including image tags would come along, which nobody looks at.
    ///
    /// **No cache.** A number shown in the registry should state the catalog as of
    /// now; the list snapshot beneath it deliberately holds a state from a moment
    /// ago. Both together would yield a number that matches the displayed list and
    /// not the server.
    public func itemCount(
        in library: Core.Library.ID, filter: Core.ItemFilter
    ) async throws
        -> Int?
    {
        var query: [String: String] = [
            "ParentId": library,
            "Recursive": "true",
            "Limit": "0",
        ]
        if !filter.kinds.isEmpty {
            let types = filter.kinds.compactMap(Self.itemType)
            if !types.isEmpty { query["IncludeItemTypes"] = types.joined(separator: ",") }
        }
        return try await cachedCount(key: Self.countCacheKey(library: library, filter: filter)) {
            [query] in
            let response: BaseItemDtoQueryResult = try await self.get(
                "Users/\(self.credentials.userID)/Items", query: query)
            return response.totalRecordCount
        }
    }

    /// The key of a count — **the same rule as ``listCacheKey``:** library
    /// and kinds, nothing else. Sort order and cap change no number.
    public nonisolated static func countCacheKey(
        library: Core.Library.ID, filter: Core.ItemFilter
    ) -> String {
        let kinds = filter.kinds.map(\.rawValue).sorted().joined(separator: ",")
        return "count:\(library):\(kinds)"
    }

    /// A count from memory, snapshot or network — in this order.
    ///
    /// The same mechanics as ``cachedItems(key:lifetime:persisted:load:)``, for a
    /// number instead of a list. A background replacement reports through
    /// ``listChanges()`` — the number sits on screen next to the list, and whoever
    /// reloads the list reads the number along with it.
    func cachedCount(
        key: String,
        persisted: Bool = true,
        load: @escaping @Sendable () async throws -> Int?
    ) async throws -> Int? {
        if let held = counts[key] {
            if !held.fromSnapshot, held.stored.duration(to: .now) < cacheLifetime {
                return held.value
            }
            refreshCount(key: key, persisted: persisted, load: load)
            return held.value
        }
        if let running = inFlightCounts[key] {
            return try await running.value
        }
        if persisted, let stored = snapshots.load(Int.self, key: key) {
            counts[key] = CachedCount(value: stored, stored: .now, fromSnapshot: true)
            refreshCount(key: key, persisted: persisted, load: load)
            return stored
        }

        let task = Task { try await load() }
        inFlightCounts[key] = task
        defer { inFlightCounts[key] = nil }
        let value = try await task.value
        counts[key] = CachedCount(value: value, stored: .now, fromSnapshot: false)
        if persisted, let value { snapshots.save(value, key: key) }
        return value
    }

    /// Fetches a count anew without anyone waiting for it.
    private func refreshCount(
        key: String, persisted: Bool, load: @escaping @Sendable () async throws -> Int?
    ) {
        guard inFlightCounts[key] == nil else { return }
        let task = Task { try await load() }
        inFlightCounts[key] = task
        Task {
            // Errors bewusst still: the old data is already on screen,
            // and the next access tries again. **`Result` and not `try?`:**
            // the result is itself optional, and `try?` turned "no number" and
            // "failure" into the same `nil`.
            let result = await task.result
            inFlightCounts[key] = nil
            guard case .success(let value) = result else { return }
            let changed = counts[key]?.value != value
            counts[key] = CachedCount(value: value, stored: .now, fromSnapshot: false)
            if persisted, let value { snapshots.save(value, key: key) }
            if changed { notifyListsChanged() }
        }
    }

    /// The key under which a list response is stored.
    ///
    /// **Deliberately without sort order, direction and cap** — that is the whole
    /// point: every view, every pill and the prewarm hit the same entry.
    /// Only a search term makes its own key, because then no complete library
    /// lies beneath it but a hit list from the server.
    ///
    /// Public so that the checks can hold prewarm and views against each other —
    /// exactly the congruence that was silently missing before.
    public nonisolated static func listCacheKey(
        library: Core.Library.ID,
        filter: Core.ItemFilter
    ) -> String {
        let kinds = filter.kinds.map(\.rawValue).sorted().joined(separator: ",")
        if let term = filter.searchTerm, !term.isEmpty {
            return "search-in:\(library):\(kinds):\(term):\(filter.limit ?? 0)"
        }
        return "items:\(library):\(kinds)"
    }

    // MARK: - Clientseitige Ordnung

    /// Searches across **all** libraries instead of one.
    ///
    /// Without a library given, the server returns everything that matches the term —
    /// that is exactly what is wanted here: whoever types "Blibiagraik" wants to find the
    /// hit without knowing beforehand whether it lies under series or movies.
    ///
    /// Deliberately **without episodes and seasons**: a search for a series would
    /// otherwise yield three hundred hits that all mean the same thing. Whoever is
    /// looking for a specific episode finds it through the series.
    ///
    /// Home videos are included, but at the end — they rarely have maintained titles
    /// and would push real hits down.
    public func search(term: String, limit: Int = 60) async throws -> [MediaItem] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }

        let query: [String: String] = [
            "SearchTerm": trimmed,
            "Recursive": "true",
            "Fields": Self.listFields,
            "IncludeItemTypes": "Series,Movie,Video",
            // The server ranks hits by relevance as soon as a search term
            // is present. A custom sort would discard that and put the
            // best hit somewhere in the middle.
            "Limit": String(limit),
        ]

        // Without a snapshot: search results are meant to be transient.
        return try await cachedItems(key: "search:\(trimmed):\(limit)", persisted: false) {
            let response: BaseItemDtoQueryResult = try await self.get(
                "Users/\(self.credentials.userID)/Items", query: query
            )
            let items = await self.mapped(
                (response.items ?? []).filter { !Self.isPlainFolder($0) })

            // Home videos to the back. `sorted` would be wrong — it is not
            // stable and would scramble the server's relevance order.
            return items.filter { $0.kind != .homeVideo }
                + items.filter { $0.kind == .homeVideo }
        }
    }

    public func item(id: String) async throws -> MediaItem {
        // Single titles are not kept: they contain the progress,
        // and an outdated state would be more annoying here than a short wait.
        let dto: BaseItemDto = try await get(
            "Users/\(credentials.userID)/Items/\(id)",
            query: ["Fields": Self.detailFields]
        )
        guard let item = await mapped([dto]).first else {
            throw SourceFailure.notFound
        }
        return item
    }

    public func children(of itemID: String) async throws -> [MediaItem] {
        try await cachedItems(key: "children:\(itemID)") {
            let response: BaseItemDtoQueryResult = try await self.get(
                "Users/\(self.credentials.userID)/Items",
                query: ["ParentId": itemID, "Fields": Self.listFields]
            )
            return await self.mapped(response.items ?? [])
        }
    }

    /// In progress — kept briefly, see ``resumableLifetime``.
    ///
    /// With a snapshot: on a cold start "Continue Watching" should be there immediately,
    /// not only after the slowest request of the day. After every playback
    /// the entry is discarded together with its snapshot — see
    /// ``invalidateCache(containing:)``.
    public func resumable(limit: Int) async throws -> [MediaItem] {
        try await cachedItems(key: "resumable:\(limit)", lifetime: Self.resumableLifetime) {
            let response: BaseItemDtoQueryResult = try await self.get(
                "Users/\(self.credentials.userID)/Items/Resume",
                query: ["Limit": String(limit), "Fields": Self.listFields]
            )
            return await self.mapped(response.items ?? [])
                // **`/Items/Resume` is already filtered by Jellyfin's thresholds** (2026-09-28):
                // a stricter rule of our own stood here, and a movie at 1.1 % dropped out
                // while the Top Shelf showed it. Only what has been watched stays out.
                .filter { $0.progress?.isWatched != true }
        }
    }

    // MARK: - Serienfreigaben

    /// Server responses become titles — **and episodes and seasons receive the rating
    /// of their series** (track K, 2026-09-25).
    ///
    /// **Every fetch that returns titles goes through here**, and that is the whole point:
    /// Jellyfin keeps no rating on episodes, and any path that did not add one
    /// would be a door through which a child sees the episodes of an FSK-16 series. That is why
    /// the addition sits not in the views but here, **before** cache
    /// and snapshot — what lies there is already completed.
    ///
    /// **Collected and kept:** all series of a list in one fetch, and a
    /// series looked up once costs nothing more in this session. A list without
    /// episodes and seasons costs none at all. If the fetch fails, the episode stays open
    /// and is locked in child mode — the reasoning is at
    /// `ParentalControls.ProtectionRule.shows(_:)`.
    func mapped(_ dtos: [BaseItemDto]) async -> [MediaItem] {
        await seriesApprovals.complete(dtos.compactMap(ItemMapping.mediaItem(from:))) { allSeries in
            try await self.seriesApprovals(forItem: allSeries)
        }
    }

    /// The collected fetch: `/Users/{id}/Items?Ids=a,b,c` with `OfficialRating`.
    ///
    /// Verified against the real server (2026-09-25): the response carries each series'
    /// rating; an unknown ID is simply missing from the response, without an error —
    /// it thus stays "not determined".
    ///
    /// **Public since AP58 R1** (finding K6): the catch-up of the downloads on the phone
    /// until then asked for each series individually, because this path was private.
    public func seriesApprovals(forItem allSeries: [String]) async throws -> [SeriesClearance] {
        let response: BaseItemDtoQueryResult = try await get(
            "Users/\(credentials.userID)/Items", query: Self.seriesRatingsQuery(allSeries))
        return (response.items ?? []).compactMap { dto in
            dto.id.map { SeriesClearance(series: $0, approval: dto.officialRating) }
        }
    }

    /// The query of the collected fetch — its own computation so that the checks can
    /// grasp it without a server.
    static func seriesRatingsQuery(_ allSeries: [String]) -> [String: String] {
        ["Ids": allSeries.joined(separator: ","), "Fields": "OfficialRating"]
    }

    // MARK: - Abschnitte und Wiedergabe

    public func segments(for itemID: String) async throws -> [MediaSegment] {
        do {
            let response: MediaSegmentDtoQueryResult = try await get("MediaSegments/\(itemID)")
            return (response.items ?? []).compactMap(ItemMapping.segment(from:))
        } catch {
            // Without the plugin on the server there are no sections —
            // that is no error, just a missing convenience.
            Diagnostics.network.info("No chapters for \(itemID, privacy: .public)")
            return []
        }
    }

    /// A related title for the offer after the end of a movie.
    ///
    /// **Collection before similar.** If the title is part of a series, the
    /// next part is the right answer — after Jeipik-Bousjinflut (2002) Jeipik-Bousjinflut 2
    /// belongs in the offer, not whatever seems similar to the server. The
    /// rule itself is tested in ``FollowUpRule``; only when it finds
    /// nothing does the `Similar` endpoint guess via ``similarItems(to:limit:)``.
    public func similarItem(to itemID: String) async throws -> MediaItem? {
        if let sequel = try? await collectionFollowUp(after: itemID) {
            return sequel
        }
        return try await similarItems(to: itemID, limit: 3).first
    }

    /// The next part of the series, if the title is part of a collection.
    ///
    /// The reverse question "which collection contains X?" is unknown to the server
    /// — it runs forward over the (cached) collection lists. All
    /// collections are checked, not just the first with a hit: a title
    /// can be in several series, and "last part of one" does not
    /// mean the other has nothing left.
    private func collectionFollowUp(after itemID: String) async throws -> MediaItem? {
        for box in try await collections() {
            let parts = try await collectionItems(in: box.id)
            if let next = FollowUpRule.nextPart(after: itemID, in: parts) {
                return next
            }
        }
        return nil
    }

    /// Related titles via the server's `Similar` endpoint.
    ///
    /// The server makes the choice: it knows collections, genres and keywords —
    /// everything that would have to be rebuilt here. The response is kept only
    /// in memory: it hangs on the title, not on the catalog, and a snapshot
    /// on disk would hold on to recommendations that nobody asks for any more.
    public func similarItems(to itemID: String, limit: Int) async throws -> [MediaItem] {
        try await cachedItems(key: "similar:\(itemID):\(limit)", persisted: false) {
            let response: BaseItemDtoQueryResult = try await self.get(
                "Items/\(itemID)/Similar",
                query: [
                    "Limit": String(limit),
                    "UserId": self.credentials.userID,
                    "Fields": Self.listFields,
                ]
            )
            return await self.mapped(response.items ?? [])
                .filter { $0.id != itemID }
        }
    }

    /// All episodes of a series, across all seasons, in broadcast order.
    ///
    /// **One** fetch via `Shows/{id}/Episodes` instead of one per season: the
    /// card "More episodes" in the player needs the list in one piece, and
    /// for series with season structure ``children(of:)`` returns only seasons.
    /// Sorting happens here and is not taken on faith from the server — the order carries
    /// the season change, and a silently different one would be a
    /// jump into the middle of the series in the panel.
    public func episodes(of seriesID: String) async throws -> [MediaItem] {
        try await cachedItems(key: "episodes:\(seriesID)") {
            let response: BaseItemDtoQueryResult = try await self.get(
                "Shows/\(seriesID)/Episodes",
                query: [
                    "UserId": self.credentials.userID,
                    "Fields": Self.listFields,
                ]
            )
            return Self.inBroadcastOrder(await self.mapped(response.items ?? []))
        }
    }

    /// Orders episodes by season and number — the broadcast order.
    ///
    /// Episodes without a number go at the end: they are usually extras, and in the
    /// middle of the count they would be an offer nobody expects. On a tie
    /// the ID decides, so that the order stays stable across two fetches.
    static func inBroadcastOrder(_ episodes: [MediaItem]) -> [MediaItem] {
        episodes.sorted { left, right in
            let l = (left.seasonNumber ?? Int.max, left.episodeNumber ?? Int.max, left.id)
            let r = (right.seasonNumber ?? Int.max, right.episodeNumber ?? Int.max, right.id)
            return l < r
        }
    }

    // MARK: - Sammlungen

    /// The key under which the collection list is stored — snapshot like
    /// every library.
    public static let collectionsKey = "boxsets"

    /// The key for the parts of a collection.
    public nonisolated static func collectionKey(_ boxSetID: String) -> String {
        "boxset:\(boxSetID)"
    }

    /// The server's collections (BoxSets), as an ordinary list in the cache.
    ///
    /// Via the list cache including snapshot: the shelf on Home
    /// should be there immediately on a cold start, and the reconciliation runs through the same
    /// change stream as with every library.
    public func collections() async throws -> [MediaItem] {
        try await cachedItems(key: Self.collectionsKey) {
            let response: BaseItemDtoQueryResult = try await self.get(
                "Users/\(self.credentials.userID)/Items",
                query: [
                    "IncludeItemTypes": "BoxSet",
                    "Recursive": "true",
                    "Fields": Self.listFields,
                ]
            )
            return await self.mapped(response.items ?? [])
        }
    }

    /// The parts of a collection, ordered by release date.
    ///
    /// By date and not alphabetically — "Jeipik-Bousjinflut 2" belongs before
    /// "Jeipik-Bousjinflut 3" and not after "Jeipik-Bousjinflut: Kleibe". The reverse query
    /// "which collection contains title X?" is unknown to the server; whoever needs the
    /// mapping builds it client-side from these lists.
    public func collectionItems(in boxSetID: String) async throws -> [MediaItem] {
        try await cachedItems(key: Self.collectionKey(boxSetID)) {
            let response: BaseItemDtoQueryResult = try await self.get(
                "Users/\(self.credentials.userID)/Items",
                query: [
                    "ParentId": boxSetID,
                    "Fields": Self.listFields,
                ]
            )
            return Self.byPremiereDate(await self.mapped(response.items ?? []))
        }
    }

    public func streamURL(for itemID: String, decision: PlaybackDecision) async throws -> URL {
        // **Clean up first, then sign in, then build the address.**
        //
        // Clean up: if an encoding is still running for an earlier address, it is
        // explicitly ended at the server. Without this, ffmpeg keeps reading the old file
        // while the new one starts — two readers on the same disk, and
        // that is exactly what once suffocated a playback here.
        //
        // Sign in: the handshake via `PlaybackInfo` fetches the session ID
        // that the **server** issues. The self-rolled UUID from before was unknown to
        // it; it considered the encoding orphaned and deleted its data after ten
        // seconds — the player ran into a 404.
        //
        // **Both at once, not one after the other** (AP75, 2026-10-11): the cleanup clears
        // the old session, the sign-in fetches the new one — two requests that need nothing
        // from each other. One after the other they cost two round trips to the server on
        // Continue Watching instead of one; `discardActiveEncoding` takes the old
        // ID before it waits, and `establishSession` sets the new one only at the end.
        async let cleanedUp: Void = discardActiveEncoding()
        let playback = await establishSession(for: itemID)
        await cleanedUp

        // **HLS goes on a path of its own: the playlist.** `main.m3u8`
        // covers the full runtime; Apple's engine fetches the segments itself
        // and jumps within it wherever it wants. Everything else is a continuous
        // file — either unchanged (`stream`, with range access: for Apple's engine
        // **and** for our own remuxer, see ``wantsUntouchedFile(_:)``)
        // or repackaged by the server (`stream.mp4`, now only for VLC: Apple's engine
        // fundamentally cannot open a growing stream without range access,
        // see ``Delivery/hls``).
        if decision.delivery == .hls {
            var playlist = URLComponents(
                url: credentials.serverURL.appending(
                    path: Self.hlsPlaylistPath(for: decision, itemID: itemID)),
                resolvingAgainstBaseURL: false
            )
            playlist?.queryItems = Self.hlsQuery(
                for: decision,
                accessToken: credentials.accessToken,
                deviceID: deviceID,
                playback: playback
            )
            guard let url = playlist?.url else { throw SourceFailure.badRequest }
            Diagnostics.verbose(
                "Stream URL \(Diagnostics.loggable(url)) — delivery \(decision.delivery.rawValue)"
            )
            return url
        }

        let path =
            Self.wantsUntouchedFile(decision.delivery)
            ? "Videos/\(itemID)/stream"
            : "Videos/\(itemID)/stream.mp4"
        var components = URLComponents(
            url: credentials.serverURL.appending(path: path),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = Self.streamQuery(
            for: decision,
            accessToken: credentials.accessToken,
            deviceID: deviceID,
            playback: playback
        )

        guard let url = components?.url else { throw SourceFailure.badRequest }
        // Only the path, without the query part — the access token would be in it. When
        // looking for a playback error this line is the anchor: it shows
        // whether the request was raw, remuxed or transcoded.
        Diagnostics.verbose(
            "Stream URL \(Diagnostics.loggable(url)) — delivery \(decision.delivery.rawValue)"
        )
        return url
    }

    /// Whether this delivery path needs the file **untouched** — path `stream`
    /// and `static=true`.
    ///
    /// **Two paths want the same thing, and one of them was never asked for.** With
    /// ``Delivery/directPlay`` Apple's engine reads the file itself, with
    /// ``Delivery/remuxInApp`` our own remuxer reads it — both via
    /// partial fetches, both on the raw bytes. But in two places only
    /// `directPlay` was asked for, and so the remuxer got `stream.mp4` with
    /// `static=false`.
    ///
    /// **The consequence was not an error but a silent regression** (on-device test
    /// 2026-08-11): the server remuxed on its own — its log lists the run as
    /// `FFmpeg.Remux` — and such a stream arrives without range access and
    /// without length. ``HTTPByteRangeSource`` needs both, ``MatroskaFileSession``
    /// therefore threw, and the player fell back to VLC as designed. What the
    /// viewer saw: picture and sound start, then the picture freezes and the sound
    /// keeps going — VLC starved on the same progressive stream. The
    /// diagnostics said `native/remuxInApp`, what played was `vlc/directPlay`.
    ///
    /// Hence a named question here instead of the same comparison twice: whoever
    /// adds a third raw delivery path changes one place and not two
    /// — and the second was the one that got forgotten.
    static func wantsUntouchedFile(_ delivery: Delivery) -> Bool {
        switch delivery {
        case .directPlay, .remuxInApp, .renderInApp: true
        case .hls, .remux, .transcode: false
        }
    }

    /// The query parts of the playback address.
    ///
    /// Extracted and stateless so that address building can be tested without
    /// asking a server. Two bugs lay exactly here that showed up on the device
    /// only as "looks bad" and "picture is washed out" respectively —
    /// both symptoms that cannot be traced from the surface.
    ///
    /// The three IDs are in **every** address: `PlaySessionId` and
    /// `MediaSourceId` come from the `PlaybackInfo` handshake, `DeviceId` is the
    /// device ID. Without the session ID the server treats the encoding as
    /// orphaned and deletes its data after ten seconds — the documented reason for
    /// "video hangs".
    static func streamQuery(
        for decision: PlaybackDecision,
        accessToken: String,
        deviceID: String,
        playback: PlaybackSession
    ) -> [URLQueryItem] {
        var query = [
            URLQueryItem(name: "api_key", value: accessToken),
            URLQueryItem(name: "MediaSourceId", value: playback.mediaSourceID),
            URLQueryItem(name: "PlaySessionId", value: playback.playSessionID),
            URLQueryItem(name: "DeviceId", value: deviceID),
            URLQueryItem(
                name: "static",
                value: wantsUntouchedFile(decision.delivery) ? "true" : "false"),
        ]

        switch decision.delivery {
        case .hls:
            // Does not occur here: the playlist has its own path and
            // its own query parts — see ``hlsQuery(for:accessToken:deviceID:playback:)``.
            break

        case .directPlay, .remuxInApp, .renderInApp:
            // `static=true` delivers the file unchanged. Any further
            // parameter would make the server do something after all.
            //
            // **The same holds for remuxing in the app** — and necessarily so: our own
            // remuxer reads the file as it is, with partial fetches. Anything the server
            // changes along the way would make it unreadable.
            break

        case .remux:
            // `copy` makes the server start ffmpeg with `-codec:v:0 copy
            // -codec:a:0 copy` — verified against its log, which
            // is then also called "FFmpeg.Remux" and not "FFmpeg.Transcode".
            //
            // The resulting stream arrives without range access and without length —
            // a path only VLC still takes (resuming a Matroska via the
            // server offset). Apple's engine fundamentally does not open such a thing;
            // it gets the equivalent as HLS with fMP4 segments.
            //
            // The container has to be passed along: without `container` the
            // server repackages into the **same** container (verified: the response
            // came as `video/x-matroska`), and the whole effort would
            // be for nothing.
            query += [
                URLQueryItem(name: "container", value: "mp4"),
                URLQueryItem(name: "videoCodec", value: "copy"),
                URLQueryItem(name: "audioCodec", value: "copy"),
            ]

        case .transcode:
            query += [
                // The container has to be passed along here too, for the same
                // reason as with remuxing and with a worse consequence: without
                // `container` the server delivers a transport stream — verified against the server,
                // the response came as `video/mp2t`. Apple's engine does not open that
                // outside HLS. And the pairing "native engine
                // plus transcoding" is no special case: it arises with Dolby
                // Vision as soon as a bandwidth limit is set. What remained was
                // a black picture, triggered by a setting that was made three
                // layers away.
                URLQueryItem(name: "container", value: "mp4"),
                URLQueryItem(name: "videoCodec", value: "h264"),
                URLQueryItem(name: "audioCodec", value: "aac"),
            ]

            // Before, 1500000 and 1280 were hardcoded here. As a result every
            // transcoded title looked like it was on mobile data even on the home network, and the
            // viewer's setting (see ``StreamQuality``) had no
            // effect — it was bypassed without anything missing anywhere.
            //
            // Without a set limit none may appear in the address: the server
            // otherwise takes the given number as a cap and transcodes down a
            // better picture that it could also deliver uncut.
            if let bitrate = decision.maxBitrate {
                query.append(URLQueryItem(name: "videoBitRate", value: String(bitrate)))
            }
            if let width = decision.maxWidth {
                query.append(URLQueryItem(name: "maxWidth", value: String(width)))
            }
        }

        // **The server-side start point for VLC used to be here** — dropped with
        // the VLC removal (AP8, 2026-09-02): with unchanged delivery the server
        // answers range requests, and Apple's engine resumes on its own. For HLS the spot
        // lives on in ``hlsQuery``, with a different job — reasoning at
        // ``PlaybackDecision/startAt``.

        return query
    }

    /// Always the single media playlist — the documented path since 2026-08-01.
    ///
    /// For three days a switch to the master playlist (`master.m3u8`) stood here for
    /// the subtitle side track. It was deliberately removed again: on
    /// Dolby Vision titles the master playlist declares the copy wrongly and
    /// puts transcoding fallbacks next to it — on the device the picture stayed black,
    /// it could not be turned off on the server, and even a playlist repaired
    /// client-side did not fix it (05./2026-08-06). Since then the app
    /// draws subtitles itself; see ``subtitleCues(for:index:)``.
    static func hlsPlaylistPath(for decision: PlaybackDecision, itemID: String) -> String {
        "Videos/\(itemID)/main.m3u8"
    }

    /// Fetches a text subtitle track as a finished list of lines.
    ///
    /// The server converts embedded tracks to WebVTT (`Stream.vtt`) — on the
    /// **first** fetch per file it extracts them from the whole container for this,
    /// which can take a while for large files; after that it sits in the server cache
    /// and comes back in milliseconds.
    /// - Parameter format: How the track exists in the file.
    ///
    ///   **ASS is fetched raw and not converted.** The conversion to
    ///   WebVTT loses the position — and with it the distinction between
    ///   dialogue (bottom) and sign (top). That was exactly why ASS previously
    ///   needed the second engine.
    public func subtitleCues(
        for itemID: String, index: Int, format: MediaSource.SubtitleFormat? = nil
    ) async throws -> [SubtitleCue] {
        let isASS = format == .ass || format == .ssa
        let url = credentials.serverURL.appending(
            path: "Videos/\(itemID)/\(itemID)/Subtitles/\(index)/Stream.\(isASS ? "ass" : "vtt")"
        )
        var request = URLRequest(url: url)
        // The extraction on first fetch takes time — the usual short deadline
        // would abort exactly when the server is still working.
        request.timeoutInterval = 60
        request.setValue(authorization, forHTTPHeaderField: "Authorization")

        let (data, response) = try await load(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
            let text = String(data: data, encoding: .utf8)
        else { throw SourceFailure.badRequest }

        // **Recognised by content and not only by the declaration.** Older server versions
        // answer `Stream.ass` with converted WebVTT; whoever then stubbornly uses the
        // ASS reader gets zero lines and no hint.
        if isASS, !text.hasPrefix("WEBVTT") {
            let cues = ASSSubtitles.parse(text)
            if !cues.isEmpty { return cues }
        }
        return WebVTTSubtitles.parse(text)
    }

    /// A PGS subtitle track as decoded images — for our own renderer.
    ///
    /// The server delivers the track **raw** (`Stream.pgssub`, "PG" segments,
    /// verified on our own server); it cannot convert it, and it answers the VTT request
    /// for image tracks permanently with an error. On the first fetch
    /// per file it first extracts the track — the same wait as with text,
    /// the same patience on the caller's side.
    /// - Parameter format: PGS or VobSub — the two image formats
    ///   take different paths through the same server.
    ///
    ///   **For VobSub the roadmap contained a wrong statement.** It said
    ///   the DVD image formats could be "neither converted nor delivered raw; every
    ///   request ends immediately in an error". The first is true — the server
    ///   answers `.vtt` and `.idx` with 400. The second is not: **it delivers `.sub`
    ///   without complaint** (measured on 2026-08-10, 92 kilobytes for one track).
    public func subtitleImageCues(
        for itemID: String, index: Int, format: MediaSource.SubtitleFormat = .pgs
    ) async throws
        -> [SubtitleImageCue]
    {
        let suffix = format == .vobsub ? "sub" : "pgssub"
        let url = credentials.serverURL.appending(
            path: "Videos/\(itemID)/\(itemID)/Subtitles/\(index)/Stream.\(suffix)"
        )
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue(authorization, forHTTPHeaderField: "Authorization")

        let (data, response) = try await load(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { throw SourceFailure.badRequest }

        let cues =
            format == .vobsub
            ? VobSubSubtitles.parse(data) : PGSSubtitles.parse(data)
        guard !cues.isEmpty else { throw SourceFailure.badRequest }
        return cues
    }

    /// The query parts of the playlist — the path for Apple's engine.
    ///
    /// The values are those with which Swiftfin and jellyfin-web coax a playable
    /// stream out of the same server:
    ///
    /// - `PlaySessionId` and `MediaSourceId` come **from the handshake**, not
    ///   from our own dice rolling. Without the server's ID it considered the
    ///   encoding orphaned, ended it after about ten seconds and deleted
    ///   the finished segments — the player ran into a 404.
    /// - `SegmentContainer=mp4` is the fix for the actual codec error
    ///   of the first HLS period: AVFoundation requires HEVC in fMP4 segments; in
    ///   MPEG-TS the picture stayed black.
    /// - `VideoCodec`/`AudioCodec` name what may arrive. The server copies
    ///   what fits and transcodes the rest — it answers the question of what the device can do
    ///   better than the client.
    /// - `MinSegments=1` lets playback start as soon as **one** piece
    ///   is ready. **From two to one** (F-004, 2026-09-03): "Return" (Hi10P, the
    ///   server transcodes) needed 6.3 s until "ready" — the ffmpeg startup plus
    ///   two finished pieces of three seconds. With one piece half
    ///   the wait disappears; whether the VAAPI server then stays ahead of the player is up to
    ///   the next measurement. If it does not, two is right again.
    /// - **No `StartTimeTicks`.** The playlist covers the full runtime and
    ///   would start at zero despite the parameter — the documented bug on which the old
    ///   resume failed. The player seeks on its own after opening.
    /// - `VideoBitrate` is **always** in the address, not only when a
    ///   limit is set — see ``fallbackVideoBitrate``.
    static func hlsQuery(
        for decision: PlaybackDecision,
        accessToken: String,
        deviceID: String,
        playback: PlaybackSession
    ) -> [URLQueryItem] {
        var query = [
            URLQueryItem(name: "api_key", value: accessToken),
            URLQueryItem(name: "MediaSourceId", value: playback.mediaSourceID),
            URLQueryItem(name: "PlaySessionId", value: playback.playSessionID),
            URLQueryItem(name: "DeviceId", value: deviceID),
            URLQueryItem(name: "VideoCodec", value: "h264,hevc"),
            // **E-AC-3 is no longer copied — a targeted trial (2026-08-05).**
            // The on-device test shows clearly offset audio in the chunked stream on an E-AC-3 title
            // (Dolby Digital Plus with Atmos), while AC-3 and AAC ran cleanly.
            // Suspicion: the priming handling of E-AC-3 in fMP4 segments. Without `eac3`
            // in the list the server transcodes exactly this track to multichannel AAC —
            // the video track stays a copy. If the test confirms sync, it stays that way and the
            // roadmap records it; if not, the format was not the cause.
            URLQueryItem(name: "AudioCodec", value: "aac,ac3"),
            // **Eight, not six** (review agent 2026-08-23): the device profile
            // promises eight channels, but the number in the playback address
            // wins — every 7.1 title was silently downmixed to 5.1.
            URLQueryItem(name: "MaxAudioChannels", value: "8"),
        ]
        // **No start position in the HLS address — learned for the second time**
        // (F-014, 2026-09-04): the attempt from F-013 to pass `StartTimeTicks`
        // so that ffmpeg starts at that position broke
        // "Continue Watching" completely. The segment addresses of the playlist inherit
        // the query part, and the segment endpoint throws it back:
        // `ArgumentException: StartTimeTicks is not allowed` for
        // `hls1/main/-1.mp4`, HTTP 400, the engine gives up after 0.1 s. That
        // was exactly "the documented bug of the first HLS period" that once stood in this
        // comment. The thirty seconds on resume
        // thus remain the server waiting for its own remuxing;
        // ``PlaybackDecision/startAt`` carries the position onward, for a
        // path that needs it elsewhere.
        query += [
            URLQueryItem(name: "SegmentContainer", value: "mp4"),
            URLQueryItem(name: "TranscodingContainer", value: "mp4"),
            URLQueryItem(name: "TranscodingProtocol", value: "hls"),
            URLQueryItem(name: "MinSegments", value: "1"),
            URLQueryItem(name: "BreakOnNonKeyFrames", value: "True"),
        ]
        // **The eight-bit condition belongs in THIS address** (F-015, 2026-09-05,
        // Woujeinspes Skutgro: "does not play smoothly, picture and sound out of sync").
        // It had been in the device profile for `PlaybackInfo` since 2026-08-15 — but
        // the app builds the playlist itself, and the server decides from its
        // query parts: without `MaxVideoBitDepth` it copied the
        // ten-bit H.264 into the chunking (`FFmpeg.Remux`, `-codec:v:0 copy`),
        // and the Apple TV decoded 1080p Hi10P in software. Only for this
        // reason — for HEVC at ten bits (HDR) the limit would be wrong, since
        // the hardware decodes that.
        if decision.reason == .videoNeedsSoftwareDecoder {
            query.append(URLQueryItem(name: "MaxVideoBitDepth", value: "8"))
        }

        // **The selected tracks, as the server's numbers.** Without them it packs
        // its default choice; with them exactly the requested track. The subtitle
        // arrives as a separate WebVTT track on the playlist (`SubtitleMethod=Hls`)
        // — for that the address has to point to `master.m3u8`, because only the
        // master playlist carries side tracks; see ``hlsPlaylistPath(for:itemID:)``.
        if let audio = decision.audioStreamIndex {
            query.append(URLQueryItem(name: "AudioStreamIndex", value: String(audio)))
        }
        // No `SubtitleMethod` in the address any more: the app draws subtitles
        // itself (``subtitleCues(for:index:)``) — the stream stays unaffected by it,
        // and a switch costs no rebuild.

        // The limit moves into the same list — the server transcodes down within the
        // chunking, and the engine does not notice the switch. Without a
        // set limit the default stands here, because without any number
        // real transcoding fails — see ``fallbackVideoBitrate``.
        query.append(
            URLQueryItem(
                name: "VideoBitrate",
                value: String(decision.maxBitrate ?? Self.fallbackVideoBitrate)
            )
        )
        if let width = decision.maxWidth {
            query.append(URLQueryItem(name: "MaxWidth", value: String(width)))
        }

        // **The display's brightness ranges belong in the address.**
        //
        // Without them the server copies Dolby Vision HEVC with the tag
        // `hvc1` — the Apple TV then reads the stream as ordinary HEVC, and
        // the embedded DV metadata shows through as brightness flashes
        // lasting milliseconds (on-device test 08/2026, profile 5 title). With
        // a declared DOVI capability it tags the same copy as `dvh1`,
        // and the device plays real Dolby Vision. Verified on the server:
        // same address, the only difference this parameter — once
        // `-tag:v:0 hvc1`, once `-tag:v:0 dvh1`, both times `copy`.
        //
        // Only for an HDR-capable display: without the declaration the previous
        // behavior stays, and an SDR device is not told anything it
        // cannot deliver.
        if decision.displaySupportsHDR {
            query.append(
                URLQueryItem(
                    name: "hevc-rangetype",
                    value: "SDR,HDR10,HLG,DOVI,DOVIWithHDR10"
                )
            )
        }
        return query
    }

    /// The cap on the frame rate when the viewer has not set one.
    ///
    /// **Without any number, real transcoding fails on the server — verified on our own
    /// catalog.** As long as it only copies, the parameter does not matter; only the
    /// home video from the DivX era forced it to really transcode, and its ffmpeg
    /// aborted immediately: without `VideoBitrate` Jellyfin starts the VAAPI encoder
    /// with `-rc_mode VBR -b:v 0`, the encoder refuses ("Bitrate must be set
    /// for VBR RC mode", exit code 234) — and on top of that the target width had collapsed to 416
    /// pixels, because the size choice also started from the zero. On the device this looked
    /// like "nothing arrives", without any error message
    /// from the server to the client.
    ///
    /// That is why a number is always in the address — the same default
    /// with which jellyfin-web asks on the home network. It is deliberately so high that
    /// it never becomes the reason to transcode anything down: what the server can
    /// copy it still copies, because every source in the catalog lies
    /// far below it.
    static let fallbackVideoBitrate = 120_000_000

    // MARK: - Wiedergabesitzung

    /// Fetches the session for this title from the server: `POST /Items/{id}/PlaybackInfo`.
    ///
    /// Whether a title ID recognisably does **not** come from this server.
    ///
    /// Jellyfin issues IDs as 32 hex digits. The Xtream provider builds
    /// its own from parts with hash signs in between (`…#movie#339501#mkv`), and a
    /// hash sign never occurs in a server ID. More precision is not needed:
    /// the question is "does this belong here", not "whom does it belong to".
    public static func isForeignItemID(_ itemID: String) -> Bool {
        itemID.contains("#")
    }

    /// If the handshake fails, playback starts anyway — with its
    /// own ID and the title ID as media source, which is the same
    /// at Jellyfin. This is deliberately not an abort: a server that does not answer the request
    /// often delivers the file nonetheless, and a movie that plays while
    /// the session limps is better than none at all.
    private func establishSession(for itemID: String) async -> PlaybackSession {
        // **A foreign title does not belong here at all, and that should be visible.**
        //
        // The same mix-up slipped through twice (2026-08-15 and 2026-08-23):
        // a call site passed along the media server even though the title came from the
        // IPTV provider. The log then showed only `badRequest` next to an
        // address — correct, but silent about the fact that the **source** was wrong
        // and not the request. This line says it.
        if Self.isForeignItemID(itemID) {
            Diagnostics.playbackProblem(
                "Wrong source: \(itemID) is a provider identifier, but the Jellyfin server "
                    + "was asked — the call site passes on the wrong "
                    + "``ContentSource`` on",
                since: nil
            )
        }

        let fallback = PlaybackSession(
            itemID: itemID,
            playSessionID: UUID().uuidString,
            mediaSourceID: itemID
        )

        var components = URLComponents(
            url: credentials.serverURL.appending(path: "Items/\(itemID)/PlaybackInfo"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "UserId", value: credentials.userID)]
        guard let url = components?.url else {
            activeSession = fallback
            return fallback
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")

        let established: PlaybackSession
        do {
            request.httpBody = try JSONEncoder().encode(PlaybackHandshake.Body.standard())
            let (data, response) = try await load(request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
            else { throw SourceFailure.badRequest }

            let info = try decoder.decode(PlaybackHandshake.Reply.self, from: data)
            established = PlaybackSession(
                itemID: itemID,
                playSessionID: info.playSessionId ?? fallback.playSessionID,
                mediaSourceID: info.mediaSources.first?.id ?? itemID
            )
            Diagnostics.success(url, step: "Request session", detail: established.playSessionID)
            // The result of the handshake as a whole — when troubleshooting, what counts
            // is which version the server chose and how many it offered.
            Diagnostics.verbose(
                "PlaybackInfo: session \(established.playSessionID), "
                    + "source \(established.mediaSourceID), "
                    + "\(info.mediaSources.count) versions"
            )
        } catch {
            Diagnostics.failure(url, step: "Request session", error: error)
            established = fallback
        }

        activeSession = established
        return established
    }

    /// Ends the running encoding on the server: `DELETE /Videos/ActiveEncodings`.
    ///
    /// Belongs at every end and every fresh start — on a seek via the server the
    /// old ffmpeg would otherwise keep running and read the disk in parallel with the new one. The
    /// server needs both IDs for this: the device and the session.
    private func discardActiveEncoding() async {
        guard let active = activeSession else { return }
        activeSession = nil

        var components = URLComponents(
            url: credentials.serverURL.appending(path: "Videos/ActiveEncodings"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "deviceId", value: deviceID),
            URLQueryItem(name: "playSessionId", value: active.playSessionID),
        ]
        guard let url = components?.url else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")

        // The response does not count: if no encoding was running — for instance after
        // unchanged delivery — the server answers with an error, and exactly that is
        // meaningless here.
        _ = try? await load(request)
    }

    /// The session for this title, if it is still the current one.
    private func currentSession(for itemID: String) -> PlaybackSession? {
        guard let active = activeSession, active.itemID == itemID else { return nil }
        return active
    }

    /// Discards the cached lists that contain this title.
    ///
    /// **Without this, the detail page shows the earlier state.** The lists are kept for two
    /// minutes so that paging between views does not wait every time —
    /// and they carry the progress. Whoever watches an episode and then goes to the
    /// series page is in exactly this window: there it then said "S1 E1
    /// play" instead of "Continue Watching", although Home already listed the title under
    /// "Continue Watching". Two views, two answers, both from the same
    /// app — from the outside it looks as if the detail page did not have the progress
    /// at all.
    ///
    /// Discarding is targeted: only lists in which the title appears. Throwing
    /// everything away would mean refetching the whole library for one changed title
    /// — and this cache exists precisely against that.
    ///
    /// Two additions, since the lists survive the session:
    ///
    /// - **The snapshot goes along.** If it stayed, the old
    ///   progress would come back from the file on the next launch — the same bug
    ///   as back then on the detail page, just one restart later.
    /// - **"Continue Watching" is always dropped**, even if the title was not in it:
    ///   whoever **starts** a movie was precisely not in the list beforehand —
    ///   that is exactly why it has to be fetched anew.
    private func invalidateCache(containing itemID: String) {
        for (key, entry) in cache {
            let affected =
                key.hasPrefix("resumable:")
                // **Also the lists that carry this ID in their key.**
                // Only the content comparison stood here, and it does not work for a
                // series: the season list (`children:`) holds seasons,
                // not the episode that just played — its unwatched counter therefore
                // stayed, and with it the season the page
                // opens on.
                || key == "children:\(itemID)" || key == "episodes:\(itemID)"
                || entry.items.contains { $0.id == itemID }
            guard affected else { continue }
            cache[key] = nil
            snapshots.remove(key: key)
        }
    }

    /// After a playback: discard what it changed and wake the listeners.
    ///
    /// **The report to the server is not the same as a fresh list.**
    /// When the player closes, the state goes out; but what the app shows comes
    /// from its cache, and that knows nothing about it. Whoever comes straight
    /// back therefore sees the state from before — the finding from the
    /// test report of 2026-08-11.
    ///
    /// Discarding is targeted and not everything: an empty cache would mean reloading every
    /// view afterwards, and over a thin line that is the
    /// wait this cache exists against.
    /// Discards "Continue Watching" together with its snapshot — the next fetch asks the server.
    public func reloadContinueWatching() async {
        for key in cache.keys where key.hasPrefix("resumable:") {
            cache[key] = nil
            snapshots.remove(key: key)
        }
    }

    public func refreshAfterPlayback(ids: [String]) async {
        guard !ids.isEmpty else { return }
        for id in ids { invalidateCache(containing: id) }
        notifyListsChanged()
    }

    public func report(progress: PlaybackProgress, for itemID: String, isPaused: Bool) async throws {
        invalidateCache(containing: itemID)
        // The session ID belongs in every report: otherwise the server does not assign the state
        // to any encoding and considers it orphaned after a short deadline —
        // then it deletes its data, and the player runs into nothing.
        let playback = currentSession(for: itemID)
        await announce(
            "Sessions/Playing/Progress",
            body: ProgressReport(
                itemId: itemID,
                positionTicks: Self.ticks(progress.position),
                isPaused: isPaused,
                playSessionId: playback?.playSessionID,
                mediaSourceId: playback?.mediaSourceID
            ),
            step: "Report progress"
        )
    }

    public func beginSession(for itemID: String) async throws {
        // Without this report the server does not track the session: in its
        // web interface the device does not appear at all, and the progress that
        // follows has nothing it could attach to.
        //
        // `CanSeek` is part of it so that the web interface's remote
        // offers a scrub bar instead of a locked bar.
        let playback = currentSession(for: itemID)
        await announce(
            "Sessions/Playing",
            body: PlaybackStartReport(
                itemId: itemID,
                positionTicks: 0,
                canSeek: true,
                playSessionId: playback?.playSessionID,
                mediaSourceId: playback?.mediaSourceID
            ),
            step: "Register session"
        )
    }

    // MARK: - Protokoll an den Server

    /// Sends a log to the server, where it is stored as a file.
    ///
    /// **The only way to get a diagnostic off the TV.** tvOS has neither
    /// mail nor a share sheet — both exist only on iOS and macOS. And collecting a
    /// log from the device is refused by macOS over the network ("Device not
    /// configured"); with a cable you are tied to the spot.
    ///
    /// Jellyfin accepts client logs for exactly this purpose and stores them with its
    /// own. They can be picked up in the web interface under Dashboard → Logs.
    /// No additional service, no credentials in the app, and the server is
    /// there anyway.
    ///
    /// The server can switch off acceptance (`AllowClientLogUpload`). It then answers
    /// with 403, and the error is passed on instead of swallowed: a button that does
    /// nothing and reports success is worse than one that complains.
    ///
    /// What comes back is the file name **that the server assigned.** It is the
    /// only information with which the file can be found again in the web interface
    /// — a self-invented name would exist on the TV and nowhere
    /// else, and that is exactly how it once was here.
    public func uploadLog(_ text: String) async throws -> String {
        let url = credentials.serverURL.appending(path: "ClientLog/Document")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.httpBody = Data(text.utf8)

        do {
            let (data, response) = try await load(request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
            else {
                throw SourceFailure.badRequest
            }
            let name = Self.uploadedLogName(from: data) ?? "(name unknown)"
            Diagnostics.success(url, step: "Send log", detail: name)
            return name
        } catch {
            Diagnostics.failure(url, step: "Send log", error: error)
            throw error
        }
    }

    /// Reads the file name from the response to `ClientLog/Document`.
    ///
    /// The server answers with `{"fileName": "…"}` — depending on the version also in its
    /// usual capitalisation as `FileName`. Both are accepted instead of committing
    /// to one: a field name is not a contract on which sending
    /// should fail. A response without a name is therefore not an error either,
    /// just one without information — the caller gets `nil` and says so honestly.
    static func uploadedLogName(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (json["fileName"] ?? json["FileName"]) as? String
    }

    // MARK: - Gesehen und Favorit

    /// Sets or deletes the watched mark.
    ///
    /// Two endpoints instead of one with a payload: the server distinguishes by the
    /// **method**, not by the body — `POST` sets, `DELETE` deletes.
    public func setPlayed(_ isPlayed: Bool, for itemID: String) async throws {
        try await mark("PlayedItems", itemID: itemID, on: isPlayed, step: "Watched mark")
    }

    /// **Only the position to zero** — `POST /UserItems/{id}/UserData` (Jellyfin 10.9+, verified on
    /// server 12.1). The unwatched mark would have done the same for "Continue Watching",
    /// but would also have touched "watched"; Apple removes only the row on removal.
    public func removeFromContinueWatching(_ itemID: String) async throws {
        invalidateCache(containing: itemID)
        var address = URLComponents(
            url: credentials.serverURL.appending(path: "UserItems/\(itemID)/UserData"),
            resolvingAgainstBaseURL: false)
        address?.queryItems = [URLQueryItem(name: "userId", value: credentials.userID)]
        guard let url = address?.url else { throw SourceFailure.badRequest }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"PlaybackPositionTicks":0}"#.utf8)
        do {
            let (_, response) = try await load(request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
            else {
                throw SourceFailure.badRequest
            }
            Diagnostics.success(url, step: "From Continue Watching", detail: "position reset to zero")
        } catch {
            Diagnostics.failure(url, step: "From Continue Watching", error: error)
            throw error
        }
    }

    public func setFavorite(_ isFavorite: Bool, for itemID: String) async throws {
        try await mark("FavoriteItems", itemID: itemID, on: isFavorite, step: "Favorite mark")
    }

    /// Common path for both marks.
    ///
    /// **The cache is discarded, and that is no extra here.** Both
    /// marks appear in the same lists that are kept for two minutes. Without
    /// discarding you would not see your own keypress: you mark a title,
    /// go back, and it stands there unmarked — the same bug as with progress,
    /// just on a different mark.
    private func mark(_ path: String, itemID: String, on: Bool, step: String) async throws {
        invalidateCache(containing: itemID)

        let url = credentials.serverURL.appending(
            path: "Users/\(credentials.userID)/\(path)/\(itemID)"
        )
        var request = URLRequest(url: url)
        request.httpMethod = on ? "POST" : "DELETE"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")

        do {
            // **A 401 is not a success** (AP6 · Q5, expert review 2026-08-24).
            // `_ = try await session.data(for: request)` stood here, and that
            // throws only on a transport error: on a rejected
            // request the trace wrote "✓ set", the optimistically set
            // checkmark stayed, the rollback never took effect — and on the next
            // load the mark was gone without anything recording it.
            //
            // In the same type `uploadLog` and `handshake` have long done it
            // right; here the three lines were missing.
            let (_, response) = try await load(request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
            else {
                throw SourceFailure.badRequest
            }
            Diagnostics.success(url, step: step, detail: on ? "set" : "cleared")
        } catch {
            Diagnostics.failure(url, step: step, error: error)
            throw error
        }
    }

    /// The titles marked as favorites, flat across all libraries.
    ///
    /// **No cache.** The list changes exactly when the viewer
    /// has just marked something — serving it from a two-minute-old state
    /// would mean withholding their own input from them.
    ///
    /// Folders stay out: the server also lists libraries and seasons as
    /// entries, and those do not belong in a favorites list.
    public func favorites() async throws -> [MediaItem] {
        let response: BaseItemDtoQueryResult = try await get(
            "Users/\(credentials.userID)/Items",
            query: [
                "Filters": "IsFavorite",
                "Recursive": "true",
                "Fields": Self.listFields,
                "SortBy": "SortName",
                "IncludeItemTypes": "Movie,Series,Episode,Video",
            ]
        )
        return await mapped(response.items ?? [])
    }

    /// What the server says about this account.
    ///
    /// **Read and displayed, not trusted** — the core sentence of parental controls. The
    /// server filters more reliably than any app because it does not release blocked titles
    /// in the first place; but it knows nothing of Xtream, nothing of the portals and nothing of
    /// the device the app runs on. That is why both are asked and the stricter
    /// one applies.
    ///
    /// **`Users/Me` and not `Users/<ID>`.** Both answer the same; the first
    /// form asks for the account that belongs to the access token — and that is exactly
    /// the question. After a move or a swapped access, the second would use the
    /// remembered ID, and the answer would be that of a different person.
    public func userPolicy() async throws -> UserPolicy {
        let reply: UserResponse = try await get("Users/Me")
        return reply.accessPolicy
    }

    public func endSession(for itemID: String, at position: TimeInterval) async throws {
        // Here too, and not only on the running report: whoever aborts a title
        // without anything having been reported in between would otherwise leave playback with the old state
        // — and meet it again on the detail page.
        invalidateCache(containing: itemID)
        // If the sign-off is omitted, the session stays at the server as
        // "running" — until its own cleanup deadline. On the TV this is not
        // noticeable; in the web interface it shows for hours a movie that
        // ended long ago.
        let playback = currentSession(for: itemID)
        await announce(
            "Sessions/Playing/Stopped",
            body: PlaybackStopReport(
                itemId: itemID,
                positionTicks: Self.ticks(position),
                playSessionId: playback?.playSessionID,
                mediaSourceId: playback?.mediaSourceID
            ),
            step: "Unregister session"
        )
        // And the encoding afterwards: the server does stop by itself at some point,
        // but until then ffmpeg keeps reading the file — on a disk
        // whose read rate demonstrably collapses under a second reader.
        if playback != nil {
            await discardActiveEncoding()
        }

        // **And discard once more, just before the report.** The discarding at the very
        // top alone is not enough: between it and this line lie the sign-off
        // and the cleanup of the encoding — seconds in which the
        // wrapper already refreshes the views once (``PlaybackRefresh``).
        // What comes in then is the state from **before** the sign-off, and it
        // lands as a fresh entry in the cache. The report right below it
        // would then hit a cache that insists on the old state for two
        // minutes — "Continue Watching" would stay empty although the server long since
        // knows.
        invalidateCache(containing: itemID)

        // **Only after the sign-off, not on the discarding above:** the listeners
        // reload immediately on this report — before it, the server would not yet know the
        // end position, and "Continue Watching" would come back with the old state.
        // That was exactly the finding of the test days: the Home shelf
        // learned of the end of playback only on the next app restart.
        notifyListsChanged()
    }

    // MARK: - Trailer, next episode, scrub preview

    public func trailer(for itemID: String) async throws -> MediaItem? {
        // The response is a **bare array** of titles, not an object with
        // `Items` like almost everything else at the server — parsing with `BaseItemDtoQueryResult`
        // fails. If no trailer is attached, `[]` comes back with status
        // 200; also for an unknown ID, not 404. Both verified
        // against the server.
        //
        // Explicitly only the local trailers. `RemoteTrailers` contains
        // YouTube links, and on tvOS there is neither a YouTube player nor
        // a web view in which they could be opened.
        let dtos: [BaseItemDto]
        do {
            dtos = try await get("Users/\(credentials.userID)/Items/\(itemID)/LocalTrailers")
        } catch {
            // A trailer is an extra. A failure when asking is, for the UI,
            // indistinguishable from "no trailer present",
            // and a propagated error would force every call site into handling
            // for which there is no action.
            Diagnostics.network.info("No trailer for \(itemID, privacy: .public)")
            return nil
        }

        // The trailer is a title of its own with its own container and its own
        // tracks — on the test server MKV with HEVC, where the movie itself is MP4.
        // That is why it is mapped completely, including ``MediaSource``: the
        // engine choice hangs on it, and with that of the movie it would play black.
        // `MediaSources` the server returns here without `Fields`.
        return await mapped(Array(dtos.prefix(1))).first
    }

    /// The episode that follows this one — not the next unwatched.
    ///
    /// Built on `Shows/{seriesID}/Episodes` with `AdjacentTo`. The server returns
    /// **three** titles in broadcast order: the previous episode, the
    /// requested one itself, the next. Verified against the server, as are the edges.
    ///
    /// Why not `Shows/NextUp`: it returns the next **unwatched** episode.
    /// Whoever watches a series for the second time would, in the credits, not be offered
    /// the episode after, but some episode a hundred further on.
    ///
    /// Why not fetch all episodes and count yourself: for a long series
    /// that is several hundred titles for one piece of information that
    /// concerns a single one — and in the credits, where it has to be fast.
    ///
    /// **The server itself crosses the season boundary.** After the last
    /// episode of a season, the first of the next one is in the response
    /// (verified: S1E25 → S2E1). That is also what is wanted: for the viewer
    /// the season boundary is no break, and an offer that stops there
    /// looks like the end of the series.
    public func nextEpisode(after itemID: String) async throws -> MediaItem? {
        // The series ID is not in the request but has to come from the
        // title itself. A movie or home video has none — then there is
        // no next episode either.
        guard let seriesID = try await item(id: itemID).seriesID else { return nil }

        let response: BaseItemDtoQueryResult = try await get(
            "Shows/\(seriesID)/Episodes",
            query: [
                "UserId": credentials.userID,
                "AdjacentTo": itemID,
                "Fields": Self.listFields,
            ]
        )
        guard let following = Self.episodeFollowing(itemID, in: response.items ?? []) else {
            return nil
        }
        return await mapped([following]).first
    }

    /// Finds the episode **after** the requested one in the group of three.
    ///
    /// Deliberately by ID and not by position: for the first episode
    /// of a series only two titles come, and the requested one is then at the front instead of
    /// in the middle. Whoever stubbornly takes the second entry offers, after the last
    /// episode, the one just watched again — it is the second entry there.
    ///
    /// If the server does not return the requested episode at all, the response
    /// cannot be interpreted and there is nothing to offer. That happens: if
    /// `AdjacentTo` points at an episode of a **different** series, the server answers
    /// with the first episode of the requested series instead of an error.
    static func episodeFollowing(_ itemID: String, in episodes: [BaseItemDto]) -> BaseItemDto? {
        guard let position = episodes.firstIndex(where: { $0.id == itemID }) else { return nil }
        let next = episodes.index(after: position)
        guard next < episodes.endIndex else { return nil }
        return episodes[next]
    }

    public func trickplay(for itemID: String) async throws -> Trickplay? {
        // `Trickplay` is not in ``detailFields`` but is requested individually:
        // only the scrub bar needs the data and nobody else,
        // and carrying it in every list response would be one more
        // dictionary for every tile.
        let dto: BaseItemDto
        do {
            dto = try await get(
                "Users/\(credentials.userID)/Items/\(itemID)",
                query: ["Fields": "Trickplay"]
            )
        } catch {
            // The preview images are generated by the server only if it is set
            // up for it. Without them nothing is shown while scrubbing.
            Diagnostics.network.info("No scrub preview for \(itemID, privacy: .public)")
            return nil
        }

        return ItemMapping.trickplay(
            from: dto,
            serverURL: credentials.serverURL,
            accessToken: credentials.accessToken
        )
    }

    // MARK: - Bilder

    /// The address of an image at the desired width.
    ///
    /// The width is passed explicitly so that a tile does not load a
    /// full-screen image — for a row with twenty posters that makes the
    /// difference between smooth and stuttering.
    /// - Parameter tag: The ID of the image, as the server delivers it in `ImageTags`.
    ///
    ///   **Without it the image cache is practically ineffective, and this is measured on the
    ///   server:**
    ///
    ///       without tag  ->  Cache-Control: public
    ///       with    tag  ->  Cache-Control: public, max-age=31536000
    ///
    ///   Without `max-age`, `URLCache` has no freshness information. It then asks for every image
    ///   again on the next launch; the answer is "304, unchanged", but
    ///   the way there is a full request over the network. With fifty tiles
    ///   behind six connections that is fifty round trips before the first tile
    ///   is up — on a line where a small request needs eight seconds to the
    ///   first byte, that is exactly the reported "images appear late".
    ///
    ///   A one-year lifetime is no risk here but the precondition
    ///   for discarding to work correctly at all: if the image changes on the
    ///   server, its tag changes — and with it the address.
    public nonisolated func imageURL(
        itemID: String,
        kind: ImageKind = .primary,
        width: Int,
        tag: String? = nil
    ) -> URL? {
        var components = URLComponents(
            url: credentials.serverURL.appending(path: "Items/\(itemID)/Images/\(kind.rawValue)"),
            resolvingAgainstBaseURL: false
        )
        var query = [
            URLQueryItem(name: "maxWidth", value: String(width)),
            URLQueryItem(name: "quality", value: "85"),
        ]
        if let tag { query.append(URLQueryItem(name: "tag", value: tag)) }
        components?.queryItems = query
        return components?.url
    }

    /// The enumeration originally belonged here; it now lives in Core so that
    /// the source contract can name it. The alias keeps all existing
    /// spellings (`JellyfinSource.ImageKind`) alive.
    public typealias ImageKind = Core.ImageKind

    /// The preview image of a chapter marker.
    ///
    /// A path of its own instead of ``ImageKind``: chapter images hang on the title **and**
    /// the running index — `Items/{id}/Images/Chapter/{index}` — and only with the tag
    /// the server assigned on extraction. Without a tag there is no image,
    /// and an address into nothing would be a 404 in the log for every card.
    public nonisolated func chapterImageURL(
        itemID: String,
        index: Int,
        tag: String?,
        width: Int
    ) -> URL? {
        guard let tag else { return nil }
        var components = URLComponents(
            url: credentials.serverURL.appending(path: "Items/\(itemID)/Images/Chapter/\(index)"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "maxWidth", value: String(width)),
            URLQueryItem(name: "quality", value: "85"),
            URLQueryItem(name: "tag", value: tag),
        ]
        return components?.url
    }

    // MARK: - Interner Unterbau

    public enum SourceFailure: Error, Equatable {
        case notFound
        case badRequest
        case unauthorized
        case server(status: Int)
        case unreachable
    }

    private var authorization: String {
        JellyfinConnection.authorizationHeader(
            deviceID: deviceID,
            deviceName: JellyfinConnection.deviceKind,
            token: credentials.accessToken
        )
    }

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        var components = URLComponents(
            url: credentials.serverURL.appending(path: path),
            resolvingAgainstBaseURL: false
        )
        if !query.isEmpty {
            components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components?.url else { throw SourceFailure.badRequest }

        var request = URLRequest(url: url)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")

        // **A discarding of the connection pool before almost every request used to be here,
        // and it destroyed more than it helped.**
        //
        // The reasoning: a reused connection sometimes does not answer at all, a fresh
        // one in 6 ms — so discard before every request after a short idle.
        // The report afterwards showed something that did not exist before:
        // "**new** connection, no response received". `flush` clears the pool for
        // the whole session, and whatever was still in flight at that moment goes with it.
        // A problem that hit individual requests became one that hit all of them.
        //
        // The finding about reused connections remains correct. The remedy was
        // wrong, and it is not replaced here by the next attempt: as long as
        // it is not proven that a remedy helps, none is better than one that
        // knocks over something else on the side.

        // **Two attempts, and the reason is in the device's diagnostic report.**
        //
        // It contains timeouts on ordinary fetches on the home network —
        // once even on `Users/…/Views`, while nothing else was running. Measured,
        // the read rate of the same server fluctuates between 9 and 500 Mbit/s, depending
        // on which part of the file is being fetched. A connection that
        // hits such a dip stalls; a new one usually gets through immediately.
        //
        // So better **wait shorter and ask again** than wait once for long:
        // the timeout stands at twelve seconds, and two attempts take, in the
        // worst case, as long as one did before — only the second often ends with
        // a result instead of an error message.
        for attempt in 0..<2 {
            do {
                let (data, response) = try await load(request)
                guard let http = response as? HTTPURLResponse else {
                    throw SourceFailure.unreachable
                }

                switch http.statusCode {
                case 200...299:
                    // **Parsing gets a step of its own.** When it was in the same
                    // block, a format error became "unreachable" — that is, the
                    // message that points to the server. Whoever then reads the diagnostic report
                    // searches the network, while in truth a response does not match
                    // the expected fields.
                    do {
                        return try decoder.decode(T.self, from: data)
                    } catch {
                        Diagnostics.failure(url, step: "Parse response", error: error)
                        throw SourceFailure.badRequest
                    }
                case 401:
                    throw SourceFailure.unauthorized
                case 404:
                    throw SourceFailure.notFound
                default:
                    throw SourceFailure.server(status: http.statusCode)
                }
            } catch let failure as SourceFailure {
                throw failure
            } catch  where Self.wasCancelled(error) {
                // **A cancellation is not a server problem, and reporting it as one was
                // the bug behind "No response. Is the server running?".**
                //
                // Cancellation happens with every ordinary action: the viewer
                // switches the area while Home is still loading, or the
                // TV falls asleep and tvOS suspends the app. Both end the
                // running requests — and both ended up here as "unreachable", that is,
                // as a message that points to the server, while nothing is wrong with it.
                //
                // This can be read in the server log: not a single rejected
                // login, but "Unexpected end of request content" at exactly those
                // times. The message stayed afterwards because nothing cleared it —
                // so only signing out and in again helped, which rebuilds
                // everything.
                //
                // The cancellation is passed on as what it is. Whoever catches it
                // should be able to recognise it.
                throw CancellationError()
            } catch  where attempt == 0 && Self.isWorthRetrying(error) {
                // **The attempt number and not a declaration of intent.** Here
                // "second attempt" stood, written *before* the second one ran — in the
                // report that looked like three attempts, and which took how long was
                // not recognisable at all.
                Diagnostics.failure(url, step: "Load data (attempt 1 of 2)", error: error)
                // **The second attempt needs a fresh line, otherwise it is
                // the same attempt.** That is exactly why the first approach failed: the
                // device's diagnostic report showed two timeouts
                // in a row on the same address — with a server that answers in fifty
                // milliseconds from another machine.
                //
                // tvOS releases network connections when an app goes to the background
                // ("socket resource reclaim", Technote 2277), but keeps the socket
                // in the pool. Whoever writes to it waits until the timeout and
                // gets no error — and because the pool holds several, it also catches
                // the second attempt. Apple names no remedy for this other than
                // one: catch it.
                //
                // `flush` is the place intended for this; its description says it
                // literally: future requests run over a **new** connection.
                guard !closed else { throw URLError(.cancelled) }
                await withCheckedContinuation { continuation in
                    session.flush { continuation.resume() }
                }
                continue
            } catch {
                Diagnostics.failure(url, step: "Load data", error: error)
                throw SourceFailure.unreachable
            }
        }
        // Reachable only if the second attempt also ended with `continue` — which
        // does not happen, because `attempt == 0` rules it out. The compiler does not know
        // that, and a `fatalError` at this point would be a bet.
        throw SourceFailure.unreachable
    }

    /// A tiny request, only to measure the response time.
    ///
    /// `System/Info/Public` and not the library: the response is a few hundred
    /// bytes and needs no key. What is to be measured is the path, not
    /// the server's work.
    public func reachable() async -> Bool {
        var request = URLRequest(url: credentials.serverURL.appending(path: "System/Info/Public"))
        // No cache — otherwise the second pass measures the device's
        // memory and not the network.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 5
        guard let (_, response) = try? await load(request),
            let http = response as? HTTPURLResponse
        else { return false }
        return http.statusCode == 200
    }

    /// The address of an arbitrary movie against which throughput can be measured.
    ///
    /// **On a real title and not on an invented file.** Only then
    /// is the server's disk part of the picture — and that is what fluctuates here between 52 and 452
    /// Mbit/s, depending on whether a second reader happens to be active.
    public func probeStreamURL() async -> URL? {
        let filter = Core.ItemFilter(kinds: [.movie], sortBy: .dateAdded, ascending: false, limit: 1)
        guard let libraries = try? await libraries(),
            let library = libraries.first(where: { $0.kind == .movies }),
            let item = try? await items(in: library.id, filter: filter).first
        else { return nil }

        var components = URLComponents(
            url: credentials.serverURL.appending(path: "Videos/\(item.id)/stream"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "api_key", value: credentials.accessToken),
        ]
        return components?.url
    }

    /// Fetches everything once that the overviews need and puts it in the
    /// cache.
    ///
    /// **So that not every view makes its own fetch when it is opened
    /// for the first time.** Before, "Movies" loaded on entering, "Series" on entering, and
    /// both again as soon as the cache expired after two minutes — on
    /// a line where a request can stall for six seconds, that is every
    /// time a wait in front of an empty screen.
    ///
    /// Runs **sequentially** on launch and not concurrently: simultaneous fetches
    /// are exactly what this connection does not tolerate — in the report, under
    /// load three of twelve requests did not arrive at all.
    ///
    /// - Parameter delay: How long to wait before the first fetch.
    ///
    ///   **Home goes first.** It fires its fetches in the first
    ///   moments; if the prewarm started at the same time, both would fight over
    ///   the same line — and Home is the one someone is looking at.
    ///   Thanks to deduplication the wait is no loss anyway: what Home
    ///   has already requested, the prewarm finds as a running
    ///   or finished fetch and attaches to it.
    public func prewarm(delayedBy delay: Duration = .seconds(2)) async {
        try? await Task.sleep(for: delay)
        guard let libraries = try? await libraries() else { return }
        for library in libraries {
            // **Exactly the key that the views hit.** Previously the view's
            // sort order had to be guessed for this — and for
            // home videos that went wrong because they ask descending by date added.
            // Since the key consists only of library and kinds,
            // the sort order does not matter; `PrewarmTests` keeps holding the kinds
            // against the version in `Features`.
            let kinds = Self.itemKinds(for: library.kind)
            // Without kinds (music, live) no view asks — a fetch without
            // `IncludeItemTypes` would fetch the complete catalog there for nothing.
            guard !kinds.isEmpty else { continue }
            _ = try? await items(in: library.id, filter: Core.ItemFilter(kinds: kinds))
        }
        _ = try? await resumable(limit: 12)
    }

    /// Which kinds a library of this sort contains.
    ///
    /// **The board has been in `Core` since AP58 R6** (``Core/Library/Kind/overviewKinds``) —
    /// the same one Home and library ask for; see ``prewarm()``.
    public nonisolated static func itemKinds(for kind: Core.Library.Kind) -> [MediaItem.Kind] {
        kind.overviewKinds
    }

    /// Discards everything remembered — memory **and** snapshots — and passes the word on.
    ///
    /// For the button "Sync now" in Settings: without it a
    /// newly added title would stay invisible for up to an hour, and there would be no
    /// way to shorten that. The notification at the end makes the open
    /// views reload — their next fetch then necessarily goes to the
    /// server, because nothing lies here any more.
    public func forgetCachedLists() {
        cache.removeAll()
        libraryList = nil
        counts.removeAll()
        snapshots.removeAll()
        notifyListsChanged()
    }

    /// Ends the session and releases its connections.
    ///
    /// Must be called when a source is no longer needed — a
    /// `URLSession` with a delegate otherwise keeps itself alive, along with everything in
    /// its connection pool.
    ///
    /// Afterwards the source rejects every request with `URLError(.cancelled)` instead of handing it to the
    /// finished session. The session itself is ended only after a grace period:
    /// a request that has already passed the lock but is still on its way
    /// to `data(for:)` would otherwise land exactly in the gap in between.
    public func close() {
        guard !closed else { return }
        closed = true
        session.getAllTasks { $0.forEach { $0.cancel() } }
        Task { [session] in
            try? await Task.sleep(for: .seconds(30))
            session.invalidateAndCancel()
        }
    }

    /// Every request of this source goes through here — see ``closed``.
    private func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard !closed else { throw URLError(.cancelled) }
        return try await session.data(for: request)
    }

    /// Whether a second attempt can help.
    ///
    /// Only for line disturbances. Everything else — a rejected login, an
    /// unreadable result — would come back the same way the second time and would cost only
    /// waiting before the same message.
    static func isWorthRetrying(_ error: any Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

    /// Whether an error was in truth a cancellation.
    ///
    /// Two forms occur, and both do happen: `CancellationError` from Swift's
    /// concurrency, and `URLError.cancelled` from `URLSession` — depending
    /// on whether the cancellation catches the task or the request first.
    static func wasCancelled(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    /// Sends a message about the playback state and does **not** evaluate the response.
    ///
    /// Intent, not negligence. These three messages accompany
    /// playback, they do not carry it: a failure must not abort a running movie.
    /// With progress that would happen every few seconds.
    ///
    /// That this is no hypothetical case was shown by the test server: if no user is attached
    /// to the session — when signing in via a server key instead
    /// of via a user account —, a plugin module of the server interferes in the
    /// aftermath, and `Sessions/Playing/Progress` answers with 400 **although**
    /// the state arrived and could be read under `Sessions` with position and pause flag.
    /// Whoever takes the status code for the truth aborts on an
    /// error that does not exist.
    private func announce<Body: Encodable>(_ path: String, body: Body, step: String) async {
        let url = credentials.serverURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")

        do {
            request.httpBody = try JSONEncoder().encode(body)
            // **The status code counts here too** (AP6 · Q5). A rejected
            // session report used to pass as done: in the
            // server's web interface the device then does not appear, the
            // progress has nothing to attach to — and the trace
            // says nothing about it.
            //
            // Nothing is thrown anyway: ``beginSession(for:)`` and
            // ``endSession(for:at:)`` carry their `throws` as inherited decoration,
            // and their error path in the player never runs. What was missing is the
            // **information**, not a second dead path.
            let (_, response) = try await load(request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                Diagnostics.failure(url, step: step, error: SourceFailure.badRequest)
            }
        } catch {
            Diagnostics.failure(url, step: step, error: error)
        }
    }

    /// Seconds into the hundred-nanosecond units the server expects.
    ///
    /// Unusable values become zero and are not passed on. The reason lies
    /// with the engines: whoever asks for the position before the first frame gets
    /// an occasional value below zero from VLC and `NaN` from AVFoundation when the
    /// duration is still unknown. The server would take the former as state —
    /// "Continue Watching" then starts at a time that does not exist. The latter
    /// and any value beyond the number range aborts the program at the conversion to `Int`,
    /// right in the middle of a running playback.
    static func ticks(_ seconds: TimeInterval) -> Int {
        guard seconds > 0, seconds.isFinite,
            let ticks = Int(exactly: (seconds * ItemMapping.ticksPerSecond).rounded())
        else { return 0 }
        return ticks
    }

    /// Serves from the cache — and waits only if there is really nothing there.
    ///
    /// The order is the concept, which is why it is spelled out here:
    ///
    /// 1. **Fresh entry** → return immediately.
    /// 2. **Expired entry** → return immediately anyway, and fetch fresh
    ///    in the background; if the result differs, ``listChanges()`` fires.
    /// 3. **Running fetch** for the same key → attach instead of asking twice.
    /// 4. **Snapshot from disk** → like an expired entry: show
    ///    immediately, confirm in the background. This is the cold-start case — the
    ///    view is up before the server has sent the first byte.
    /// 5. Only with no stock at all is there a wait.
    ///
    /// The fetch runs as a task of its own, detached from the waiter: if the
    /// viewer switches the area, their view cancels — the fetch runs to completion
    /// and fills the cache for next time.
    ///
    /// Not `private` so that the checks can play through deduplication and expiry behavior
    /// without a server.
    func cachedItems(
        key: String,
        lifetime: Duration? = nil,
        persisted: Bool = true,
        load: @escaping @Sendable () async throws -> [MediaItem]
    ) async throws -> [MediaItem] {
        let maxAge = lifetime ?? cacheLifetime

        if let entry = cache[key] {
            if !entry.fromSnapshot, entry.stored.duration(to: .now) < maxAge {
                return entry.items
            }
            refreshList(key: key, persisted: persisted, load: load)
            return entry.items
        }
        if let running = inFlightLists[key] {
            return try await running.value
        }
        if persisted, let stored = snapshots.load([MediaItem].self, key: key) {
            // The read blocks the actor for milliseconds — measured against the
            // network with seconds to the first byte, that is the cheap way.
            cache[key] = CachedList(items: stored, stored: .now, fromSnapshot: true)
            refreshList(key: key, persisted: persisted, load: load)
            return stored
        }

        let task = Task { try await load() }
        inFlightLists[key] = task
        defer { inFlightLists[key] = nil }
        let items = try await task.value
        cache[key] = CachedList(items: items, stored: .now, fromSnapshot: false)
        if persisted { snapshots.save(items, key: key) }
        return items
    }

    /// Fetches a list anew without anyone waiting for it.
    private func refreshList(
        key: String,
        persisted: Bool,
        load: @escaping @Sendable () async throws -> [MediaItem]
    ) {
        guard inFlightLists[key] == nil else { return }
        let task = Task { try await load() }
        inFlightLists[key] = task
        Task {
            // Errors bewusst still: the old data is already on screen,
            // the next access tries again — a message about a
            // failed sync that nobody triggered would only confuse.
            let items = try? await task.value
            inFlightLists[key] = nil
            guard let items else { return }
            let changed = cache[key]?.items != items
            cache[key] = CachedList(items: items, stored: .now, fromSnapshot: false)
            if persisted { snapshots.save(items, key: key) }
            if changed { notifyListsChanged() }
        }
    }

    // MARK: - Wer vom stillen Austausch erfahren will

    /// Reports when a list was replaced in the background.
    ///
    /// **The missing piece of the cache-first path.** Whoever was served immediately from the
    /// snapshot sees an old state — somebody has to tell them
    /// that something new has arrived in the meantime. The views' models listen
    /// here and then reload from the (now fresh) cache; a network fetch
    /// no longer results from it.
    ///
    /// `bufferingNewest(1)`: when four libraries are confirmed one after
    /// the other on launch, the message "there were changes" is enough for the listener —
    /// four queued repetitions of it would be four superfluous rebuilds.
    ///
    /// **`async`, although nothing waits here** — and that is not cosmetic
    /// but the lesson from the finding of 2026-08-13. (spelled out at
    /// ``ContentSource/listChanges()``): when `async` was absent here, the call
    /// on the concrete type deviated to the contract's default of the same name
    /// — a stream that ends immediately. The signature must match the contract to the
    /// letter, otherwise with two candidates the wrong one wins.
    public func listChanges() async -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            listObservers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.removeListObserver(id) }
            }
        }
    }

    private func removeListObserver(_ id: UUID) {
        listObservers[id] = nil
    }

    private func notifyListsChanged() {
        for continuation in listObservers.values {
            continuation.yield()
        }
    }

    /// Discards the cache — after a playback, for instance, the
    /// progress changes, and then the old state must not appear.
    /// The snapshots go along, for the same reason.
    public func invalidateCache() {
        cache.removeAll()
        libraryList = nil
        counts.removeAll()
        snapshots.removeAll()
    }

    /// Which fields the server should deliver along.
    ///
    /// `ParentBackdropImageTags` and `ParentThumbImageTag` are indispensable:
    /// episodes carry no backdrop of their own, only the series. Without this
    /// parameter the header area of Home stays empty — that was exactly the case.
    /// `SortName` was added when ordering became client-side: the server
    /// sorts titles by this name (articles stripped), and whoever orders on their own
    /// needs the same key — otherwise "The Prouklaus" would be filed under T.
    static let listFields = [
        "Overview", "Genres", "ProductionYear", "CommunityRating", "CriticRating",
        "ProviderIds", "ImageTags", "BackdropImageTags", "UserData", "RunTimeTicks",
        "OfficialRating", "Studios", "ParentBackdropItemId", "ParentBackdropImageTags",
        "ParentLogoItemId", "ParentThumbItemId", "SeriesId", "IsFolder",
        "DateCreated", "PremiereDate", "ChildCount", "RecursiveItemCount", "SortName",
        // **`PrimaryImageAspectRatio` has to be requested** — measured on 2026-09-08:
        // without this field it is missing in **22 of 22** responses, with it it is in
        // all of them. It carries the image format and thus the frame in which a tile
        // is drawn; see ``ItemMapping/wideImage(_:)``.
        "PrimaryImageAspectRatio",
    ].joined(separator: ",")
    static let detailFields = listFields + ",MediaSources,People,Taglines"

    static func sortField(_ sortBy: Core.ItemFilter.SortBy) -> String {
        switch sortBy {
        case .title: "SortName"
        case .dateAdded: "DateCreated"
        case .dateCreated: "PremiereDate,ProductionYear"
        case .rating: "CommunityRating"
        // The media server has no notion of "as delivered" — it delivers what it
        // sorts. For it the usual order stays; `.natural` belongs to the
        // portals, whose lists bring an order of their own.
        case .natural: "SortName"
        }
    }

    /// Whether an entry is a pure directory — as opposed to series and
    /// seasons, which the server also lists as folders.
    static func isPlainFolder(_ dto: BaseItemDto) -> Bool {
        switch dto.type {
        case .folder, .collectionFolder, .userView, .aggregateFolder, .playlistsFolder:
            true
        default:
            false
        }
    }

    /// What the media server calls this kind — `nil` if it does not know it.
    ///
    /// **Explicitly `nil` and not the empty string.** `.separator`
    /// is a subheading from a portal; the server knows nothing
    /// like it. An empty value in `IncludeItemTypes` there would mean
    /// not "nothing" but **"everything"** — a query for an
    /// entry type that does not exist would thus return the whole catalog.
    static func itemType(_ kind: MediaItem.Kind) -> String? {
        switch kind {
        case .series: "Series"
        case .season: "Season"
        case .episode: "Episode"
        case .movie: "Movie"
        case .homeVideo: "Video"
        case .channel: "TvChannel"
        case .collection: "BoxSet"
        // The server manages folders itself — see ``isPlainFolder``.
        case .folder: "Folder"
        case .separator: nil
        }
    }

    // MARK: - Antwortformen
}
