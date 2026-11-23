import CloudSync
import Core
import Foundation

/// A note that a profile has disappeared **on purpose** — deleted or merged into
/// another (AP43 · B5, AP45 "Merge", 2026-09-25).
///
/// **The finding:** ``ProfileCloud/find()`` treated every profile zone the book did not know
/// as a profile coming from another device. A profile that was just removed here
/// is exactly such a zone — and came back on the next launch, on this
/// device and on every other one of the same Apple ID.
///
/// **A tombstone and not a deleted zone, and that is the safe one of the two
/// variants.** Three reasons, each sufficient on its own:
/// - **A deleted zone rises again.** ``CloudSync/ProfileZone`` recreates an own zone
///   that is missing on fetch by itself and writes its mirror into it — that is how it is built
///   for the first pass. Every other device that still has the profile in its book (even
///   one with an older version) brings it back that way, and ``find()`` would find it
///   again. Without a note, deleting does not even help.
/// - **Deleting is final, a note is not.** Whoever made a mistake while merging
///   loses with the zone the state that another device may not yet have
///   synced; a note can be taken back (``lift(_:in:)``). The zone is deleted
///   only when the note expires after ``retention``.
/// - **A shared zone belongs to others too** (AP44): its participants would lose
///   access without being asked, because someone pressed "Remove" on a TV.
///
/// The price is stated too: the records of the vanished profile stay in this Apple account's
/// private database — where they were before, and visible to nobody
/// else.
///
/// **Two places, and both are needed.** On the device (``key`` in the book store), so that
/// the note holds without network and without an Apple account; in the **household zone**
/// (``PINFallback/zone``), so that every other device of the same Apple ID sees it. The
/// household zone is right for this because it is **never shared** and reaches exactly the devices
/// whose ``ProfileCloud/find()`` could see the zone at all.
///
/// **A note with a target is a move note since C2** (cross-check strand C, R1–R4).
/// It is laid **before** the book, and every device that still has the source in its book or in
/// its state follows it (``ProfileMove/episode(_:ledgerStore:keychain:startStore:)``).
/// Before, it stood only if everything went well — a crash between book and move left the
/// state under an identifier nobody read any more, and a second device that knew both
/// profiles kept writing into the dead zone.
public enum ProfileTombstone {

    /// The record type in the household zone.
    ///
    /// **New in the CloudKit schema** — promote from development to production before the next
    /// TestFlight build, like `Portalmarke`.
    public static let contentType = "Profilgrabstein"

    static let targetField = "ziel"
    static let liftedField = "aufgehoben"

    /// Where the notes live on the device.
    public static let key = "profiles.tombstones"

    /// How long a note holds — **180 days** (cross-check strand C, finding 8).
    ///
    /// **Without expiry the list would grow with every removal and every merge**, and
    /// every device would read it in full at every launch. Half a year is long enough that every
    /// device that is still used at all has seen and followed the note. What
    /// expires afterwards is cleared by ``ProfileCloud/find()`` together with the dead zone — otherwise
    /// it would find the zone the day after as a new profile.
    public static let retention: TimeInterval = 180 * 24 * 60 * 60

    /// How far a date may lie in the future before it counts as "now" — **one
    /// day** (final review 2026-09-25, C2-3).
    ///
    /// A device with a clock set ahead stamps its notes into the future; without this
    /// limit such a note would expire only half a year after a day that did not exist yet.
    /// One day of slack covers time zones and a badly set clock.
    public static let leadTime: TimeInterval = 24 * 60 * 60

    /// The name of the clock record in the household zone (C2-3) — see ``clockRecord(now:)``.
    public static let clockName = "serveruhr"

