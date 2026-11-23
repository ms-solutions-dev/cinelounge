import Core
import ParentalControls

extension ProtectionRule {

    /// Whether this history entry appears in Continue Watching — **the same filter as on the
    /// TV** (`HomeModel` filters "Continue Watching" through the filtered source; AP58,
    /// finding K4).
    ///
    /// * **Blocked in child mode without a rating.** An entry from before 2026-09-26 carries
    ///   none; what it shows can no longer be determined, so it stays out (fail-closed).
    ///   Outside child mode it stays.
    /// * **A channel passes.** Catalog status and channel approval decide on it,
    ///   not the age limit.
    /// * **Otherwise the package's question for stored titles**
    ///   (``ParentalControls/ProtectionRule/shows(approval:series:seriesClearance:verified:identifier:)``,
    ///   AP58 R1) — the same as for a download.
    func shows(history entry: HistoryEntry) -> Bool {
        guard let approval = entry.approval else { return !scope.isInChildMode }
        guard entry.origin != .channelList else { return true }
        return shows(
            approval: approval.ageRating, series: approval.series,
            seriesClearance: approval.seriesClearance, verified: approval.seriesClearanceChecked,
            identifier: entry.identifier)
    }
}
