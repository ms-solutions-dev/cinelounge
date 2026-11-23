import Core
import Foundation
import Observation
import ParentalControls
import ProfileKit

/// Everything the parental controls currently know — **in one place.**
///
/// The `ParentalControls` package is pure logic and knows neither store nor view; it
/// answers questions about values that someone passes in. **This class is that
/// someone.** It reads the settings, holds the ``Pass`` and hands out the rule as
/// a single value that every view can ask the same question of.
///
/// **Whoever rebuilds the rule elsewhere builds the gap back in** — and the gap was the
/// most serious finding of the usability pass: four taps from the child account to the
/// "Adult channels" switch, without a PIN.
///
/// **The PIN is in the Keychain, everything else in the default store.** That this
/// phone is currently in child mode is no secret; the PIN is one.
@MainActor
@Observable
public final class ParentalControlsState {

    /// The device state — "what is locked now".
    public let mode: ChildMode

    /// The age limit of this device. `nil` means **no limit** and not "level 0".
    public private(set) var limit: AgeLimit?

    /// Whether the uninterpreted is locked. **Default: yes** — when in doubt show less.
    public private(set) var blocksUnrecognized: Bool

    /// The lock on adult channels.
    ///
    /// **The first half lives elsewhere, and that is deliberate.** `showsAdult` is
    /// the same as `LivePreferences.showsAdultChannels` — the switch that has always existed on the
    /// TV and that sits under the same key `live.showsAdult`. A second key next to it would be a second truth: whoever
    /// flipped it on the phone changed nothing on the TV, and both devices would claim something different
    /// about the same catalog. Only `hidesUnlabeled` is new.
    public private(set) var channelLock: ChannelLock

    /// What could not be interpreted, and what the parent has assigned of it.
    public private(set) var approvals: UnrecognizedRatings

    /// The flag of the **old account list** (G1) for the signed-in account.
    ///
    /// **No longer the whole answer** (tvOS roadmap AP45, 2026-09-25): what applies is computed by
    /// ``rule`` via ``ParentalControls/RuleBuilder`` — this flag **or** the kind of the
    /// active profile. The flag stays because it carries the households that were set up before AP41; dropping
    /// it would mean opening a lock there that someone set deliberately.
    public var accountKind: AccountKind = .adult

    /// What the media server says about this account — `nil` means "not asked yet".
    ///
    /// **Read and displayed, not trusted.** Two filters that want the same thing are
    /// no error: the server knows its libraries, the app knows the device. For three
    /// of four sources there is no policy at all — the media server
    /// knows nothing of Xtream and the portals.
    public private(set) var accessPolicy: ServerPolicy?

    /// What the app makes of the catalog's data — for the "Age ratings" sheet.
    public private(set) var mirrored = ApprovalMirror()

    private let pin: Pin
    private let store: UserDefaults
    private let keychain: any KeyValueStore

    /// Where the ``ProfileKit/ProfileBook`` lives — `nil` means: **no book**, then the account flag
    /// alone decides. The tests that check only device values pass none.
    private let ledgerStore: (any KeyValueStore)?
    private var doorGuard = DoorGuard()

    /// **The keys for limit and uninterpreted no longer live here** (AP40,
    /// 2026-09-20). They were spelled out in **both** programs — there
    /// as a string in the Keychain, here as `Int` or `Bool` in
    /// `UserDefaults`, under the same name. That is why the fix that the
    /// TV got for the age limit on 2026-09-11. (AP22) never arrived here: it was made on the
    /// shared building block, which this side did not use.
    /// Now both read and write via ``ParentalControls/AgeLimit`` and
    /// ``ParentalControls/UnrecognizedLock`` — and since G3 also the "Hide unlabeled"
    /// switch via ``ParentalControls/ChannelLock/stored(store:keychain:)``.

    /// The old places, only for taking over — see ``adoptFromStore()``.
    private nonisolated static let oldLimitKey = "childLock.ageLimit"
    private nonisolated static let oldNotUnderstoodKey = "childLock.blockUnknown"

    public init(
        store: UserDefaults = .standard, keychain: (any KeyValueStore)? = nil,
        ledgerStore: (any KeyValueStore)? = nil
    ) {
        let bucket = keychain ?? SecureStore()
        self.store = store
        self.keychain = bucket
        self.ledgerStore = ledgerStore
        self.mode = ChildMode(store: store)
        self.pin = Pin(store: bucket)
        // **From the Keychain and via the shared building block** (AP40, 2026-09-20).
        //
        // **Why these two in particular do not belong in the file store**, although the
        // rule says "structure → file": they apply together with the PIN, and the PIN
        // is in the Keychain — it survives a reinstall. If the limit lived in
        // a file, afterwards there would be: PIN set, child mode on, **no limit** — and
        // without a limit ``ProtectionRule/shows(approval:)`` lets everything through. Exactly
        // this state was the finding of 2026-09-11. (AP22), and it does not announce itself: the
        // filter runs and filters nothing.
        self.limit = AgeLimit.read(from: bucket)
        self.blocksUnrecognized = UnrecognizedLock.read(from: bucket)
        // **One half from the shared set, the other from here.** See
        // ``channelLock``: a key of its own for "Show adult channels" would be
        // a second truth next to `live.showsAdult`.
        self.channelLock = ChannelLock.stored(store: store, keychain: bucket)
        self.approvals = UnrecognizedRatings.load(from: bucket)
    }

