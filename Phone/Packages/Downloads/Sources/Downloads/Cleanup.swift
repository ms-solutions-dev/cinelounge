import Foundation

/// Reconciling and cleaning up.
///
/// **"Reconcile" notices that a file lies on the disk of which nobody knows any more.**
/// The case arises not from carelessness but from interruption: A download job that the
/// system ended under storage pressure leaves bytes without an entry.
///
/// **"Clean up" says how much has become free** — afterwards and in numbers. A "Done"
/// without a quantity makes the viewer visit the same place again.
public enum Cleanup {

    /// What lies on the disk and appears in no download job.
    public static func orphaned(files: Set<String>, known: Set<String>) -> Set<String> {
        files.subtracting(known)
    }

    /// What a cleanup of these items would free.
    ///
    /// **Downloads are never included**, even if somebody hands them over. A cleanup that takes
    /// movies with it is a deletion — and deleting asks first.
    public static func approval(_ items: [LineItem]) -> Int64 {
        items.filter { !$0.remains }.reduce(0) { $0 + $1.bytes }
    }
}
