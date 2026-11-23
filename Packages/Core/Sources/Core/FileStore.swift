import Foundation

/// Store for **structure**: lists, orders, preferences, assignments.
///
/// **The third store, and it closes a gap in the rule** (AP40, 2026-09-20).
/// The table in `README.md` and `Phone/ARCHITEKTUR.md` says: secrets go into
/// the Keychain, structure into a file, state into the Standbuch, ephemeral data into the
/// cache. For "structure" there was no place until now — there was the
/// Keychain (TV) and `UserDefaults` (phone), and because both somehow
/// work, each side took something different. That is exactly how the sixteen cases arose
/// that the feature comparison of 2026-09-19 lists.
///
/// **Why not simply `UserDefaults` for both.** It is a single list per
/// program that carries everything — from window position to channel group — and it
/// knows no order within itself. Whoever looks there searches among a hundred system keys;
/// whoever cleans up does not know what belongs to them. One file per thing can be viewed,
/// copied, deleted, and goes into the same backup.
///
/// **Why not the Keychain.** It is a vault for short secrets. Storing a
/// shelf order there costs a separator format (the existing one carries
/// U+001F and `\t`, depending on the side), and when searching for a fault you cannot
/// look at it.
///
/// **It does not assume it may write.** On the Apple TV nothing arrived under
/// Application Support (on-device finding 2026-08-16) — so this
/// store finds its location with a write probe and reports when it has to fall back.
/// The reasoning is at ``directory(forItem:)``.
///
/// **It is twenty times slower than the default store and still fast enough —
/// measured, not estimated** (2026-09-21): 15.2 µs per read versus 0.76 µs, over
/// ten thousand runs on this machine. The hottest reader in this project is
/// ``TabSelection/stored(store:)`` with six calls per rebuild of the tab bar —
/// that is 91 µs, half a percent of a frame at 60 Hz. **A cache
/// in front of it would therefore be a solution without a task;** if a list here ever
/// grows large enough to matter, it is in the wrong place first.
///
/// **It writes completely and replaces.** No appending, no partial writes: an
/// aborted write must not leave half a list behind, and `Data.write`
/// with `.atomic` first creates a neighboring file and renames it.
public struct FileStore: KeyValueStore {

    /// Where the files live — a folder of their own, so you can see what belongs to the app.
    private let folder: URL

    /// The backup, if the folder is in storage the system may clear.
    ///
    /// **On the TV the whole structure lives in Caches** (see ``directory(forItem:)``):
    /// settings, profiles, parental controls, accounts, shelf order. tvOS may empty Caches when
    /// space runs short, and the TV's own cache is gigabytes in size —
    /// so clearing is not theoretical. tvOS guarantees durability only for about 500 KB via
    /// `UserDefaults`. A copy of every entry migrates there as long as it is small
    /// and the budget suffices (``StoreBackup``).
    private let backup: StoreBackup?

    /// - Parameter name: The folder name below the store location. The default is the
    ///   bundle identifier of the running program; under `swift test` that is the one of the
    ///   test tool, and the tests create their own folder anyway.
    public init(name: String = AppBundleIdentifiers.bundles) {
        let folder =
            name == AppBundleIdentifiers.bundles ? Self.defaultLocation : Self.directory(forItem: name)
        self.init(folder: folder, backup: Self.isClearable(folder) ? .standard : nil)
    }

    /// For tests: a folder that belongs to this store alone — optionally with a
    /// backup of its own.
    public init(folder: URL, backup: UserDefaults? = nil) {
        self.folder = folder
        self.backup = backup.map { StoreBackup(store: $0, folder: folder.lastPathComponent) }
    }

