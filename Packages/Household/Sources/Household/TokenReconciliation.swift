import Core
import Diagnose
import Foundation
import PortalKit
import ProfileKit

/// **Keep the person mark in the profile at the server's state** — the way in which
/// the new mark reaches the app after a revocation (AP47, 2026-09-25).
///
/// **The finding:** The self sign-in was built but waited for a new mark in the
/// profile that never came. The server issues it on revocation and hands it out again at any time on
/// `POST /household/people/{id}/mark` — the app just never asked.
/// Now every **own, still signed-in** device of the person asks when the portals are opened
/// and stores a different mark in the compartment; via ``ProfileKit/PortalMarkerMapping`` it
/// migrates into the zone, and the devices that dropped out silently sign in again with it.
///
/// **Only for the own person.** An administrator feature would also get the mark of
/// somebody else, and it would then lie in a profile that happens to be sitting in front. That is why the
/// server person of the feature must be the same as that of the active profile, and a
/// borrowed profile never asks (the server would reject it with `auth.borrowed_profile`).
///
/// **And the revocation itself**, when the sharing of a profile ends (decision 8.4):
/// ``revoke(forItem:)`` — **for the named profile, no matter which one is sitting in front.** If
/// it fails, it stays noted (``ProfileKit/JoinNote/openRevocations``, a set), and every
/// sync catches up on all that the feature may revoke.
///
/// **One version for TV and phone** (AP58 R2, finding P3). The phone had its
/// own, ninety percent identical — without a loaner-device check and without the self sign-in
/// after a new mark. A phone signed in via PIN is exactly the device that can fetch the
/// new mark after a revocation: Its feature never depended on the mark, and
/// ``SelfSignIn/expectedValue(_:hasTrait:tag:used:failed:signedOut:)`` says "nothing to do"
/// for it.
public struct TokenReconciliation {

    public enum SwitchOutcome: Equatable, Sendable {
        /// No reason — no feature, borrowed, child, foreign person.
        case notNeeded
        /// The server has the same mark that is already in the compartment.
        case unchanged
        /// A different mark is now in the compartment.
        case fresh
        case failed
    }

    let basis: URL
    let session: URLSession
    let keychain: any KeyValueStore
    let ledgerStore: any KeyValueStore
    let deviceName: String
    let kind: DeviceKind

    public init(
        basis: URL, session: URLSession, keychain: any KeyValueStore,
        ledgerStore: any KeyValueStore, deviceName: String = DeviceName.thisDevice,
        kind: DeviceKind = .thisDevice
    ) {
        self.basis = basis
        self.session = session
        self.keychain = keychain
        self.ledgerStore = ledgerStore
        self.deviceName = deviceName
        self.kind = kind
    }

    /// **The decision as a calculation:** only an own device, only an adult
    /// profile with portals, and only if feature and profile mean the same person.
    public nonisolated static func expectedValue(profile: Profile?, me: String, isBorrowed: Bool) -> Bool {
        guard !isBorrowed, let profile, profile.kind != .kind, profile.wantsPortals else {
            return false
        }
        return profile.portalPerson == me
    }

    /// With an already known situation — Settings has just asked `household/me`
    /// and does not need to do it twice.
    ///
    /// **First the open revocations, then the own mark.** Every revocation that this
    /// feature may perform (``mayRevoke(person:me:)``) now goes to the server — also for
    /// profiles that are not currently sitting in front (counter-check strand D, finding 2.1).
    @discardableResult
    public func reconcile(me: HouseholdPerson, isBorrowed: Bool) async -> SwitchOutcome {
        guard !isBorrowed, let trait = DeviceTrait.load(from: keychain) else {
            return .notNeeded
        }
        let ledger = ProfileBook.read(from: ledgerStore)
        let revoked = await catchUpRevocations(me: me, ledger: ledger, trait: trait)

        // **Not `revoked.values.first`** (finding 2026-09-27, e2): That would be the
        // outcome of a FOREIGN profile that is not currently sitting in front. `MainView.loadPortals()`
        // checks `== .fresh` and rebuilt the portal source unnecessarily every time any
        // other profile got a new mark in the same sync — the active profile
        // itself needed nothing.
        // Who may hold a mark of their own the server states itself — see `holdsOwnMark`.
        guard let profile = ledger.activeProfile, Self.holdsOwnMark(me),
            Self.expectedValue(profile: profile, me: me.id, isBorrowed: isBorrowed)
        else { return .notNeeded }
        if let done = revoked[profile.identifier] { return done }
        let value: String
        do {
            value = try await join(trait).ownToken(person: me.id)
        } catch {
            Diagnose.hint(.network, "Person token not fetched", error)
            return .failed
        }
        return await create(value, forItem: profile.identifier)
    }

