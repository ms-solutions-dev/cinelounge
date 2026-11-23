import Core
import Foundation

/// Setting, changing, removing and "Forgot PIN" of a profile PIN — **on the device and in the
/// cloud in one step** (AP52, 2026-09-25).
///
/// **Here and not in the view**, because TV and phone need the same rules:
/// changing and removing require the old PIN, "Forgot PIN" clears household-wide, and
/// every change goes immediately into the profile zone's mirror. If that sat in two views,
/// it would drift apart — exactly what happened to the keypad in AP45.
///
/// **The parental controls door does not sit here**, but at the call site
/// (``ParentalControls/LockedDoors`` "profilpin"): whether the device PIN is asked depends
/// on the UI's rule, which this package does not hold. The old profile PIN proves
/// who the profile belongs to; the door proves that an adult is sitting in front.
@MainActor
public enum ProfilePINMaintenance {

    /// How an operation turned out.
    public enum SwitchOutcome: Equatable, Sendable {
        case isSet
        case removed
        /// There is a PIN, and the old one is missing or wrong. **Nothing is changed.**
        case oldWrong
        /// The new one is not a four-digit sequence of digits. **Nothing is changed.**
        case invalid
    }

    /// Sets a PIN — **the first without, every further one with the old one.**
    ///
    /// A pending "Forgot PIN" request of this profile lapses in the process: whoever
    /// knows the old one or sets a first one does not need it, and if it stayed, the new
    /// PIN would fall with its deadline.
    ///
    /// - Parameters:
    ///   - alte: `nil` if there is none yet. If one is set, it must match.
    ///   - wolke: `nil` without an Apple account — then the PIN holds only here until one exists;
    ///     the first pass takes it up along.
    public static func set(
        _ fresh: String, old: String?, forItem identifier: Profile.Identifier,
        keychain: any KeyValueStore, cloud: ProfileCloud?, now: Date
    ) -> SwitchOutcome {
        let pin = ProfilePIN(store: keychain, forItem: identifier)
        if pin.isSet {
            guard let old, pin.matches(old) else { return .oldWrong }
        }
        guard ProfilePIN.isValid(fresh), pin.set(fresh, now: now) != nil else {
            return .invalid
        }
        handOff(identifier, from: keychain, cloud: cloud)
        return .isSet
    }

    /// Removes the PIN — **with the old one, and as a tombstone**, so that it does not
    /// come back on any device that still has the old record in its mirror.
    public static func remove(
        old: String, forItem identifier: Profile.Identifier,
        keychain: any KeyValueStore, cloud: ProfileCloud?, now: Date
    ) -> SwitchOutcome {
        let pin = ProfilePIN(store: keychain, forItem: identifier)
        guard pin.isSet else { return .removed }
        guard pin.matches(old) else { return .oldWrong }
        pin.remove(now: now)
        handOff(identifier, from: keychain, cloud: cloud)
        return .removed
    }

    /// "Forgot PIN" is due — **the PIN falls household-wide**, not only here.
    ///
    /// **Without the old PIN, and that is the point:** the way out has supplied the proof —
    /// 24 hours' deadline by the server's clock or confirmation on a second device
    /// (``PINFallback``). Whether it is due is decided by the call site that shows it.
    ///
    /// **A tombstone in the cloud**, not only deleting on the device: otherwise the PIN would fall
    /// here, and on the next pass the sync would fetch it back from the zone — and on
    /// every other device it would stay standing anyway.
    public static func redeem(
        forItem identifier: Profile.Identifier, keychain: any KeyValueStore, cloud: ProfileCloud?,
        now: Date
    ) {
        ProfilePIN(store: keychain, forItem: identifier).remove(now: now)
        handOff(identifier, from: keychain, cloud: cloud)
    }

    private static func handOff(
        _ identifier: Profile.Identifier, from keychain: any KeyValueStore, cloud: ProfileCloud?
    ) {
        guard let cloud else { return }
        cloud.passOnPin(identifier, from: keychain)
        cloud.closePinRecovery(forItem: .profile(identifier))
    }
}
