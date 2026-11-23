import Foundation

/// What a person has watched — **per profile and not per device.**
///
/// **The finding that triggered AP42** (2026-09-19): all progress must hang on
/// the profile — IPTV too. Until then it lived in three device dictionaries
/// (`vod.memory.v1`, `live.lastChannel*`, `playlists.favorites.v1`) that
/// belonged to nobody. The profile switch left them standing: whoever watched
/// TV after a child continued where the child had stopped — and the child
/// found the adults' films under "Continue Watching" the next day.
///
/// **The reasoning in the source was right and irrelevant.** It said an Xtream
/// panel knows no user state, so the state must live locally. That is true —
/// but it does not follow that it belongs to the *device*. It belongs to the
/// person who sat in front of it.
///
/// ## Journal and snapshot
///
/// **Two parts, because they have two jobs.** The ``StateRecording`` is the
/// truth that is read: a dictionary that answers a tile in microseconds. The
/// ``journal`` is the outbox — every event that has not yet been reconciled.
///
/// **Without a journal, airplane mode would lose events.** Whoever watches
/// without a network books locally; at the next reconciliation (AP43) it must
/// be recognisable *what* happened and not only what it looks like now. That
/// cannot be derived from two snapshots: did the phone take the film from 10
/// to 40 minutes, or did the TV take it from 60 to 40? A comparison takes the
/// larger number and is wrong in one of the two cases.
///
/// **The journal is emptied and does not grow forever.** It is an outbox and
/// not a history; AP43 removes what has arrived. Whoever never gets online
/// hits ``maximumCount`` — then the oldest drops out, and for those events the
/// snapshot applies. That is the loss a device without a network has to
/// accept; a ledger that instead grew without limit would eventually make
/// startup slow.
public struct StillLedger: Codable, Sendable, Equatable {
    /// Stored keys keep their original (German) names — renaming them would
    /// make data written by earlier versions unreadable (AP85 B4).
    private enum CodingKeys: String, CodingKey {
        case state = "stand"
        case journal
    }

    /// The readable truth.
    public private(set) var state: StateRecording

    /// What is still to be reconciled, oldest first.
    public private(set) var journal: [StillLedgerEntry]

    /// This many events does the outbox hold — see the reasoning above.
    ///
    /// **Fifty, no longer five hundred** (AP71, 2026-10-11). Five hundred were
    /// around a hundred kilobytes as a file — and because ``acknowledge(_:)`` was
    /// never called (the cloud reconciles via the snapshot, not via the journal),
    /// every ledger ran into that limit and stayed there: too big for the backup
    /// to `UserDefaults` (AP66), an error line every ten seconds (428 in one
    /// report, F-017). The only reader of the journal is the profile move, and
    /// the most recent fifty events are enough for it.
    public static let maximumCount = 50

    public init(state: StateRecording = StateRecording(), journal: [StillLedgerEntry] = []) {
        self.state = state
        self.journal = journal
    }

