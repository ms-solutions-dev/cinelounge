import Core
import Foundation
import ParentalControls
import PlaylistKit
import ProfileKit

/// The clean cut after the handover into the profile (AP48, product decision 2 of
/// 2026-09-25): **Once the handover stands, the legacy keys are gone immediately** — no rollback,
/// no grace period. If it fails, everything stays.
///
/// **What is cleared, in full** — each key only if its content has demonstrably
/// arrived (the evidence stands at the two steps):
/// - `vod.memory.v1` (Keychain) — movies in progress, now in the ``Core/StillLedger``;
/// - `playlists.favorites.v1` (Keychain) — channel favorites, likewise;
/// - `live.lastChannel` and `live.lastChannel.<XtreamList>` (Keychain) — last watched
///   channel, for the lists the device keeps today;
/// - `accounts.children` (Keychain) — the TV's child markers before AP40;
/// - `accounts.children` in `UserDefaults` — the phone's child markers before AP40.
///
/// **What expressly stays**, although the handover reads it — it is not legacy,
/// but the current store:
/// - `server.accounts` and `server.credentials` — the media servers' access tokens. The
///   profile carries only server and user, **no token**; without these entries every
///   switch would be a new sign-in.
/// - `setup.deviceToken`, `setup.deviceProfile`, `setup.deviceOwned` — the sign-in at the
///   CineLounge server; ``ProfileKit/ProfileSwitch`` writes the header at every switch.
/// - `accounts.children` in the file store — the current child-marker list, which
///   ``ParentalControlsState`` keeps reading (child profile **or** child account).
/// - the device base of the still-frame ledger and the shelf order — it applies as long as no profile
///   is chosen, and is the evidence on which the clearing depends.
///
/// **Since AP58 R2 for both programs** (finding P5). Until then the phone cleared only the
/// child lists (`SetupState.clearLegacyCatalog`); it never had the state dictionaries,
/// and every clearing step demands its evidence — what the phone does not have therefore stays
/// untouched, and a dictionary that is there after all falls only with evidence. Moved from `Features`
/// to here so that ``ProfileStartup`` calls it on both devices.
///
/// **Why here and not in the ``ProfileKit`` package:** The state dictionaries are known to `PlaylistKit`,
/// and ``ProfileKit`` does not depend on it.
public enum LegacyData {

    /// Clears if ``ProfileKit/ProfileBook/takeoverPending(in:)`` allows it.
    ///
    /// - Parameters:
    ///   - buchablage: the file store with profile ledger, still-frame ledger and child markers.
    ///   - schluesselbund: the Keychain with the old dictionaries.
    ///   - standard: the phone's old `UserDefaults` store; `nil` leaves it alone.
    ///   - listen: the list IDs whose last watched channel is cleared.
    /// - Returns: the cleared keys — empty if the handover does not stand.
    @discardableResult
    public static func cleanUp(
        ledgerStore: any KeyValueStore, keychain: any KeyValueStore,
        standard: UserDefaults?, listen: [String]
    ) -> [String] {
        guard ProfileBook.takeoverPending(in: ledgerStore) else { return [] }
        return ChildAccountList(store: ledgerStore).clearOldLists(
            keychain: keychain, store: standard)
            + StateTransfer.clearLegacyCatalog(
                listen: listen, from: keychain, in: ledgerStore)
    }
}