    // MARK: - The rule

    /// The rule as **one value** — exactly the question every view asks.
    ///
    /// **The computation is in the shared package** (AP58 R1, finding K2,
    /// ``ParentalControls/RuleBuilder``) — the same as on the TV: limit the stricter of
    /// profile and device, "lock the uninterpreted" one of the two (a profile without an entry
    /// stays silent), assignments of both boards with the last word at the profile, account kind
    /// child profile **or** child account, allow list only for the child. Here only
    /// what was read is remembered: the device base in the properties of this state, the
    /// person's share per identifier.
    public var rule: ProtectionRule {
        RuleBuilder.rule(
            device: RuleBuilder.Device(
                locked: mode.on, isPinSet: pin.isSet, limit: limit,
                blocksUnrecognized: blocksUnrecognized, assignments: approvals.assignments),
            person: profileState, accountIsChild: accountKind == .kind)
    }

    /// The profile share, **remembered per identifier**.
    ///
    /// **Remembered and not read on every access:** ``rule`` is asked per title
    /// while filtering, and every question to the Keychain is a system call. It is re-read
    /// as soon as ``Core/ProfilePointer`` points to a different profile — the
    /// pointer is a static value and costs nothing — and after
    /// ``rereadProfile()``.
    @ObservationIgnored private var rememberedProfileState: RuleBuilder.Person?

    /// Counts up on every re-read — **the observed anchor** for ``rule``.
    ///
    /// The remembered state is explicitly unobserved (it is written while reading);
    /// without this counter a view would, after a profile switch, keep drawing with the rule
    /// of the previous person.
    private var profileRound = 0

    var profileState: RuleBuilder.Person {
        _ = profileRound
        let active = ProfilePointer.active
        if let remembered = rememberedProfileState, remembered.identifier == active { return remembered }
        let fresh = readProfileState(forItem: active)
        rememberedProfileState = fresh
        return fresh
    }

    private func readProfileState(forItem active: String?) -> RuleBuilder.Person {
        let kind = ledgerStore.flatMap { store in
            ProfileBook.read(from: store).profile.first { $0.identifier.rawValue == active }?.kind
        }
        return RuleBuilder.Person.read(active, isChild: kind == .kind, from: keychain)
    }

    // MARK: - Live for children

    /// The child profiles in the book — **the rows of "Live for children".** Without a book none.
    public var childProfiles: [Profile] {
        _ = profileRound
        guard let ledgerStore else { return [] }
        return ProfileBook.read(from: ledgerStore).profile.filter { $0.kind == .kind }
    }

    /// The stored allow list of a profile (tvOS roadmap AP52, decision 14).
    ///
    /// **In the Keychain of this phone and not in the cloud** — the same store as
    /// age limit and assignments and for the same reason: what applies together with the PIN
    /// must survive together with it. That is why the phone needs a **separate**
    /// setting; the TV's list never arrives here.
    public func channelApproval(forItem profile: String) -> ChannelApproval {
        _ = profileRound
        return ChannelApproval.load(from: keychain, forItem: profile)
    }

    /// Stores the allow list of a profile — **and re-reads the rule**, so that tabs,
    /// Home and Search ask the new list at the next look.
    public func set(channelApproval incoming: ChannelApproval, forItem profile: String) {
        incoming.save(to: keychain, forItem: profile)
        rereadProfile()
    }

    /// Throws away the remembered profile share — **after every profile switch and every
    /// change to the book** (for example when another device has made a profile a child).
    public func rereadProfile() {
        rememberedProfileState = nil
        profileRound += 1
    }

    public var isPinSet: Bool { pin.isSet }

    /// What of the PIN travels along to another device — `nil` if none is set.
    ///
    /// **Digest and salt, not the digits.** Those are stored nowhere; see
    /// ``ParentalControls/Pin/Extract``. This is needed on the device handoff
    /// (``HandoffModel``) — without this line the parental controls would arrive on the TV as
    /// "switched on, but without a PIN".
    public var pinDigest: Pin.Extract? { pin.extract }
    public var pinChanged: Date? { pin.changed }

    /// Whether this door requires the PIN now — **netted against the pass.**
    ///
    /// Returns the request with which the sheet opens, or `nil` if the path is free.
    /// **A request and not a `Bool`**: without it the keypad would stand there without a sentence,
    /// and nobody would know what it currently unlocks.
    public func job(forItem door: String) -> PinTask? {
        doorGuard.job(forItem: door, rule: rule)
    }

