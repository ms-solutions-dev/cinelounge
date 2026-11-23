import Core
import Foundation
import ParentalControls

/// What hangs off a profile identifier and has to come along when the profile is merged into another
/// (AP45 "Perform merge", 2026-09-25).
///
/// **The finding that makes this type necessary:** a profile is more than its entry in the book.
/// Off its identifier hang the state (``Core/StillLedger``), the shelf order, the
/// playback preferences, the person marker, parental controls, the PIN, the start choice and
/// open questions. If the identifier disappears, all of that lies under a name that nobody
/// reads any more — silently, and noticed only when someone misses their history.
///
/// **Two callers, one path.** Merging by hand (``ProfileMerge``) and
/// merging at the first iCloud contact (``ProfileCloud/adopt(_:)``). Until
/// today the second carried along only the person marker — the state of a profile
/// taken over on the TV stayed under the device identifier as soon as iCloud brought the same
/// profile under its identifier.
///
/// **The rule on contradiction is the cautious one everywhere.** If one of the two has
/// something left, it holds; if both contradict each other, what protects or what promises less wins — the
/// earlier position, the stricter limit, the set PIN.
@MainActor
public enum ProfileMove {

    /// Moves everything that hangs off `leaving` to `remains` — and then clears `leaving`.
    ///
    /// - Parameters:
    ///   - buchablage: where state, shelves and open questions lie (``Core/FileStore``).
    ///   - schluesselbund: preferences, person marker, parental controls and PIN. `nil` leaves
    ///     them in place — an app that does not keep them should not clear them either.
    ///   - startablage: where ``StartChoice`` lies; `nil` leaves it untouched.
    public static func migrate(
        from leaving: Profile.Identifier, after remains: Profile.Identifier,
        ledgerStore: any KeyValueStore, keychain: (any KeyValueStore)?,
        startStore: UserDefaults?
    ) {
        guard leaving != remains else { return }
        moveState(from: leaving, after: remains, in: ledgerStore)
        moveShelves(from: leaving, after: remains, in: ledgerStore)
        DocumentPreference.moveChannelHistory(
            from: leaving.rawValue, after: remains.rawValue, in: ledgerStore)
        moveQuestions(from: leaving, after: remains, in: ledgerStore)
        if let keychain {
            movePreferences(from: leaving, after: remains, in: keychain)
            PortalMarkerSlot(keychain).migrate(from: leaving, to: remains)
            moveBackup(from: leaving, after: remains, in: keychain)
            movePIN(from: leaving, after: remains, in: keychain)
            let note = JoinNote(keychain)
            if note.openRequest?.profile == leaving { note.forgetRequest() }
        }
        if let startStore {
            let choice = StartChoice(store: startStore)
            if choice.identifier == leaving { choice.set(remains) }
        }
        // **And whoever is watching right now writes into the remaining book from now on.** Without this
        // line the running film would keep booking its position under the vanished
        // identifier — the book that was just cleared.
        if ProfilePointer.active == leaving.rawValue { ProfilePointer.show(to: remains.rawValue) }
    }

    // MARK: - Nachziehen

