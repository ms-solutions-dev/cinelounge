import Core
import Foundation
import ParentalControls

/// A profile switch — **the three changeovers in one step.**
///
/// **The finding this code grew out of** (2026-09-19): there were three switch points. The
/// "account" was the media server session in the Keychain and was switched by
/// ``AccountsModel``. The channel lists hung off the device and were **never** switched. The
/// CineLounge server's household person lay on the device as `setup.deviceProfile` too —
/// and `PortalBridge.using(trait:profile:)` had **not a single caller**: the
/// `X-CL-Profile` header was set where the bridge was built and never touched again
/// afterwards. Whoever switched the account switched one of three.
///
/// **Nothing is loaded and nothing is emptied here.** A switch is not a sign-out: it
/// swaps identifiers and leaves the image store, the snapshots per library and the
/// Top Shelf marker in place. On the TV, signing out was the only way until 2026-09-06, and
/// it cost an app that had to refill itself every time (E85: *"Switch without reloading
/// the posters"*).
///
/// **A result instead of an effect on the outside.** What the caller does with the new
/// session — re-query the views, redraw the bridge — is its decision;
/// this type knows neither ``PortalKit`` nor SwiftUI. Otherwise the notion of "profile"
/// would hang off the UI, and that is exactly the entanglement AP41 dissolves.
public enum ProfileSwitch {

    /// What holds after the switch.
    public struct Outcome: Sendable, Equatable {

        /// The profile that is now active.
        public let profile: Profile

        /// Whether the media server session could be switched.
        ///
        /// **`false` is not a failure of the switch.** A profile without a media server —
        /// channel lists only, portals only — is a valid profile; the library is then missing,
        /// and ``ProfileBook/Situation`` says so too. The switch itself
        /// took place.
        ///
        /// **Since the final review of 2026-09-25 (N-1), `false` also means: no session is
        /// left** — see ``didClearSession``. Whoever keeps showing the predecessor's session on
        /// `false` shows a child another person's library.
        public let didSwitchSession: Bool

        /// Whether the current media server session was emptied (N-1, 2026-09-25).
        ///
        /// `true` if the target has no media server **or** its media server could not be
        /// switched. The access list stays untouched — only the currently signed-in
        /// session is emptied; switching back restores the session again,
        /// without anyone having to sign in anew. The caller then shows the state
        /// "no media server" and does **not** sign out: signing out would take the snapshots and
        /// the image store with it, and those belong to the account, not to the profile.
        public let didClearSession: Bool

        /// The value that is sent along as `X-CL-Profile` from now on. `nil` means: no header.
        public let portalPerson: String?
    }

    /// How a switch turned out.
    ///
    /// **Three cases and no `Outcome?`.** A `nil` would mean "did not work" and leave open
    /// **why** — and the difference is the one between a screen that shows the
    /// keypad and one that does nothing. Exactly this kind of
    /// summary led in AP39 to a rejected parental control being read as
    /// "did not arrive".
    ///
    /// **`wrongPin` separate from `pinRequired`** (AP58 R2): the phone has said it this way since AP52,
    /// the TV read both as "show the keypad". Both cases change **nothing**; the
    /// only difference is whether the keypad reports "wrong".
    public enum SwitchOutcome: Sendable, Equatable {
        case switched(Outcome)
        /// This profile is protected by a PIN, and none was supplied.
        case pinRequired
        /// This profile is protected by a PIN, and the one supplied is wrong.
        case wrongPin
        /// This profile does not exist — for ``episode(account:ledgerStore:keychain:pinStore:deviceStore:pin:)``:
        /// no profile has this account as its media server.
        case unknown
        /// The profile of this account is already in front (only ``episode(account:ledgerStore:keychain:pinStore:deviceStore:pin:)``).
        /// Nothing is changed; the caller switches the session itself.
        case unchanged
    }

