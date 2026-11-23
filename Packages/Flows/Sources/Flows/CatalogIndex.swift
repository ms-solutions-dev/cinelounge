import Core
import Foundation
import ParentalControls

/// The own catalog, collected once — **for "do I have this?" in the filmography and
/// for counting the releases** (AP58 R6, St6).
///
/// **Previously built twice** (report A): `LibraryIndexStore` on the TV and
/// `CatalogIndex` on the phone, almost line for line the same — cache, one load
/// at a time, title sorting, slim copies for the filter. The board "library kind →
/// title kind" existed three times as well; it now lives in ``Core/Library/Kind/overviewKinds``.
///
/// **Why an actor:** It is asked from a background task while a filmography loads, and
/// two filmographies in quick succession must not collect the catalog twice. A running
/// task also serves the second asker.
///
/// **Collection happens only on demand**, not at launch — a fetch at launch has already
/// choked the Home screen twice (08-01, 08-08).
///
/// **Filtering happens when asked** (AP58 R1): The store holds the whole catalog because
/// the release count needs it; ``index(from:rule:)`` builds the index over what the
/// rule shows. The "have it" marker thus never reveals a title that a child does not see.
public actor CatalogIndex {

    public static let shared = CatalogIndex()

    /// What was collected.
    public struct CatalogSurvey: Sendable {
        public var approvals: [String: Int] = [:]
        /// **Slim copies** — ID, kind, title, year and what the filter needs. A thousand
        /// of them weigh less than one poster.
        public var title: [MediaItem] = []

        public var index: LibraryIndex { LibraryIndex(title) }
        public var isEmpty: Bool { title.isEmpty }
    }

    /// Who a catalog belongs to — **source, profile and point in time** (check 2026-09-27, D4).
    ///
    /// **Previously the first catalog held forever.** The marker knew neither the source nor
    /// the profile, and nobody called ``forget()``. A child with its own Jellyfin account saw
    /// in the filmography the titles from the household library as "in the catalog", a
    /// tap opened a foreign ID, and the release count counted the account seen
    /// first. **The source is held and compared with `===`**, not via
    /// an ID: The ID of a released source can be inherited by the next one. An
    /// account or server switch builds a new source on both devices; the
    /// profile switch is in ``Core/ProfilePointer/active``.
    private struct Owner {
        let source: AnyObject?
        let profile: String?
        let since: Date

        /// Whether this catalog applies to this source and the active profile.
        ///
        /// **A source that is not a reference type never applies** — its identity cannot
        /// be held, and then it collects anew instead of guessing.
        func applies(
            forItem source: any ContentSource, now: Date, lifetime: TimeInterval
        )
            -> Bool
        {
            guard let own = self.source, let other = Self.reference(source), own === other
            else { return false }
            return profile == ProfilePointer.active && now.timeIntervalSince(since) < lifetime
        }

        static func reference(_ source: any ContentSource) -> AnyObject? {
            type(of: source) is AnyClass ? source as AnyObject : nil
        }
    }

    /// How long a collected catalog applies — **after that it is collected anew.**
    ///
    /// A title that arrived after the first collection never showed as
    /// "in the catalog" until the restart. A quarter of an hour is the trade-off: One filmography after the
    /// other does not ask the server every time, and a new film shows up after an
    /// evening.
    public static let lifetime: TimeInterval = 15 * 60

    private var remembered: (survey: CatalogSurvey, owner: Owner)?
    private var isRunning: (job: Task<CatalogSurvey, Never>, owner: Owner)?
    private let duration: TimeInterval
    private let clock: @Sendable () -> Date

    public init(
        lifetime: TimeInterval = CatalogIndex.lifetime,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.duration = lifetime
        self.clock = clock
    }

    /// The release count, **if collection has already happened** — otherwise `nil`.
    ///
    /// Only while the catalog belongs to the active profile; after a switch the
    /// count would otherwise see the releases of another one.
    public func countedRatings() -> [String: Int]? {
        guard let remembered, remembered.owner.profile == ProfilePointer.active else { return nil }
        return remembered.survey.approvals
    }

    /// Fetches the catalog — once per source and profile, then from the store.
    ///
    /// **An empty result is not kept**: Its most common cause is the connection,
    /// not an empty shelf.
    public func survey(from source: any ContentSource) async -> CatalogSurvey {
        let now = clock()
        if let remembered, remembered.owner.applies(forItem: source, now: now, lifetime: duration) {
            return remembered.survey
        }
        if let isRunning, isRunning.owner.applies(forItem: source, now: now, lifetime: duration) {
            return await isRunning.job.value
        }
        let owner = Owner(
            source: Owner.reference(source), profile: ProfilePointer.active, since: now)
        let job = Task { await Self.collect(from: source) }
        isRunning = (job, owner)
        let result = await job.value
        if isRunning?.owner.since == owner.since, isRunning?.owner.source === owner.source {
            isRunning = nil
        }
        if !result.isEmpty, (remembered?.owner.since ?? .distantPast) <= owner.since {
            remembered = (result, owner)
        }
        return result
    }

    /// The index over what the rule shows.
    public func index(
        from source: (any ContentSource)?, rule: ProtectionRule
    ) async
        -> LibraryIndex
    {
        guard let source else { return LibraryIndex() }
        return LibraryIndex(rule.filter(await survey(from: source).title))
    }

    /// Forget — after a sync. ``survey(from:)`` detects account and profile switches
    /// by itself.
    public func forget() { remembered = nil }

    /// Marks on each entry of a filmography whether and where it is in the catalog.
    public nonisolated static func mark(
        _ entries: [FilmographyEntry], against index: LibraryIndex
    ) -> [FilmographyEntry] {
        guard !index.isEmpty else { return entries }
        return entries.map { entry in
            var marked = entry
            marked.libraryItemID = index.itemID(forTitle: entry.title, year: entry.year)
            return marked
        }
    }

    private static func slim(_ title: MediaItem) -> MediaItem {
        var slim = MediaItem(
            id: title.id, kind: title.kind, title: title.title, seriesID: title.seriesID,
            year: title.year, ageRating: title.ageRating)
        slim.seriesClearance = title.seriesClearance
        slim.seriesClearanceChecked = title.seriesClearanceChecked
        return slim
    }

    /// **No upper limit**: "Do I have this?" must not depend on whether a title is among the
    /// first hundred.
    private static func collect(from source: any ContentSource) async -> CatalogSurvey {
        guard let libraries = try? await source.libraries() else { return CatalogSurvey() }
        var title: [MediaItem] = []
        for library in libraries {
            let kinds = library.kind.overviewKinds
            guard !kinds.isEmpty else { continue }
            let filter = ItemFilter(kinds: kinds, sortBy: .title, ascending: true)
            guard let found = try? await source.items(in: library.id, filter: filter)
            else { continue }
            title += found
        }
        var approvals: [String: Int] = [:]
        for entry in title {
            approvals[ApprovalMirror.key(forItem: entry.ageRating), default: 0] += 1
        }
        return CatalogSurvey(approvals: approvals, title: title.map(slim))
    }
}