    /// **Every field may be missing** — for the same reason as with
    /// ``ShelfOrder``: a file written by an older version does not know later
    /// fields, and discarding it for that reason would mean taking the viewer's
    /// state away.
    public init(from decoder: any Decoder) throws {
        let bucket = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            state: try bucket.decodeIfPresent(StateRecording.self, forKey: .state) ?? StateRecording(),
            journal: try bucket.decodeIfPresent([StillLedgerEntry].self, forKey: .journal) ?? [])
    }

    // MARK: - Buchen

    /// Books an event: **first into the state, then into the outbox.**
    ///
    /// **Even when nothing changes in the state.** A second "favourite set" looks
    /// like none in the state — in the reconciliation it is the proof that this
    /// person wanted it *now*, and so decides against an older "favourite
    /// deleted" from the other device. Exactly this information is the reason the
    /// journal exists.
    /// **The profile card does not go into the outbox.** It is no action of the
    /// viewer but something added on the side while a list is walked — and a list
    /// has thousands of entries. As an event it would fill the outbox in a single
    /// pass and push out every channel switch and every position.
    public mutating func record(_ event: StillEvent, on timestamp: Date = Date()) {
        state.apply(event, on: timestamp)

        if case .profileCard = event { return }

        journal.append(StillLedgerEntry(event: event, time: timestamp))
        if journal.count > Self.maximumCount {
            journal.removeFirst(journal.count - Self.maximumCount)
        }
    }

    /// Takes the reconciled events out of the outbox — for AP43.
    ///
    /// **By count and not by the entries themselves.** Whoever passed entries to
    /// be struck would have to compare them; but two channel switches to the same
    /// channel in the same second are equal, and the wrong one would be struck.
    /// The outbox is a queue: what was collected at the front drops out at the
    /// front.
    public mutating func acknowledge(_ count: Int) {
        guard count > 0 else { return }
        journal.removeFirst(min(count, journal.count))
    }

    /// Takes over a state **without booking it.**
    ///
    /// **The path for everything that comes from outside** — today the
    /// reconciliation via iCloud (AP43). An entry in the journal would be exactly
    /// wrong here: the journal is an outbox, and what has just arrived would go
    /// back up on the next round. Two devices would push the same state to each
    /// other endlessly, each time with a new timestamp — the rule "the younger
    /// writer wins" would then decide between two copies of the same value.
    ///
    /// **The outbox stays.** What this device has not yet sent remains in the
    /// journal; the incoming state is already merged with it, otherwise nobody
    /// would have sent it.
    public mutating func adopt(_ new: StateRecording) {
        state = new
    }

    // MARK: - Umschlüsseln

    /// Rewrites everything belonging to a list to a new list key.
    ///
    /// **The reason is at ``ListKey``**: until 2026-09-21 the list ID was
    /// a random number per device. It sits in the ledger in three places — in the
    /// *key* of the last watched channel, in the *value* next to it (a channel ID
    /// reads `<list>#…`) and at the front of every title ID. Whoever forgets one
    /// has a state that points to something that does not exist — and that looks
    /// like "never watched".
    ///
    /// **The journal stays as it is.** It is an outbox: what is in it has already
    /// happened, and the receiver (AP43) knows both keys because it witnesses the
    /// move itself. Rewriting it too would mean changing the past.
    ///
    /// - Returns: Whether anything changed.
    @discardableResult
    public mutating func rekey(from old: String, after fresh: String) -> Bool {
        guard old != fresh, !old.isEmpty, !fresh.isEmpty else { return false }
        let previous = state

        if let channels = state.lastChannel.removeValue(forKey: old) {
            state.lastChannel[fresh] = Self.rewritten(channels, from: old, after: fresh)
        }
        if let general = state.lastChannel[""] {
            state.lastChannel[""] = Self.rewritten(general, from: old, after: fresh)
        }

        for (title, location) in state.titlePositions where title.hasPrefix(old + "#") {
            state.titlePositions.removeValue(forKey: title)
            state.titlePositions[fresh + title.dropFirst(old.count)] = location
        }

        return state != previous
    }

    /// An ID with a new list ID at the front — **only with the hash sign.** Without
    /// it, the replacement would also hit an ID that happens to start the same
    /// way.
    static func rewritten(_ identifier: String, from old: String, after fresh: String) -> String {
        guard identifier.hasPrefix(old + "#") else { return identifier }
        return fresh + identifier.dropFirst(old.count)
    }

    // MARK: - Ablage

    /// **One file per profile**, by the store rule from `README.md`: state belongs
    /// in the Standbuch, and the Standbuch is structure, so one file.
    public static let key = "stand"

    /// The key of this profile — or that of the **device**.
    ///
    /// The same form as for ``ShelfOrder/key(forItem:)`` and
    /// ``ParentalControls/ProfileSlot``, and written out separately in each for the
    /// same reason: three lines of string work are not worth a shared dependency.
    public static func key(forItem profile: String?) -> String {
        guard let profile, !profile.isEmpty else { return key }
        return key + "." + profile
    }

    /// **Nothing stored means "nothing watched yet"** and yields the empty ledger
    /// — no error that every caller would have to catch.
    ///
    /// - Parameter profil: Whose state. `nil` is the **device's** — the state
    ///   before first setup and the base that ``StateTransfer`` draws from.
    public static func read(
        from store: any KeyValueStore, forItem profile: String? = nil
    )
        -> StillLedger
    {
        RecordSheet.read(under: key(forItem: profile), from: store) ?? StillLedger()
    }

    /// Writes the ledger — **and deletes it when nothing is left in it.**
    public func write(in store: any KeyValueStore, forItem profile: String? = nil) {
        let key = Self.key(forItem: profile)
        guard self != StillLedger() else {
            RecordSheet.cleanUp(key, in: store)
            return
        }
        RecordSheet.write(self, under: key, in: store)
    }
}

/// An event with its point in time.
public struct StillLedgerEntry: Codable, Sendable, Equatable {
    /// Stored keys keep their original (German) names — renaming them would
    /// make data written by earlier versions unreadable (AP85 B4).
    private enum CodingKeys: String, CodingKey {
        case event = "ereignis"
        case time = "zeit"
    }

    public var event: StillEvent
    public var time: Date