    /// A vanished profile — and, if it was merged, where to.
    public struct ContentEntryRecord: Codable, Equatable, Sendable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case identifier = "kennung"
            case target = "ziel"
            case datum
            case lifted = "aufgehoben"
            case serverTime = "serverzeit"
        }

        public let identifier: Profile.Identifier
        /// `nil` means deleted; otherwise the profile it was merged into — the
        /// **move note** that every device follows (``ProfileMove/episode(_:ledgerStore:keychain:startStore:)``).
        public let target: Profile.Identifier?
        /// When it was laid or lifted. `nil` for notes from the time before expiry;
        /// ``cleanUp(now:in:)`` stamps them the first time so that they expire too.
        public var datum: Date?
        /// **Taken back, and as a record of its own and not as a deletion** (finding 8).
        ///
        /// A deletion would look on another device like "never noted" — and that
        /// would write its own, older note back up on the next ``ProfileCloud/find()``.
        /// A record with a date says instead **when** it was taken back,
        /// and the younger of the two holds.
        public var lifted: Bool

        /// When the **server** last wrote the record — `nil` on the device and in
        /// the mirror as long as it has not been up (final review 2026-09-25, C2-3).
        ///
        /// **``datum`` is the clock of the writing device**, and whoever sits in front of it
        /// sets that. For the question "who was last" that is right; for a deadline
        /// at whose end a zone is deleted **irrevocably**, it is wrong — a
        /// device with a clock set back by a year would lay a note that would expire at once on
        /// every other device, together with the zone.
        public var serverTime: Date?

        public init(
            identifier: Profile.Identifier, target: Profile.Identifier? = nil, datum: Date? = nil,
            lifted: Bool = false, serverTime: Date? = nil
        ) {
            self.identifier = identifier
            self.target = target
            self.datum = datum
            self.lifted = lifted
            self.serverTime = serverTime
        }

        /// Also reads the notes of the version before expiry — without `datum` and
        /// `lifted`.
        public init(from decoder: any Decoder) throws {
            let bucket = try decoder.container(keyedBy: CodingKeys.self)
            identifier = try bucket.decode(Profile.Identifier.self, forKey: .identifier)
            target = try bucket.decodeIfPresent(Profile.Identifier.self, forKey: .target)
            datum = try bucket.decodeIfPresent(Date.self, forKey: .datum)
            lifted = try bucket.decodeIfPresent(Bool.self, forKey: .lifted) ?? false
            serverTime = try bucket.decodeIfPresent(Date.self, forKey: .serverTime)
        }

        /// From when the deadline runs — **the server date, if there is one**, otherwise
        /// ``datum``; a date more than ``ProfileTombstone/leadTime`` in the future counts
        /// as `now` (C2-3).
        public func cutoffDate(now: Date = Date()) -> Date? {
            guard let when = serverTime ?? datum else { return nil }
            return when > now.addingTimeInterval(ProfileTombstone.leadTime) ? now : when
        }

        /// Whether the note has expired. Never without a date — see ``datum``.
        ///
        /// **Computed against ``cutoffDate(now:)``** and thus against the server date, where there is
        /// one. Whether the zone may be deleted afterwards is not yet answered by this: for that the
        /// "now" must come from the server too — see
        /// ``ProfileTombstone/isOldEnough(_:serverClock:)``.
        public func expired(now: Date = Date()) -> Bool {
            guard let cutoffDate = cutoffDate(now: now) else { return false }
            return now.timeIntervalSince(cutoffDate) > ProfileTombstone.retention
        }
    }

    /// Whether a note has **provably** been on the server longer than ``retention`` —
    /// the condition for irrevocably deleting its zone (final review
    /// 2026-09-25, C2-3).
    ///
    /// **Both points in time from the server, none from the device.** The note's `serverTime` is
    /// when the server wrote it; `serverClock` is the most recent server date that
    /// could be read in the same household zone — a lower bound for "now" on the
    /// server. The device's clock sits in the TV's settings and not
    /// behind parental controls; a deletion that depends on it is triggered by anyone who
    /// sets it ahead by half a year.
    ///
    /// **If one of the two is missing, nothing is proven**, and the zone stays. A note
    /// that lies a few days longer than necessary costs nothing.
    public static func isOldEnough(_ entry: ContentEntryRecord, serverClock: Date?) -> Bool {
        guard let since = entry.serverTime, let serverClock else { return false }
        return serverClock.timeIntervalSince(since) > retention
    }

    /// A record whose only purpose is its server date (C2-3).
    ///
    /// **Without it there would often be no proof:** ``isOldEnough(_:serverClock:)`` needs a
    /// server date that is younger than the note, and in a household zone nobody has
    /// written to for half a year there is none. ``ProfileCloud/find(now:)``
    /// writes it as soon as a note has expired by the device's clock but is not yet
    /// proven; on the next pass it carries the server's date.
    ///
    /// **In the existing record type and as lifted**, so that the CloudKit schema stays
    /// as it is, and an older version reads it as a taken-back note for an
    /// identifier that does not exist — that is, as nothing.
    public static func clockRecord(now: Date = Date()) -> CloudRecord {
        CloudRecord(
            contentType: contentType, name: clockName, fields: [liftedField: .bool(true)], changed: now)
    }

    // MARK: - On the device

    /// This device's notes — empty if there are none.
    public static func all(from store: any KeyValueStore) -> [ContentEntryRecord] {
        guard let text = try? store.value(for: key),
            let raw = text.data(using: .utf8),
            let entries = try? JSONDecoder().decode([ContentEntryRecord].self, from: raw)
        else { return [] }
        return entries
    }

    /// Sets a note — **a second one for the same identifier replaces the first.**
    public static func create(
        _ identifier: Profile.Identifier, target: Profile.Identifier? = nil, now: Date = Date(),
        in store: any KeyValueStore
    ) {
        var entries = all(from: store).filter { norm($0.identifier) != norm(identifier) }
        entries.append(ContentEntryRecord(identifier: identifier, target: target, datum: now))
        write(entries, in: store)
    }

    /// Takes a note back on the device — when the same profile comes back **explicitly**,
    /// for example via a share link (``ProfileCloud/accept(_:)``). The "lifted"
    /// record in the household zone is written by ``ProfileCloud/liftTombstone(_:now:)``.
    public static func lift(_ identifier: Profile.Identifier, in store: any KeyValueStore) {
        let entries = all(from: store)
        guard entries.contains(where: { norm($0.identifier) == norm(identifier) }) else { return }
        write(entries.filter { norm($0.identifier) != norm(identifier) }, in: store)
    }

    /// Clears the expired notes on the device and stamps the unstamped ones.
    ///
    /// **A date in the future is stamped to `now`** (C2-3): it comes from a
    /// clock set ahead, and left standing the note would expire only half a year after
    /// a day that did not exist yet.
    ///
    /// - Returns: the cleared ones.
    @discardableResult
    public static func cleanUp(now: Date = Date(), in store: any KeyValueStore) -> [ContentEntryRecord] {
        let previous = all(from: store)
        guard !previous.isEmpty else { return [] }
        let expire = previous.filter { $0.expired(now: now) }
        let after = previous.filter { !$0.expired(now: now) }.map { entry in
            var stamped = entry
            stamped.datum =
                entry.datum.map { $0 > now.addingTimeInterval(leadTime) ? now : $0 } ?? now
            return stamped
        }
        if after != previous { write(after, in: store) }
        return expire
    }

    private static func write(_ entries: [ContentEntryRecord], in store: any KeyValueStore) {
        guard !entries.isEmpty else {
            try? store.remove(key)
            return
        }
        guard let raw = try? JSONEncoder().encode(entries),
            let text = String(data: raw, encoding: .utf8)
        else { return }
        try? store.set(text, for: key)
    }

    // MARK: - Welcher Vermerk gilt

    /// An identifier in the notation that ``ProfileCloud/identifier(from:)`` returns —
    /// **uppercase**, because the zone name is lowercase and the book uppercase, and a comparison
    /// across notations would never find the buried profile.
    public static func norm(_ identifier: Profile.Identifier) -> String {
        UUID(uuidString: identifier.rawValue)?.uuidString ?? identifier.rawValue
    }

    /// From notes of several sources (device, mirror, server) **the youngest per identifier** —
    /// and of those only the ones that hold: not lifted, not expired.
    ///
    /// **The youngest and not the first**, because a profile can be buried, brought back and
    /// buried again; only the date says what was wanted last. A
    /// note without a date is the oldest.
    ///
    /// **And without the winner of a cycle** (final review 2026-09-25, C2-2). If one
    /// device puts A into B and another B into A, two move notes point at each other. Until
    /// then both held: ``finalTarget(from:in:)`` yielded `nil`, nobody followed, both
    /// identifiers counted as buried — and the two devices stayed split, each with
    /// its own identifier. Now in a cycle whoever wins by ``ProfileSync/wins(_:about:)``
    /// wins; its note drops, and the others follow it. The same rule as with the
    /// name sync and for the same reason: it depends only on the identifiers, so
    /// all devices decide alike.
    public static func applicable(_ entries: [ContentEntryRecord], now: Date = Date()) -> [ContentEntryRecord]
    {
        withoutCycleWinner(newest(entries).filter { !$0.lifted && !$0.expired(now: now) })
    }

    /// How a chain walk ends — shared between ``withoutCycleWinner(_:)`` and
    /// ``finalTarget(from:in:)`` (finding 2026-09-27, e1: both ran the same loop with
    /// their own 32-step limit; now one loop, and each caller reads the outcome in
    /// its own way).
    enum ChainOutcome: Equatable {
        /// Natural end — the last position in the path has no further target.
        case end
        /// A cycle, closed at this index in the path.
        case circle(from: Int)
        /// Longer than the limit without a cycle being found.
        case tooLong
    }

    /// Follows the targets from `start`, up to 32 steps, and reports the path walked
    /// together with the outcome.
    static func chainWalk(
        from startValue: Profile.Identifier, targets: [String: Profile.Identifier]
    ) -> (route: [Profile.Identifier], outcome: ChainOutcome) {
        var route = [startValue]
        var location = startValue
        while true {
            guard let next = targets[norm(location)] else { return (route, .end) }
            if let start = route.firstIndex(where: { norm($0) == norm(next) }) {
                return (route, .circle(from: start))
            }
            guard route.count <= 32 else { return (route, .tooLong) }
            route.append(next)
            location = next
        }
    }

    /// Takes from the holding notes per cycle the winner's — see ``applicable(_:now:)``.
    static func withoutCycleWinner(_ effective: [ContentEntryRecord]) -> [ContentEntryRecord] {
        let targets = Dictionary(
            effective.compactMap { e in e.target.map { (norm(e.identifier), $0) } },
            uniquingKeysWith: { first, _ in first })
        var winner: Set<String> = []
        for start in targets.keys {
            let (route, outcome) = chainWalk(from: Profile.Identifier(rawValue: start), targets: targets)
            guard case .circle(let from) = outcome else { continue }
            let circle = route[from...]
            if let first = circle.min(by: { ProfileSync.wins($0, about: $1) }) {
                winner.insert(norm(first))
            }
        }
        guard !winner.isEmpty else { return effective }
        return effective.filter { !winner.contains(norm($0.identifier)) }
    }

    /// Per identifier the youngest note, lifted or not.
    static func newest(_ entries: [ContentEntryRecord]) -> [ContentEntryRecord] {
        var per: [String: ContentEntryRecord] = [:]
        var row: [String] = []
        for entry in entries {
            let key = norm(entry.identifier)
            guard let previous = per[key] else {
                per[key] = entry
                row.append(key)
                continue
            }
            if (entry.datum ?? .distantPast) > (previous.datum ?? .distantPast) {
                per[key] = entry
            }
        }
        return row.compactMap { per[$0] }
    }

    /// Where a profile has **finally** moved to — across a chain of moves.
    ///
    /// **A chain arises when merging happens twice** (A into B, later B into C).
    /// A device that follows only afterwards should not put A into the dead B. A cycle
    /// yields `nil` — in holding notes it no longer occurs, because
    /// ``applicable(_:now:)`` breaks it at the winner (C2-2).
    ///
    /// **If the end itself is deleted, there is no target** (final review 2026-09-25,
    /// C2-1). A into B, and afterwards B was removed: until then ``ProfileMove`` renamed A to
    /// B and thereby revived a profile that someone had explicitly deleted — together with its
    /// zone, which ``ProfileCloud/find(now:)`` would find again. **A stays as it is**, and
    /// that is the safe one of the three readings: deleting A too would discard a state that the
    /// deleter never saw (they removed B, perhaps before A was merged into it);
    /// renaming A to B contradicts their removal. Leaving it loses nothing,
    /// and whoever no longer wants A removes it with one press.
    public static func finalTarget(
        from identifier: Profile.Identifier, in effective: [ContentEntryRecord]
    ) -> Profile.Identifier? {
        let targets = Dictionary(
            effective.compactMap { e in e.target.map { (norm(e.identifier), $0) } },
            uniquingKeysWith: { first, _ in first })
        let (route, outcome) = chainWalk(from: identifier, targets: targets)
        // A cycle and a chain that is too long are the same here: no safe target, A
        // stays as it is.
        guard outcome == .end, route.count > 1, let target = route.last else { return nil }
        let deleted = effective.contains { $0.target == nil && norm($0.identifier) == norm(target) }
        return deleted ? nil : target
    }

    // MARK: - In der Wolke

    /// The record in the household zone — **named after the identifier**, so that two devices
    /// that remove different profiles never fight over the same record.
    public static func message(forItem entry: ContentEntryRecord, now: Date = Date()) -> CloudRecord {
        var fields: [String: FieldValue] = [:]
        if let target = entry.target { fields[targetField] = .text(target.rawValue) }
        if entry.lifted { fields[liftedField] = .bool(true) }
        return CloudRecord(
            contentType: contentType, name: entry.identifier.rawValue, fields: fields,
            changed: entry.datum ?? now)
    }

    /// The notes from a set of records — foreign types and the clock record
    /// (``clockRecord(now:)``) are skipped.
    ///
    /// **The date is the record's `changed`** — the time at which the writing
    /// device laid or lifted it. **The server time is added where the record has
    /// been up** (C2-3).
    public static func entries(from wordings: [CloudRecord]) -> [ContentEntryRecord] {
        wordings.filter { $0.contentType == contentType && $0.name != clockName }.map { message in
            ContentEntryRecord(
                identifier: Profile.Identifier(rawValue: message.name),
                target: message[targetField]?.text.flatMap {
                    $0.isEmpty ? nil : Profile.Identifier(rawValue: $0)
                },
                datum: message.changed,
                lifted: message[liftedField]?.bool ?? false,
                serverTime: message.serverTime)
        }
    }

    /// The most recent server date among these records — the lower bound for "now" on
    /// the server (C2-3, ``isOldEnough(_:serverClock:)``). `nil` if none has been up.
    public static func serverClock(from wordings: [CloudRecord]) -> Date? {
        wordings.compactMap(\.serverTime).max()
    }
}
