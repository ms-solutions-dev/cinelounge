import CloudSync
import Core
import Diagnose
import Foundation
import Observation
import ParentalControls
import PlaylistKit
import ProfileKit

/// The profiles of this device, for the settings — **create, change, switch,
/// remove, merge** (shared since AP58 R7, finding P6).
///
/// **The finding:** The management existed as `ProfileModel` (500 lines) only on the TV;
/// the phone wrote its profile picture into the book by its own path (`ProfilePictureState`),
/// with a second version of the immediate push-up to the cloud. Here both exist
/// once; the TV keeps the management behind its `ProfileModel`, the phone
/// writes its picture via ``setPicture(_:avatar:)``.
///
/// **The successor of `AccountsModel`** (AP41, line 5). The owner's decision
/// of 2026-09-21: there should be only profiles from now on; accounts with their progress
/// and accesses etc. all live in the profiles themselves and are then stored in
/// CloudKit. This means the account list is no longer a list of Jellyfin users but
/// a list of **people**; an access is something that one of them has.
///
/// **A holder above the book and no second store.** The ``ProfileKit/ProfileBook`` lives
/// as a file; this type reads it, hands it to the view and writes it back.
@Observable
public final class ProfileManagement {

    /// The profiles, in the order of the book.
    public private(set) var profile: [Profile] = []
    /// Wer gerade davorsitzt.
    public private(set) var active: Profile.Identifier?

    /// This device's Keychain — **readable within the module** for a profile's limit
    /// (``save(_:existing:)``), so that it lands where PIN and session also live.
    let keychain: SecureStore
    private let store: any KeyValueStore

    /// The channel lists — **only to notify them after a switch.**
    ///
    /// `weak`, because the catalog belongs to the wrapper and not to this model; a strong
    /// reference would turn information into a claim of ownership. `nil` is allowed and means:
    /// This model lives in the settings and does not know the catalog — then it
    /// re-reads at the next build.
    public weak var listen: PlaylistStore?

    /// Where a change goes up immediately — **asked for and not held.**
    ///
    /// The wrapper may build the cloud (`CloudStartup`) only after this model; a
    /// ``ProfileKit/ProfileCloud/attached`` read at build time would then be `nil` forever.
    /// The checks pass in their own.
    private let cloud: @MainActor () -> ProfileCloud?

    /// Where ``ProfileKit/StartChoice`` lives — replaceable for the checks, so that a
    /// merge there does not change the machine's choice.
    private let startStore: UserDefaults

    /// The list catalog **of the device**, unfiltered — to clean up, on removal, the channel lists
    /// that nobody keeps any more (``cleanUpLists(from:ledger:)``). Asked for because
    /// ``listen`` is held only weakly and is not set at all in the settings.
    ///
    /// **Without a default, on the real Keychain**, deliberately: A check that does not
    /// name it should not touch this machine's lists.
    private let deviceLists: @MainActor () -> PlaylistStore?

    public init(
        keychain: SecureStore = SecureStore(),
        store: any KeyValueStore = FileStore(),
        listen: PlaylistStore? = nil,
        cloud: @escaping @MainActor () -> ProfileCloud? = { ProfileCloud.attached },
        startStore: UserDefaults = .standard,
        deviceLists: @escaping @MainActor () -> PlaylistStore? = { nil }
    ) {
        self.keychain = keychain
        self.store = store
        self.listen = listen
        self.cloud = cloud
        self.startStore = startStore
        self.deviceLists = deviceLists
        load()
    }

    public func load() {
        let ledger = ProfileBook.read(from: store)
        profile = ledger.profile
        active = ledger.active
    }

    /// What happens to the media server session after a re-read book.
    public enum SessionSequence: Equatable {
        /// The existing session matches the active profile.
        case remains
        /// The session was switched — `nil` if it was cleared. The value goes to
        /// the same `onSwitched` callback as with a manual switch.
        case migrate(ServerCredentials?)
    }

