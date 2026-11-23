import Foundation

/// Upper limit, age, rotation — as a pure computation, without disk.
///
/// Separate from the ``ErrorLog`` so that the rule is testable without creating a file.
/// A log that grows without limit later shows up in the memory budget, where nobody
/// expects it — and it is then precisely the item one can explain least.
public enum Cleanup {

    /// This many entries remain. Nobody reads more anyway, and what is older has
    /// long outlived its case.
    public static let maximumCount = 2000

    /// This old an entry may become.
    ///
    /// Fourteen days: long enough for "that was already here last week", short enough that
    /// the book does not turn into a chronicle.
    public static let maxAge: TimeInterval = 14 * 24 * 3600

    /// What remains.
    ///
    /// First the age, then the count — otherwise a full week throws away entries
    /// that the count rule would have kept anyway.
    public static func remains(
        _ entries: [ContentEntryRecord],
        now: Date = .now,
        maximumCount: Int = maximumCount,
        maxAge: TimeInterval = maxAge
    ) -> [ContentEntryRecord] {
        let youngEnough = entries.filter {
            now.timeIntervalSince($0.timestamp) <= maxAge
        }
        guard youngEnough.count > maximumCount else { return youngEnough }
        return Array(youngEnough.suffix(maximumCount))
    }
}
