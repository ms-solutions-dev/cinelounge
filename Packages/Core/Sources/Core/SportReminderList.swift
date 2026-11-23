import Foundation

/// **A watchlist for the schedule — the same on both devices** (decision 27,
/// B5, 2026-09-26).
///
/// **Until then each device remembered something different.** The TV followed
/// teams and competitions (`SportMemory`, in the Keychain under
/// `schedule.watchlist.v1`), the phone remembered single matches
/// (`Merkzettel`, in the file store under `live.sportMarks`). A club followed
/// on the TV was unknown on the phone, and a match bookmarked on the phone
/// was not visible on the TV. **Both in one** is decided: following a club or
/// competition (applies to all its matches) **and** bookmarking a single
/// match.
///
/// Clubs and competitions are compared in the normal form (lowercase, without
/// diacritics): "Demirbahçe" and "DEMIRBAHCE" are the same club. A match is
/// remembered by its ID (``SportEvent/id``) — it is built from sport, folded
/// title and start time and so survives every recomputation.
public struct SportReminderList: Sendable, Equatable, Codable {
    /// Stored keys keep their original (German) names — renaming them would
    /// make data written by earlier versions unreadable (AP85 B4).
    private enum CodingKeys: String, CodingKey {
        case teams
        case competitions
        case labels
        case matches = "spiele"
    }

    public private(set) var teams: Set<String> = []
    public private(set) var competitions: Set<String> = []

    /// The display names as they came in when remembered — the key is the normal
    /// form, the value is what the viewer reads.
    public private(set) var labels: [String: String] = [:]

    /// Individually bookmarked matches, by ``SportEvent/id``.
    public private(set) var matches: Set<String> = []

    public init() {}

    /// **Every field may be missing.** The TV's list knows no matches, and a field
    /// that a later version adds must not make the rest unreadable.
    public init(from decoder: any Decoder) throws {
        let field = try decoder.container(keyedBy: CodingKeys.self)
        teams = try field.decodeIfPresent(Set<String>.self, forKey: .teams) ?? []
        competitions = try field.decodeIfPresent(Set<String>.self, forKey: .competitions) ?? []
        labels = try field.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        matches = try field.decodeIfPresent(Set<String>.self, forKey: .matches) ?? []
    }

    /// Whether anything is remembered at all.
    public var isEmpty: Bool { teams.isEmpty && competitions.isEmpty && matches.isEmpty }

    // MARK: - Folgen

    public mutating func toggleTeam(_ name: String) {
        setEnabled(name, in: \.teams)
    }

    public mutating func toggleCompetition(_ name: String) {
        setEnabled(name, in: \.competitions)
    }

    private mutating func setEnabled(_ name: String, in members: WritableKeyPath<Self, Set<String>>) {
        let key = SportKind.normalized(name)
        guard !key.isEmpty else { return }
        if self[keyPath: members].contains(key) {
            self[keyPath: members].remove(key)
            labels.removeValue(forKey: key)
        } else {
            self[keyPath: members].insert(key)
            labels[key] = name
        }
    }

    public func hasTeam(_ name: String) -> Bool {
        teams.contains(SportKind.normalized(name))
    }

    public func hasCompetition(_ name: String) -> Bool {
        competitions.contains(SportKind.normalized(name))
    }

    // MARK: - Vormerken

    /// Bookmarks a single match or removes the bookmark.
    public mutating func toggleMatch(_ identifier: String) {
        guard !identifier.isEmpty else { return }
        if matches.contains(identifier) {
            matches.remove(identifier)
        } else {
            matches.insert(identifier)
        }
    }

    public func isBookmarked(_ event: SportEvent) -> Bool {
        matches.contains(event.id)
    }

    // MARK: - Anwenden

    /// Whether an event carries a remembered team or a remembered competition.
    public func follows(_ event: SportEvent) -> Bool {
        if let competition = event.competition,
            competitions.contains(SportKind.normalized(competition))
        {
            return true
        }
        guard !teams.isEmpty else { return false }
        let title = SportKind.normalized(event.title)
        return teams.contains { title.contains($0) }
    }

    /// **Remembered is what one has bookmarked or whom one follows** — the one
    /// question that ordering, the "Bookmarked" filter and the star on the row
    /// ask.
    public func marks(_ event: SportEvent) -> Bool {
        isBookmarked(event) || follows(event)
    }

    /// Clears out bookmarked matches that are no longer in the schedule.
    ///
    /// **Otherwise the list grows forever.** Nobody can see a match from
    /// yesterday any more.
    /// **Only against a filled schedule:** without a fetched guide it is empty,
    /// and then "whatever is not in it gets thrown out" would simply mean:
    /// everything. **Clubs and competitions stay** — one follows them beyond the
    /// day.
    ///
    /// - Returns: whether anything changed.
    @discardableResult
    public mutating func cleanUp(to validOnes: Set<String>) -> Bool {
        guard !validOnes.isEmpty else { return false }
        let retained = matches.intersection(validOnes)
        guard retained != matches else { return false }
        matches = retained
        return true
    }

    // MARK: - Ablage

    /// The key in the file store.
    ///
    /// **No "sport." prefix:** that is the namespace of the language catalogs, and
    /// the key checker would otherwise take the store key for a missing
    /// translation.
    public static let key = "spielplan.merkzettel.v2"

    /// Where the TV kept its list until 2026-09-26 — in the Keychain.
    static let legacyTV = "spielplan.merkzettel.v1"

    /// Where the phone kept its matches until 2026-09-26 — in the file store,
    /// before that (until AP40) in the user defaults. **Assembled from parts**,
    /// because the key checker would otherwise take a text with a "live." prefix
    /// for a missing translation.
    static let legacyPhone = ["live", "sportMarks"].joined(separator: ".")
}