    /// Follows every move note whose source still has something here — **idempotent**
    /// (cross-check strand C, R2–R4).
    ///
    /// **Called at startup and on every pass**, with and without cloud: ``ProfileCloud`` hands in
    /// the notes from the device, from the household zone's mirror and from the server; the
    /// startup without an Apple account only those from the device. For every source that is still
    /// in the book or still carries a state:
    /// 1. **the book** — the source is merged into the target (``ProfileMerge/merge(_:in:)``);
    ///    if this device does not yet know the target, the source gets its identifier and keeps
    ///    everything else until the sync fetches the target down. If someone was sitting in the source,
    ///    they sit in the target afterwards.
    /// 2. **the move** (``migrate(from:after:ledgerStore:keychain:startStore:)``) — on an
    ///    empty source without effect, therefore safe to repeat.
    ///
    /// **Only notes with a target.** A note without a target means "removed", and a note
    /// from afar does not take away from anyone the profile they are using right now (see
    /// ``ProfileCloud/download(_:)``). A note with a target says instead: this person is called
    /// something else now — and whoever keeps writing under the old name writes into a zone
    /// that nobody reads any more.
    ///
    /// - Returns: the sources that were followed.
    @discardableResult
    public static func episode(
        _ tombstones: [ProfileTombstone.ContentEntryRecord],
        ledgerStore: any KeyValueStore, keychain: (any KeyValueStore)?,
        startStore: UserDefaults?, now: Date = Date()
    ) -> [Profile.Identifier] {
        let effective = ProfileTombstone.applicable(tombstones, now: now)
        var migrated: [Profile.Identifier] = []
        for note in effective where note.target != nil {
            guard let target = ProfileTombstone.finalTarget(from: note.identifier, in: effective) else {
                continue
            }
            var ledger = ProfileBook.read(from: ledgerStore)
            let source =
                ledger.profile.first {
                    ProfileTombstone.norm($0.identifier) == ProfileTombstone.norm(note.identifier)
                }?.identifier ?? note.identifier
            let settled = ledger.profile.first { $0.identifier == source }
            guard
                settled != nil
                    || StillLedger.read(from: ledgerStore, forItem: source.rawValue) != StillLedger()
            else { continue }

            if let settled {
                let wasActive = ledger.active == source
                let profileName = ledger.profile.compactMap { profile -> Profile? in
                    if profile.identifier == source {
                        // If this device does not know the target, the source becomes the target.
                        return ledger.profile.contains { $0.identifier == target }
                            ? nil : settled.withIdentifier(target)
                    }
                    if profile.identifier == target {
                        return ProfileMerge.merge(settled, in: profile)
                    }
                    return profile
                }
                let empty = ledger.active == nil
                ledger = ProfileBook(profile: profileName, active: wasActive ? target : ledger.active)
                if empty { ledger.clearActive() }
                ledger.write(in: ledgerStore)
                guard
                    !ProfileBook.read(from: ledgerStore).profile.contains(where: { $0.identifier == source })
                else { continue }
            }
            migrate(
                from: source, after: target, ledgerStore: ledgerStore, keychain: keychain,
                startStore: startStore)
            migrated.append(source)
        }
        return migrated
    }

    // MARK: - Stand

    private static func moveState(
        from leaving: Profile.Identifier, after remains: Profile.Identifier, in store: any KeyValueStore
    ) {
        let old = StillLedger.read(from: store, forItem: leaving.rawValue)
        guard old != StillLedger() else { return }
        let target = StillLedger.read(from: store, forItem: remains.rawValue)
        // **The outbox of both, by time.** What one of the two has not yet sent
        // has happened regardless; throwing it away would mean withholding a step from the sync.
        let post = Self.post(target.journal, old.journal).suffix(StillLedger.maximumCount)
        StillLedger(state: merge(target.state, using: old.state), journal: Array(post))
            .write(in: store, forItem: remains.rawValue)
        StillLedger().write(in: store, forItem: leaving.rawValue)
    }

    /// The outbox of both, by time — **and each event only once** (R6).
    ///
    /// **A move can run twice,** and since C2 that is intended: the move note
    /// (``ProfileTombstone``) stands before the book, and whoever follows after a crash
    /// may find the source still full. Without this step every event of the
    /// source would afterwards be in the outbox twice — and the sync, which is meant to work it off
    /// once, would work it off twice. Equal means: **the same event at the same time**;
    /// two channel switches to the same channel in different seconds remain two.
    static func post(
        _ target: [StillLedgerEntry], _ old: [StillLedgerEntry]
    ) -> [StillLedgerEntry] {
        var once: [StillLedgerEntry] = []
        for entry in (target + old).sorted(by: { $0.time < $1.time })
        where !once.contains(entry) {
            once.append(entry)
        }
        return once
    }

