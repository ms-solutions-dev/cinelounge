import Core
import Foundation

/// A ``Core/ContentSource`` that books its viewer's progress into the ``Core/StillLedger``
/// — **and changes nothing else.**
///
/// **The finding of AP42** (2026-09-19): "All progress must hang off the profile — IPTV
/// too." Before, the booking lived **in** ``XtreamVODSource``, with the reasoning that an
/// Xtream panel has no user state. The reasoning is right; the conclusion was
/// not: it follows that the state lives locally, not that it belongs to the *source*.
/// It belongs to the person who sat in front of it — and the next source without server state (an
/// M3U library, the cache) would have had to write the same thing again.
///
/// ## What is passed through and what is not
///
/// **Jellyfin and the portals pass through.** They answer
/// ``Core/ContentSource/tracksStateItself`` with `true`, and then this wrapper does **nothing
/// at all** — every call goes on unchanged. With the media server it has to be this way:
/// Jellyfin knows what has been watched, and whoever kept track on the side here would have two
/// truths as soon as someone watches something on the phone. That makes the wrapper **harmless
/// everywhere** — even over itself, because it also keeps its state itself.
///
/// ## Everything spelled out, nothing inherited
///
/// **Not a single default of the contract is used**, and with a wrapper that is not a
/// formality: an inherited default would answer *for* the wrapped source instead of asking
/// it — `trailer(for:)` would give `nil` although the source has one, and `collections()`
/// an empty list above a full shelf. That is the finding of 2026-08-13 in its
/// nastiest form: there a default cut one wire, here it would cut **all** of them.
///
/// ## Generic, so that the source keeps its own capabilities
///
/// ``XtreamVODSource`` can do more than the contract requires — `search(term:limit:)`,
/// `prewarmSearch()`, `libraries(for:)`. Wrapped as `any ContentSource` they would be gone,
/// and search on the TV would silently fall back to the media server. Through the
/// generic parameter they stay reachable; the forwarding lives in ``ProviderSource``.
public actor StateSource<Source: ContentSource>: ContentSource {

    /// **`nonisolated let`**, so that the queries needed while drawing
    /// (``displayName``, ``imageURL(itemID:kind:width:tag:)``) do not wait on an actor.
    public nonisolated let source: Source

    private let state: VODMemory

    /// Whether this wrapper does anything at all. Fixed at construction — see above.
    private nonisolated let books: Bool

    /// - Parameter buch: Where the Standbuch files live. In production ``Core/FileStore``.
    public init(_ source: Source, ledger: any KeyValueStore) {
        self.source = source
        self.state = VODMemory(store: ledger)
        self.books = !source.tracksStateItself
    }

    // MARK: - What makes up the wrapper

    public nonisolated var tracksStateItself: Bool { true }

    /// Inserts the remembered state into fresh titles.
    ///
    /// **Over every query that returns titles**, and not only over the lists: Whoever opens a
    /// detail page from a collection has never seen the title in a list
    /// — its progress bar would sit at zero.
    private func enriched(_ title: [MediaItem]) async -> [MediaItem] {
        guard books else { return title }
        return await state.enrich(title)
    }

    private func enriched(_ title: MediaItem) async -> MediaItem {
        await enriched([title]).first ?? title
    }

    // MARK: - Titel

    public func libraries() async throws -> [Library] { try await source.libraries() }

    public func items(in library: Library.ID, filter: ItemFilter) async throws -> [MediaItem] {
        await enriched(try await source.items(in: library, filter: filter))
    }

    public func itemCount(in library: Library.ID, filter: ItemFilter) async throws -> Int? {
        try await source.itemCount(in: library, filter: filter)
    }

    public func item(id: String) async throws -> MediaItem {
        await enriched(try await source.item(id: id))
    }

    public func children(of itemID: String) async throws -> [MediaItem] {
        await enriched(try await source.children(of: itemID))
    }

    public func episodes(of seriesID: String) async throws -> [MediaItem] {
        await enriched(try await source.episodes(of: seriesID))
    }

    public func collections() async throws -> [MediaItem] {
        await enriched(try await source.collections())
    }

    public func similarItem(to itemID: String) async throws -> MediaItem? {
        guard let match = try await source.similarItem(to: itemID) else { return nil }
        return await enriched(match)
    }

    public func similarItems(to itemID: String, limit: Int) async throws -> [MediaItem] {
        await enriched(try await source.similarItems(to: itemID, limit: limit))
    }

    public func trailer(for itemID: String) async throws -> MediaItem? {
        // **Not enriched.** A trailer is not a title you resume; nobody would
        // ever have set a progress bar on it.
        try await source.trailer(for: itemID)
    }

    public func nextEpisode(after itemID: String) async throws -> MediaItem? {
        guard let episode = try await source.nextEpisode(after: itemID) else { return nil }
        return await enriched(episode)
    }

    // MARK: - Der Stand

    /// The started titles — **from the book and without a fetch at the provider.**
    ///
    /// **The old data is resolved one by one**, but only as far as there is still room
    /// in the list: Whoever started before the rebuild should find their movie again, and a
    /// title the provider no longer knows silently drops out. The reasoning
    /// is given in detail at ``VODMemory/resumableWithoutProfile(limit:)``.
    public func resumable(limit: Int) async throws -> [MediaItem] {
        guard books else { return try await source.resumable(limit: limit) }

        var found = await state.resumable(limit: limit)
        guard found.count < limit else { return found }

        for identifier in await state.resumableWithoutProfile(limit: limit - found.count) {
            if var title = try? await item(id: identifier) {
                title.lastWatched = await state.lastWatched(identifier)
                found.append(title)
            }
        }
        return found
    }

    /// The marked titles, resolved through the single fetch.
    ///
    /// **One fetch per mark is deliberately good enough**: Favorites are few, and the
    /// single fetch brings plot and image along. A title the provider no
    /// longer knows silently drops out of the list — the mark stays in case it returns.
    public func favorites() async throws -> [MediaItem] {
        guard books else { return try await source.favorites() }

        var title: [MediaItem] = []
        for identifier in await state.favoriteIDs {
            if let entry = try? await item(id: identifier) { title.append(entry) }
        }
        return title
    }

    /// **Booked and passed on anyway.** The source learns of every report — it may
    /// discard its cache on it or keep a session. It no longer books;
    /// that is the point of this wrapper.
    public func report(progress: PlaybackProgress, for itemID: String, isPaused: Bool) async throws {
        if books {
            await state.setPosition(progress.position, of: progress.duration, for: itemID)
        }
        try await source.report(progress: progress, for: itemID, isPaused: isPaused)
    }

    /// "Unwatched" also takes the position — as with the media server, see
    /// ``PortalKit/PortalSource/setPlayed(_:for:)``.
    public func setPlayed(_ isPlayed: Bool, for itemID: String) async throws {
        if books {
            await state.setWatched(isPlayed, for: itemID)
            if !isPlayed { await state.setPosition(0, of: nil, for: itemID) }
        }
        try await source.setPlayed(isPlayed, for: itemID)
    }

    public func setFavorite(_ isFavorite: Bool, for itemID: String) async throws {
        if books { await state.setFavorite(isFavorite, for: itemID) }
        try await source.setFavorite(isFavorite, for: itemID)
    }

    public func beginSession(for itemID: String) async throws {
        try await source.beginSession(for: itemID)
    }

    public func endSession(for itemID: String, at position: TimeInterval) async throws {
        if books { await state.setPosition(position, of: nil, for: itemID) }
        try await source.endSession(for: itemID, at: position)
    }

    // MARK: - Durchgereicht

    public nonisolated var displayName: String { source.displayName }
    public nonisolated var canStartAtOffset: Bool { source.canStartAtOffset }

    public func segments(for itemID: String) async throws -> [MediaSegment] {
        try await source.segments(for: itemID)
    }

    public func streamURL(for itemID: String, decision: PlaybackDecision) async throws -> URL {
        try await source.streamURL(for: itemID, decision: decision)
    }

    public func trickplay(for itemID: String) async throws -> Trickplay? {
        try await source.trickplay(for: itemID)
    }

    public nonisolated func imageURL(
        itemID: String, kind: ImageKind, width: Int, tag: String?
    ) -> URL? {
        source.imageURL(itemID: itemID, kind: kind, width: width, tag: tag)
    }

    public func listChanges() async -> AsyncStream<Void> { await source.listChanges() }

    public func refreshAfterPlayback(ids: [String]) async {
        await source.refreshAfterPlayback(ids: ids)
    }

    public func reloadContinueWatching() async { await source.reloadContinueWatching() }

    /// Passed through — the collected query of the source underneath (AP58 R1, K6).
    public func seriesApprovals(forItem allSeries: [String]) async throws -> [SeriesClearance] {
        try await source.seriesApprovals(forItem: allSeries)
    }

    /// **Searched once, then remembered** (product decision 2026-10-01: also store the link
    /// itself on top). The match via the series catalog costs one fetch; the result
    /// is then in the info card and travels with the state to the other devices.
    /// The position to zero — the title drops out of "started" (``VODMemory``), and the
    /// event travels via the journal to the other devices.
    public func removeFromContinueWatching(_ itemID: String) async throws {
        guard books else { return try await source.removeFromContinueWatching(itemID) }
        await state.setPosition(0, of: nil, for: itemID)
    }

    public func seriesReference(zu item: MediaItem) async -> String? {
        if let series = item.seriesID { return series }
        if books, let remembered = await state.series(forItem: item.id) { return remembered }
        guard let found = await source.seriesReference(zu: item) else { return nil }
        if books { await state.rememberSeries(found, forItem: item.id) }
        return found
    }
}

/// The wrapped provider source — **the type the UI holds.**
///
/// One name instead of `StateSource<XtreamVODSource>` in eight places, and at the same time the answer
/// to the question why the wrapper has a generic parameter at all: so that ``XtreamVODSource``
/// keeps its capabilities that go beyond the contract.
public typealias ProviderSource = StateSource<XtreamVODSource>

extension StateSource where Source == XtreamVODSource {

    /// The categories of **one** list — for the area of a single provider.
    public func libraries(for playlistID: String) async -> [Library] {
        await source.libraries(for: playlistID)
    }

    /// The search across all provider lists.
    ///
    /// **Enriched like any other result list.** Before AP42 ``XtreamVODSource`` did this
    /// itself; whoever had wrapped it as `any ContentSource` back then would have lost the search
    /// without anything turning red — the contract does not know it.
    public func search(term: String, limit: Int = 60) async throws -> [MediaItem] {
        await enriched(try await source.search(term: term, limit: limit))
    }

    /// Warms up the search cache — nothing to book, nothing to enrich.
    public func prewarmSearch() async throws { try await source.prewarmSearch() }
}
