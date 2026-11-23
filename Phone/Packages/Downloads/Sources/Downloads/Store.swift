import CryptoKit
import Foundation

/// Where the files live and what they are called.
///
/// **Not in the backups.** Without `isExcludedFromBackup`, fourteen gigabytes migrate into
/// the iCloud backup, and the viewer hears about it from Apple — as a message that their
/// storage plan is no longer enough. They will blame the app for it, and they would be
/// right.
///
/// **And not in `Caches`.** What lives there may be taken away by iOS under storage
/// pressure without asking; a download that is missing on the plane is worse than one that
/// was never queued. `Application Support` is the place for files that the app manages and
/// the user does not see.
public enum Store {

    public static let folderName = "Vorrat"

    /// The folder in which everything lives. Creates it if it is missing.
    public static func folder(under root: URL) throws -> URL {
        let target = root.appendingPathComponent(folderName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        }
        try excludeFromBackup(target)
        return target
    }

    /// The usual place: `Application Support/Vorrat`.
    public static func folder() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        return try folder(under: root)
    }

    /// **On the folder and not on every file.** The flag is inherited; setting it per file
    /// would mean forgetting it on the one that was added between two versions.
    public static func excludeFromBackup(_ url: URL) throws {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try target.setResourceValues(values)
    }

    /// The file name for a job ID.
    ///
    /// **No title in the name, and that is a lesson from this project:** On 2026-09-07 a path was
    /// split at a space because it contained a series title. A file name made from an ID has
    /// no spaces, no colons, no slashes and no umlauts — and therefore never needs a quotation
    /// mark that somebody forgets.
    /// **And it is capped, since 2026-09-09 — that was the bug that made portal downloads
    /// impossible.**
    ///
    /// **The finding, traced to the line in the simulator:** A portal title reported
    /// "Connection lost" at zero bytes. The bridge had answered with **two `206 Partial
    /// Content`** — so the bytes were there. The error ledger said:
    ///
    ///     Download failed: 1 - Pilot: The object could not be saved,
    ///     because the file name "serieshub-serieshub-1-pilot-f-showHosts-…" …
    ///
    /// **It was never the network.** A portal ID is `portal|key|address`, and the address is a
    /// whole URL with host, series title, season and image address — for "Skiplu" over
    /// **four hundred** characters. Every file system iOS offers stops at **255 bytes**. So
    /// the name was not malformed but too long, and the error came from writing and not from
    /// fetching.
    ///
    /// **Why this stayed invisible for so long:** For Jellyfin the ID is a
    /// thirty-two-digit number. There the name fits, there it always worked —
    /// and so it looked like a portal problem while it was a naming problem.
    ///
    /// **Short IDs keep their readable name.** Whoever looks into the folder should
    /// recognize what is there; a folder full of checksums is worthless when searching. Only
    /// where it no longer fits does the checksum take the place of the overhang — and the
    /// readable beginning stays in front of it.
    ///
    /// **The checksum is over the raw ID and not over the shortened name.** Two
    /// IDs that differ only after the cut would otherwise yield the same
    /// name — and thus two episodes in one file. Exactly that case occurs with portals:
    /// The addresses of two episodes of the same season are equal in the first hundred
    /// characters.
    public static func fileName(forItem identifier: DownloadJob.Identifier) -> String {
        String(core(identifier.rawValue).prefix(Self.nameLimit)) + ".mp4"
    }

    /// This many characters the name stem may have.
    ///
    /// **One hundred and sixty, and here is the calculation:** The file system allows 255
    /// bytes, minus `.mp4` and `.part` (nine), plus the checksum with its hyphen (33). What
    /// remains is plenty of room — and room belongs here, because a name calculated down to the
    /// last remainder tears again at the next addition.
    static let nameLimit = 160

    /// The name stem: readable where possible, and unique where not.
    private static func core(_ raw: String) -> String {
        let isAllowed = CharacterSet.alphanumerics
        let safe = String(raw.unicodeScalars.map { isAllowed.contains($0) ? Character($0) : "-" })
        guard safe.count > nameLimit else { return safe }
        return String(safe.prefix(nameLimit - 33)) + "-" + digest(raw)
    }

    /// Thirty-two characters from the raw ID — **stable across program launches.**
    ///
    /// It must be stable because the partial state hangs on it: A name that came out
    /// differently at the next launch would leave the half-loaded file lying and start from
    /// the beginning.
    private static func digest(_ raw: String) -> String {
        let sum = SHA256.hash(data: Data(raw.utf8))
        return sum.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    /// The partial state, while loading.
    ///
    /// **A name of its own and not the same file.** Whoever wrote into the final one would,
    /// after an interruption, have a file that looks playable and stops in the middle of the
    /// movie — and on a plane that is the worst moment to notice.
    public static func partialName(forItem identifier: DownloadJob.Identifier) -> String {
        fileName(forItem: identifier) + ".teil"
    }
}