    /// Two states into one — **for the same title the earlier position holds.**
    ///
    /// **That is the decision from the AP45 line, and it is a weighing of two
    /// mistakes:** the further position would let one of the two never see a part,
    /// the earlier one lets him see one part twice. The second mistake is the cheaper one — it costs
    /// a skip forward and not a missed ending.
    ///
    /// For the rest, what both know together holds: favorites of both, the last
    /// watched channel of the one who stays (otherwise the other's), the group order of the one who stays.
    public static func merge(
        _ remains: StateRecording, using leaving: StateRecording
    ) -> StateRecording {
        var fresh = remains
        for (title, location) in leaving.titlePositions {
            fresh.titlePositions[title] = merge(remains.titlePositions[title], location)
        }
        for (list, channels) in leaving.lastChannel where fresh.lastChannel[list] == nil {
            fresh.lastChannel[list] = channels
        }
        fresh.channelFavorites = Array(Set(remains.channelFavorites + leaving.channelFavorites)).sorted()
        if fresh.groupOrder.isEmpty { fresh.groupOrder = leaving.groupOrder }
        if fresh.hiddenGroups.isEmpty {
            fresh.hiddenGroups = leaving.hiddenGroups
        }
        return fresh
    }

    /// A title from two states.
    ///
    /// **Only whoever says something about watching counts for watching.** An entry that carries only a
    /// favorite star has neither a position nor a check mark — it does not say "never
    /// started", it says nothing at all. Reading it as "from the beginning" would turn a
    /// watched film into an unwatched one.
    static func merge(
        _ remains: StateRecording.TitlePosition?, _ leaving: StateRecording.TitlePosition
    ) -> StateRecording.TitlePosition {
        guard let remains else { return leaving }
        let sayers = [remains, leaving].filter { $0.location != nil || $0.seen }
        let locations = sayers.compactMap(\.location)
        var fresh = remains
        if !sayers.isEmpty {
            fresh.location = locations.min()
            fresh.seen = locations.isEmpty && sayers.allSatisfy(\.seen)
        }
        fresh.favorite = remains.favorite || leaving.favorite
        fresh.duration = remains.duration ?? leaving.duration
        fresh.title = remains.title ?? leaving.title
        fresh.kind = remains.kind ?? leaving.kind
        fresh.image = remains.image ?? leaving.image
        fresh.recent = [remains.recent, leaving.recent].compactMap { $0 }.max()
        return fresh
    }

    // MARK: - Regale, Fragen

    /// **The order of the one who stays, if he has one.** A shelf order cannot
    /// be merged without both seeing a Home screen of someone else's.
    private static func moveShelves(
        from leaving: Profile.Identifier, after remains: Profile.Identifier, in store: any KeyValueStore
    ) {
        let old = ShelfOrder.read(from: store, forItem: leaving.rawValue)
        guard old != ShelfOrder() else { return }
        if ShelfOrder.read(from: store, forItem: remains.rawValue) == ShelfOrder() {
            old.write(in: store, forItem: remains.rawValue)
        }
        ShelfOrder().write(in: store, forItem: leaving.rawValue)
    }

    /// Open questions in which the vanishing profile appears point afterwards to the
    /// remaining one — **and a question about itself drops.** It is answered.
    private static func moveQuestions(
        from leaving: Profile.Identifier, after remains: Profile.Identifier, in store: any KeyValueStore
    ) {
        let previous = ProfileSync.openQuestions(from: store)
        guard ProfileSync.isInQuestion(leaving, under: previous) else { return }
        var after: [ProfileSync.Pair] = []
        for pair in previous {
            let fresh = ProfileSync.Pair(
                device: pair.device == leaving ? remains : pair.device,
                cloud: pair.cloud == leaving ? remains : pair.cloud)
            guard fresh.device != fresh.cloud, !after.contains(fresh) else { continue }
            after.append(fresh)
        }
        ProfileSync.memorize(after, in: store)
    }

    // MARK: - Keychain

    /// **What the remaining one set himself holds;** what he lacks comes from the other.
    private static func movePreferences(
        from leaving: Profile.Identifier, after remains: Profile.Identifier, in keychain: any KeyValueStore
    ) {
        let old = ProfileStore(keychain, forItem: leaving.rawValue)
        let target = ProfileStore(keychain, forItem: remains.rawValue)
        let available = target.own()
        target.adopt(old.own().filter { available[$0.key] == nil })
        old.forget()
    }