    /// Whether the server issues this person a mark of their own — a device that belongs
    /// to them instead of a borrowed profile.
    ///
    /// **The right, not the role** (AP85, 2026-11-09). Since the console rebuild roles are
    /// data: a person can sit in an adult role with the 18+ lock and still be reported as
    /// `child` in the derived old label. The server decides by `own_devices`; asking the
    /// label kept such a person from signing in a second device of their own.
    ///
    /// **Missing right = the old rule.** A server from before the rebuild does not name
    /// `own_devices`; there `child` still means "no mark".
    public nonisolated static func holdsOwnMark(_ me: HouseholdPerson) -> Bool {
        if let own = me.permissions?.ownDevices { return own }
        return me.role != "child"
    }

    /// Whether this feature may revoke the mark of **this** server person: its own
    /// always, a foreign one only with the right to pair devices — because a revocation throws
    /// devices out.
    ///
    /// **The calculation only saves hopeless requests.** The server decides; a
    /// refusal leaves the note in place, and another device catches up on it.
    public nonisolated static func mayRevoke(person: String, me: HouseholdPerson) -> Bool {
        person == me.id || me.permissions?.pairDevices == true
    }

    /// Works off the open revocations — **all, not only that of the active profile.**
    ///
    /// A note for a profile that no longer exists, that is a child by now or
    /// that no longer carries a server person is cleared (finding 2.2): It could never run
    /// again and would otherwise hang around forever.
    ///
    /// - Returns: the outcome per processed profile.
    private func catchUpRevocations(
        me: HouseholdPerson, ledger: ProfileBook, trait: String
    ) async -> [Profile.Identifier: SwitchOutcome] {
        let note = JoinNote(keychain)
        var outcomes: [Profile.Identifier: SwitchOutcome] = [:]
        for identifier in note.openRevocations {
            guard let profile = ledger.profile.first(where: { $0.identifier == identifier }),
                profile.kind != .kind, let person = profile.portalPerson
            else {
                note.forgetRevocation(identifier)
                continue
            }
            guard Self.mayRevoke(person: person, me: me) else { continue }
            outcomes[identifier] = await revokeNow(profile, person: person, trait: trait)
        }
        return outcomes
    }

    /// Without a situation: asks `household/me` itself — for the sidebar and the startup, which
    /// otherwise know no situation.
    ///
    /// **A loaner device never asks** (finding P3): With a remembered profile the server answers
    /// for the borrowed person, and that person's mark does not belong in this device's compartment. The
    /// phone did not check this until AP58 R2 — it never wrote a header; since it switches via
    /// ``ProfileKit/ProfileSwitch``, the same rule applies.
    @discardableResult
    public func reconcile() async -> SwitchOutcome {
        guard let trait = DeviceTrait.load(from: keychain) else { return .notNeeded }
        let borrow = DeviceTrait.profile(from: keychain)
        guard borrow == nil else { return .notNeeded }
        guard
            let me = try? await Household(
                binding: PortalBridge(
                    basis: basis, dialect: .cinelounge, trait: trait, session: session)
            ).me()
        else { return .failed }
        return await reconcile(me: me, isBorrowed: false)
    }

