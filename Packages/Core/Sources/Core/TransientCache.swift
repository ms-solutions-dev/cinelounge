import Foundation

/// What the app has lying on disk — and how to get rid of it again.
///
/// **What for** (AP18): The app stores a few things, and none of it was visible:
/// the channel database (15 MB at the test provider), the episode index, the list
/// copies, the diagnostic traces, the pictures. On a TV with 32 gigabytes this is
/// no side issue — and anyone who wants to know whether the app is the reason for
/// "storage full" had no way of looking so far.
///
/// **And clearing is no loss.** Everything here is a copy of something that lives
/// elsewhere: Channels and program come from the provider, the lists from Jellyfin,
/// the pictures from both. What is lost is time at the next opening — not content.
/// That is exactly why it lives in the cache directory, which the system may also
/// clear.
///
/// **The diagnostic trace stays anyway** when only "clean up" is pressed: It is the
/// only thing here that cannot be restored, and anyone currently investigating an
/// error would throw it away with the cleanup.
public enum TransientCache {

    /// An item with its size.
    public struct LineItem: Sendable, Equatable, Identifiable {
        /// The key for the translation, not the text itself.
        public let nameKey: String
        public let bytes: Int64
        /// Whether "clean up" takes it along.
        public let isCleared: Bool

        public var id: String { nameKey }
    }

    /// How an item in the directory is recognized.
    ///
    /// By name pattern and not by subdirectory, because the stores historically lie
    /// flat next to each other — a move would be a trek through five packages for a
    /// display value.
    struct Pattern: Sendable {
        let nameKey: String
        let prefix: [String]
        let isCleared: Bool
    }

    static let patterns: [Pattern] = [
        // Channels and program — the database together with its companion files (`-wal`,
        // `-shm`), hence as a prefix and not as a name.
        .init(nameKey: "cache.channels", prefix: ["cinelounge-live"], isCleared: true),
        .init(nameKey: "cache.episodes", prefix: ["cinelounge-folgen"], isCleared: true),
        // The list copies live as a **directory** under `CineLounge/Lists`.
        .init(nameKey: "cache.lists", prefix: ["CineLounge"], isCleared: true),
        // Start and file header of IPTV films (AP62) — the second start gets back to
        // ~8 s without them, nothing is lost.
        .init(nameKey: "cache.fileHeads", prefix: ["Dateikoepfe"], isCleared: true),
        // The picture of the place where playback continues (AP63) — gone means: until the
        // next stop the episode or series picture.
        .init(nameKey: "cache.stills", prefix: ["Standbilder"], isCleared: true),
        // **The pictures are counted here but not cleared.** They live in a `URLCache`
        // that the system manages itself; taking files away there under its hand is a
        // different operation from emptying a directory. The button for that has long
        // existed — it goes through the `URLCache` itself, and two paths to the same thing
        // would be one too many.
        .init(nameKey: "cache.images", prefix: ["cinelounge.images"], isCleared: false),
        // **Not cleared**, see the rationale at the enumeration above. Both traces: the
        // error trace always runs, the verbose one only with a switch — neither may be
        // thrown away while someone is investigating an error.
        .init(
            nameKey: "cache.diagnostics",
            prefix: ["cinelounge-spur", "cinelounge-fehler"], isCleared: false),
    ]

    /// How large an entry is — for a directory including everything in it.
    ///
    /// **Via `FileManager` and not via `resourceValues`** of the URL: The latter holds
    /// on to the first value read per URL instance — the same pitfall that already
    /// affected the ``TraceRecorder``.
    static func size(from entry: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: entry.path)
        if (attributes?[.type] as? FileAttributeType) == .typeDirectory {
            let content =
                FileManager.default.enumerator(atPath: entry.path)?
                .compactMap { $0 as? String } ?? []
            return content.reduce(0) { sum, name in
                let file = entry.appendingPathComponent(name)
                let values = try? FileManager.default.attributesOfItem(atPath: file.path)
                // **Subdirectories do not count.** A directory itself has a size (on APFS 64 to 96
                // bytes per entry) — anyone who counts it reports a number that depends on the file
                // system and not on the content. Measured in the test: 1224 instead of 1000 bytes
                // for two files in two levels.
                guard (values?[.type] as? FileAttributeType) != .typeDirectory else { return sum }
                return sum + (((values?[.size]) as? NSNumber)?.int64Value ?? 0)
            }
        }
        return ((attributes?[.size]) as? NSNumber)?.int64Value ?? 0
    }

    /// What lies in a directory — **and in the shared folder with the Top Shelf**, if
    /// it is the app's caches: There the still frames have lived since 2026-10-01
    /// (``StillFrameStore``). Without it the listing did not count them and never
    /// cleared them.
    static func content(from directory: URL) -> [URL] {
        var locations = [directory]
        let own = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        if directory == own, let shared = StillFrameStore.sharedCaches {
            locations.append(shared)
        }
        return locations.flatMap {
            (try? FileManager.default.contentsOfDirectory(
                at: $0, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        }
    }

    /// Measures what lies in a directory.
    ///
    /// - Parameter verzeichnis: The default is the app's cache.
    public static func catalog(
        in directory: URL? = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first
    ) -> [LineItem] {
        guard let directory else { return [] }
        let files = content(from: directory)

        var sums: [String: Int64] = [:]
        var remaining: Int64 = 0
        for file in files {
            let name = file.lastPathComponent
            let bytes = size(from: file)
            if let match = patterns.first(where: { m in m.prefix.contains { name.hasPrefix($0) } }) {
                sums[match.nameKey, default: 0] += bytes
            } else {
                remaining += bytes
            }
        }

        var items = patterns.compactMap { m -> LineItem? in
            guard let bytes = sums[m.nameKey], bytes > 0 else { return nil }
            return LineItem(nameKey: m.nameKey, bytes: bytes, isCleared: m.isCleared)
        }
        // **The remainder is listed and not concealed.** A listing that names less than
        // the disk holds does not answer the question for which someone is looking at it.
        if remaining > 0 {
            items.append(LineItem(nameKey: "cache.other", bytes: remaining, isCleared: true))
        }
        return items.sorted { $0.bytes > $1.bytes }
    }

    /// Cleans up and reports how much was freed.
    @discardableResult
    public static func cleanUp(
        in directory: URL? = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first
    ) -> Int64 {
        guard let directory else { return 0 }
        let shielded = Set(patterns.filter { !$0.isCleared }.flatMap(\.prefix))
        let files = content(from: directory)

        var unrestricted: Int64 = 0
        for file in files {
            let name = file.lastPathComponent
            guard !shielded.contains(where: { name.hasPrefix($0) }) else { continue }
            let bytes = size(from: file)
            guard (try? FileManager.default.removeItem(at: file)) != nil else { continue }
            unrestricted += bytes
        }
        return unrestricted
    }

    /// "15.2 MB" — for the display.
    public static func readable(_ bytes: Int64) -> String {
        let former = ByteCountFormatter()
        former.allowedUnits = [.useKB, .useMB, .useGB]
        former.countStyle = .file
        return former.string(fromByteCount: bytes)
    }
}
