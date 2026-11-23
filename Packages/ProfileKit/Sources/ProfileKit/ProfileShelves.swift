import Core
import Foundation

/// How a device's shelf order becomes that of its profiles.
///
/// **The last of the four pointers from E77 to E80** (AP41, 2026-09-21): the arrangement of the
/// Home screen lay as **one** file per device and applied to everyone who sat in front. Whoever
/// reordered their rows reordered everyone else's.
///
/// **That it was only one store any more is the groundwork from AP40.** Before, there were
/// six Keychain lines here and five over there, each with its own separator; making
/// those "per profile" would have meant multiplying eleven keys. Now it is one
/// more file name.
public enum ProfileShelves {

    /// Gives every profile the device's arrangement — **once.**
    ///
    /// **Everyone gets the same here, unlike with the channel lists.** There,
    /// passing on was a hole (the child saw the adults' channels); a shelf order
    /// takes nothing from anyone and is what everyone already had. **Not** taking it over
    /// would mean putting a Home screen sorted by someone else in front of everyone at the first launch after the update.
    ///
    /// **Once means: once per device, with a marker** (check finding A-S4, 2026-09-27). Until
    /// then it was "only where nothing stands yet" — and a profile order that returns to the
    /// default *no longer stands* (``Core/ShelfOrder/write(in:forItem:)`` deletes the
    /// empty file). Whoever showed a hidden shelf again had it taken away again on the next
    /// launch by the device order, and every profile created later,
    /// including a child's, inherited the old device order. Now ``distributedKey`` is set
    /// after the first distribution, and after that nothing happens here.
    ///
    /// **The device base stays.** It is the state before the first setup —
    /// and as long as ``ProfileBook`` is empty, the app keeps reading it. Without profiles
    /// nothing is marked either: the distribution is then still pending.
    ///
    /// - Returns: How many profiles received an arrangement.
    @discardableResult
    public static func adopt(_ ledger: ProfileBook, store: any KeyValueStore) -> Int {
        guard !ledger.profile.isEmpty, (try? store.value(for: distributedKey)) == nil
        else { return 0 }
        let deviceOrder = ShelfOrder.read(from: store)
        var counted = 0
        if deviceOrder != ShelfOrder() {
            for person in ledger.profile {
                let identifier = person.identifier.rawValue
                // **Only where nothing stands yet** — an already set-up profile order
                // (for example from the cloud) is not overwritten.
                guard ShelfOrder.read(from: store, forItem: identifier) == ShelfOrder() else {
                    continue
                }
                deviceOrder.write(in: store, forItem: identifier)
                counted += 1
            }
        }
        try? store.set("1", for: distributedKey)
        return counted
    }

    /// The marker "the device order is distributed".
    static let distributedKey = ShelfOrder.key + ".verteilt"
}