    /// Check an entry — **and on success open exactly one door.**
    @discardableResult
    public func verify(_ digits: String, forItem job: PinTask) -> Bool {
        guard case .door(let identifier, _) = job else { return pin.matches(digits) }
        return doorGuard.open(identifier, using: digits, pin: pin)
    }

    /// After the action the door is closed again.
    public func consume() { doorGuard.consume() }

    // MARK: - What the screen changes

    @discardableResult
    public func setPin(_ digits: String) -> Bool { pin.set(digits) }

    /// **Removing the PIN switches child mode off too.** A lock without a PIN
    /// takes no effect anyway (``ParentalControls/applies``); leaving it in place would mean
    /// showing a switch that does nothing.
    public func clearPin() {
        pin.delete()
        mode.set(false)
    }

    public func set(limit incoming: AgeLimit?) {
        limit = incoming
        AgeLimit.write(incoming, in: keychain)
    }

    public func set(blocksUnrecognized fresh: Bool) {
        blocksUnrecognized = fresh
        UnrecognizedLock.write(fresh, in: keychain)
    }

    /// Brings limit and lock over from the old `UserDefaults` store — **once
    /// and only if the Keychain holds nothing yet.**
    ///
    /// **The order is the caution:** if something already stands over there, either this
    /// app wrote it or a handoff brought it — both are younger than the old
    /// value. Overwriting a set limit with an older one would mean loosening a
    /// parental control without anyone seeing it.
    public func adoptFromStore() {
        if AgeLimit.read(from: keychain) == nil,
            let old = store.object(forKey: Self.oldLimitKey) as? Int,
            let limit = AgeLimit(rawValue: old)
        {
            AgeLimit.write(limit, in: keychain)
            self.limit = limit
        }

        if (try? keychain.value(for: UnrecognizedLock.storeKey)) == nil,
            let old = store.object(forKey: Self.oldNotUnderstoodKey) as? Bool
        {
            UnrecognizedLock.write(old, in: keychain)
            blocksUnrecognized = old
        }

        // **And afterwards the old places are gone** (clean cut, product decision 2
        // of 2026-09-25) — **with evidence per key:** only what has arrived in the
        // Keychain is cleared.
        //
        // **The finding that makes this necessary:** "No limit" **removes** the entry in the
        // Keychain (``ParentalControls/AgeLimit/write(_:in:forItem:)``). At the next
        // launch nothing stood there, the takeover above kicked in again — and fetched the
        // limit from before 2026-09-20 back. Whoever switched the limit off on the phone had
        // it back after a restart.
        if AgeLimit.read(from: keychain) != nil {
            store.removeObject(forKey: Self.oldLimitKey)
        }
        if (try? keychain.value(for: UnrecognizedLock.storeKey)) != nil {
            store.removeObject(forKey: Self.oldNotUnderstoodKey)
        }
    }

    /// **Read fresh, change, write back.** `LivePreferences` stores all its
    /// fields in one go; a copy held here would write the hidden groups along on saving,
    /// as they looked at launch — and with 96 groups that
    /// is the most expensive loss this app has to offer.
    public func set(showsAdult fresh: Bool) {
        channelLock.showsAdult = fresh
        var preferences = LivePreferences.load(from: keychain)
        preferences.setShowsAdultChannels(fresh)
        preferences.save(to: keychain)
    }

    public func set(hidesUnlabeled fresh: Bool) {
        channelLock.hidesUnlabeled = fresh
        ChannelLock.write(hidesUnlabeled: fresh, in: store)
    }

    /// **The mirror is updated along, not reloaded.** An assignment moves
    /// an entry from the open to the understood side — asking thirty-two
    /// thousand titles again for that would be a loading indicator for a calculation
    /// that is already there.
    public func arrange(_ rawText: String, to alter: Int) {
        approvals.arrange(rawText, to: alter)
        approvals.save(to: keychain)
        mirror()
    }

    public func redeem(_ rawText: String) {
        approvals.redeem(rawText)
        approvals.save(to: keychain)
        mirror()
    }

    /// Recomputes the mirror over the same catalog.
    private func mirror() {
        let rawTexts =
            (mirrored.recognized + mirrored.pending)
            .flatMap { Array(repeating: $0.rawText, count: $0.count) }
        mirrored = ApprovalMirror.about(rawTexts, assignments: approvals.assignments)
    }

    /// Counts through the ratings of a catalog — for the "Age ratings" sheet.
    ///
    /// **One pass for both sides of the sheet.** The mirror carries the understood
    /// **and** the open; the memo gets from it only what it has to keep.
    public func tally(_ rawTexts: [String?]) {
        mirrored = ApprovalMirror.about(rawTexts, assignments: approvals.assignments)
        approvals.tally(rawTexts)
    }

    /// Takes over what the media server says about this account.
    public func adopt(_ incoming: ServerPolicy?) {
        accessPolicy = incoming
    }
}
