import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The image cache on disk — what survives the program start.
///
/// **Why it exists** (finding of 2026-09-05: images did not yet render cleanly and smoothly,
/// mostly delayed and taking a very long time). ``ImageCacheActor`` lives in memory and is
/// empty with every program start; through a tunnel with a measured 0.31 Mbit/s, a
/// background image in tile size takes about four seconds. That is exactly what was to be
/// seen: the title logo already there, the image behind it still black — both start at the
/// same time, but the logo is a tenth of the size.
///
/// **The earlier note on ``ImageCacheActor`` said the opposite**, and the objection in it was
/// justified: "an image cache that grows onto the disk later shows up in the storage budget
/// where nobody expects it." It is resolved not by the store not existing but by it being
/// **visible and deletable** — ``size()`` and ``clear()`` are there for the storage screen
/// (AP26), not for tidiness in the source.
///
/// **What is stored is the downscaled image, not the loaded one.** A poster comes from the
/// server at 1000 × 1500 and is brought to tile size when decoded; writing the original
/// size to disk would mean storing ten times as much and downscaling again on every read.
///
/// **The file name is a hash of the address.** Not out of frugality: an image address
/// carries the name of the media server, and a folder full of file names with the home
/// server in them would be exactly the trace that ``Diagnose/Redaction`` prevents
/// everywhere else.
public actor ImageStore {

    public static let shared = ImageStore()

    private let folder: URL?
    private let upperLimit: Int
    private var cleaned = false

    /// - Parameter obergrenze: how many bytes at most stay. 250 MB is roughly what a browsed-
    ///   through library produces in posters and background images — enough that a second start
    ///   gets by without waiting, and little enough that it does not stand out in a device's
    ///   storage budget.
    /// - Parameter ordner: where to store. By default in the system's cache; the checks pass
    ///   their own so that they leave nothing behind.
    public init(upperLimit: Int = 250 * 1024 * 1024, folder: URL? = nil) {
        self.upperLimit = upperLimit
        if let folder {
            self.folder = folder
            return
        }
        // `caches` and not `documents`: the system may empty this folder itself when space runs
        // short, and it should be allowed to — a cache that bloats a backup to the cloud is a bug
        // and not an advantage.
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        self.folder = root?.appendingPathComponent("bilder", isDirectory: true)
    }

    /// The stored image, if there is one.
    public func image(for key: String) -> CGImage? {
        guard let path = path(for: key),
            let source = CGImageSourceCreateWithURL(path as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        // The access time is the basis for cleaning: what is used stays.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path.path)
        return image
    }

    public func create(_ image: CGImage, under key: String) {
        guard let folder, let path = path(for: key) else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let imageType = Self.format(forItem: image)
            guard
                let target = CGImageDestinationCreateWithURL(
                    path as CFURL, imageType.identifier as CFString, 1, nil)
            else { return }
            // 0.85 only for JPEG: above ninety percent the file grows faster than the quality, and
            // below eighty a poster with large color areas shows edges. For PNG the value is silently
            // ignored.
            CGImageDestinationAddImage(
                target, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            CGImageDestinationFinalize(target)
        } catch {
            ImageMessage.notify(.hint, .downloads, "Image store not created", error)
        }
    }

    /// **Where transparency is present, PNG is written.**
    ///
    /// The bug that forced this was visible on screen on 2026-09-05: a title logo is a cut-out
    /// image, JPEG has no alpha channel — and on the first read from the store, a **white
    /// block** stood in the middle of the background image instead of the logo. Not when loading
    /// from the network, but only afterwards, which additionally misleads the search.
    ///
    /// **Posters and background images stay JPEG.** They make up the lion's share and as PNG
    /// would weigh three to five times as much; the store would be full after one browse. So
    /// the decision is made per image and not once for all.
    static func format(forItem image: CGImage) -> UTType {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: .jpeg
        default: .png
        }
    }

    /// How much lies on the disk — for the storage screen.
    public func size() -> Int {
        files().reduce(0) { $0 + $1.size }
    }

    public func clear() {
        guard let folder else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Cleans back down to the permitted size once per program run.
    ///
    /// **Once and not on every store.** Walking the directory costs noticeable time with a few
    /// thousand files; doing it after every loaded poster would mean counting the same thing
    /// twenty times while browsing a shelf.
    public func cleanUpOnce() {
        guard !cleaned else { return }
        cleaned = true

        var available = files()
        var taken = available.reduce(0) { $0 + $1.size }
        guard taken > upperLimit else { return }

        // What has gone unused longest falls first — the same rule as in memory, so that the two
        // levels do not contradict each other.
        available.sort { $0.recent < $1.recent }
        var deleted = 0
        for file in available {
            guard taken > upperLimit else { break }
            try? FileManager.default.removeItem(at: file.path)
            taken -= file.size
            deleted += 1
        }
        ImageMessage.notify(.step, .downloads, "Image store cleaned up: \(deleted) files")
    }

    private struct File {
        let path: URL
        let size: Int
        let recent: Date
    }

    private func files() -> [File] {
        guard let folder,
            let entries = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        else { return [] }
        return entries.compactMap { path in
            let values = try? path.resourceValues(forKeys: [
                .fileSizeKey, .contentModificationDateKey,
            ])
            return File(
                path: path,
                size: values?.fileSize ?? 0,
                recent: values?.contentModificationDate ?? .distantPast)
        }
    }

    /// **Without a file extension**, and that is deliberate: whether a file contains JPEG or PNG
    /// is decided only on storing (see ``format(forItem:)``) — on reading nobody would know under
    /// which of the two extensions to look. `CGImageSource` recognizes the format by the content
    /// and not by the name.
    private func path(for key: String) -> URL? {
        guard let folder else { return nil }
        let hashValue = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(hashValue)
    }
}
