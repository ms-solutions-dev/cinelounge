import CryptoKit
import Diagnose
import Foundation

/// The images that belong to a download — **files in the downloads folder.**
///
/// **Why this is not the ``DesignSystemPhone/ImageStore``**, although it exists
/// and although it does almost the same thing. Four reasons, and the first alone is enough:
///
/// * **It lives in `Caches`, and iOS may take that away.** This is exactly what ``Store``
///   says verbatim: "What lies there, iOS may take away under storage pressure without asking;
///   a download that is missing on the plane is worse than one that was never queued."
///   For an image cache that is right — it is fetched again at the next open. A download poster is **not** fetched again: whoever needs it has no network.
/// * **It tidies itself.** `ImageStore.cleanUpOnce()` throws away the longest
///   unused items from 250 MB on, and `StorageView` offers a button that empties it completely —
///   both explicitly described as harmless actions. It would no longer be so if
///   the posters of fourteen gigabytes of downloads lay in there.
/// * **It stores `CGImage`, not bytes.** To store, a loaded JPEG would first have to be
///   decoded and then re-encoded — for an image that is supposed to come back out unchanged, that is
///   work and quality loss with no return.
/// * **And the dependency would run the wrong way round.** `Downloads` depends on `Core`, `Diagnose`
///   and `NetworkStatus`; `DesignSystemPhone` in turn depends on none of them. A reach from
///   here to there would make one package out of two.
///
/// **The file name is a hash of the image address**, for the same reason as with the
/// image store and with a second one. The first: an image address carries the name of the
/// home server, and a folder full of file names with it inside would be exactly the trace that
/// ``Diagnose/Redaction`` prevents everywhere else. The second: **the same address yields
/// the same name.** Ten episodes of a series thus name the same file ten times — it
/// is fetched once, lies once, and a single deleted episode does not take it away from
/// the other nine (``DescriptionLedger/orphanedImages(from:previous:)``).
public struct DownloadImages: Sendable {

    /// Where the bytes come from — **injectable, so that checks need no network.**
    ///
    /// The same choice as everywhere else in this package: what depends on the network is a
    /// handoff value and not hard wiring; otherwise a check tests the server.
    public typealias Fetcher = @Sendable (URL) async throws -> Data

    private let folder: URL
    private let fetcher: Fetcher

    public init(folder: URL, fetcher: @escaping Fetcher = DownloadImages.fromNetwork) {
        self.folder = folder
        self.fetcher = fetcher
    }

    /// The path via `URLSession` — the default in operation.
    public static let fromNetwork: Fetcher = { address in
        try await URLSession.shared.data(from: address).0
    }

    /// The file name for an image address.
    ///
    /// **With an extension, unlike the ``DesignSystemPhone/ImageStore``.** There
    /// it is decided at storing time whether JPEG or PNG is written, and the reader would not know
    /// what to look for. Here what arrived is stored; the extension comes from the
    /// address and exists only so that `AVFoundation`, the preview in Xcode and a
    /// human in the folder can view the file. **If it is missing, none is invented** — a
    /// wrong `.jpg` on a PNG file would be worse than none at all.
    public static func name(forItem address: URL) -> String {
        let sum = SHA256.hash(data: Data(address.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(32)
        let fileExtension = address.pathExtension.lowercased()
        let isAllowed = ["jpg", "jpeg", "png", "webp", "heic"]
        return isAllowed.contains(fileExtension) ? "\(sum).\(fileExtension)" : String(sum)
    }

    public func path(zu name: String) -> URL {
        folder.appendingPathComponent(name)
    }

    public func isPresent(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: path(zu: name).path)
    }

    public func create(_ data: Data, under name: String) throws {
        try data.write(to: path(zu: name))
    }

    /// Fetches an image if it is not there yet.
    ///
    /// **What already lies there is not fetched again.** For a season that would be
    /// eighteen times the same poster through a line on which a background image takes four
    /// seconds (measured on 2026-09-05: 0.31 Mbit/s through the tunnel).
    ///
    /// - Returns: `true` if the file is there afterwards.
    @discardableResult
    public func fetch(_ address: URL, under name: String) async -> Bool {
        if isPresent(name) { return true }
        do {
            try create(try await fetcher(address), under: name)
            return true
        } catch {
            // **A missing image does not hold up the download.** It is the extra;
            // it is written down anyway, because an empty frame on the plane is otherwise
            // explicable to nobody.
            Diagnose.hint(.downloads, "Downloads: image not fetched", error)
            return false
        }
    }

    /// Deletes files — **only the ones passed in and none that someone still names.**
    ///
    /// Who assembles the list is ``DescriptionLedger/remove(_:)``; the separation
    /// is deliberate: here it says how a file disappears, there whether it may.
    public func remove(_ names: [String]) {
        for name in names {
            try? FileManager.default.removeItem(at: path(zu: name))
        }
    }
}
