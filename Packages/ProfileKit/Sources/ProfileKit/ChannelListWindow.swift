import Core
import Foundation

extension ProfileBook {

    /// Which of the device's channel lists the person currently sitting in front sees — `nil` means:
    /// all (no profile yet). The window for ``PlaylistKit/PlaylistStore/viewport``,
    /// the same computation on both devices (decision 25).
    ///
    /// **The finding from the on-device test (build 1332, 2026-09-27, findings 1 and 3):** A list lies
    /// on the device, whose it is is in the profile (AP41) — but filtering only happened in the
    /// overview. A new profile saw the deleted one's access under "IPTV access", and
    /// Live played it while the overview said "nothing".
    ///
    /// - Parameter vorhanden: the IDs of the lists that are on the device.
    public func channelListWindow(available: [String]) -> Set<String>? {
        activeProfile?.channelListWindow(available: available)
    }
}

extension Profile {

    /// The IDs of the channel lists that belong to this person — `nil` means: all.
    ///
    /// **A safety valve for orphaned references:** If the profile points only to lists of which none
    /// is on the device anymore, the whole catalog applies. That is the provider move
    /// (``PlaylistKit/ListMigration``): If the domain changes, the list gets a new
    /// key, and the profile knows only the old one. Without the valve Live would vanish for
    /// someone who deleted nothing; a new profile, on the other hand, has no reference at all
    /// and stays empty.
    ///
    /// - Parameter vorhanden: the IDs of the lists that are on the device.
    public func channelListWindow(available: [String]) -> Set<String>? {
        let own = Set(channelLists.compactMap(\.channelListID))
        guard !own.isEmpty, own.isDisjoint(with: available), !available.isEmpty else {
            return own
        }
        return nil
    }
}

extension ProfileBook {

    /// Who gets IPTV lists that belong to **no** profile.
    ///
    /// **The finding (phone, 2026-09-28: "Xtream VOD is not shown"):** Since a profile
    /// sees only its own lists (``ProfileKit/channelListWindow(available:)``),
    /// a list from the time before profiles vanished entirely — no profile pointed to
    /// it, so none saw it. The VOD catalog went with it.
    ///
    /// **The active profile, unless it is freshly created** — then the first one that already
    /// existed before. A new profile starts empty (owner, 2026-09-28) and does not inherit
    /// an orphaned list either.
    ///
    /// - Returns: whether the book changed.
    public mutating func adoptOrphaned(
        available: [String], isFresh: (Profile.Identifier) -> Bool
    ) -> Bool {
        let assigned = Set(profile.flatMap { $0.channelLists.compactMap(\.channelListID) })
        let orphaned = available.filter { !assigned.contains($0) }
        guard !orphaned.isEmpty else { return false }
        let target =
            activeProfile.flatMap { isFresh($0.identifier) ? nil : $0.identifier }
            ?? profile.first(where: { !isFresh($0.identifier) })?.identifier
        guard let target else { return false }
        update(target) { profile in
            for identifier in orphaned { profile.create(.channelList(identifier: identifier)) }
        }
        return true
    }
}
