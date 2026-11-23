import Core
import Diagnose
import Foundation
import ParentalControls
import ProfileKit

/// The one-time migration to simple child protection — **one child profile, one PIN**
/// (AP59 N4, owner decision 2026-09-30).
///
/// Until then there were five concepts: child profile, child account, child mode, device lock,
/// device and profile PIN. What remains are the child profile and the one household PIN, which is
/// asked for when leaving the child profile. What goes away must not open a gap
/// during the update:
///
/// - **The device lock becomes the start profile.** A device that was previously in child mode
///   starts in the child profile from now on — out only with a PIN, so just as protected as before.
///   If there is none yet, the migration creates one, **with the accesses of the previously active
///   profile**: In child mode the child saw its sources, only filtered, and an empty
///   child profile would have shown it nothing at all after the update. It does not get its own
///   age limit — the device's limit applies to every profile, the stricter one wins
///   (``ParentalControls/AgeLimit/forItem(profile:device:)``).
/// - **Profile PINs are deleted**, as a tombstone (``ProfileKit/ProfilePIN/remove(now:)``):
///   The newer entry wins in the sync, an older PIN from the cloud does not come back.
/// - **The child account stays where it is set.** Only the switch disappears. The mark on the
///   access keeps working; deleting it would mean putting a child, who counted as a child only through its access,
///   in front of the screen unfiltered after the update.
///
/// **Exactly once per device**, remembered under ``done``, and **before the start choice** in
/// ``ProfileStartup/fetch(_:device:keychain:ledgerStore:startStore:legacyStore:)`` — so that the
/// start profile already applies at the first launch after the update.
public enum ParentalControlsMigration {

    /// Where the migration remembers that it has run.
    public static let done = "kinderschutz.umzug.ap59"

    /// What the migration did — for diagnosis and checking.
    public struct Outcome: Equatable, Sendable {
        /// The profile in which the device will start from now on — only where the device lock was on.
        public var startProfile: Profile.Identifier?
        /// Whether a child profile was created for it.
        public var created: Bool
        /// How many profile PINs were deleted.
        public var deletedPins: Int
    }

    /// Runs the migration if it has not yet run on this device.
    ///
    /// - Parameter startablage: Where start choice, device lock and the marker live — the
    ///   same `UserDefaults` on both devices.
    /// - Returns: `nil` if it had already run.
    @discardableResult
    public static func perform(
        ledger: inout ProfileBook, ledgerStore: any KeyValueStore, keychain: any KeyValueStore,
        startStore: UserDefaults, childName: String, now: Date = Date()
    ) -> Outcome? {
        guard !startStore.bool(forKey: done) else { return nil }
        var result = Outcome(startProfile: nil, created: false, deletedPins: 0)

        if startStore.bool(forKey: ChildMode.key) {
            var kind = ledger.profile.first { $0.kind == .kind }?.identifier
            if kind == nil {
                let taken = Set(ledger.profile.map(\.color))
                let newProfile = Profile(
                    name: childName,
                    color: Profile.ColorTag.allCases.first { !taken.contains($0) } ?? .moss,
                    kind: .kind, credentials: ledger.activeProfile?.credentials ?? [])
                ledger.create(newProfile)
                ledger.write(in: ledgerStore)
                ProfileBackup.setUp(newProfile, keychain: keychain)
                kind = newProfile.identifier
                result.created = true
            }
            if let kind {
                StartChoice(store: startStore).set(kind)
                result.startProfile = kind
            }
            startStore.set(false, forKey: ChildMode.key)
        }

        for profile in ledger.profile {
            let pin = ProfilePIN(store: keychain, forItem: profile.identifier)
            guard pin.isSet else { continue }
            pin.remove(now: now)
            result.deletedPins += 1
        }

        startStore.set(true, forKey: done)
        Diagnose.hint(
            .parentalControls,
            "Parental controls migrated: "
                + (result.startProfile == nil ? "start profile unchanged" : "starts in the child profile")
                + (result.created ? " (newly created)" : "")
                + ", \(result.deletedPins) profile PIN(s) deleted")
        return result
    }
}
