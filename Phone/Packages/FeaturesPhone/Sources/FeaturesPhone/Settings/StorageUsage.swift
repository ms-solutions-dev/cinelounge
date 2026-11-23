import Diagnose
import Downloads
import Foundation

/// What the app occupies on this device — **measured and not estimated.**
///
/// **The finding of 2026-09-07:** "What is on this device" was a row under the account,
/// `StorageView.swift` was eight lines of comment, and the way there ended in the developer
/// placeholder — three taps away from Settings the viewer saw "speicher · not built yet" with
/// three developer buttons.
///
/// **What stands here is what is really there today.** The downloads from AP2 are not built;
/// showing them as an empty item would be a claim about something that does not exist. What
/// is shown are the three items that are measurable — images, log, the rest — and the
/// device's free space next to them, because "3.8 GB" is no statement without it.
///
/// **The device's storage space is information that has to be declared.** Apple's privacy
/// manifest lists it under `NSPrivacyAccessedAPICategoryDiskSpace`, reason 85F4.1 — and that
/// expressly allows only display on the device. **It therefore must not go into the
/// diagnostic report**, which goes to the media server.
public enum StorageUsage {

    /// An item of the household.
    public struct LineItem: Sendable, Identifiable {
        public let id: String
        public let bytes: Int64

        /// **Whether it stays until somebody deletes it.**
        ///
        /// Only the downloads. Everything else is cache and comes back — this is no judgment but the
        /// information that is missing before cleaning up: a deleted poster is back on the next
        /// open, a deleted film is not. Calling both "storage" and letting them look the same is the
        /// reason why viewers delete their downloads by accident.
        public var remains = false

        public init(id: String, bytes: Int64, remains: Bool = false) {
            self.remains = remains
            self.id = id
            self.bytes = bytes
        }
    }

    /// Where the app stores its things.
    private static var applicationSupport: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    private static var cache: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }

    /// How big a folder is — **recursively and without throwing.**
    ///
    /// A failure while counting is no error of the viewer: they then get a smaller number and no
    /// message. An error message about a folder that cannot be read helps nobody and stands above
    /// a view that is otherwise correct.
    static func size(_ location: URL?) -> Int64 {
        guard let location,
            let run = FileManager.default.enumerator(
                at: location, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        else { return 0 }
        var sum: Int64 = 0
        for scenario in run {
            guard let file = scenario as? URL,
                let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
                let bytes = values.totalFileAllocatedSize
            else { continue }
            sum += Int64(bytes)
        }
        return sum
    }

    /// The measurable items, largest first.
    ///
    /// **The downloads have been included since 2026-09-08, and that was overdue.** They lie under
    /// `Application Support/Vorrat` — thus **within** what "Other" had been adding up until then.
    /// Fourteen gigabytes of films stood under a heading that suggests "can go"; exactly that is
    /// what the screen they appear on warns against. They are subtracted here and listed
    /// separately.
    /// Which files in the downloads belong to what — **the information this type does not have.**
    ///
    /// **The finding of 2026-09-12, from a product requirement:** under Storage, content should
    /// be separated by kind … when videos have been downloaded, there should also be videos
    /// under Clean up. The downloads stood as **one** number, and in it films, posters, details
    /// and the leftovers of aborted downloads lay together.
    ///
    /// **The names of the files do not carry their kind.** `Store.fileName(forItem:)` produces a
    /// hash identifier without an extension — `e221619bca8fb99c08d83212a3c55626` does not say
    /// whether a film or a poster is in it. Only whoever knows the entries can separate, and the
    /// downloads know them and not this type. That is why the knowledge is passed in — the same
    /// design as with ``StartPreferences/show(_:_:from:)``.
    public struct DownloadFiles: Sendable {

        /// File names that belong to a download job — the actual films.
        public let videos: Set<String>

        /// File names that the description ledger keeps: posters, backgrounds, logos, faces, plus
        /// the ledger itself and the permanent list.
        public let details: Set<String>

        public init(videos: Set<String>, details: Set<String>) {
            self.videos = videos
            self.details = details
        }

        /// **No knowledge, and that is not the same as "nothing there".** Without set-up downloads
        /// there are no entries, and then every file would be "orphaned" — a claim that nobody has
        /// verified. Then the downloads remain a single number.
        public static let unknown = DownloadFiles(videos: [], details: [])

        var hasKnowledge: Bool { !videos.isEmpty || !details.isEmpty }
    }

    /// The measurable items, in display order.
    ///
    /// **Two shapes, and the choice depends on knowledge.** With known files the downloads split
    /// into videos, details and orphaned; without, they stay a number. The lookup is by
    /// identifier and never by position — see the finding of 2026-09-12 in ``StorageView``.
    public static func items(downloads files: DownloadFiles = .unknown) -> [LineItem] {
        let frames = size(cache?.appending(path: "bilder"))
        let log = size(applicationSupport?.appending(path: "Diagnose"))
        let downloadsFolder = applicationSupport?.appending(path: Store.folderName)
        let downloads = size(downloadsFolder)
        let other = max(
            0,
            size(applicationSupport) - log - downloads + size(cache) - frames)

        var split: [LineItem] = []
        if files.hasKnowledge, let downloadsFolder {
            let sizes = splitSizes(in: downloadsFolder, files)
            split = [
                LineItem(id: "storage.videos", bytes: sizes.videos, remains: true),
                LineItem(id: "storage.details", bytes: sizes.details, remains: true),
                LineItem(id: "storage.orphans", bytes: sizes.orphaned, remains: true),
            ]
        } else {
            split = [LineItem(id: "storage.stock", bytes: downloads, remains: true)]
        }

        return split + [
            LineItem(id: "storage.images", bytes: frames),
            LineItem(id: "storage.log", bytes: log),
            LineItem(id: "storage.other", bytes: other),
        ]
    }

    /// Add up the downloads folder by kind.
    ///
    /// **Only the top level**, and that is no simplification: `Store` stores flat. A descent
    /// into the depth would find nothing there and would cost a directory tree every time on a
    /// disk with fourteen gigabytes of films.
    static func splitSizes(
        in folder: URL, _ files: DownloadFiles
    ) -> (videos: Int64, details: Int64, orphaned: Int64) {
        let content =
            (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])) ?? []
        var videos: Int64 = 0
        var details: Int64 = 0
        var orphaned: Int64 = 0
        for file in content {
            let bytes = Int64(
                (try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                    .totalFileAllocatedSize ?? 0)
            let name = file.lastPathComponent
            // **Partial files count toward the video they belong to.** An aborted download is no
            // orphaned leftover as long as its job is still there — it will be resumed. See
            // ``Store/partialName(forItem:)``.
            if files.videos.contains(name) {
                videos += bytes
            } else if files.details.contains(name) {
                details += bytes
            } else {
                orphaned += bytes
            }
        }
        return (videos, details, orphaned)
    }

    /// How much is still free on the device — `nil` if the system does not say.
    public static func unrestricted() -> Int64? {
        guard let location = applicationSupport,
            let values = try? location.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        else { return nil }
        return values.volumeAvailableCapacityForImportantUsage
    }

    /// What stands in the value column of the root.
    public static func short() -> String {
        readable(items().reduce(0) { $0 + $1.bytes })
    }

    /// **How iOS writes sizes and not how a programmer calculates them.**
    ///
    /// `ByteCountFormatStyle` brings along the rules of the system — decimal prefixes, the
    /// language's separator, the usual number of decimal places. Calculated by hand, the Turkish
    /// version would have a period where a comma belongs.
    public static func readable(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }
}
