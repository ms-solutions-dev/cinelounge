import Core
import Foundation
import ParentalControls

extension Profile.Kind {

    /// The same question as parental controls ask it.
    ///
    /// **Two types and one translation — instead of one type for both.** ``AccountKind``
    /// belongs in the package that carries the rule; replacing it there with ``ProfileKit/Kind``
    /// would make `ParentalControls` depend on `ProfileKit` and thereby on
    /// color marks and accesses that no lock decides. The translation sits
    /// **in one place** for that, and a third case would break here and not at forty
    /// call sites.
    public var accountKind: AccountKind {
        switch self {
        case .adult: .adult
        case .kind: .kind
        }
    }
}

extension ProtectionRule {

    /// The rule for **this person** on **this device.**
    ///
    /// **Up to here the question was posed wrongly** (AP41, 2026-09-21). It read "is
    /// this device locked?" plus "is the open account a child account?" — and the
    /// limit that came out of it lay under **one** key per device. A
    /// parent who set their own limit thereby changed the child's.
    ///
    /// **Now the limit, "Block what is not understood" and the mapping board hang off the
    /// profile** (``ParentalControls/ProfileSlot``). The device base stays alongside
    /// and is the named exception: the TV in a child's room that is locked for everyone,
    /// no matter who signs in. **The stricter of the two applies** —
    /// the same sentence as since 2026-09-06, only that "both" now means person and device
    /// instead of account and device.
    ///
    /// **Without a profile the device base applies alone.** That is the state before the first
    /// setup; reading it as "no lock" would mean opening a device in a child's room
    /// between two sign-ins.
    ///
    /// - Parameters:
    ///   - profil: Who is sitting in front. `nil` means: nobody yet.
    ///   - geraetGesperrt: The ``ParentalControls/ChildMode`` of this device.
    ///   - schluesselbund: Where limit, lock and board lie — **in the Keychain and
    ///     not in the file.** That is the exception to "structure → file" from AP40,
    ///     and its reason applies here unchanged: what holds together with the PIN must survive
    ///     together with it. If the limit lay in a file, after a
    ///     reinstall there would be "PIN set, no limit" — and the filter would let everything through
    ///     without reporting it (AP22).
    ///
    /// **Since AP58 R1 via ``ParentalControls/RuleBuilder``** — the same computation as in both
    /// apps, including the device base for limit and mappings. Until then this
    /// version read the limit only on the profile.
    public static func forItem(
        _ profile: Profile?,
        deviceLocked: Bool,
        keychain: any KeyValueStore
    ) -> ProtectionRule {
        RuleBuilder.rule(
            profile: profile?.identifier.rawValue, profileIsChild: profile?.kind == .kind,
            accountIsChild: false, deviceLocked: deviceLocked, from: keychain)
    }
}

/// How a device's parental controls become those of its profiles.
public enum ProfileBackup {

    /// Explicitly gives a **freshly created** child profile "Block what is not understood".
    ///
    /// **Why this line is needed since 2026-09-25 (strand G):** until then the
    /// rule read a profile without an entry as "yes" (``ParentalControls/UnrecognizedLock/read(from:forItem:)``),
    /// and every new child profile was thereby protected — regardless of what the device said. Since
    /// an unset profile stays silent (``ParentalControls/UnrecognizedLock/applicable(from:forItem:)``),
    /// on a device set to "off" the device switch alone would decide, and a new child
    /// would see items that nobody can classify. **It keeps the previous protection by
    /// writing it at creation**, instead of arising as a default on reading.
    ///
    /// **Only at creation, only for children, only where nothing stands:**
    /// * An adult gets nothing — exactly there the old default acted wrongly.
    /// * An existing child profile without an entry stays without: there the
    ///   device decides, and that is the owner decision of 2026-09-25.
    /// * The kind cannot be changed afterwards (`ProfileModel.update`), so
    ///   there is no second moment at which a profile becomes a child.
    ///
    /// - Returns: Whether anything was written.
    @discardableResult
    public static func setUp(_ newProfile: Profile, keychain: any KeyValueStore) -> Bool {
        let identifier = newProfile.identifier.rawValue
        guard newProfile.kind == .kind,
            UnrecognizedLock.own(from: keychain, forItem: identifier) == nil
        else { return false }
        UnrecognizedLock.write(true, in: keychain, forItem: identifier)
        return true
    }

    /// Brings the **device's** limit into the child profiles — **once.**
    ///
    /// **It goes to the children and not to everyone**, and that is the same decision
    /// as with the channel lists in ``ProfileBook/adopt(jellyfin:children:channelLists:wantsPortals:portalPerson:signedIn:fallbackName:in:)``:
    /// a device limit applied to everyone who sat in front. Giving it to every profile would mean
    /// slipping an adult a limit that was never meant for them; giving it to nobody would mean
    /// leaving a child profile open after the update.
    /// **The second is the more expensive mistake**, and the children are the safe way here.
    ///
    /// **The device base stays.** It is not deleted: whoever set it
    /// meant "this device", and ``ProtectionRule/forItem(_:deviceLocked:keychain:)``
    /// continues to take the stricter of the two.
    ///
    /// - Returns: How many profiles received a limit.
    @discardableResult
    public static func adopt(
        _ ledger: ProfileBook, keychain: any KeyValueStore
    ) -> Int {
        guard let deviceLimit = AgeLimit.read(from: keychain) else { return 0 }
        let lock = UnrecognizedLock.read(from: keychain)
        let board = UnrecognizedRatings.load(from: keychain)

        var counted = 0
        for person in ledger.profile where person.kind == .kind {
            let identifier = person.identifier.rawValue
            // **Only where nothing stands yet.** A second takeover must not replace a limit
            // set in the meantime with the device's old one — that would be a
            // loosening that nobody sees.
            guard AgeLimit.read(from: keychain, forItem: identifier) == nil else { continue }
            AgeLimit.write(deviceLimit, in: keychain, forItem: identifier)
            UnrecognizedLock.write(lock, in: keychain, forItem: identifier)
            board.save(to: keychain, forItem: identifier)
            counted += 1
        }
        return counted
    }
}
