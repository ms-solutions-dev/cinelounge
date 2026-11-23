import Core
import Diagnose
import Downloads

/// Catches up the series approval of **old** episode downloads (finding of 2026-09-25).
///
/// Since 2026-09-25 ``DownloadDescriber`` also stores whether the series' approval
/// was looked up; an episode without this information is blocked in kids mode
/// (``ParentalControls/ProtectionRule/shows(downloads:)``). That affected every episode download from
/// before. Here they are caught up, **as soon as the Jellyfin server answers** — at start and
/// after every network change.
///
/// **The same calculation as every list:** the description becomes the ``Core/MediaItem``
/// (``Downloads/DownloadDescription/approvalTitle``), ``Core/SeriesClearances/complete(_:fetch:)``
/// supplements it — collected, once per series —, and approval, series approval and the mark
/// "looked up" go back into the description. **Without an answer everything stays as it
/// is**, i.e. blocked.
///
/// **Only Jellyfin titles.** A portal or provider episode has no series on the
/// Jellyfin server, and in kids mode these origins deliver nothing anyway.
enum SeriesClearanceBackfill {

    /// Which descriptions still need a series approval.
    static func pending(_ all: [DownloadDescription]) -> [DownloadDescription] {
        all.filter {
            $0.series != nil && $0.seriesClearanceChecked != true
                && PlaybackJob.origin(zu: $0.id) == .jellyfin
        }
    }

    /// Looks up and writes into the ledger — **and returns how many it became.**
    ///
    /// **It is only read back when writing**, so that a description that was added or dropped
    /// during the fetch is not overwritten.
    @discardableResult
    static func backfill(
        in ledger: DescriptionLedger, approvals: SeriesClearances, fetch: SeriesClearances.Fetch
    ) async -> Int {
        let pendingItems = pending(ledger.read())
        guard !pendingItems.isEmpty else { return 0 }
        let completed = await approvals.complete(pendingItems.map(\.approvalTitle), fetch: fetch)
        let addedLater = Dictionary(
            completed.filter { $0.seriesClearanceChecked == true }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        guard !addedLater.isEmpty else { return 0 }
        let fresh = ledger.read().map { description -> DownloadDescription in
            guard let title = addedLater[description.id],
                description.seriesClearanceChecked != true
            else { return description }
            var changed = description
            changed.ageRating = title.ageRating
            changed.seriesClearance = title.seriesClearance
            changed.seriesClearanceChecked = true
            return changed
        }
        ledger.write(fresh)
        Diagnose.step(.downloads, "Downloads: series clearance backfilled for \(addedLater.count) episode(s)")
        return addedLater.count
    }

    /// The fetch via a content source — **collected where it can** (AP58 R1, K6).
    ///
    /// Until here the catch-up asked every series individually via `item(id:)`, because the
    /// Jellyfin server's collected fetch was private. Now it asks
    /// ``Core/ContentSource/seriesApprovals(forItem:)``: the Jellyfin server answers with one
    /// fetch per hundred series, every other source with the default over individual titles. A
    /// series that is missing stays open.
    static func fetch(about source: any ContentSource) -> SeriesClearances.Fetch {
        { allSeries in try await source.seriesApprovals(forItem: allSeries) }
    }
}
