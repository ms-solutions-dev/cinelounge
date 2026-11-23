import Core
import Diagnose
import Foundation
import Household
import ParentalControls
import ProfileKit

/// How what lies on a device becomes profiles — **and what happens at startup
/// afterwards** (AP41; merged in AP58 R2, finding P5).
///
/// **The finding:** The TV did this in the app target (`ProfileStartup`, unchecked), the phone
/// in `SetupState.createProfiles` — the same sequence, but without `ProfileStates`, without
/// ``ProfileKit/StartChoice`` and with a different cleaner for the legacy data. Now the
/// sequence lives once here, and **every deviation is a value in ``Steps``**, in one place,
/// with its rationale.
///
/// **It runs at every start and does nothing after the first.** Each takeover checks itself
/// whether something is already there — a "done" marker would be another truth and would be lost at the
/// first failure.
public enum ProfileStartup {

    /// What a device does at startup — **the deliberate differences as values.**
    nonisolated public struct Steps: Sendable, Equatable {

        /// Take the device's state (started films, channel favourites, last watched
        /// channel) into the signed-in profile (``ProfileKit/ProfileStates``).
        ///
        /// **Not on the phone, and that is intentional:** It never wrote to the device base
        /// of the ``Core/StillLedger``; its progress lives in the history and on the server. There is
        /// nothing to take over there, and ``ProfileKit/ProfileBook/takeoverPending(in:)`` does not hinge on it
        /// with an empty base.
        public var progressStates: Bool

        /// Apply "Start automatically as …" (``ProfileKit/StartChoice``) — **never past a PIN**:
        /// That is what ``ProfileKit/ProfileSwitch`` ensures.
        ///
        /// **On both devices** (AP58 R2). The phone did not have the step; as long as it
        /// shows no switch for it, there is no choice there, and it does nothing. When the
        /// switch arrives (profile management on the phone, decision 18), it takes effect without further
        /// rework — and through the same latch.
        public var startChoice: Bool

        /// Record a login at the CineLounge server from the time before AP58 R2 as **own**
        /// (``Household/DeviceSignIn/adoptsLegacySignIn(in:)``).
        ///
        /// **Only on the phone:** It never wrote a loan header, every one of its logins was
        /// its own. A TV without an own-marker, on the other hand, is a shared device —
        /// adding the marker to it would turn the living room into a person.
        public var backfillOwn: Bool

        public init(progressStates: Bool, startChoice: Bool, backfillOwn: Bool) {
            self.progressStates = progressStates
            self.startChoice = startChoice
            self.backfillOwn = backfillOwn
        }

        public static let tv = Steps(progressStates: true, startChoice: true, backfillOwn: false)
        public static let phone = Steps(progressStates: false, startChoice: true, backfillOwn: true)
    }

    /// What the device knew until today — **the inputs that only the app knows.**
    nonisolated public struct DeviceState: Sendable {
        /// The IDs of the channel lists on the device.
        public var channelLists: [String]
        /// Whether portals are wanted — the device state; from the next start on the book says it.
        public var wantsPortals: Bool
        /// The server person remembered on the device (ever set only on the TV).
        public var portalPerson: String?
        /// The name for a device without a media server user — from the language catalog.
        public var fallbackName: String
        /// The app's version (AP48): the reference point for "deleted in the
        /// version after next".
        public var version: String

        public init(
            channelLists: [String], wantsPortals: Bool, portalPerson: String? = nil,
            fallbackName: String,
            version: String = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        ) {
            self.channelLists = channelLists
            self.wantsPortals = wantsPortals
            self.portalPerson = portalPerson
            self.fallbackName = fallbackName
            self.version = version
        }
    }

