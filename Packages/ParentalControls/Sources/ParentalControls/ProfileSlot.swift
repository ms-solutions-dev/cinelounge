import Core
import Foundation

/// A store key that belongs to **one person** instead of the device.
///
/// **The rework of AP41, 2026-09-21.** Until here the age limit, "lock the not understood" and
/// the mapping board lay under one key per device: `childLock.ageLimit` applied to **everyone**
/// sitting in front of it. That was right as long as the app knew only one device state; as soon
/// as a profile has a kind (``ProfileKit/Kind``), it is wrong — then a parent sets their own limit
/// and thereby changes the child's.
///
/// **The device baseline stays, and it is the named exception.** `profile == nil` still means
/// "this device": the TV in the children's room that is locked for everyone, no matter who signs
/// in. ``ProtectionRule`` takes the **stricter** of the two — the device baseline can only
/// tighten, never loosen.
///
/// **The dot as separator, and the identifier goes last.** In front it would stand before
/// `childLock.` and turn a readable namespace into a random sequence; at the back
/// `childLock.ageLimit.…` stays sortable and recognizable in the Keychain. A profile identifier
/// is a `UUID` text and carries no dot itself.
public enum ProfileSlot {

    /// The key for this profile — or the device's, if none is named.
    ///
    /// **The calculation lives in ``Core/ProfileStore/bucket(_:forItem:)``** (since 2026-09-24) and here
    /// there is only the call: `Core` lies below this package and cannot see `ProfileSlot`, the
    /// other way round it works. Two copies of the same rule would drift apart at the next rework —
    /// and limit and audio preference would stand under different names.
    public static func key(_ basis: String, forItem profile: String?) -> String {
        ProfileStore.bucket(basis, forItem: profile)
    }
}
