import Core
import Diagnose
import Foundation

/// Where the history lives, so that it survives app launch.
///
/// **On disk and not only in memory.** "What did I watch last" is the
/// question with which one opens the app the next day — a history that is empty on every launch
/// never answers it.
///
/// **And not in the Keychain.** What someone watched is not a secret in the sense of
/// credentials; it belongs in the same area as the remembered category and the
/// order of the shelves. The Keychain also survives deleting the app, and
/// that is exactly what a history should **not** do.
///
/// **One file per profile** (AP58, finding K4, 2026-09-26). Until then there was one file per
/// device, and the Continue Watching of a child profile showed what an adult had started on the same
/// phone. Which file applies is told by ``Core/ProfilePointer`` at the moment
/// of the question; without a pointer the device's file applies. The device file moves, on the first read with a
/// profile, **once** into that profile (``adoptDeviceCatalog(in:)``).
///
/// **The identifiers do not go into the error log.** A history row carries an image address
/// with the name of the media server in it; whatever goes wrong here is therefore reported without
/// the entry — the same rule as for the ``ImageStore``.
public actor HistoryStore {

    public static let shared = HistoryStore()

    private let basis: URL?
    /// What has already been read, per profile — `""` is the device.
    private var held: [String: History] = [:]

    /// - Parameter ordner: where to store. By default in the application support directory of the
    ///   app; the checks pass their own so they leave nothing behind.
    public init(folder: URL? = nil) {
        let basis =
            folder
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appending(path: "Verlauf")
        if let basis {
            try? FileManager.default.createDirectory(
                at: basis, withIntermediateDirectories: true,
                // **Locked as long as the device is locked** (2026-09-07, AP10).
                // Without this setting the platform default applies — readable as soon as the
                // device has been unlocked **once**. For access tokens that would be the
                // right choice (the ``Core/SecureStore`` makes it, with reasons);
                // for "what did this person watch" it is the wrong one.
                //
                // **The condition under which this holds is in a check and not
                // only here:** this file is read and written only in the foreground — player,
                // Home screen, portals. If a background task were ever added, it would read an empty
                // file on a locked device and "Continue Watching" would be silently empty, without an error. That is why
                // ``HistoryTests`` guards the absence of `BGTaskScheduler`.
                //
                // **And why this is a property of its own** (2026-09-09):
                // `FileProtectionType` does not exist on macOS. `createDirectory`
                // **throws** there on this attribute — the throw ran into the `try?`
                // above, the folder was never created, ``save(_:)`` wrote into the void and
                // ``load()`` returned an empty list. Exactly the two checks that go through the disk
                // were affected ("The history carries the series across
                // a restart", "… the format …"); both reported `nil` instead of the
                // value and thus looked as if the **encoding** were broken — which they never
                // reached. The package checks run on macOS, the device does not:
                // the protection stays where it takes effect (see ``protection``).
                attributes: Self.protection)
            Self.restoreFromBackup(basis)
        }
        self.basis = basis
    }

    /// The file of a profile — `history.json` for the device, `history-<profile>.json` otherwise.
    ///
    /// A profile identifier is a `UUID` text; whatever in it does not work as a file name
    /// is dropped, so that no identifier points out of the folder.
    func location(forItem profile: String?) -> URL? {
        guard let profile else { return basis?.appending(path: "verlauf.json") }
        let clean = profile.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        guard !clean.isEmpty else { return basis?.appending(path: "verlauf.json") }
        return basis?.appending(path: "verlauf-\(clean).json")
    }

    /// Moves the device catalog **once** into the profile that reads it first.
    ///
    /// Moved and not copied: a copy would land in every profile that reads afterwards for the
    /// first time, and a child profile would get the adults' history. This way
    /// the profile that is active at the update gets it, and no other. What carries no
    /// rating in it, child mode filters out anyway.
    private func adoptDeviceCatalog(in profile: String?) {
        guard profile != nil, let target = location(forItem: profile), let old = location(forItem: nil),
            target != old,
            !FileManager.default.fileExists(atPath: target.path),
            FileManager.default.fileExists(atPath: old.path)
        else { return }
        do {
            try FileManager.default.moveItem(at: old, to: target)
            held[""] = nil
            Diagnose.step(.downloads, "Device history adopted into the active profile")
        } catch {
            Diagnose.hint(.downloads, "Device history not adopted")
        }
    }

    /// How the folder is protected — **locked on the device, not at all on the Mac.**
    /// The reasoning is at the call site in `init`.
    private static var protection: [FileAttributeKey: Any]? {
        #if os(iOS)
            [.protectionKey: FileProtectionType.complete]
        #else
            nil
        #endif
    }

    /// Takes the folder out of the iCloud backup.
    ///
    /// **The finding of 2026-09-07. (AP10):** The DocC of this file has always declared the content
    /// worth protecting — "a history row carries an image address with the name
    /// of the home server in it" — and yet stood without this line. The error log
    /// next door (``Diagnose/StoreLocation``) has always taken its folder out, with exactly
    /// the reasoning that applies here too: otherwise the history migrates into the
    /// iCloud backup, and the viewer learns about it from Apple.
    ///
    /// **And it does not contradict the sentence above.** "The Keychain survives
    /// deleting the app, and that is exactly what a history should not do" — a backup that
    /// keeps it beyond deletion is the same case, only via another route.
    private static func restoreFromBackup(_ folder: URL) {
        var folder = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }

    /// The history of the person currently watching.
    public func load() -> History {
        load(forItem: ProfilePointer.active)
    }

    private func load(forItem profile: String?) -> History {
        let key = profile ?? ""
        if let history = held[key] { return history }
        adoptDeviceCatalog(in: profile)
        guard let location = location(forItem: profile), let data = try? Data(contentsOf: location) else {
            held[key] = History()
            return History()
        }
        do {
            let read = try JSONDecoder().decode([Stored].self, from: data)
            let history = History(read.map(\.entry))
            held[key] = history
            return history
        } catch {
            // **Reported without the content.** A history row carries an image address with
            // the name of the home server in it.
            Diagnose.hint(.downloads, "History unreadable, creating a new one")
            held[key] = History()
            return History()
        }
    }

    /// Removes a title — **the one place where an entry disappears.**
    ///
    /// **It lives here and not in the view, and a test suite forced that.**
    /// "There is exactly one write point, and it lies in the player" counts the calls of
    /// ``save(_:)`` across the whole source; a long press on a tile would have been the
    /// second. The test suite turned out right, just not literally: what it is meant to
    /// prevent are second places that **create** a history — there were four of them
    /// in the TV program, all before the player, and whoever switched inside it passed
    /// none. A **removal** cannot do that damage.
    ///
    /// So it gets a name and a place instead of loosening the rule: whoever wants to change the
    /// history without having watched anything calls this method — and
    /// ``save(_:)`` stays with the player.
    public func remove(_ identifier: String, origin: Catalog.Origin) {
        var history = load()
        history.remove(identifier, origin: origin)
        save(history)
    }

    /// Throws away the history of **a removed profile** — file and held state.
    ///
    /// **The finding from the on-device test (build 1332, 2026-09-27):** On removal the
    /// shared management cleared the position, shelves and PIN of the person, but their history file
    /// stayed behind — this package does not know the management. "Their data goes with them" meant on the
    /// phone: except for what one watched last.
    public func forget(profile: String) {
        held[profile] = nil
        guard let location = location(forItem: profile), location != self.location(forItem: nil) else {
            return
        }
        try? FileManager.default.removeItem(at: location)
    }

    /// Writes the history of the person currently watching.
    public func save(_ history: History) {
        let profile = ProfilePointer.active
        adoptDeviceCatalog(in: profile)
        held[profile ?? ""] = history
        guard let location = location(forItem: profile) else { return }
        do {
            let data = try JSONEncoder().encode(history.entries.map(Stored.init))
            try data.write(to: location, options: .atomic)
        } catch {
            Diagnose.hint(.downloads, "History not written")
        }
    }

    /// **A form of its own for the disk**, not `HistoryEntry` itself.
    ///
    /// The entry is a display value and may change with the UI; what lies on
    /// the disk must stay readable across app versions. Whoever puts both into
    /// one type can no longer change either without breaking the other —
    /// the same separation as with `RatingsKit.Awards`, where an added field once
    /// would have made the entire cache unreadable.
    struct Stored: Codable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case identifier = "kennung"
            case origin = "herkunft"
            case title = "titel"
            case beside = "neben"
            case image = "bild"
            case backdrop = "hintergrund"
            case description = "beschreibung"
            case progress = "fortschritt"
            case timestamp = "zeitpunkt"
            case series = "serie"
            case wide = "breit"
            case approval = "freigabe"
        }

        let identifier: String
        let origin: String
        let title: String
        let beside: String?
        let image: String?
        let backdrop: String?
        let description: String?
        let progress: Double?
        let timestamp: Date

        /// Which series the episode belongs to — see ``HistoryEntry/series``.
        ///
        /// **The finding of 2026-09-07, on the device:** The field existed on the ``HistoryEntry``,
        /// but not here — it was never written, never read. So the whole
        /// chain ("the detail page passes its identifier along, the history writes it, the
        /// tile carries it") ended **at app launch**: after the next open the
        /// tile carried the episode identifier again, and for a portal the series cannot be derived from
        /// `serieshub|1-mebik|…`. Within one
        /// session it went unnoticed, because ``HistoryStore/held`` holds the entry
        /// completely.
        let series: String?

        /// Whether the image is landscape — see ``HistoryEntry/wide``.
        ///
        /// **The same chain as for ``series``, a day later** (2026-09-08): The field existed on
        /// the tile, but not here. Without this line a landscape poster would stand in the portrait frame
        /// again after the next app launch — unnoticeable within a session,
        /// because ``HistoryStore/held`` holds the entry completely.
        let wide: Bool?

        /// The rating — see ``HistoryEntry/approval``. Entries from before
        /// 2026-09-26 carry none.
        let approval: HistoryClearance?

        /// **Missing fields are read as empty, not as an error.**
        ///
        /// This form lies on the disk. If a field were added and expected on reading,
        /// every entry written before would be unreadable — and with it the whole
        /// history gone. That is exactly where such extensions fail; `RatingsKit.Awards`
        /// carries the same note for the same occasion.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            identifier = try container.decode(String.self, forKey: .identifier)
            origin = try container.decode(String.self, forKey: .origin)
            title = try container.decode(String.self, forKey: .title)
            beside = try container.decodeIfPresent(String.self, forKey: .beside)
            image = try container.decodeIfPresent(String.self, forKey: .image)
            backdrop = try container.decodeIfPresent(String.self, forKey: .backdrop)
            description = try container.decodeIfPresent(String.self, forKey: .description)
            progress = try container.decodeIfPresent(Double.self, forKey: .progress)
            timestamp = try container.decode(Date.self, forKey: .timestamp)
            series = try container.decodeIfPresent(String.self, forKey: .series)
            wide = try container.decodeIfPresent(Bool.self, forKey: .wide)
            approval = try container.decodeIfPresent(HistoryClearance.self, forKey: .approval)
        }

        init(_ entry: HistoryEntry) {
            identifier = entry.identifier
            origin = entry.origin.rawValue
            title = entry.title
            beside = entry.beside
            image = entry.image?.absoluteString
            backdrop = entry.backdrop?.absoluteString
            description = entry.description
            progress = entry.progress
            timestamp = entry.timestamp
            series = entry.series
            wide = entry.wide
            approval = entry.approval
        }

        var entry: HistoryEntry {
            HistoryEntry(
                identifier: identifier,
                // An unknown origin — from an older state, say — ends up with the
                // media server and drops out there at the latest via `validOnes(at:)`.
                // Discarding it would mean losing a whole history over one field.
                origin: Catalog.Origin(rawValue: origin) ?? .jellyfin,
                title: title, beside: beside, image: image.flatMap(URL.init(string:)),
                backdrop: backdrop.flatMap(URL.init(string:)),
                description: description, progress: progress, timestamp: timestamp,
                series: series, wide: wide, approval: approval)
        }
    }
}
