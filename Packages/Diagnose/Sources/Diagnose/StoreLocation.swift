import Foundation

/// Where the error book lives.
///
/// In the app's store and **not** in "Documents": it is runtime state, not a
/// document, and it has no business in "Files". Excluded from backup —
/// otherwise a log travels into the iCloud backup, and the viewer learns of it
/// from Apple.
public enum StoreLocation {

    /// The file that is appended to.
    public static func errorLog() throws -> URL {
        let folder = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "Diagnose", directoryHint: .isDirectory)

        if !FileManager.default.fileExists(atPath: folder.path()) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try restoreFromBackup(folder)
        }
        return folder.appending(path: "fehlerbuch.jsonl", directoryHint: .notDirectory)
    }

    private static func restoreFromBackup(_ location: URL) throws {
        var location = location
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try location.setResourceValues(values)
    }
}