    /// Switches to a profile.
    ///
    /// **The order is not a whim.** Book first, then the Keychain: if
    /// switching the session aborts, it is still settled who is sitting in front — and the
    /// UI shows a profile without a library instead of a profile circle that belongs to
    /// nobody. The other way round, the session would be switched and the book not, and
    /// the app would show one person's library under another person's name.
    ///
    /// **The book is written here and not by the caller.** A switch that
    /// nobody persists holds until the next launch — and then the previous
    /// person is sitting in front again, without anyone having done anything. Leaving that to the caller
    /// would mean demanding the same line at every switch point and
    /// forgetting it at one.
    ///
    /// - Parameters:
    ///   - schluesselbund: Carries the media server session.
    ///   - geraeteablage: Where `setup.deviceProfile` lives — in the app the same
    ///     Keychain, in the checks a compartment of its own.
    ///   - buchablage: Where the ``ProfileBook`` lives (``Core/FileStore``).
    ///   - pin: The entered PIN, if the target carries one.
    ///
    /// **The bolt sits here and not in front of it** (AP41, line 4). A profile can have its
    /// own PIN — *"a PIN locks one's own adult profile if its
    /// owner wants that"*. Putting the check into the caller would mean forgetting it at one
    /// place; and a lock that is missing at one of five places is
    /// none. This is the same finding as with ``SettingsView/door(forItem:)`` in AP40, just
    /// one level up.
    ///
    /// **The check happens before anything is switched.** A switch that first rewrites the book
    /// and then asks for the PIN already has the other person's name on
    /// the screen.
    public static func switchTo(
        zu identifier: Profile.Identifier,
        in ledger: inout ProfileBook,
        keychain: SecureStore,
        deviceStore: any KeyValueStore,
        ledgerStore: any KeyValueStore,
        pin: String? = nil
    ) -> SwitchOutcome {
        switchOver(
            zu: identifier, in: &ledger, keychain: keychain, pinStore: keychain,
            deviceStore: deviceStore, ledgerStore: ledgerStore, pin: pin)
    }

    /// The bolt of a profile PIN — **the one place where every switch is asked.**
    ///
    /// **Since AP52 the profile PIN** (``ProfilePIN``) and no longer the device PIN with an
    /// identifier behind it — it travels via iCloud, and ``ProfileCloud/download(_:)`` puts it
    /// into the ``pinStore`` before anyone switches. **The check happens on the device**: a bolt that
    /// asked the cloud would stand open offline.
    ///
    /// - Returns: `nil` if the way is clear; otherwise, why not.
    static func lock(
        _ identifier: Profile.Identifier, pinStore: any KeyValueStore, pin: String?
    ) -> SwitchOutcome? {
        let lock = ProfilePIN(store: pinStore, forItem: identifier)
        guard lock.isSet else { return nil }
        guard let pin else { return .pinRequired }
        return lock.matches(pin) ? nil : .wrongPin
    }

    /// The switch itself — for ``switchTo(zu:in:keychain:deviceStore:ledgerStore:pin:)``
    /// and ``episode(account:ledgerStore:keychain:pinStore:deviceStore:pin:)``.
    ///
    /// **`pinStore` separate from the session's Keychain**, because the phone checks the PIN in the
    /// cloud's move bundle and the checks put it into a compartment of their own. In the
    /// app it is the same Keychain on both devices.
    private static func switchOver(
        zu identifier: Profile.Identifier,
        in ledger: inout ProfileBook,
        keychain: SecureStore,
        pinStore: any KeyValueStore,
        deviceStore: any KeyValueStore,
        ledgerStore: any KeyValueStore,
        pin: String?
    ) -> SwitchOutcome {
        guard let target = ledger.profile.first(where: { $0.identifier == identifier }) else {
            return .unknown
        }
        if let dismissed = lock(identifier, pinStore: pinStore, pin: pin) { return dismissed }

        ledger.switchTo(zu: identifier)
        guard let profile = ledger.activeProfile, profile.identifier == target.identifier else {
            return .unknown
        }

        var converted = false
        if case .jellyfin(let server, let user, _) = profile.jellyfin {
            do {
                try keychain.switchTo(server: server, user: user)
                converted = true
            } catch {
                // **Visible and not silent.** A switch that does not switch the session
                // shows the previous person's library under the new name;
                // that is the kind of error one takes on screen for a loading
                // error.
                Diagnostics.failure(server, step: "Profile switch", error: error)
            }
        }
        let cleared = converted ? false : clearSession(in: keychain)

        // **`nil` is written too**, and that is the point: whoever switches from a profile with a
        // household person to one without must **lose** the header. If it stayed
        // in place, the new profile would run under the old one's person — and the server
        // answers every request willingly, just for the wrong one.
        //
        // **Except on a device that belongs to one person** (AP47): there the header is not
        // information but turns one's own sign-in into a loan — see
        // ``Core/DeviceTrait/ownKey``.
        // **Into the target's compartment, explicitly** — the pointer still sits on the previous
        // profile here, and the trait lives per profile (``Core/DeviceTrait``).
        let targetCompartment = ProfileStore(deviceStore, forItem: profile.identifier.rawValue)
        DeviceTrait.saveProfile(
            DeviceTrait.own(in: targetCompartment) ? nil : profile.portalPerson,
            to: targetCompartment)
        ledger.write(in: ledgerStore)

        // **And from here on every store reads this person's book** (AP42, 2026-09-21).
        //
        // Here and not at the callers: one can switch from the switcher, from the
        // settings and — on the phone — from the setup. If the line sat there, it would
        // be right twice and forgotten once, and the forgotten one would write the state
        // of the new person into the old person's book. That would be noticed only when someone misses their
        // progress, and by then it is already overwritten.
        ProfilePointer.show(to: profile.identifier.rawValue)
        SyncCall.call(.profileSwitch)

        return .switched(
            Outcome(
                profile: profile, didSwitchSession: converted, didClearSession: cleared,
                portalPerson: profile.portalPerson))
    }

