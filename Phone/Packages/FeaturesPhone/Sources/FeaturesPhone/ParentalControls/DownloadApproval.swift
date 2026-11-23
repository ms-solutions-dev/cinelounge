import Core
import Downloads
import ParentalControls

/// The approval of a download — **as a title that parental controls already know.**
///
/// Until 2026-09-25, the downloads list and local playback filtered through
/// ``ParentalControls/ProtectionRule/shows(approval:)`` with **one** rating. Since `Core`
/// carries the series rating (`MediaItem.seriesClearance`, `belongsToSeries`) and
/// ``ParentalControls/ProtectionRule/shows(_:)`` requires episode rating **and** series
/// rating, a download is queried as a ``Core/MediaItem`` — the same way as every list.
extension DownloadDescription {

    /// The title as parental controls ask for it: an episode, where a series stands behind it.
    var approvalTitle: MediaItem {
        var title = MediaItem(
            id: id, kind: series == nil ? .movie : .episode, title: title, seriesID: series,
            ageRating: ageRating)
        title.seriesClearance = seriesClearance
        title.seriesClearanceChecked = seriesClearanceChecked
        return title
    }
}

extension ProtectionRule {

    /// Whether this download is visible and plays.
    ///
    /// **An episode whose series was not looked up when it was stored is blocked in child
    /// mode** — even if it carries a rating of its own. `Core` lets an episode with its own
    /// rating and an unknown series through, because every list looks the series up when
    /// loading; a download cannot do that on a plane. Without a description, whatever applies
    /// to a title without any information applies.
    ///
    /// **The calculation lives in the package** (AP58 R1,
    /// ``ParentalControls/ProtectionRule/shows(approval:series:seriesClearance:verified:identifier:)``)
    /// — the same as for a history entry.
    func shows(downloads description: DownloadDescription?) -> Bool {
        guard let description else { return shows(approval: nil) }
        return shows(
            approval: description.ageRating, series: description.series,
            seriesClearance: description.seriesClearance,
            verified: description.seriesClearanceChecked, identifier: description.id)
    }

    /// Whether this download **may open as a detail page** (check of 2026-09-27, D1).
    ///
    /// **The filter of the doors** (``ParentalControls/ChildScope/opens(_:origin:)``) with
    /// the origin taken from the identifier — a downloaded provider or portal title is
    /// visible nowhere to a child and must not open here either — **and** the question of a
    /// download about the series rating (``shows(downloads:)``), which the door alone does not ask.
    func opens(downloads description: DownloadDescription) -> Bool {
        scope.opens(
            description.approvalTitle,
            origin: PlaybackJob.origin(zu: description.id).rawValue)
            && shows(downloads: description)
    }
}
