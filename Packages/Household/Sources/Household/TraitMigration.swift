import Core
import Diagnose
import Foundation
import ProfileKit

/// Moves a credential that still sits **in the device** into the profile it belongs to.
///
/// **Why this exists:** Since 2026-09-28 the credential is stored per profile
/// (``Core/DeviceTrait``). Two paths still leave one in the device: every
/// TV from before the move, and the setup, which can pair before a profile
/// exists. As long as it sits there, every older profile would fall back to it
/// (``Core/ProfileStore``) — and would show up at the server as the device's person.
///
/// **Who gets it:**
/// * **A device with an owner** (`setup.deviceOwned`): only the active profile, and only
///   if it wants the CL-Server. The server always answers for this credential as that
///   one person; giving it to two profiles would make both appear as them —
///   exactly the finding.
/// * **A shared device**: every profile that wants the CL-Server. There the profile
///   header tells the people apart, and each profile carries its own.
///
/// Afterwards the device slot is empty. Whoever got nothing pairs themselves or requests access.
public enum TraitMigration {

    /// - Returns: how many profiles received the credential; `nil` if there was nothing to move.
    @discardableResult
    public static func migrate(device: any KeyValueStore, ledgerStore: any KeyValueStore) -> Int? {
        guard let trait = try? device.value(for: DeviceTrait.storageKey), !trait.isEmpty
        else { return nil }
        let ledger = ProfileBook.read(from: ledgerStore)
        // Without a profile it stays where it is: the setup creates the first one right away.
        guard let active = ledger.activeProfile else { return nil }

        let own = (try? device.value(for: DeviceTrait.ownKey)) == "1"
        let receiver =
            own
            ? (active.wantsPortals ? [active] : [])
            : ledger.profile.filter(\.wantsPortals)
        for profile in receiver {
            let bucket = ProfileStore(device, forItem: profile.identifier.rawValue)
            guard
                (try? device.value(
                    for: ProfileStore.bucket(DeviceTrait.storageKey, forItem: profile.identifier.rawValue)))
                    == nil
            else { continue }
            DeviceTrait.save(trait, to: bucket)
            DeviceTrait.saveOwn(own, to: bucket)
            DeviceTrait.saveProfile(own ? nil : profile.portalPerson, to: bucket)
        }
        for key in DeviceTrait.allKeys {
            try? device.remove(key)
        }
        Diagnose.step(
            .login,
            "CL-Server: trait moved from the device into \(receiver.count) profile(s) (\(own ? "device with person" : "shared device"))"
        )
        return receiver.count
    }
}