    /// Turns the device into profiles and puts them in order.
    ///
    /// **The order is no whim:** first the profiles, then their backup and their
    /// shelves (both need the IDs), then the state (only to the signed-in profile),
    /// then the migration notes, then the clean cut (AP48 — cleaning happens **after** the
    /// takeover of the state, otherwise the evidence would be missing), then the start choice, last the pointer.
    ///
    /// - Parameters:
    ///   - schluesselbund: session, access list, PINs and trait.
    ///   - buchablage: profile book, still-frame book, child marks (``Core/FileStore``).
    ///   - startablage: where ``ProfileKit/StartChoice`` lives and where a migration carries the choice.
    ///   - altablage: the old `UserDefaults` store with `accounts.children` — `nil` leaves
    ///     it alone.
    /// - Returns: whether profiles were created on the first start.
    @discardableResult
    public static func fetch(
        _ steps: Steps, device: DeviceState, keychain: SecureStore,
        ledgerStore: any KeyValueStore, startStore: UserDefaults, legacyStore: UserDefaults?
    ) -> Bool {
        if steps.backfillOwn, DeviceSignIn.adoptsLegacySignIn(in: keychain) {
            Diagnose.step(.login, "Old sign-in recorded as own")
        }
        let session = try? keychain.loadCredentials()
        // **The session belongs to it, even if it is not in the list.** Why that is
        // no edge case is explained in ``ProfileKit/Access/jellyfin(list:signedIn:)``.
        let created = ProfileBook.adopt(
            jellyfin: Access.jellyfin(
                list: keychain.allAccounts(), signedIn: session),
            children: ChildAccountList(store: ledgerStore).all(),
            channelLists: device.channelLists,
            wantsPortals: device.wantsPortals,
            portalPerson: device.portalPerson,
            signedIn: session.map { "\($0.serverURL.absoluteString)|\($0.userID)" },
            fallbackName: device.fallbackName,
            version: device.version,
            in: ledgerStore)

        var ledger = ProfileBook.read(from: ledgerStore)
        guard !ledger.profile.isEmpty else { return created }
        ProfileBackup.adopt(ledger, keychain: keychain)
        ProfileShelves.adopt(ledger, store: ledgerStore)
        // **The state goes only to the signed-in profile** (AP42) — unlike the shelves:
        // A shelf order takes nothing from anybody, a state does.
        //
        // **And only in the startup that creates the profiles** (on-device test build 1332, 2026-09-27,
        // finding 1). Here the takeover used to happen at every start, and its own latch asked
        // only "does the active profile already have a state?". But the device base remains
        // (it applies as long as nobody is selected); whoever deleted the old profile and created a new one
        // got, at the next start, the favourites and started films from the
        // time before profiles — into a profile that was supposed to start empty.
        if steps.progressStates, created {
            ProfileStates.adopt(ledger, store: ledgerStore)
        }
        // **Catch up with the migration notes — even without an Apple account** (counter-check strand C,
        // R3/R4). If the app crashed during merging between book and migration, the
        // note lies on the device and the state still under the old ID; here it is
        // completed. With the cloud, ``ProfileKit/ProfileCloud`` does the same with the remote notes.
        let migrated = ProfileMove.episode(
            ProfileTombstone.all(from: ledgerStore), ledgerStore: ledgerStore,
            keychain: keychain, startStore: startStore)
        if !migrated.isEmpty {
            Diagnose.step(.login, "Server move caught up: \(migrated.count) profile(s)")
            ledger = ProfileBook.read(from: ledgerStore)
        }
        let cleaned = LegacyData.cleanUp(
            ledgerStore: ledgerStore, keychain: keychain, standard: legacyStore,
            listen: device.channelLists)
        if !cleaned.isEmpty {
            Diagnose.step(.login, "Legacy data cleared: \(cleaned.joined(separator: ", "))")
        }
        // **Child protection migrates once, before the start choice applies** (AP59 N4) — so a
        // device that was in child mode via the device lock until just now starts straight in the child profile.
        if ParentalControlsMigration.perform(
            ledger: &ledger, ledgerStore: ledgerStore, keychain: keychain,
            startStore: startStore, childName: AppLanguageSetting.text("profiles.kidsName")) != nil
        {
            ledger = ProfileBook.read(from: ledgerStore)
        }
        if steps.startChoice {
            StartChoice(store: startStore).apply(
                in: &ledger, keychain: keychain, deviceStore: keychain,
                ledgerStore: ledgerStore)
        }
        pointToActive(in: ledgerStore)
        return created
    }

    /// Sets ``Core/ProfilePointer`` to the profile that watched last (AP42).
    ///
    /// **Without this pointer every profile-related store would read the device base** — the
    /// ``Core/StillLedger`` would then be kept per person and nobody would write to it.
    /// Afterwards ``ProfileKit/ProfileSwitch`` keeps it up to date.
    public static func pointToActive(in store: any KeyValueStore) {
        ProfilePointer.show(to: ProfileBook.read(from: store).active?.rawValue)
    }
}