/// **Where the watchlist lives: per profile in the file store** (B5,
/// 2026-09-26).
///
/// **The same pattern as ``ProfileStore/bucket(_:forItem:)`` for the channel
/// history**, and without fallback to the device: whom the child follows is no
/// business of the parents, and vice versa. A fallback would be exactly the
/// way in which one person's club would appear at the top for another.
///
/// **One-time takeover of the two old lists.** If the profile's compartment
/// still holds nothing, the TV's clubs and competitions (Keychain) and the
/// phone's matches (file store, before that user defaults) are merged and
/// written to the compartment — and **only when reading it back succeeds**
/// deleted at the old locations (decision 2 of 2026-09-25: clean cut, only
/// after a successful takeover). The takeover goes to the profile that reads
/// first; that is, as a rule, the one who created the list. **A child never
/// reads** (Live check, finding 4, 2026-09-27): the schedule is missing for
/// the child on both devices (`ChildTarget.sport`), and since then the phone
/// builds its schedule model only with a sport page — before, the child also
/// read and got the parents' bookmarks into its compartment.
///
/// **On the TV in the Keychain, not in the file store** (finding 9): there
/// the ``FileStore`` falls back to `Caches`, which the system clears. See
/// ``tv()``.
public final nonisolated class SportReminderListStore: @unchecked Sendable {

    let store: any KeyValueStore
    private let profile: @Sendable () -> String?
    private let keychain: (any KeyValueStore)?
    private let old: UserDefaults?
    /// Where this device's list lay **since 2026-09-26**, if that is not
    /// ``store`` — on the TV the file store (``tv()``). A list there moves
    /// once into the compartment of ``store`` and is only cleared after a
    /// successful read-back.
    private let previous: (any KeyValueStore)?

    /// - Parameters:
    ///   - profil: Whose list — **asked on every access**, so that a profile
    ///     switch takes effect without a new model.
    ///   - schluesselbund: the TV's old location. Tests pass `nil` or an
    ///     in-memory store.
    ///   - alt: the phone's oldest location. Tests pass `nil`.
    public init(
        store: any KeyValueStore = FileStore(),
        profile: @escaping @Sendable () -> String? = { ProfilePointer.active },
        keychain: (any KeyValueStore)? = SecureStore(),
        old: UserDefaults? = .standard,
        previous: (any KeyValueStore)? = nil
    ) {
        self.store = store
        self.profile = profile
        self.keychain = keychain
        self.old = old
        self.previous = previous
    }

    /// The TV's store — **in the Keychain**, like its other preferences (live
    /// preferences, sound, subtitles via ``ProfileStore``).
    ///
    /// **Checked against the code and the device finding of 2026-08-16:**
    /// ``FileStore`` tries Application Support and falls back to `Caches` when
    /// nothing arrives there — and on the Apple TV nothing arrived there. The
    /// system may clear `Caches`; followed clubs and competitions would then be
    /// gone. Until 2026-09-26 the TV's list lived in the Keychain and survived
    /// that. What has lived in the file store since then, ``previous`` fetches over
    /// once.
    public static func tv(
        profile: @escaping @Sendable () -> String? = { ProfilePointer.active }
    ) -> SportReminderListStore {
        let sharedStore = SecureStore()
        return SportReminderListStore(
            store: sharedStore, profile: profile, keychain: sharedStore, old: nil, previous: FileStore())
    }

    private var bucket: String { ProfileStore.bucket(SportReminderList.key, forItem: profile()) }

    public func read() -> SportReminderList {
        if let own = RecordSheet.read(SportReminderList.self, under: bucket, from: store) {
            return own
        }
        if let migration = adoptsPrevious() { return migration }
        return adoptsOldLists()
    }

    /// The list from ``previous`` — **only its own compartment**, deleted only after
    /// read-back (decision 2).
    private func adoptsPrevious() -> SportReminderList? {
        guard let previous,
            let found = RecordSheet.read(SportReminderList.self, under: bucket, from: previous)
        else { return nil }
        RecordSheet.write(found, under: bucket, in: store)
        if RecordSheet.read(SportReminderList.self, under: bucket, from: store) == found {
            RecordSheet.cleanUp(bucket, in: previous)
        }
        return found
    }

    /// **Nothing remembered means: no entry** (``RecordSheet/cleanUp(_:in:)``).
    public func write(_ watchlist: SportReminderList) {
        if watchlist.isEmpty {
            RecordSheet.cleanUp(bucket, in: store)
        } else {
            RecordSheet.write(watchlist, under: bucket, in: store)
        }
    }

    private func adoptsOldLists() -> SportReminderList {
        var watchlist = SportReminderList()
        var found = false
        if let keychain,
            let alter = RecordSheet.read(
                SportReminderList.self, under: SportReminderList.legacyTV, from: keychain)
        {
            watchlist = alter
            found = true
        }
        let matchesFile = RecordSheet.read(
            [String].self, under: SportReminderList.legacyPhone, from: store)
        let legacyMatches = old?.stringArray(forKey: SportReminderList.legacyPhone)
        for identifier in (matchesFile ?? []) + (legacyMatches ?? [])
        where !watchlist.matches.contains(identifier) {
            watchlist.toggleMatch(identifier)
            found = true
        }
        guard found else { return watchlist }

        RecordSheet.write(watchlist, under: bucket, in: store)
        guard RecordSheet.read(SportReminderList.self, under: bucket, from: store) == watchlist else {
            return watchlist
        }
        if let keychain { try? keychain.remove(SportReminderList.legacyTV) }
        if matchesFile != nil { RecordSheet.cleanUp(SportReminderList.legacyPhone, in: store) }
        if legacyMatches != nil { old?.removeObject(forKey: SportReminderList.legacyPhone) }
        return watchlist
    }
}
