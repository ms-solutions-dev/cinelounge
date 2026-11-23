import Foundation

/// The copy of the structure store in `UserDefaults` — see ``FileStore``.
///
/// **A budget, because the space is shared and tight:** tvOS guarantees about 500 KB via
/// `UserDefaults`, for the whole app. The backup takes at most ``budget``, a single entry
/// only up to ``entryLimit`` — a profile picture or a long list would otherwise
/// overwhelm everything else. What does not fit is reported once and stays only in the
/// file.
///
/// **The limit per entry is 96 KB, no longer 32** (AP71, 2026-10-11): The still-frame
/// ledger — the most important entry, the person's progress — was at 80–107 KB with a full
/// journal and thus **always** fell out; progress on the TV was never backed up. The
/// journal is now small (``StillLedger/maximumCount``), and what still lies above the limit is
/// written **compactly** before measuring: The file stays readable with indentation, the
/// copy does not need the whitespace.
///
/// `@unchecked Sendable`, because `UserDefaults` is thread-safe according to Apple but not
/// marked as such.
struct StoreBackup: @unchecked Sendable {
    static let budget = 300 * 1024
    static let entryLimit = 96 * 1024

    struct ContentEntryRecord: Codable, Equatable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case value = "wert"
            case changed = "geaendert"
        }

        var value: String
        var changed: Date
    }

    private let store: UserDefaults
    private let prefix: String

    init(store: UserDefaults, folder: String) {
        self.store = store
        self.prefix = "ablage§\(folder)§"
    }

    private var sizesKey: String { prefix + "§groessen" }

    /// How much the backup occupies per key.
    var sizes: [String: Int] {
        store.dictionary(forKey: sizesKey) as? [String: Int] ?? [:]
    }

    func memorize(_ value: String, forItem key: String, changed: Date) {
        // Measure first what would really fit: indented JSON carries about 40 % whitespace.
        let compact = value.utf8.count > Self.entryLimit ? Self.compact(value) : value
        let size = compact.utf8.count
        var taken = sizes
        let withoutThis = taken.values.reduce(0, +) - (taken[key] ?? 0)
        guard size <= Self.entryLimit, withoutThis + size <= Self.budget,
            let data = try? JSONEncoder().encode(ContentEntryRecord(value: compact, changed: changed))
        else {
            // A stale state in the backup would be worse than none.
            if taken[key] != nil { forget(key) }
            // **Once per key**, as promised above — before, the line appeared on every write, that is
            // every ten seconds during playback (F-017: 428 lines).
            if Self.reported.memorize(prefix + key) {
                Diagnostics.defect(
                    "Structure store: “\(key)” (\(size >> 10) KB) does not fit into the backup — "
                        + "it is lost when the system clears the cache",
                    since: nil, area: "Ablage")
            }
            return
        }
        store.set(data, forKey: prefix + key)
        taken[key] = size
        store.set(taken, forKey: sizesKey)
    }

    func entry(forItem key: String) -> ContentEntryRecord? {
        guard let data = store.data(forKey: prefix + key) else { return nil }
        return try? JSONDecoder().decode(ContentEntryRecord.self, from: data)
    }

    func forget(_ key: String) {
        store.removeObject(forKey: prefix + key)
        var taken = sizes
        if taken.removeValue(forKey: key) != nil { store.set(taken, forKey: sizesKey) }
    }

    /// JSON without indentation and line breaks; what is not JSON stays as it is.
    static func compact(_ value: String) -> String {
        guard let raw = value.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: raw),
            let dense = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let text = String(data: dense, encoding: .utf8)
        else { return value }
        return text
    }

    /// Which keys have already been reported in this run.
    private static let reported = Reported()

    private final class Reported: @unchecked Sendable {
        private let lock = NSLock()
        private var keys: Set<String> = []
        /// `true` if the key is new — then it is reported.
        func memorize(_ keyName: String) -> Bool {
            lock.withLock { keys.insert(keyName).inserted }
        }
    }
}
