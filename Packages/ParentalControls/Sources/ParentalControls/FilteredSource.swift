import Core
import Diagnose
import Foundation

/// The media server, **seen through the age limit.**
///
/// **The filter acts before a list is built** — not after. A locked title that is only
/// struck through in the finished list was visible for a moment, and in a search it would
/// be in the hit count. Titles above the limit are **not greyed out, they are not there**;
/// a locked title that stays visible is an invitation.
///
/// **A wrapper around the source and no check in the views.** Home, library, search and
/// detail page ask the same source; if each of them filtered itself, there would be four
/// places with the same rule — and at the next screen five, of which one is missing. This
/// kind of gap was exactly the most serious finding of the usability pass.
///
/// **Only the media server carries ratings.** `MediaItem.ageRating` is filled in exactly
/// one place in the whole shared set (`JellyfinKit/ItemMapping`); the provider catalog
/// delivers none, the channels none and the portals none. For those this wrapper has no
/// effect, and that is why they drop out **entirely** in child mode
/// (``TabScope/delivers(_:isInChildMode:)``) — a limit needs something to attach
/// to.
///
/// **In the shared package since AP58 R1** (finding K3). Until then it existed only on the
/// phone; the TV filtered itself at every call site, and every new list had to remember
/// that. Now it builds Home, libraries, search and catalog index through this as well.
///
/// **Complete, including the side paths** (finding K3): collections are passed on and
/// filtered (until here the wrapper always returned `[]`), the trailer is filtered, and a
/// single title via ``item(id:)`` reports ``ChildProtectionError/locked``.
public struct FilteredSource: PageSource {

    /// The source underneath — for callers that read the origin from it.
    public let source: any ContentSource
    public let rule: ProtectionRule

    public init(source: any ContentSource, rule: ProtectionRule) {
        self.source = source
        self.rule = rule
    }

    public var displayName: String { source.displayName }
    public nonisolated var canStartAtOffset: Bool { source.canStartAtOffset }

    /// **Passed through and not answered.**
    ///
    /// This wrapper filters titles; it says nothing about progress. A fixed `true` would mean
    /// "I keep it myself" — then `StateSource` would no longer create one over a filtered
    /// provider source, and the child's progress would be lost. A fixed `false` would be just
    /// as wrong for the media server: then the wrapper would book a second time next to the
    /// server.
    public nonisolated var tracksStateItself: Bool { source.tracksStateItself }

    private func filter(_ title: [MediaItem]) -> [MediaItem] {
        rule.filter(title)
    }

    private func single(_ title: MediaItem?) -> MediaItem? {
        title.flatMap { filter([$0]).first }
    }

    // MARK: - Was gefiltert wird

    public func libraries() async throws -> [Library] { try await source.libraries() }

    public func items(in library: Library.ID, filter predicate: ItemFilter) async throws -> [MediaItem] {
        filter(try await source.items(in: library, filter: predicate))
    }

    /// **Filtered like any other list** — the second and the twentieth page as well (AP60).
    ///
    /// If the source underneath knows no pages, a single piece comes back to it without a
    /// marker.
    public func page(
        in library: Library.ID, filter predicate: ItemFilter, next: String?,
        progress: @Sendable (Int) async -> Void
    ) async throws -> PageChunk {
        guard let pagedSource = source as? any PageSource else {
            return PageChunk(items: try await items(in: library, filter: predicate), next: nil)
        }
        let piece = try await pagedSource.page(
            in: library, filter: predicate, next: next, progress: progress)
        return PageChunk(items: filter(piece.items), next: piece.next)
    }

    /// **No number is better than a wrong one.**
    ///
    /// The server counts what it has, not what this account may see — writing the one over
    /// the other would be finding M2 of 05.09. all over again: there, 5,389 stood above a list
    /// of 2,055 entries. Counting it ourselves would mean fetching every catalog completely,
    /// just to put a number under a line.
    public func itemCount(in library: Library.ID, filter: ItemFilter) async throws -> Int? {
        guard !rule.applies else { return nil }
        return try await source.itemCount(in: library, filter: filter)
    }

    public func children(of itemID: String) async throws -> [MediaItem] {
        filter(try await source.children(of: itemID))
    }

    public func resumable(limit: Int) async throws -> [MediaItem] {
        filter(try await source.resumable(limit: limit))
    }

    public func favorites() async throws -> [MediaItem] {
        filter(try await source.favorites())
    }

