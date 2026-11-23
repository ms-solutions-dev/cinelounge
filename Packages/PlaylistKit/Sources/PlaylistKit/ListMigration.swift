import Core
import Foundation

/// Brings a device's list IDs onto the computed key.
///
/// **The reason is given at ``Core/ListKey``**: Until 2026-09-21 every list
/// got a random number when it was added. It sits in the access, in the last-watched channel and
/// at the front of every title ID — all under an ID that does not
/// occur on any second device.
///
/// **One pass at startup and not a special path per store.** The entry moves via
/// ``PlaylistStore/rekey(_:after:)``, the progress via
/// ``Core/StillLedger/rekey(from:after:)``; both know best how their
/// keys are built. What stands here is the order and the question of **which**
/// list moves at all.
///
/// **Every book, not just that of the person currently watching.** A list key belongs
/// to the device and not to the viewer; whoever re-keyed only the active book would take
/// everyone else's progress away without anyone having deleted anything — and that would only be noticed
/// at the next profile switch.
///
/// **The same procedure carries the provider move.** Whoever's provider changes domain
/// gets a different computed key — and this pass moves their progress along,
/// instead of leaving it unfindable. That is why it runs at **every** start and not
/// once behind a marker.
public enum ListMigration {

    /// Re-keys every list whose ID is not that of its kind.
    ///
    /// **The progress moves before the entry.** If writing the entry fails, the
    /// progress already sits under the new key and the entry under the old one — then
    /// the last-watched channel is missing once. The other way round, the entry would be new and the
    /// progress old, and the next pass would find nothing left to move: The loss would be
    /// permanent instead of one-off.
    ///
    /// - Parameters:
    ///   - bestand: The lists of this device.
    ///   - buch: Where the progress books live.
    ///   - profile: The profile IDs. The **device base** is always included and is
    ///     not in this list — before first setup it is the only book.
    /// - Returns: How many lists were moved.
    @discardableResult
    @MainActor
    public static func perform(
        in catalog: PlaylistStore, ledger store: any KeyValueStore, profile: [String] = []
    ) -> Int {
        var counted = 0
        // Over a copy: ``PlaylistStore/rekey(_:after:)`` changes the catalog
        // that would otherwise be iterated over at that moment.
        for list in catalog.playlists {
            let fresh = list.key
            guard list.id != fresh else { continue }
            // **Ask first whether the slot is free.** Otherwise the progress would move to a
            // key that another list already occupies — and would lie on top of its entry.
            guard !catalog.playlists.contains(where: { $0.id == fresh }) else { continue }

            for bucket in [nil] + profile.map(Optional.init) {
                var ledger = StillLedger.read(from: store, forItem: bucket)
                guard ledger.rekey(from: list.id, after: fresh) else { continue }
                ledger.write(in: store, forItem: bucket)
            }
            if catalog.rekey(list.id, after: fresh) { counted += 1 }
        }
        return counted
    }
}