    /// Re-reads the book **and follows up the session if a remote migration moved the active
    /// profile** (strand F, 2026-09-25).
    ///
    /// The rule is at ``ProfileKit/ProfileSwitch/followUpMove(from:ledgerStore:keychain:deviceStore:)``;
    /// here only the "before" is recorded, which cannot be learned after ``load()``,
    /// and the result is converted as with the TV's `AccountSwitcher` — so that the wrapper
    /// takes the same callback and not a second path for the same thing.
    public func loadAfterArrival() -> SessionSequence {
        let previous = active
        load()
        guard
            let result = ProfileSwitch.followUpMove(
                from: previous, ledgerStore: store, keychain: keychain,
                deviceStore: keychain)
        else { return .remains }
        return .migrate(
            result.didSwitchSession ? try? keychain.loadCredentials() : nil)
    }

    public var activeProfile: Profile? { profile.first { $0.identifier == active } }

    /// Whether there is anything to switch at all.
    public var canSwitch: Bool { profile.count > 1 }

    /// Whether "Who's watching?" stands before the media library at startup (AP45, 2026-09-23).
    ///
    /// **Read and not applied.** ``ProfileKit/StartChoice/apply(in:keychain:deviceStore:ledgerStore:)``
    /// runs exactly once, in the startup; this property only looks at what came
    /// out of it. A view that tried the switch itself again would write
    /// to the book on every redraw.
    /// The active profile and how many there are — for the guard against a main screen
    /// without a person (``ProfilePicker/asksWithoutActive(active:profiles:protectionActive:)``).
    public var activeAndCount: (active: Profile.Identifier?, count: Int) {
        let ledger = ProfileBook.read(from: store)
        return (ledger.active, ledger.profile.count)
    }

    public var launchGate: StartCurtain {
        let ledger = ProfileBook.read(from: store)
        return StartCurtain.forItem(
            startTarget: StartChoice().applies(in: ledger)?.identifier, active: ledger.active,
            profile: ledger.profile.count)
    }

    // MARK: - Creating

    /// The colour a new profile gets suggested.
    ///
    /// **The first that nobody has yet** — and only when all six are taken does it
    /// continue in rotation. Two people in the same colour are two circles that cannot be told
    /// apart from three metres; excluding them would still be wrong, because
    /// from the seventh profile on there would be none.
    public var nextColor: Profile.ColorTag {
        let assigned = Set(profile.map(\.color))
        return Profile.ColorTag.allCases.first { !assigned.contains($0) }
            ?? Profile.ColorTag.allCases[profile.count % Profile.ColorTag.allCases.count]
    }

