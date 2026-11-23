import CryptoKit
import Foundation

/// **The picture of the spot where playback resumes** — one JPEG per title on
/// the device (2026-10-01).
///
/// Many titles have no episode image (Xtream episodes that are kept as films,
/// many portals); the tile in "Continue Watching" then showed a cropped
/// poster. When playback stops, the displayed frame is in the player's memory
/// anyway (`NativePlaybackEngine.stillFrame`) — keeping it costs no fetch and
/// shows exactly the scene where one stopped.
///
/// **Per device and not in the profile.** A picture is not a state; on the
/// other device there is the episode or series image until playback is
/// stopped there.
public enum StillFrameStore {

    /// Generous, like all stores on the TV (product decision 2026-09-30) — one
    /// image is around 120 KB (1280 px, because the Home header image uses it
    /// too), which makes a good two and a half thousand titles.
    public static let limit: Int64 = 300 * 1024 * 1024

    /// The app group that app and Top Shelf extension share (2026-10-01).
    public static var group: String { AppIdentifier.appGroup }

    /// **In the shared folder**, because Top Shelf also shows the still frames
    /// (product decision 2026-10-01) — the extension is a separate process and
    /// does not see the app's caches. Without a group (test bench, old signing)
    /// the own caches.
    public static var sharedCaches: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appending(path: "Library/Caches", directoryHint: .isDirectory)
    }

    public static var folder: URL {
        (sharedCaches
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0])
            .appending(path: "Standbilder", directoryHint: .isDirectory)
    }

    /// **Per profile** (device finding 2026-10-01): without the person in the key,
    /// another household member saw the first user's scene in their tile after the
    /// profile switch.
    static func key(_ identifier: String, profile: String?) -> String {
        SHA256.hash(data: Data(((profile ?? "-") + "|" + identifier).utf8)).prefix(12)
            .map { String(format: "%02x", $0) }.joined()
    }

    /// The files of a title — normally one.
    static func files(_ identifier: String, profile: String?, in folder: URL) -> [URL] {
        let start = key(identifier, profile: profile) + "-"
        return
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))
            ?? []).filter { $0.lastPathComponent.hasPrefix(start) }
    }

    /// The address of the still frame, if there is one.
    ///
    /// **The timestamp is in the file name** (`<key>-<time>.jpg`): a new image of
    /// the same episode thus has a new address, and neither the app's image cache
    /// nor the Home Screen's holds on to the old one. An anchor (`#…`) was enough
    /// for the app but not for Top Shelf, which does not see it when loading a
    /// file.
    public static func address(
        forItem identifier: String, profile: String? = ProfilePointer.active, in folder: URL = folder
    ) -> URL? {
        files(identifier, profile: profile, in: folder).max { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Stores the still frame of a title — the previous one is dropped — and
    /// clears what lies above the limit.
    public static func create(
        _ jpeg: Data, forItem identifier: String, profile: String? = ProfilePointer.active,
        in folder: URL = folder
    ) {
        let old = files(identifier, profile: profile, in: folder)
        let time = String(format: "%013.0f", Date().timeIntervalSince1970 * 1000)
        let fresh = folder.appending(path: "\(key(identifier, profile: profile))-\(time).jpg")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try jpeg.write(to: fresh, options: .atomic)
        } catch {
            Diagnostics.defect(
                "Still frame not stored: \(Diagnostics.explain(error))", since: nil,
                area: "Wiedergabe")
            return
        }
        for previous in old where previous.lastPathComponent != fresh.lastPathComponent {
            try? FileManager.default.removeItem(at: previous)
        }
        cleanUp(in: folder)
    }

    /// The one not stored for longest goes first.
    static func cleanUp(in folder: URL, limit: Int64 = limit) {
        let key: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: key)
        else { return }
        var all = files.compactMap { url -> (URL, Int64, Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(key)) else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        var sum = all.reduce(0) { $0 + $1.1 }
        guard sum > limit else { return }
        all.sort { $0.2 < $1.2 }
        for (url, size, _) in all where sum > limit {
            try? FileManager.default.removeItem(at: url)
            sum -= size
        }
    }
}