    /// The parental controls — **the stricter of the two, and only what is explicitly
    /// set.**
    ///
    /// **"Block what is not understood" carries over only an explicit yes.** Unset means
    /// "never asked" and not "yes" — since 2026-09-25 also in the rule itself
    /// (``ParentalControls/UnrecognizedLock/applicable(from:forItem:)``): a profile without an
    /// entry stays silent, and the device decides. What is read is therefore
    /// ``ParentalControls/UnrecognizedLock/own(from:forItem:)`` and not the default.
    /// **A no does not carry over:** it loosens nothing that the target does not already loosen,
    /// and setting it against a yes of the remaining one would be the loosening that nobody sees.
    private static func moveBackup(
        from leaving: Profile.Identifier, after remains: Profile.Identifier, in keychain: any KeyValueStore
    ) {
        let old = leaving.rawValue
        let target = remains.rawValue

        if let limit = AgeLimit.read(from: keychain, forItem: old) {
            AgeLimit.write(
                AgeLimit.forItem(
                    profile: AgeLimit.read(from: keychain, forItem: target), device: limit),
                in: keychain, forItem: target)
            AgeLimit.write(nil, in: keychain, forItem: old)
        }

        if let lock = UnrecognizedLock.own(from: keychain, forItem: old) {
            if lock { UnrecognizedLock.write(true, in: keychain, forItem: target) }
            try? keychain.remove(
                ProfileSlot.key(UnrecognizedLock.storeKey, forItem: old))
        }

        let board = UnrecognizedRatings.load(from: keychain, forItem: old)
        if !board.assignments.isEmpty {
            if UnrecognizedRatings.load(from: keychain, forItem: target).assignments.isEmpty {
                board.save(to: keychain, forItem: target)
            }
            UnrecognizedRatings().save(to: keychain, forItem: old)
        }

        moveChannelApproval(from: old, after: target, in: keychain)
    }

    /// The allow list for channels (AP52) — **if the remaining one has one, the
    /// intersection holds; if he has none, he gets the other's.**
    ///
    /// **The intersection is "the stricter of the two" here**, the same rule as at the
    /// limit: a group that only one of the two lists allows has not been looked at for the other
    /// by anyone. **An empty list of the remaining one is not a choice**, but
    /// the absence of one — just as with the mapping board above. A profile that arrives via
    /// iCloud with a new identifier would otherwise have no Live after the move, although
    /// an adult has just approved it on this device.
    private static func moveChannelApproval(
        from old: String, after target: String, in keychain: any KeyValueStore
    ) {
        let departing = ChannelApproval.load(from: keychain, forItem: old)
        guard !departing.isEmpty else { return }
        let remaining = ChannelApproval.load(from: keychain, forItem: target)
        let fresh =
            remaining.isEmpty
            ? departing : ChannelApproval(groups: remaining.groups.intersection(departing.groups))
        fresh.save(to: keychain, forItem: target)
        ChannelApproval().save(to: keychain, forItem: old)
    }

    /// The PIN — **if the remaining one has none, he gets the other's.**
    ///
    /// The other way round, after merging the history of a protected profile would be
    /// open inside an unprotected one. Whoever merges has entered both PINs
    /// (``ProfileMerge``); when merging through iCloud the same rule applies as
    /// for the kind: what protects wins.
    ///
    /// **Since AP52 the new record** (``ProfilePIN``). "None" here also means: a
    /// tombstone. The migrating PIN therefore gets a time **after** the remaining one's
    /// tombstone — otherwise the older tombstone would beat it in the cloud, and the
    /// merged profile would stand open on the next device. The departing one's PIN
    /// disappears with it; its zone is buried, a tombstone there would be for nobody.
    static func movePIN(
        from leaving: Profile.Identifier, after remains: Profile.Identifier, in keychain: any KeyValueStore
    ) {
        let old = ProfilePIN(store: keychain, forItem: leaving)
        defer { old.forget() }
        guard let value = old.entry?.verifier else { return }
        let target = ProfilePIN(store: keychain, forItem: remains)
        guard !target.isSet else { return }
        let afterTombstone = (target.entry?.time ?? .distantPast).addingTimeInterval(0.001)
        target.adopt(
            ProfilePIN.ContentEntryRecord(
                verifier: value, time: max(Date(), afterTombstone), basis: target.entry?.time))
    }
}