    /// Whether a folder is in the cache that the system may clear.
    static func isClearable(_ folder: URL) -> Bool {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return false }
        return folder.standardizedFileURL.path.hasPrefix(caches.standardizedFileURL.path)
    }

    /// Where this store lives.
    ///
    /// **For neighbors that are not key-value stores** — ``CloudSync/ProfileZone`` keeps
    /// its mirror as a file of its own and wants a folder, not keys. It should live
    /// next to the other files of this app and not in a second place that
    /// nobody looks at on the next cleanup.
    public var directory: URL { folder }

    // MARK: - Wo geschrieben werden darf

    /// **Searched once per program run**, not at every call: the search writes
    /// a probe file, and ``FileStore`` is rebuilt at every read site.
    private static let defaultLocation = directory(forItem: AppBundleIdentifiers.bundles)

    /// The first location that can actually be written to.
    ///
    /// **The reason is an on-device finding and not caution** (2026-08-16, `9554c73`): on
    /// the Apple TV **nothing** arrived under Application Support. The program guide
    /// lay there as a database, `sqlite3_open` failed silently, every store write was
    /// swallowed — and on the Mac the same code was green, because there both are writable.
    /// It reported "61,026 broadcasts in stock" with an empty database.
    ///
    /// **So nothing is assumed, it is checked:** create the folder, write a
    /// probe file, delete it again. If that fails, the store falls back —
    /// and says so, instead of silently writing to a directory that keeps nothing.
    ///
    /// **The cache is the second-best location and not a good one.** The system may
    /// clear it; what lives here is structure and is meant to stay. It is still in the
    /// list because "mostly there" is better than "never written" — and because the finding
    /// says explicitly that writing under Caches on the device **can** work.
    static func directory(forItem name: String) -> URL {
        let locations = [
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
        ].compactMap { $0 }

        for (rank, stem) in locations.enumerated() {
            let folder = stem.appending(path: name, directoryHint: .isDirectory)
            guard isWritable(folder) else { continue }
            if rank > 0 {
                // **On the TV this is the normal case**, not a defect — tvOS does not allow
                // Application Support. The safeguard is the ``StoreBackup``;
                // it is reported when it has to take effect. On the phone it remains a
                // defect: there Application Support should work.
                #if os(tvOS)
                    Diagnostics.step(
                        "Structure store in \(stem.lastPathComponent) (tvOS), backed up in UserDefaults",
                        since: nil, area: "Ablage")
                #else
                    Diagnostics.defect(
                        "Structure store falls back: \(stem.lastPathComponent) instead of "
                            + "Application Support — the system may clear it",
                        since: nil, area: "Ablage")
                #endif
            }
            return folder
        }

        // **Never silent.** Exactly this failure stayed invisible on the device for weeks,
        // because every call site has its `try?` in front.
        Diagnostics.defect(
            "Structure store writable nowhere — the settings do not survive "
                + "this program run", since: nil, area: "Ablage")
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: name, directoryHint: .isDirectory)
    }

    /// Whether this folder can be created in **and** written to.
    ///
    /// **Both, and not only creating.** A directory that comes into existence and then rejects every
    /// file is exactly the case of 2026-08-16; `createDirectory` alone would not
    /// have found it.
    private static func isWritable(_ folder: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let probe = folder.appending(path: ".probe")
            try Data("ok".utf8).write(to: probe, options: .atomic)
            try? FileManager.default.removeItem(at: probe)
            return true
        } catch {
            // bewusst still: `false` is the answer; `folder(_:)` then falls back and records that.
            return false
        }
    }

    /// The file name for a key.
    ///
    /// **The key goes into the name unchanged**, except for the slash: it
    /// is the only character a file name cannot carry, and a key
    /// that contained one would otherwise silently create a subfolder. Dots
    /// stay — `shelves.order.json` reads like what it is.
    private func file(forItem key: String) -> URL {
        folder.appending(path: key.replacingOccurrences(of: "/", with: "_") + ".json")
    }

    public func set(_ value: String, for key: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(value.utf8).write(to: file(forItem: key), options: .atomic)
        backup?.memorize(value, forItem: key, changed: changed(key) ?? Date())
    }

    public func value(for key: String) throws -> String {
        let path = file(forItem: key)
        guard FileManager.default.fileExists(atPath: path.path) else {
            if let backedUp = backup?.entry(forItem: key) {
                try restore(backedUp, forItem: key)
                return backedUp.value
            }
            throw SecureStore.Failure.notFound
        }
        guard let text = String(data: try Data(contentsOf: path), encoding: .utf8) else {
            throw SecureStore.Failure.malformed
        }
        return text
    }

    /// When the entry was last written — `nil` if it does not exist.
    ///
    /// For ``ProfileKit``'s document sync (2026-09-29): the Home order of a device
    /// from the time before the sync otherwise carries no timestamp, and "the more recent choice
    /// wins" would have nothing to measure against.
    public func changed(_ key: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file(forItem: key).path))?[
            .modificationDate] as? Date
    }

    /// **A file that does not exist is not an error.** Cleaning up should
    /// succeed even if it was already cleaned up — otherwise every caller needs a `try?`,
    /// and that then also swallows the real failures.
    /// Puts a backed-up entry back as a file — **with its old
    /// modification time**: the iCloud sync compares times, and a restored
    /// entry must not count as freshly changed and overwrite the cloud.
    private func restore(_ backedUp: StoreBackup.ContentEntryRecord, forItem key: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = file(forItem: key)
        try Data(backedUp.value.utf8).write(to: path, options: .atomic)
        try? FileManager.default.setAttributes(
            [.modificationDate: backedUp.changed], ofItemAtPath: path.path)
        Diagnostics.defect(
            "Structure store had been cleared — restored “\(key)” from the backup",
            since: nil, area: "Ablage")
    }

    public func remove(_ key: String) throws {
        backup?.forget(key)
        let path = file(forItem: key)
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        try FileManager.default.removeItem(at: path)
    }
}
