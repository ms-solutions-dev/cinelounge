import CloudSync
import Core
import Foundation
import ParentalControls

/// **Deleted iCloud data stays deleted** (on-device test build 1332, finding 10, 2026-09-27).
///
/// **The finding:** the owner had deleted the app's iCloud data in the iOS settings,
/// and the profile was still there. `ProfileZone` recreated the missing zone on the
/// next pass and wrote the mirror up again; the book on the device had never lost the
/// profile anyway. Since `grundstock` locks and reports a vanished zone
/// (``CloudSync/ProfileZone/onRemoval``), the app decides here what happens on the device:
/// **the profile goes with it** — as if it had never been in iCloud.
///
/// **And the app offers it itself** (GDPR, the app is going commercial):
/// ``deleteAllCloudData()`` deletes its own zones and clears this device. The other
/// devices of the same Apple ID then see only `zoneNotFound` — and because they already
/// knew the zones, they lock them and clear likewise, instead of reviving them from their mirror.
extension ProfileCloud {

    /// Deletes **all of this app's own zones** in iCloud — the profile zones and the
    /// household's — and clears this device, as if nothing had ever been in iCloud.
    ///
    /// **All its own, not only the known ones:** a zone that no book on this device
    /// names any more (a profile from another device, a buried zone) also belongs to "my
    /// data". The database's default zone cannot be deleted and stays.
    ///
    /// **Borrowed profiles stay** — their zone belongs to another Apple account; whoever wants to
    /// get rid of them leaves them (``leave(_:)``).
    ///
    /// - Returns: how many zones were deleted.
    @discardableResult
    public func deleteAllCloudData() async throws(CloudError) -> Int {
        guard let service = hub.service else { throw CloudError.noAccount }
        let own = try await service.zones(shared: false).filter(Self.belongsToApp)
        for zone in own { try await hub.delete(zone) }

        let cleaned = ProfileBook.read(from: store).profile.filter { profile in
            zone(forItem: profile.identifier)?.sharedBy == nil
        }
        for profile in cleaned { cleanUpAfterDeletion(profile.identifier) }
        household()?.discard()
        forgetTombstonesOnDevice()
        // No identifier and no name — only what happened.
        Diagnostics.step(
            "Cloud: all own iCloud data deleted — \(own.count) zone(s), \(cleaned.count) profile(s) cleared on the device",
            since: nil, area: "Wolke")
        notify()
        return own.count
    }

    /// Whether a zone of the private database belongs to "my data" — every one except the
    /// default zone, which CloudKit does not let you delete.
    nonisolated static func belongsToApp(_ zone: ZoneID) -> Bool {
        zone.name != "_defaultZone"
    }

    /// A profile's zone has vanished — **the profile on the device goes with it.**
    ///
    /// **Both reasons alike** (``CloudSync/ZoneRemoval``): deleted in the iOS settings
    /// promises "on all devices"; deleted remotely means another device
    /// of the same Apple ID chose "Delete all iCloud data" or cleared an expired
    /// tombstone. In neither case should this device carry the profile back up.
    func zoneRemoved(_ identifier: Profile.Identifier, _ reason: ZoneRemoval) {
        Diagnostics.defect(
            reason == .byUser
                ? "Cloud: profile zone deleted in iOS Settings — profile cleared on the device"
                : "Cloud: profile zone deleted remotely — profile cleared on the device",
            since: nil, area: "Wolke")
        cleanUpAfterDeletion(identifier)
        notify()
    }

    /// The household's zone has vanished — **empty from scratch.** It carries tombstones and
    /// the way out "forgot PIN"; both start without the old notes, and the zone
    /// is recreated on the next write.
    func householdRemoved(_ reason: ZoneRemoval) {
        Diagnostics.defect(
            reason == .byUser
                ? "Cloud: household zone deleted in iOS Settings — started over"
                : "Cloud: household zone deleted remotely — started over",
            since: nil, area: "Wolke")
        household()?.discard()
        forgetTombstonesOnDevice()
    }

    /// The tombstones **on the device** — they belong to the deleted household zone.
    ///
    /// ``find(now:)`` would otherwise write them up into the new zone: identifiers and data of
    /// profiles that no longer exist in iCloud, right after "Delete all my iCloud
    /// data". And they would hold nothing back any more — the zones whose rediscovery they
    /// guarded against are gone.
    func forgetTombstonesOnDevice() {
        for entry in ProfileTombstone.all(from: store) {
            ProfileTombstone.lift(entry.identifier, in: store)
        }
    }

    /// Clears a profile **on the device** whose zone is deleted in iCloud: mirror, book,
    /// state, shelf order and the compartments in the Keychain.
    ///
    /// **The same list as on removal** (`ProfileManagement.cleanUp`), without a tombstone —
    /// the zone is already gone, and a note in the household zone would hold on to what is just
    /// being deleted. The mirror is discarded first (``CloudSync/ProfileZone/discard()``),
    /// so that nothing of the old state stays on disk.
    ///
    /// **If it was the active profile, nobody is in front afterwards** (``ProfileBook/clearActive()``);
    /// if the book is empty, the next launch sets the device up anew — as the first time.
    func cleanUpAfterDeletion(_ identifier: Profile.Identifier) {
        zone(forItem: identifier)?.discard()
        forget(identifier)
        var ledger = ProfileBook.read(from: store)
        if ledger.profile.contains(where: { $0.identifier == identifier }) {
            let wasActive = ledger.active == identifier
            ledger.remove(identifier)
            if wasActive { ledger.clearActive() }
            ledger.write(in: store)
        }
        StillLedger().write(in: store, forItem: identifier.rawValue)
        ShelfOrder().write(in: store, forItem: identifier.rawValue)
        guard let moveBundle else { return }
        ProfilePIN(store: moveBundle, forItem: identifier).forget()
        ProfileStore(moveBundle, forItem: identifier.rawValue).forget()
        PortalMarkerSlot(moveBundle).forget(forItem: identifier)
        AgeLimit.write(nil, in: moveBundle, forItem: identifier.rawValue)
        ChannelApproval().save(to: moveBundle, forItem: identifier.rawValue)
    }
}
