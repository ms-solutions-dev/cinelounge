import Core
import Flows
import Foundation
import ProfileKit

/// The profile PIN on the phone — **set, change, remove and "forgot PIN"**
/// (tvOS roadmap AP52, product decision 12 of 2026-09-25).
///
/// **The rules do not live here but in ``ProfileKit/ProfilePINMaintenance``** — the same for
/// TV and phone: changing and removing require the old PIN, every change goes
/// immediately into the mirror of the profile zone, "forgot PIN" clears household-wide. This type
/// records only **with which Keychain and which cloud** the phone calls them.
///
/// **The Keychain is the cloud's move bundle** (``ProfileKit/ProfileCloud/moveBundle``).
/// The reconciliation puts every PIN that comes from another device there, and the latch
/// reads there (``ProfileKit/ProfileSwitch/lock(account:ledgerStore:pinStore:)``). If the phone
/// put its PIN in another place, it would check against one and write to the other.
///
/// **The door in front is ``door``** and sits at the call site (``ShellModel``), as on the
/// TV: the old PIN proves who owns the profile — not that an adult
/// is sitting in front of it.
@MainActor
struct ProfilePinManagement {

    /// The parental-controls door before every touch of a profile PIN — the same identifier
    /// as on the TV (``ParentalControls/LockedDoors``).
    ///
    /// **Also before setting, not only before removing:** a child who assigns a PIN of their own
    /// locks their parents out of the profile whose limit they are responsible for.
    /// The door asks only when parental controls apply.
    nonisolated static let door = "profilpin"

    /// Where the PIN lives on the device.
    let keychain: any KeyValueStore

    /// `nil` means: without an Apple account — the PIN then applies only here, until one exists, and
    /// "forgot PIN" does not exist.
    let cloud: ProfileCloud?

    /// What this device is called in a "forgot PIN" request.
    let device: String

    /// The management as the program needs it: **the connected cloud and its
    /// move bundle**, without a cloud the device's Keychain.
    static func live() -> ProfilePinManagement {
        let cloud = ProfileCloud.attached
        return ProfilePinManagement(
            keychain: cloud?.moveBundle ?? SecureStore(), cloud: cloud,
            device: DeviceName.thisDevice)
    }

    // MARK: - Lesen

    /// Whether this profile requires a PIN — ``ProfileKit/ProfilePIN/isSet``.
    func isSet(_ identifier: Profile.Identifier) -> Bool {
        ProfilePIN(store: keychain, forItem: identifier).isSet
    }

    func matches(_ digits: String, forItem identifier: Profile.Identifier) -> Bool {
        ProfilePIN(store: keychain, forItem: identifier).matches(digits)
    }

    // MARK: - Der Ablauf

    /// The shared flow for this sheet (``Flows/ProfilePinFlow``) — with this phone's
    /// Keychain and cloud.
    ///
    /// **Setting, removing and "forgot PIN" have lived there since AP58 R2** and no longer here:
    /// until then this type ran a resolution path of its own (`redeem(forItem:state:now:)`) alongside the
    /// TV's.
    func flow(forItem state: ProfilePinState) -> ProfilePinFlow {
        let kind: ProfilePinFlow.Situation =
            switch state {
            case .maintain: .maintain
            case .lock: .lock
            }
        return ProfilePinFlow(
            profile: state.profile, state: kind, keychain: keychain, cloud: cloud,
            device: device)
    }
}