    /// Re-aligns the session **when a remote move has relocated the active profile**
    /// (strand F, 2026-09-25).
    ///
    /// **The finding:** a move note from another device
    /// (``ProfileMove/episode(_:ledgerStore:keychain:startStore:now:)``) puts the
    /// active profile into another one and switches book and ``Core/ProfilePointer`` — but not
    /// the media server session. If the target had a different media server or
    /// none, the app showed the old account's library under the new profile. If
    /// an adult moved their profile into a child's profile without an account of its own, the child
    /// then saw the adult's library.
    ///
    /// **The same switch as in ``switchTo(zu:in:keychain:deviceStore:ledgerStore:pin:)``,
    /// but without its framing:**
    ///
    /// * **No PIN.** The profile is the same, only its identifier changed; the question
    ///   was asked when it became active. The session follows the target profile's access.
    /// * **No ``Core/ProfilePointer``, no ``Core/SyncCall``, no writing into the book.**
    ///   The move has already done that. Each of these lines would trigger a notification here that
    ///   the shell listens to again with a call to this function — a loop that ended only
    ///   because the second pass would find nothing left.
    ///
    /// **Only if the active profile has changed**, and only if the current session
    /// does not already fit. A sync that does not touch the active profile passes
    /// every arrival by; a session that a manual switch has already switched shortly before
    /// stays in place.
    ///
    /// - Parameter vorher: the active profile before the book was re-read.
    /// - Returns: `nil` if the session stays; otherwise, what was switched.
    public static func followUpMove(
        from previous: Profile.Identifier?,
        ledgerStore: any KeyValueStore,
        keychain: SecureStore,
        deviceStore: any KeyValueStore
    ) -> Outcome? {
        let ledger = ProfileBook.read(from: ledgerStore)
        guard let profile = ledger.activeProfile, profile.identifier != previous else { return nil }

        // The portal header belongs to the switch as in a manual switch — rationale
        // there.
        // **Into the target's compartment, explicitly** — the pointer still sits on the previous
        // profile here, and the trait lives per profile (``Core/DeviceTrait``).
        let targetCompartment = ProfileStore(deviceStore, forItem: profile.identifier.rawValue)
        DeviceTrait.saveProfile(
            DeviceTrait.own(in: targetCompartment) ? nil : profile.portalPerson,
            to: targetCompartment)

        let existing = try? keychain.loadCredentials()
        var converted = false
        if case .jellyfin(let server, let user, _) = profile.jellyfin {
            if existing?.serverURL == server, existing?.userID == user { return nil }
            do {
                try keychain.switchTo(server: server, user: user)
                converted = true
            } catch {
                Diagnostics.failure(server, step: "Profile move", error: error)
            }
        } else if existing == nil {
            return nil
        }
        let cleared = converted ? false : clearSession(in: keychain)
        return Outcome(
            profile: profile, didSwitchSession: converted, didClearSession: cleared,
            portalPerson: profile.portalPerson)
    }

    /// Empties the current session, **without touching the access list** (final review
    /// 2026-09-25, N-1).
    ///
    /// **The finding:** a profile without a `.jellyfin` access took over the predecessor's
    /// session on a switch — the branch above simply did nothing when `jellyfin == nil`,
    /// and the Keychain kept pointing at another person's account. A child without an account of its own
    /// thus saw that person's library, with that person's permissions.
    ///
    /// **Also after a failed switch**, for the same reason: the session that
    /// is still standing then belongs to the previous person. No library is a state the
    /// UI knows; someone else's is one nobody notices.
    ///
    /// - Returns: whether no session is left now.
    private static func clearSession(in keychain: SecureStore) -> Bool {
        guard (try? keychain.loadCredentials()) != nil else { return true }
        do {
            try keychain.clearCredentials()
            return true
        } catch {
            Diagnostics.cursorKey("Profile switch", "Session not cleared — \(Diagnostics.explain(error))")
            return false
        }
    }
}

// MARK: - The profile follows the account

extension ProfileSwitch {

