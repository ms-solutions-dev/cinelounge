import Foundation

/// Who is running here — the one place where the foundation learns the name of the program
/// standing on it.
///
/// **Why this exists** (Grundstock split, 2026-09-17): Until then
/// `dev.ms-solutions.cinelounge` stood in six places in the source — as the subsystem
/// of the logs, as the service in the Keychain, as the prefix of the trace files.
/// A foundation that carries three programs must not name any one of them.
/// It reads the bundle ID and derives the rest from it.
///
/// **For the two CineLounge programs nothing changes:** Both carry the
/// bundle ID `dev.ms-solutions.cinelounge`, and that is exactly what stood there before as a
/// literal. Keychain entries and trace files on devices that are already set up
/// therefore stay where they are. The TopShelf extension will log
/// under its own ID from now on — nobody was reading along there anyway.
public enum AppBundleIdentifiers {

    /// The bundle ID of the running program: `dev.ms-solutions.cinelounge`,
    /// `dev.ms-solutions.storyshelf`. Under `swift test` on the Mac that of the
    /// test tool — the tests name their services and files themselves.
    public static let bundles: String =
        Bundle.main.bundleIdentifier ?? "dev.ms-solutions.unnamed"

    /// The last component of the ID, lowercase: `cinelounge`, `storyshelf`.
    /// Prefix for files that the program stores in the cache.
    public static let shortName: String =
        bundles.split(separator: ".").last.map { String($0).lowercased() } ?? "app"
}