    /// Revoke the mark **because the sharing of this profile ended** (decision 8.4).
    ///
    /// First noted, then asked: If the app crashes in between or the server stays
    /// silent, the next sync catches up on the revocation. Only for a profile that carries a
    /// mark — without a mark in the compartment the participant did not get one either.
    ///
    /// **Immediately and for the named profile** (counter-check strand D, finding 2.1): The
    /// person comes from this profile, the feature from the Keychain. Until then the
    /// revocation aborted silently if another profile happened to be sitting in front — and the removed
    /// participant kept a valid mark. **Also for a child** that (after
    /// switching, say) still carries a mark in the compartment: The mark holds at the server, no matter what
    /// the profile has become here in the meantime.
    @discardableResult
    public func revoke(forItem identifier: Profile.Identifier) async -> SwitchOutcome {
        guard PortalMarkerSlot(keychain).tag(forItem: identifier) != nil else {
            return .notNeeded
        }
        JoinNote(keychain).rememberRevocation(identifier)
        guard
            let profile = ProfileBook.read(from: ledgerStore).profile.first(where: {
                $0.identifier == identifier
            }),
            let person = profile.portalPerson,
            let trait = DeviceTrait.load(from: keychain)
        else { return .failed }
        return await revokeNow(profile, person: person, trait: trait)
    }

    /// `DELETE` at the server, then the new mark into the compartment — **none for a child**: By the
    /// household rule it gets none, so its compartment stays empty.
    private func revokeNow(
        _ profile: Profile, person: String, trait: String
    ) async -> SwitchOutcome {
        let value: String
        do {
            value = try await join(trait).renewToken(person: person).tag
        } catch let rejection as PortalBridge.TestError where Self.isFinal(rejection) {
            // **A refusal that will turn out the same next time is done**
            // (diagnosis F-025, 2026-09-28): For a child the server issues no mark.
            // The note stayed in place, and every sync asked again — three times in
            // the same second, each time as an error in the report.
            JoinNote(keychain).forgetRevocation(profile.identifier)
            PortalMarkerSlot(keychain).forget(forItem: profile.identifier)
            Diagnose.step(.login, "Person token: none exists for this person, note resolved")
            return .notNeeded
        } catch {
            Diagnose.hint(.network, "Person token not renewed", error)
            return .failed
        }
        JoinNote(keychain).forgetRevocation(profile.identifier)
        guard profile.kind != .kind else {
            PortalMarkerSlot(keychain).forget(forItem: profile.identifier)
            SyncCall.call(.byHand)
            return .fresh
        }
        return await create(value, forItem: profile.identifier)
    }

    /// Refusals that do not change by repeating: **no mark for children.**
    nonisolated static func isFinal(_ rejection: PortalBridge.TestError) -> Bool {
        if case .cancelled(_, let code, _) = rejection { return code == "mark.not_for_children" }
        return false
    }

    private func join(_ trait: String) -> Join {
        Join(
            binding: PortalBridge(
                basis: basis, dialect: .cinelounge, trait: trait, session: session))
    }

    /// Stores a different mark and triggers the sync.
    ///
    /// **If this device itself fell victim to the revocation** (it came in via the old mark),
    /// it signs in again at once with the new one — the same rule as after `auth.required`,
    /// decided by ``SelfSignIn/expectedValue(_:hasTrait:tag:used:failed:signedOut:)``.
    private func create(_ value: String, forItem identifier: Profile.Identifier) async -> SwitchOutcome {
        guard let tag = PersonMarker(value: value) else { return .failed }
        guard PortalMarkerSlot(keychain).create(tag, forItem: identifier) else {
            return .unchanged
        }
        Diagnose.step(.network, "Person token brought up to date")
        SyncCall.call(.byHand)
        _ = await SelfSignIn(
            basis: basis, session: session, keychain: keychain,
            ledgerStore: ledgerStore, deviceName: deviceName, kind: kind
        ).attempts(.dismissed)
        return .fresh
    }

    /// This programme's sync — `nil` without an entered address.
    ///
    /// **The address via ``Core/BridgeAddress/effective(from:)``** on both devices;
    /// the phone read only the entered one until AP58 R2 (the difference is the hook
    /// `CINELOUNGE_PORTALE` in the simulator).
    public static func onDevice() -> TokenReconciliation? {
        let keychain = SecureStore()
        guard let bridgeAddress = BridgeAddress.effective(from: keychain) else { return nil }
        return TokenReconciliation(
            basis: bridgeAddress, session: .shared, keychain: keychain,
            ledgerStore: FileStore())
    }
}