    public init(event: StillEvent, time: Date) {
        self.event = event
        self.time = time
    }
}

/// What the viewer has done.
///
/// **An enumeration with associated values and not a dictionary of strings.**
/// A journal invites storing everything as text ("kind", "subject",
/// "value") — and then a number of seconds sits there as text, and somebody
/// reads it with the wrong decimal separator. Here the compiler helps check.
public enum StillEvent: Codable, Sendable, Equatable {
    /// Stored case names keep their original (German) form — renaming them would
    /// make data written by earlier versions unreadable (AP85 B4).
    private enum CodingKeys: String, CodingKey {
        case senderGewaehlt
        case titlePosition = "titelstelle"
        case seen = "gesehen"
        case titelfavorit
        case senderfavorit
        case senderreihenfolge
        case profileCard = "steckbrief"
    }

    /// Stored keys of ``profileCard`` keep their original (German) names (AP85 B4).
    private enum ProfileCardCodingKeys: String, CodingKey {
        case title
        case name
        case kind = "art"
        case image
        case series
    }

    /// Stored keys of ``senderfavorit`` keep their original (German) names (AP85 B4).
    private enum SenderfavoritCodingKeys: String, CodingKey {
        case key = "schluessel"
        case _1
    }

    /// Stored keys of ``seen`` keep their original (German) names (AP85 B4).
    private enum GesehenCodingKeys: String, CodingKey {
        case title = "titel"
        case _1
    }

    /// Stored keys of ``senderGewaehlt`` keep their original (German) names (AP85 B4).
    private enum SenderGewaehltCodingKeys: String, CodingKey {
        case list = "liste"
        case channels = "sender"
    }

    /// Stored keys of ``senderreihenfolge`` keep their original (German) names (AP85 B4).
    private enum SenderreihenfolgeCodingKeys: String, CodingKey {
        case groups = "gruppen"
        case hidden = "ausgeblendet"
    }

    /// Stored keys of ``profileCard`` keep their original (German) names (AP85 B4).
    private enum SteckbriefCodingKeys: String, CodingKey {
        case title = "titel"
        case name
        case kind = "art"
        case image = "bild"
        case series = "serie"
    }

    /// Stored keys of ``titelfavorit`` keep their original (German) names (AP85 B4).
    private enum TitelfavoritCodingKeys: String, CodingKey {
        case title = "titel"
        case _1
    }

    /// Stored keys of ``titlePosition`` keep their original (German) names (AP85 B4).
    private enum TitelstelleCodingKeys: String, CodingKey {
        case title = "titel"
        case location = "stelle"
        case duration = "dauer"
    }

    /// Which channel ran last. **The list is the list key** from
    /// ``ListKey`` — empty for "last overall, in whichever list".
    case senderGewaehlt(list: String, channels: String)

    /// How far a title has been watched.
    ///
    /// **Carries catch-up too.** A recalled programme is the same as a film for
    /// this store: an ID and a position in it. A second case for it would have
    /// produced two dictionaries answering the same question — and the tile would
    /// have to ask both. Its ID is built by
    /// ``StateIdentifier/catchUp(list:channels:from:)``.
    case titlePosition(title: String, location: TimeInterval, duration: TimeInterval?)

    /// The watched mark of a title.
    case seen(title: String, Bool)

    /// The favourite mark of a title.
    case titelfavorit(title: String, Bool)

    /// The favourite mark of a channel. **The key is the one built from the
    /// channel name** (``PlaylistKit/PlaylistStore/favoriteKey(for:)``) and not
    /// the channel ID — favourites apply across lists, see the reasoning there.
    case senderfavorit(key: String, Bool)

    /// How the channel groups are ordered and which are left out.
    ///
    /// **Both in one event**, because it is one action: whoever hides a group
    /// also changes what the order still contains. Two events could arrive
    /// separately in the reconciliation, and between them an order would stand
    /// that never existed.
    case senderreihenfolge(groups: [String], hidden: [String])

    /// The profile card of a title — title, kind, poster.
    ///
    /// **Not an event of the viewer, and yet here.** "Continue Watching" draws
    /// tiles without having loaded the list they come from (AP39); without the
    /// profile card every tile cost a fetch from the provider. It is added while
    /// a list is walked — see ``StateRecording/TitlePosition/title``.
    ///
    /// **The series attaches here and is no event of its own** (2026-10-01): the
    /// journal is reconciled between devices. An unknown case could not be read
    /// by an older build; an additional key inside a known one it overlooks.
    case profileCard(
        title: String, name: String, kind: MediaItem.Kind?, image: String?, series: String? = nil)
}
