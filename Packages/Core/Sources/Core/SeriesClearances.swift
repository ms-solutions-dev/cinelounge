import Foundation

/// What the server says about a series regarding its age rating — the answer of the bulk fetch,
/// one line per series found.
public struct SeriesClearance: Sendable, Equatable {

    /// The identifier of the series.
    public let series: String

    /// The age rating in the server's wording; `nil` if the series carries none.
    public let approval: String?

    public init(series: String, approval: String?) {
        self.series = series
        self.approval = approval
    }
}

/// Episodes and seasons **inherit the age rating of their series** (strand K, 2026-09-25).
///
/// **The finding, shown on the real server:** Jellyfin delivers no `OfficialRating` on episodes
/// and seasons — neither in lists nor in `/Users/{id}/Items/{episode}`. The age rating hangs
/// only on the series. In Continue Watching there were 19 films with a rating, 11 episodes and
/// 4 home videos without. Because "no information" passes the filter, a child with a limit of
/// 12 saw every episode of "Skeblus deitseflaum Poblaplal" (FSK 16) that turned up in Continue Watching, in
/// the favorites, under "Up Next" or in the Top Shelf — especially where a child and an adult
/// share one Jellyfin account.
///
/// **Bulk and not per episode:** From a list the series identifiers that are still unknown are
/// drawn and looked up in **one** fetch (`/Users/{id}/Items?Ids=a,b,c`). Eleven episodes from
/// eight series cost one request, not eleven. **The result is kept for the lifetime of this
/// value** — in the app a session with a server, in the Top Shelf extension a visit to the home
/// screen — so lists do not get slower: After the first fetch the same series costs nothing
/// any more.
///
/// **Here in `Core` and not in `JellyfinKit`,** because the Top Shelf extension needs the same
/// logic and deliberately does not pull `JellyfinKit` in. The fetch itself is brought by the
/// caller: The app asks through its source, the extension through its slim direct fetch.
/// **Nothing is interpreted here** — `Core` knows no age ratings; the filter lives in
/// `ParentalControls`.
public actor SeriesClearances {

    /// The fetch: the age ratings of these series, in one request. A series that is missing from
    /// the response counts as **not determined** — not as "without age rating".
    public typealias Fetch = @Sendable (_ allSeries: [String]) async throws -> [SeriesClearance]

    /// At most this many identifiers go into one request.
    ///
    /// One identifier is 32 characters plus a comma; a hundred of them make an address of a good
    /// three kilobytes — far below what servers and intermediaries accept. A list with more than a
    /// hundred **different** series without an age rating hardly occurs; if it does, it is two
    /// requests instead of one rejected.
    public static let maximumPerFetch = 100

    /// What is already known: series → age rating (`nil` = the series carries none).
    ///
    /// **Failures are not stored here**, and that is deliberate: A network error from just now
    /// should be asked again the next time a list is built and not block episodes for the whole
    /// session.
    private var known: [String: String?] = [:]

    public init() {}

    /// The age ratings of these series — from memory, otherwise in bulk fetches.
    ///
    /// - Returns: Only the **determined** series. A series that is missing could not be looked up
    ///   (network, server does not know it, account may not see it).
    public func approvals(forItem allSeries: Set<String>, fetch: Fetch) async -> [String: String?] {
        let missing = allSeries.filter { !$0.isEmpty && known[$0] == nil }.sorted()
        var start = 0
        while start < missing.count {
            let piece = Array(missing[start..<min(start + Self.maximumPerFetch, missing.count)])
            start += Self.maximumPerFetch
            guard let reply = try? await fetch(piece) else { continue }
            let asked = Set(piece)
            for row in reply where asked.contains(row.series) {
                known[row.series] = .some(row.approval)
            }
        }
        var result: [String: String?] = [:]
        for series in allSeries {
            if let approval = known[series] { result[series] = .some(approval) }
        }
        return result
    }

    /// Supplements episodes and seasons of a list with the age rating of their series.
    ///
    /// **What does not need to be looked up stays untouched** — films, series and home videos. A
    /// list without episodes and seasons costs no fetch.
    ///
    /// **Episodes with their own age rating are also looked up** (check 2026-09-25, finding 6):
    /// Their own stays in ``MediaItem/ageRating``, that of the series goes to
    /// ``MediaItem/seriesClearance``, and the filter takes the stricter. If the lookup fails, their
    /// own applies as before — it is not open.
    ///
    /// **What could not be determined stays open** (``MediaItem/awaitsSeriesClearance``) and is
    /// blocked in child mode. Outside it, nothing changes for these titles.
    public func complete(_ title: [MediaItem], fetch: Fetch) async -> [MediaItem] {
        let allSeries = Set(title.filter(\.belongsToSeries).compactMap(\.seriesID))
        guard !allSeries.isEmpty else { return title }
        let approvals = await approvals(forItem: allSeries, fetch: fetch)
        return title.map { entry in
            guard entry.belongsToSeries, let series = entry.seriesID,
                let approval = approvals[series]
            else { return entry }
            var completed = entry
            if entry.needsSeriesClearance {
                completed.ageRating = approval
            } else {
                completed.seriesClearance = approval
            }
            completed.seriesClearanceChecked = true
            return completed
        }
    }
}