    public func similarItems(to itemID: String, limit: Int) async throws -> [MediaItem] {
        filter(try await source.similarItems(to: itemID, limit: limit))
    }

    public func episodes(of seriesID: String) async throws -> [MediaItem] {
        filter(try await source.episodes(of: seriesID))
    }

    /// **The side paths too.** "Similar title" and "next episode" bypass every list; a filter
    /// that left them out would have a hole exactly where nobody looks.
    public func similarItem(to itemID: String) async throws -> MediaItem? {
        single(try await source.similarItem(to: itemID))
    }

    public func nextEpisode(after itemID: String) async throws -> MediaItem? {
        single(try await source.nextEpisode(after: itemID))
    }

    public func trailer(for itemID: String) async throws -> MediaItem? {
        single(try await source.trailer(for: itemID))
    }

    /// Collections are titles themselves and carry a rating of their own.
    public func collections() async throws -> [MediaItem] {
        filter(try await source.collections())
    }

    /// **Passed through**: A series' rating is the information that is used for filtering â
    /// filtering it itself would mean calling a locked series "not determinable".
    public func seriesApprovals(forItem allSeries: [String]) async throws -> [SeriesClearance] {
        try await source.seriesApprovals(forItem: allSeries)
    }

    /// Passed through — the series itself then goes through ``item(id:)`` and thus through
    /// the filter.
    public func seriesReference(zu item: MediaItem) async -> String? {
        await source.seriesReference(zu: item)
    }

    public func removeFromContinueWatching(_ itemID: String) async throws {
        try await source.removeFromContinueWatching(itemID)
    }

    // MARK: - Was durchgereicht wird

    /// **A single title is filtered** (AP58 R1, finding K3/K4).
    ///
    /// Until now this said "an ID comes from a filtered list". That was not true: the phone's
    /// history led IDs past every list, and the detail page fetched the title that way
    /// unfiltered. A locked title now reports ``ChildProtectionError/locked`` — the page shows
    /// an error instead of the title, and a playback path that depends on it does not play.
    public func item(id: String) async throws -> MediaItem {
        let title = try await source.item(id: id)
        guard single(title) != nil else {
            Diagnose.hint(.parentalControls, "Single fetch locked (filter was bypassed on the direct path)")
            throw ChildProtectionError.locked
        }
        return title
    }

    public func segments(for itemID: String) async throws -> [MediaSegment] {
        try await source.segments(for: itemID)
    }

    public func streamURL(for itemID: String, decision: PlaybackDecision) async throws -> URL {
        try await source.streamURL(for: itemID, decision: decision)
    }

    public func report(progress: PlaybackProgress, for itemID: String, isPaused: Bool) async throws {
        try await source.report(progress: progress, for: itemID, isPaused: isPaused)
    }

    public func setPlayed(_ isPlayed: Bool, for itemID: String) async throws {
        try await source.setPlayed(isPlayed, for: itemID)
    }

    public func setFavorite(_ isFavorite: Bool, for itemID: String) async throws {
        try await source.setFavorite(isFavorite, for: itemID)
    }

    public func trickplay(for itemID: String) async throws -> Trickplay? {
        try await source.trickplay(for: itemID)
    }

    public func beginSession(for itemID: String) async throws {
        try await source.beginSession(for: itemID)
    }

    public func endSession(for itemID: String, at position: TimeInterval) async throws {
        try await source.endSession(for: itemID, at: position)
    }

    public nonisolated func imageURL(itemID: String, kind: ImageKind, width: Int, tag: String?) -> URL? {
        source.imageURL(itemID: itemID, kind: kind, width: width, tag: tag)
    }

    public func listChanges() async -> AsyncStream<Void> { await source.listChanges() }

    public func refreshAfterPlayback(ids: [String]) async {
        await source.refreshAfterPlayback(ids: ids)
    }

    public func reloadContinueWatching() async { await source.reloadContinueWatching() }
}

/// Why a single title does not arrive.
public enum ChildProtectionError: Error, Sendable, Equatable {
    /// Parental controls do not let it through.
    case locked
}

extension ProtectionRule {

    /// Puts the limit over a source — **or returns it unchanged.**
    ///
    /// Without an effective lock there is no wrapper: a forwarding layer that does nothing
    /// costs a hop on every call and hides the real source in every troubleshooting session.
    public func about(_ source: any ContentSource) -> any ContentSource {
        applies ? FilteredSource(source: source, rule: self) : source
    }
}