    /// The profile **whose media server access is this account** — `nil` if none.
    ///
    /// - Parameter konto: `server|user`, the same notation as
    ///   ``Access/legacyAccountID``.
    ///
    /// **Never a profile without a media server** (question N-1 from strand E): a profile with only
    /// a channel list or portals is thus never the target of an account switch, and the
    /// predecessor's session cannot stay in place under its name.
    public static func profile(toAccount account: String, in ledger: ProfileBook) -> Profile? {
        ledger.profile.first { $0.jellyfin?.legacyAccountID == account }
    }

    /// The profile that a switch to this account would lead to — `nil` if none
    /// or if it is already in front (book **and** ``Core/ProfilePointer``).
    public static func followUpTarget(account: String, ledgerStore: any KeyValueStore) -> Profile? {
        let ledger = ProfileBook.read(from: ledgerStore)
        guard let target = profile(toAccount: account, in: ledger),
            ledger.active != target.identifier || ProfilePointer.active != target.identifier.rawValue
        else { return nil }
        return target
    }

    /// The profile whose PIN is required **before** a switch to this account — `nil`
    /// if the way is clear.
    ///
    /// **A question before ``episode(account:ledgerStore:keychain:pinStore:deviceStore:pin:)``**,
    /// because the UI has to show the keypad before it switches anything. The
    /// answer is information and not a bolt: that sits in the switch itself.
    public static func lock(
        account: String, ledgerStore: any KeyValueStore, pinStore: any KeyValueStore
    ) -> Profile? {
        guard let target = followUpTarget(account: account, ledgerStore: ledgerStore),
            ProfilePIN(store: pinStore, forItem: target.identifier).isSet
        else { return nil }
        return target
    }

    /// The profile that should apply again when **nobody is in front** — that of the
    /// signed-in account; `nil` if a profile is active or the account has none.
    ///
    /// **Since 2026-09-25 ``ProfileBook/read(from:)`` leaves an empty "active" empty.** After
    /// the active profile is removed, nobody is in front. A device without a "Who's watching?"
    /// switcher (the phone) then takes the profile of its account again — **through
    /// the same bolt** as every switch.
    public static func restorable(
        account: String?, ledgerStore: any KeyValueStore
    ) -> Profile? {
        guard let account, ProfileBook.read(from: ledgerStore).active == nil else { return nil }
        return followUpTarget(account: account, ledgerStore: ledgerStore)
    }

    /// An account switch **is** a profile switch — the profile follows the account (AP58 R2, P1).
    ///
    /// **The finding:** the phone has no "Who's watching?" switcher; the
    /// account is switched, and the profile followed via a separate rebuild (`Profilfolge`) — with a
    /// second bolt in the shell, without `didClearSession` and without a portal header. Here
    /// the same switch as in ``switchTo(zu:in:keychain:deviceStore:ledgerStore:pin:)``
    /// stands: bolt, book, session, portal header, pointer, sync — only the target is found via the
    /// account.
    ///
    /// **The portal header follows ``Core/DeviceTrait/own(in:)`` and not the platform.**
    /// Whether it goes along with a request is decided by whoever builds the bridge.
    ///
    /// - Returns: ``SwitchOutcome/unknown`` if no profile has this account;
    ///   ``SwitchOutcome/unchanged`` if it is already in front — then the caller only switches
    ///   the session. For ``SwitchOutcome/pinRequired`` and ``SwitchOutcome/wrongPin`` **nothing** is
    ///   changed, not even the session.
    @discardableResult
    public static func episode(
        account: String,
        ledgerStore: any KeyValueStore,
        keychain: SecureStore,
        pinStore: any KeyValueStore,
        deviceStore: any KeyValueStore,
        pin: String?
    ) -> SwitchOutcome {
        var ledger = ProfileBook.read(from: ledgerStore)
        guard let target = profile(toAccount: account, in: ledger) else { return .unknown }
        guard followUpTarget(account: account, ledgerStore: ledgerStore) != nil else { return .unchanged }
        return switchOver(
            zu: target.identifier, in: &ledger, keychain: keychain, pinStore: pinStore,
            deviceStore: deviceStore, ledgerStore: ledgerStore, pin: pin)
    }
}

extension ProfileSwitch.SwitchOutcome {

    /// The result if a switch happened.
    ///
    /// **For the checks and for callers that need only the good case.** Whoever needs the
    /// reason for a failure looks at the ``ProfileSwitch/SwitchOutcome`` itself
    /// — that is what it is for.
    public var result: ProfileSwitch.Outcome? {
        if case .switched(let result) = self { return result }
        return nil
    }
}
