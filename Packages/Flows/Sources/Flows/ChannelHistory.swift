import Core
import Foundation
import ProfileKit

/// Which channels ran last — **per profile and beyond the app run.**
///
/// **Why this is not in the app's history.** That remembers how far someone is into a
/// film; a channel has no progress and explicitly does not belong there.
/// "Recently watched" is nevertheless the most common intention for a channel — the answer to
/// "my channel", and with 7,746 rows obtainable without this list only through search.
///
/// **Per profile since AP58 R5 (finding L1, 2026-09-26).** Until then the list lay in the
/// phone's default settings and belonged to the **device**: Whoever watched TV after the child
/// found its channels at the top — and the child the next day those of an adult, as a
/// suggestion on the Home screen. The TV has kept its last watched channel per person
/// since AP42 (``LiveMemory``).
///
/// **The name is remembered and not the ID** (``Channel/channelName``) — an
/// Xtream ID changes when the provider rebuilds its list. The name excludes the
/// quality mark: Whoever saw "Das Nordlicht HD" yesterday and finds only "Das Nordlicht" today
/// means the same channel.
///
/// **In the profile's compartment in the file store** (``ProfileStore/bucket(_:forItem:)``) and not in the
/// ``StillLedger``: The book is the outbox for the sync, and an abbreviation in
/// a list is nothing that would have to travel between devices. **Without fallback to the
/// device compartment**, unlike ``ProfileStore/value(for:)`` — exactly that fallback would be the
/// path by which the child sees an adult's channels.
public final nonisolated class ChannelHistory: @unchecked Sendable {

    /// **Eight and not fifty.** The list sits above the channel list and takes space
    /// from it; it should answer "my channel" and not be a second directory.
    public static let length = 8

    static let key = "live.recentChannels"

    private let store: any KeyValueStore
    private let profile: @Sendable () -> String?
    private let legacy: UserDefaults?

    /// - Parameters:
    ///   - profil: Whose list — **asked on every access**, so that a profile switch
    ///     takes effect without a new model.
    ///   - alt: Where the list lay for the whole device until 2026-09-26. On the
    ///     first read it goes **once** to the profile that is then watching — in all
    ///     likelihood the one who created it — and is deleted there. Checks give `nil`.
    public init(
        store: any KeyValueStore = FileStore(),
        profile: @escaping @Sendable () -> String? = { ProfilePointer.active },
        legacy: UserDefaults? = .standard
    ) {
        self.store = store
        self.profile = profile
        self.legacy = legacy
    }

    private var bucket: String { ProfileStore.bucket(Self.key, forItem: profile()) }

    /// A remembered channel — **with the moment it last ran** (C5, 2026-09-26).
    ///
    /// The time was added so that "Continue Watching" has the same deadline on both devices
    /// (``applies``). Lists from before carry only names; they read as entries without
    /// a time and thus apply to the list but no longer to "Continue Watching".
    public struct ContentEntryRecord: Sendable, Equatable, Codable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case name
            case timestamp = "zeitpunkt"
            case forgotten = "vergessen"
        }

        public let name: String
        public let timestamp: Date?
        /// **When it was taken out of "Continue Watching"** (2026-09-29) — a tombstone. Until
        /// then there was only an empty timestamp here, and when merging with another
        /// device its dated entry won: The channel came back.
        public var forgotten: Date? = nil
    }

    /// How long a channel stays in "Continue Watching": **six hours.**
    ///
    /// Long enough for an evening, short enough that it is gone the next morning. A
    /// channel keeps running whether one watches or not — what one saw yesterday no longer exists
    /// today. Until 2026-09-26 the deadline existed only in the phone's history.
    public static let applies: TimeInterval = 6 * 60 * 60

    /// The entries, last watched first.
    public var entries: [ContentEntryRecord] {
        if let own = RecordSheet.read([ContentEntryRecord].self, under: bucket, from: store) { return own }
        if let names = RecordSheet.read([String].self, under: bucket, from: store) {
            return names.map { ContentEntryRecord(name: $0, timestamp: nil) }
        }
        return adoptLegacyList().map { ContentEntryRecord(name: $0, timestamp: nil) }
    }

    /// The names, last watched first.
    public var names: [String] { entries.map(\.name) }

    /// The names that ran **in the last six hours** — what "Continue Watching"
    /// shows.
    public func recentlyUsed(now: Date = Date()) -> [String] {
        entries.compactMap { entry in
            guard let timestamp = entry.timestamp,
                now.timeIntervalSince(timestamp) < Self.applies
            else { return nil }
            return entry.name
        }
    }

    /// Bring a channel to the front.
    ///
    /// **To the front and not added**: Whoever watches the same channel twice has
    /// last watched it once.
    public func memorize(_ name: String, um now: Date = Date()) {
        var list = entries.filter { $0.name != name }
        list.insert(ContentEntryRecord(name: name, timestamp: now), at: 0)
        RecordSheet.write(Array(list.prefix(Self.length)), under: bucket, in: store)
        // **The history travels along** (``ProfileKit/DocumentPreference``, 2026-09-28) — pushed up straight away,
        // so that the other device shows it in "Continue Watching".
        SyncCall.call(.byHand)
    }

    /// **Only what has been read back is deleted** (decision 2; Live check, finding 3,
    /// 2026-09-27) — as with the ``Core/SportReminderList``. If the store does not write (on Apple TV
    /// this is documented, ``Core/FileStore``), the old list stays and is offered again at the
    /// next read, instead of being gone for good after one read.
    /// Takes a channel out of "Continue Watching" — **without striking it from the list**
    /// (Live check, finding 7, 2026-09-27).
    ///
    /// The entry loses only its timestamp: For "recently watched" in the Live shelf
    /// it stays where it is, for ``recentlyUsed(now:)`` it no longer applies. Until then only
    /// the six-hour deadline cleared the tile.
    public func forget(_ name: String) {
        let list = entries
        guard list.contains(where: { $0.name == name && $0.timestamp != nil }) else { return }
        let now = Date()
        let without = list.map {
            $0.name == name ? ContentEntryRecord(name: $0.name, timestamp: nil, forgotten: now) : $0
        }
        RecordSheet.write(without, under: bucket, in: store)
        // Forgetting travels along too — otherwise the other device brings the channel back.
        SyncCall.call(.byHand)
    }

    private func adoptLegacyList() -> [String] {
        guard let legacy, let list = legacy.stringArray(forKey: Self.key), !list.isEmpty
        else { return [] }
        let trimmed = Array(list.prefix(Self.length))
        RecordSheet.write(trimmed, under: bucket, in: store)
        guard RecordSheet.read([String].self, under: bucket, from: store) == trimmed else {
            return trimmed
        }
        legacy.removeObject(forKey: Self.key)
        return trimmed
    }
}