    /// Creates a profile — **without accesses.**
    ///
    /// **A profile without access is a valid profile**, and that is the point of this
    /// line: Until now a person came into being only by someone signing in to a
    /// media server. Whoever wants to set up the TV for a child who does not own
    /// anything yet can now do so and give the accesses afterwards.
    ///
    /// - Parameter avatar: the profile picture (AP49), `nil` means letter.
    /// - Returns: The ID of the new profile, or `nil` if the name was empty.
    @discardableResult
    public func create(
        name: String, color: Profile.ColorTag, kind: Profile.Kind, avatar: String?
    ) -> Profile.Identifier? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }

        var ledger = ProfileBook.read(from: store)
        let newProfile = Profile(name: clean, color: color, kind: kind, avatar: avatar)
        ledger.create(newProfile)
        ledger.write(in: store)
        // **Default settings instead of the device's** (owner, 2026-09-28) —
        // ``Core/ProfileStore/markFresh(_:in:)``.
        ProfileStore.markFresh(newProfile.identifier.rawValue, in: keychain)
        // **A new child explicitly blocks what is not understood** — the protection that until
        // 2026-09-25 was given by the default on reading (``ProfileKit/ProfileBackup/setUp(_:keychain:)``).
        ProfileBackup.setUp(newProfile, keychain: keychain)
        // **A new profile starts empty** (on-device test build 1332) — the line documents it in the
        // report: no accesses, no state; what it gets, it gets afterwards, visibly.
        Diagnose.step(
            .login,
            "Profile created (\(kind == .kind ? "child" : "adult"), credentials: \(newProfile.credentials.count))"
        )
        handOff(newProfile.identifier)
        load()
        return newProfile.identifier
    }

    /// Changes name, colour and picture of a profile.
    ///
    /// **The kind stays as it was created, and that is no oversight.** The rule
    /// has stood since 09-06 at ``Core/AccountCreation/mark(kind:forItem:list:)`` and applies
    /// here just the same: What could be set to "child" afterwards could also be
    /// set back — and whoever knows the PIN would then not have to get around parental controls,
    /// they would switch them off. A child becomes an adult by someone giving it a
    /// new profile; that is a visible operation and not a switch.
    public func update(
        _ identifier: Profile.Identifier, name: String, color: Profile.ColorTag, avatar: String?
    ) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        var ledger = ProfileBook.read(from: store)
        ledger.update(identifier) { profile in
            profile.name = clean
            profile.color = color
            profile.avatar = avatar
        }
        ledger.write(in: store)
        handOff(identifier)
        load()
    }

    /// Sets only the picture of a profile — **the phone's path** (picture choice in the
    /// person sheet). Name, colour and kind stay as they are; a profile that
    /// no longer exists in the meantime is left unwritten.
    ///
    /// - Parameter avatar: `""` means "No picture" (decided), `nil` "never decided" —
    ///   the difference is a contract with the cloud (`ProfilePictureChoice`).
    public func setPicture(_ identifier: Profile.Identifier, avatar: String?) {
        var ledger = ProfileBook.read(from: store)
        ledger.update(identifier) { $0.avatar = avatar }
        ledger.write(in: store)
        handOff(identifier)
        load()
    }

    /// Writes the profile just changed **immediately** into its mirror and kicks off a
    /// round trip.
    ///
    /// **The finding of the counter-check of 2026-09-25:** If the choice stood only in the book, a
    /// silent push before the next round trip fetched the cloud state down — and
    /// ``ProfileKit/ProfileCloud/download(_:)`` wrote it over the fresh choice (picture, name,
    /// colour). If it stands in the mirror and waits in the queue, the zone merges an
    /// incoming record by the rule "younger writer wins", and that is the choice.
    ///
    /// **On first contact only if the mirror comes from here** — the rule is at
    /// ``ProfileKit/ProfileCloud/mayPassOn(_:)``.
    private func handOff(_ identifier: Profile.Identifier) {
        defer { SyncCall.call(.byHand) }
        guard let cloud = cloud(), cloud.mayPassOn(identifier),
            let profile = ProfileBook.read(from: store).profile.first(where: { $0.identifier == identifier })
        else { return }
        cloud.upload(profile)
    }

    // MARK: - Removing

    /// Whether this profile may be removed.
    ///
    /// **The last one must not go, and the reason is not taste.** An empty book
    /// means to ``ProfileKit/ProfileBook/adopt(jellyfin:children:channelLists:wantsPortals:portalPerson:signedIn:fallbackName:in:)``
    /// "not yet taken over": The next start would rebuild, from what lies on the device,
    /// exactly the profile that someone has just removed. A deletion that takes itself back
    /// overnight is worse than a button that does not exist.
    public func mayRemove(_ identifier: Profile.Identifier) -> Bool {
        profile.count > 1 && profile.contains { $0.identifier == identifier }
    }

    /// How a removal turned out.
    public enum RemovalOutcome: Equatable {
        case removed
        /// This profile carries a PIN, and it is missing or wrong.
        case pinRequired(Profile)
        /// **A lent profile** (AP44) — it belongs to another Apple account and is
        /// not buried but left: ``leave(_:)``. Nothing is changed.
        case isBorrowed(Profile)
        /// The last profile, an unknown one, or the book could not be written.
        case impossible
    }

    /// **How far a removal reaches** — the choice that "Manage profiles" presents to the viewer
    /// (owner request on on-device test build 1332, 2026-09-27).
    ///
    /// Until here there was only one kind, and it was both halves: The tombstone took the profile
    /// off every device of the same Apple ID, but the zone stayed in iCloud for half a year
    /// (``ProfileKit/ProfileTombstone/retention``). Whoever wanted to get rid of a test profile did
    /// not get rid of it; whoever only wanted to take it off a second household's TV took it away everywhere.
    public enum RemovalMode: Sendable, Equatable {
        /// **Remove from this device** — only here; in iCloud and on the other devices
        /// it stays, and via "add existing profiles" it can be fetched again
        /// (``ProfileKit/ProfileHiding``).
        case hereOnly
        /// **Delete everywhere** — tombstone for every device and the zone gone for good
        /// (``ProfileKit/ProfileCloud/deleteZone(_:)``). A lent profile is left.
        case everywhere
    }

    /// The deletion of the zone after ``RemovalMode/everywhere`` — **held so that it can be
    /// awaited** (the checks; the interface does not wait).
    public private(set) var zoneDeletion: Task<Void, Never>?

    /// Whether a profile is **lent** (AP44) — then there is only "Leave sharing", because
    /// the zone belongs to another Apple account.
    public func isBorrowed(_ identifier: Profile.Identifier) -> Bool {
        cloud()?.zone(forItem: identifier)?.sharedBy != nil
    }

    /// Removes a profile — **and the accesses that belonged only to it.**
    ///
    /// **A media server account that nobody has any more does not stay in the Keychain.**
    /// Otherwise there would be a login on the device to which no person
    /// belongs; it would show up again as a profile at the next startup, because that is exactly what
    /// it builds them from. An account that another profile still has stays untouched.
    /// **The same has applied to channel lists since 2026-09-27** — see ``cleanUpLists(from:ledger:)``.
    ///
    /// **"Everywhere" does not come back from iCloud** (AP43 · B5, 2026-09-25): A tombstone
    /// tells every device of the same Apple ID, even without a cloud on the device — whoever turns on iCloud later
    /// should not get the removed profile back from there. Since
    /// 2026-09-27 the zone goes afterwards as well. **"Only here"** lays no tombstone but
    /// hides the profile on this device (``ProfileKit/ProfileHiding``).
    ///
    /// **With the same PIN as merging** (counter-check strand C, finding 8): Removing a
    /// protected profile takes its state and lock; without a latch in front, that would be
    /// the shortest way to get rid of a profile PIN. **A lent profile is
    /// left and not buried** — its tombstone would sit in this account's household zone
    /// and take it away on every device of this household, although it belongs to someone
    /// else; only the owner may delete its zone.
    @discardableResult
    public func remove(
        _ identifier: Profile.Identifier, pin: String? = nil, mode: RemovalMode = .everywhere
    ) -> RemovalOutcome {
        guard mayRemove(identifier),
            let departing = ProfileBook.read(from: store).profile.first(where: { $0.identifier == identifier }
            )
        else { return .impossible }
        let lock = ProfilePIN(store: keychain, forItem: identifier)
        if lock.isSet {
            guard let pin, lock.matches(pin) else { return .pinRequired(departing) }
        }
        if isBorrowed(identifier) {
            return .isBorrowed(departing)
        }

        var ledger = ProfileBook.read(from: store)
        let wasActive = ledger.active == identifier
        ledger.remove(identifier)
        if wasActive { ledger.clearActive() }
        ledger.write(in: store)
        guard !ProfileBook.read(from: store).profile.contains(where: { $0.identifier == identifier })
        else { return .impossible }
        switch mode {
        case .hereOnly:
            if let cloud = cloud() {
                cloud.hide(identifier)
            } else {
                ProfileHiding.create(identifier, in: store)
            }
            Diagnose.step(.login, "Profile removed from this device (stays in iCloud)")
        case .everywhere:
            if let cloud = cloud() {
                cloud.bury(identifier)
                cloud.cancelPinRecovery(forItem: .profile(identifier))
                zoneDeletion = Task { await cloud.deleteZone(identifier) }
            } else {
                ProfileTombstone.create(identifier, in: store)
            }
            Diagnose.step(.login, "Profile deleted everywhere")
        }
        cleanUp(departing, ledger: ledger, wasActive: wasActive)
        return .removed
    }

    /// The profiles that are **hidden on this device** and live on in iCloud —
    /// the selection behind "add existing profiles". Without the cloud: none.
    public func hiddenProfiles() async -> [Profile] {
        guard let cloud = cloud() else { return [] }
        return await cloud.findHidden()
    }

    /// Explicitly brings hidden profiles back (``ProfileKit/ProfileCloud/restore(_:now:)``).
    public func restore(_ profile: [Profile]) {
        guard !profile.isEmpty, let cloud = cloud() else { return }
        cloud.restore(profile)
        load()
        SyncCall.call(.byHand)
    }

    /// Leaves a **lent** profile — participation is withdrawn at CloudKit, then
    /// it disappears from the book (``ProfileKit/ProfileCloud/leave(_:)``); cleaning up
    /// happens afterwards as with removal, only without a tombstone.
    public func leave(_ identifier: Profile.Identifier) async throws(CloudError) {
        guard let cloud = cloud(),
            let departing = ProfileBook.read(from: store).profile.first(where: { $0.identifier == identifier }
            )
        else { return }
        let wasActive = ProfileBook.read(from: store).active == identifier
        try await cloud.leave(identifier)
        var ledger = ProfileBook.read(from: store)
        if wasActive {
            ledger.clearActive()
            ledger.write(in: store)
        }
        cleanUp(departing, ledger: ledger, wasActive: wasActive)
    }

    /// What lies on the device under the ID after removing or leaving — **gone.**
    ///
    /// **PIN, age limit, state and shelf order** (finding 8): Until C2 they stayed,
    /// under an ID that nobody reads any more — the PIN in the Keychain and in its
    /// iCloud backup, the state as a file.
    ///
    /// **If the one leaving sat in front, their successor must pass the latch** (check 2026-09-25
    /// evening) — see ``followSuccessor()``.
    private func cleanUp(_ departing: Profile, ledger: ProfileBook, wasActive: Bool) {
        let identifier = departing.identifier
        // **And this person's playback preferences** (decision 4, 2026-09-24) —
        // otherwise their compartments would stay as corpses in the Keychain.
        ProfileStore(keychain, forItem: identifier.rawValue).forget()
        // **And their person token** (AP47) — a secret without an owner is the last thing
        // that should stay in the Keychain.
        PortalMarkerSlot(keychain).forget(forItem: identifier)
        // **And an open join request of this profile** — otherwise a later
        // share would land at an ID that no longer exists.
        let note = JoinNote(keychain)
        if note.openRequest?.profile == identifier { note.forgetRequest() }
        // **And an open revocation** (counter-check strand D, finding 2.2) — without a profile
        // it lacks the server person, it could never run again.
        note.forgetRevocation(identifier)
        // **The profile PIN on the device removed entirely** (AP52) — no tombstone: The zone is
        // buried or left, a "no PIN" there would be information for nobody.
        ProfilePIN(store: keychain, forItem: identifier).forget()
        AgeLimit.write(nil, in: keychain, forItem: identifier.rawValue)
        // **And the allow list for channels** (AP52) — from the same compartment.
        ChannelApproval().save(to: keychain, forItem: identifier.rawValue)
        StillLedger().write(in: store, forItem: identifier.rawValue)
        ShelfOrder().write(in: store, forItem: identifier.rawValue)

        cleanUpAccess(from: departing, ledger: ledger)
        cleanUpLists(from: departing, ledger: ledger)

        load()
        // **And the session follows whoever sits in front now.** Whoever removes the active profile
        // would otherwise stand in front of the media library of a person who no longer exists.
        if wasActive {
            followSuccessor()
        } else if let remains = active {
            switchTo(zu: remains)
        }
    }

    /// Who sits in front after the active profile — **the first that gets through
    /// ``ProfileKit/ProfileSwitch`` without a PIN, otherwise nobody** (check 2026-09-25 evening).
    ///
    /// **The finding:** ``ProfileKit/ProfileBook/remove(_:)`` let the first profile move up,
    /// and if a PIN stood in front of it, it was active without anyone having entered it — the
    /// shortest way into a protected profile was to remove one's own.
    ///
    /// **The same latch as at startup** (``ProfileKit/StartChoice/apply(in:keychain:deviceStore:ledgerStore:)``):
    /// The switch without a PIN returns ``ProfileKit/ProfileSwitch/SwitchOutcome/pinRequired`` for a protected profile
    /// and touches nothing. If none gets through, the book stays without an active profile
    /// (``ProfileKit/ProfileBook/clearActive()``), session, portal header and ``Core/ProfilePointer``
    /// fall back to the device, and the next start asks "Who's watching?"
    /// (``ProfileKit/StartCurtain``). Until then the profile list itself is the choice, with
    /// number pad.
    private func followSuccessor() {
        let candidates = profile
        guard !candidates.contains(where: { switchTo(zu: $0.identifier).result != nil }) else {
            return
        }
        try? keychain.clearCredentials()
        DeviceTrait.saveProfile(nil, to: keychain)
        ProfilePointer.show(to: nil)
    }

    /// Takes the media server account of a vanished profile out of the Keychain —
    /// **if nobody has it any more.** Shared by removing and merging: When
    /// merging, an account is dropped if both had one and only one can
    /// remain (``ProfileKit/ProfileSync/fuse(device:cloud:)``).
    private func cleanUpAccess(from departing: Profile?, ledger: ProfileBook) {
        guard case .jellyfin(let server, let user, _) = departing?.jellyfin else { return }
        let stillNeeded = ledger.profile.contains { profile in
            if case .jellyfin(let s, let b, _) = profile.jellyfin {
                return s == server && b == user
            }
            return false
        }
        guard !stillNeeded else { return }
        try? keychain.forget(server: server, user: user)
        // **And the session, if it pointed to exactly this account.** The finding from AP22
        // (2026-09-11) is at the predecessor ``AccountsModel/remove(_:)`` and applies here
        // unchanged: An access token for an account that no longer exists is not a
        // login but a riddle — the app would keep running until the server rejects it.
        let session = try? keychain.loadCredentials()
        if session?.serverURL == server, session?.userID == user {
            try? keychain.clearCredentials()
        }
    }

    /// Takes the channel lists of a vanished profile off the device — **those that no
    /// other profile keeps**, including the password in the Keychain.
    ///
    /// **The finding from the on-device test (build 1332, 2026-09-27):** Old profile deleted, new one
    /// created — and under "IPTV accesses" the old one's access stood, active, while the
    /// overview above it reported "nothing". The profile carries only the ID of the list
    /// (AP41); the list itself stayed on the device, without a person, and every view that
    /// read the device catalog showed it to the next person. The same rule as with the
    /// media server account (``cleanUpAccess(from:ledger:)``): What nobody has any more does not stay
    /// around; what another profile still keeps stays untouched.
    private func cleanUpLists(from departing: Profile, ledger: ProfileBook) {
        let own = Set(departing.channelLists.compactMap(\.channelListID))
        guard !own.isEmpty, let catalog = listen ?? deviceLists() else { return }
        let kept = Set(ledger.profile.flatMap { $0.channelLists.compactMap(\.channelListID) })
        let route = own.subtracting(kept).filter { catalog.playlist(withID: $0) != nil }
        guard !route.isEmpty else { return }
        for identifier in route { catalog.remove(identifier) }
        // **And every other catalog re-reads** — on the TV `MainView` holds one of its own.
        ListGuard.call()
        Diagnose.step(.login, "Channel lists of the removed profile cleared: \(route.count)")
    }

    // MARK: - PIN (AP52)

    /// Whether this profile requires a PIN.
    public func isPinSet(_ identifier: Profile.Identifier) -> Bool {
        ProfilePIN(store: keychain, forItem: identifier).isSet
    }

    /// Whether these digits are the profile's PIN — **without opening anything.**
    public func matchesPin(_ digits: String, forItem identifier: Profile.Identifier) -> Bool {
        ProfilePIN(store: keychain, forItem: identifier).matches(digits)
    }

    /// The "set, change, remove PIN" flow for this profile — **the shared one**
    /// (``Flows/ProfilePinFlow``, AP58 R2), with this model's Keychain. Until
    /// then there was a `setPin`/`entfernePin` of its own here beside the phone's path.
    ///
    /// - Parameter wolke: as the view has it — `nil` without an Apple account.
    public func pinFlow(
        forItem profile: Profile, state: ProfilePinFlow.Situation, cloud: ProfileCloud?
    ) -> ProfilePinFlow {
        ProfilePinFlow(profile: profile, state: state, keychain: keychain, cloud: cloud)
    }

    // MARK: - Merging

    /// Counts answered questions — so that ``openQuestions`` is re-read when one
    /// disappears (the answer lives in the store, not in this model).
    private var questionRevision = 0

    /// The open "merge?" questions (AP45 ← AP48) — for "Manage profiles".
    public var openQuestions: [ProfileSync.Pair] {
        _ = questionRevision
        return ProfileSync.openQuestions(from: store).filter { pair in
            profile.contains { $0.identifier == pair.device }
                && profile.contains { $0.identifier == pair.cloud }
        }
    }

    /// "Keep both" — the question is answered and does not come back.
    public func keepBoth(_ pair: ProfileSync.Pair) {
        ProfileSync.answer(pair, in: store)
        questionRevision += 1
    }

    /// Puts `leaving` into `remains` — **irrevocably**; the view asks for confirmation.
    ///
    /// The rule is in ``ProfileKit/ProfileMerge`` and not here, so that the phone
    /// uses the same. This model adds what is known only on the TV: the
    /// orphaned media server account in the Keychain, the channel lists' favourites row,
    /// and the session if the viewer was just in the vanished profile.
    ///
    /// - Parameter pins: the PINs entered; if one is missing, the outcome answers with
    ///   ``ProfileKit/ProfileMerge/SwitchOutcome/pinRequired(_:)``, and the view asks.
    @discardableResult
    public func merge(
        _ leaving: Profile.Identifier, in remains: Profile.Identifier,
        pins: [Profile.Identifier: String] = [:]
    ) -> ProfileMerge.SwitchOutcome {
        let departing = ProfileBook.read(from: store).profile.first { $0.identifier == leaving }
        let outcome = ProfileMerge.perform(
            leaving, in: remains, pins: pins, ledgerStore: store, keychain: keychain,
            startStore: startStore, cloud: cloud())
        guard case .merged(_, let wasActive) = outcome else { return outcome }
        cleanUpAccess(from: departing, ledger: ProfileBook.read(from: store))
        load()
        // **Even if the remaining one is the active one, the switch is redone** (counter-check
        // strand C): If a child merges into it, it is now a child profile with the
        // child's media server — session, server header and parental controls must know that
        // immediately, not only at the next switch. The PIN of the remaining one may
        // be that of the departed one (``ProfileKit/ProfileMove``), hence both.
        if wasActive || active == remains {
            switchTo(zu: remains, pin: pins[remains] ?? pins[leaving])
        } else {
            listen?.loadFavorites()
        }
        SyncCall.call(.byHand)
        return outcome
    }

    // MARK: - Switching

    /// Switches to a profile.
    ///
    /// **The rule is in ``ProfileKit/ProfileSwitch`` and not here** — including PIN latch,
    /// session and `X-CL-Profile`. This type only passes in the stores: What a
    /// switch is must not depend on which screen triggers it.
    @discardableResult
    public func switchTo(zu identifier: Profile.Identifier, pin: String? = nil) -> ProfileSwitch.SwitchOutcome
    {
        var ledger = ProfileBook.read(from: store)
        let outcome = ProfileSwitch.switchTo(
            zu: identifier, in: &ledger, keychain: keychain,
            deviceStore: keychain, ledgerStore: store, pin: pin)
        // **The favourites row must re-read** (AP42). The catalog lives as long as the
        // app and keeps the favourites in memory; without this nudge it would, after
        // the switch, keep showing the previous viewer's — and the next press on a
        // star would write them into the new one's book.
        if let result = outcome.result {
            listen?.loadFavorites()
            Diagnose.step(
                .login,
                "Profile switched (channel lists: \(result.profile.channelLists.count), portals: \(result.profile.wantsPortals ? "yes" : "no"), media server: \(result.profile.jellyfin != nil ? "yes" : "no"))"
            )
        }
        load()
        return outcome
    }
}
