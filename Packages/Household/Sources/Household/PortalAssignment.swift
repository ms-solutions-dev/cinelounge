import Core
import Foundation
import ProfileKit

/// A person on the CineLounge server belongs to a **profile** — not to the device (AP45, "One
/// Switcher"; shared since AP58 R7, finding E4).
///
/// **The finding:** The TV wrote the chosen person into the active profile
/// (``ProfileKit/Access/portals(person:)``), while the phone signed in at the server with person and PIN
/// and left the profile empty. But ``TokenReconciliation`` asks the profile
/// (`portalPerson`), and a profile that travels to the TV via iCloud did not bring
/// its person along.
///
/// **Two paths, one store:** A TV **borrows** the person (``borrow(_:ledgerStore:keychain:)``,
/// header on the device, the device counts as shared); a phone signs in as the person
/// (``DeviceSignIn/notify(on:pin:basis:session:keychain:deviceName:)``) and
/// afterwards only records it in the profile (``assign(_:ledgerStore:)``).
public enum PortalAssignment {

    /// Records the person in the active profile — and sends the change to the cloud.
    ///
    /// - Returns: whether it is in the profile afterwards — read back, not remembered.
    @discardableResult
    public static func assign(_ person: String, ledgerStore: any KeyValueStore) -> Bool {
        var ledger = ProfileBook.read(from: ledgerStore)
        guard let active = ledger.active else { return false }
        ledger.update(active) { $0.create(.portals(person: person)) }
        ledger.write(in: ledgerStore)
        SyncCall.call(.byHand)
        return ProfileBook.read(from: ledgerStore).activeProfile?.portalPerson == person
    }

    /// After redeeming a pairing code: **the active profile wants the CL-Server from now
    /// on** — with the person the code brought along, or without, in which case one chooses
    /// them afterwards.
    ///
    /// **The finding (test Apple TV, 2026-09-28):** The code was redeemed, the server
    /// knew the device including the person, and still nothing happened. Redeeming only put
    /// the credential into the Keychain; since the sidebar and source ask
    /// ``ProfileKit/Profil/wantsPortals`` (so that a new profile inherits nothing), a
    /// profile without this access stayed empty after pairing. In the simulator it went unnoticed
    /// because its profile already carried the person from earlier.
    ///
    /// **A person already chosen stays** if the code brings none: re-pairing a device
    /// must not erase the choice.
    @discardableResult
    public static func afterRedemption(person: String?, ledgerStore: any KeyValueStore) -> Bool {
        if let person { return assign(person, ledgerStore: ledgerStore) }
        var ledger = ProfileBook.read(from: ledgerStore)
        guard let active = ledger.active else { return false }
        if ledger.activeProfile?.wantsPortals != true {
            ledger.update(active) { $0.create(.portals(person: nil)) }
            ledger.write(in: ledgerStore)
            SyncCall.call(.byHand)
        }
        return ProfileBook.read(from: ledgerStore).activeProfile?.wantsPortals == true
    }

    /// The TV's path: assign the person to the active profile **and carry it on the device as a
    /// borrowed header.** The device then counts as shared (`setup.deviceOwned` drops):
    /// whoever has to choose is sitting in front of a device that belongs to no one person.
    @discardableResult
    public static func borrow(
        _ person: String, ledgerStore: any KeyValueStore, keychain: any KeyValueStore
    ) -> Bool {
        guard ProfileBook.read(from: ledgerStore).active != nil else { return false }
        DeviceTrait.saveProfile(person, to: keychain)
        DeviceTrait.saveOwn(false, to: keychain)
        return assign(person, ledgerStore: ledgerStore)
    }
}
