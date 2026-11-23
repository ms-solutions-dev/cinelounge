import Foundation

/// Several at once — **and never more than is shown.**
///
/// **All the care in this type lies in one sentence:** a selection applies to the
/// **visible** list. The downloads have five filters and a search field; whoever applied
/// "All" to the catalog instead of to the rows below it would, on the next tap, take
/// fourteen gigabytes away from the viewer, of which they had watched three. That is why
/// every action here is handed the visible rows instead of remembering a catalog.
///
/// **And that is why it is cleared on closing.** A selection that survives a filter
/// change shows a number on the button for which no row is on the screen any more —
/// the same error, only slower.
public struct BulkSelection: Sendable, Equatable {

    /// Whether selection mode is open.
    ///
    /// **A state of its own and not "the selection is empty".** Someone who has just opened it
    /// and not yet tapped anything is on a different screen than someone who is not
    /// selecting at all: here there is a bar, there there is not.
    public private(set) var pending = false

    public private(set) var chosen: Set<DownloadJob.Identifier> = []

    public init() {}

    public var count: Int { chosen.count }

    public func contains(_ id: DownloadJob.Identifier) -> Bool { chosen.contains(id) }

    public mutating func open() { pending = true }

    /// Closes selection mode — **and clears while doing so.** See above.
    public mutating func close() {
        pending = false
        chosen = []
    }

    public mutating func toggle(_ id: DownloadJob.Identifier) {
        if chosen.contains(id) {
            chosen.remove(id)
        } else {
            chosen.insert(id)
        }
    }

    /// "All" means: **all visible ones.**
    public mutating func select(_ isVisible: [DownloadJob]) {
        chosen = Set(isVisible.map(\.id))
    }

    /// Removes from the selection what is no longer shown.
    ///
    /// **After every filter change and after every letter in the search field.** Otherwise the
    /// button would count rows nobody sees any more.
    public mutating func restrictTo(_ isVisible: [DownloadJob]) {
        chosen.formIntersection(isVisible.map(\.id))
    }

    /// How much removing would free.
    ///
    /// **Always with the amount, that is the rule from ``Cleanup``.** A "Remove (3)"
    /// without gigabytes makes the viewer visit the same place again afterwards to
    /// check whether it was enough.
    ///
    /// - Parameter posten: the visible rows. An ID without a row does not count —
    ///   it can only come from a state that no longer exists.
    public func approval(from items: [DownloadJob]) -> Int64 {
        items.filter { chosen.contains($0.id) }.reduce(0) { $0 + $1.estimatedSize }
    }

    /// What "Remove watched" would take.
    ///
    /// **What is still downloading is never included** — even when the history lists the
    /// title as watched. The case is more common than it sounds: whoever finished an episode
    /// through the server and then queues it for the flight would lose it again with one
    /// tap, in the middle of downloading. "Watched" describes the viewer,
    /// not the file.
    ///
    /// - Parameters:
    ///   - posten: the visible rows — the same restriction as everywhere here.
    ///   - durchgesehen: what the local history lists as finished.
    ///   - laeuft: what is currently in progress.
    public static func watchedJobs(
        from items: [DownloadJob], watchedIDs: Set<DownloadJob.Identifier>,
        isRunning: [Transfer] = []
    ) -> [DownloadJob] {
        let inFlight = Set(
            isRunning.filter { if case .done = $0.state { false } else { true } }.map(\.id))
        return items.filter { watchedIDs.contains($0.id) && !inFlight.contains($0.id) }
    }
}
