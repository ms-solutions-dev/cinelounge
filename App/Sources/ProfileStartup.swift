import Core
import Features
import Flows
import Foundation
import PlaylistKit
import ProfileKit

/// What **this TV** contributes to the profile startup — the sequence itself has lived since
/// AP58 R2 in the shared ``Flows/ProfileStartup`` (finding P5).
///
/// **Until then the whole sequence stood here**, in the app target and thus untested, and the
/// phone had a second one. What stays here is only what only the program knows: which stores it
/// keeps (the TV's list store, the portal preference in `AccountState`, the
/// remembered loan profile) and the language catalog for the fallback name.
extension ProfileStartup {

    /// The name for a device on which there is no media server user.
    ///
    /// **A language key and no text in the model.** A device that only knows channel lists
    /// is set up and needs a profile; what it is called is decided by the
    /// catalog and not by ``ProfileBook``.
    static let fallbackName = "profile.default.name"

    /// The startup on the TV — with ``Flows/ProfileStartup/Steps/tv``.
    @MainActor
    static func fetch(
        keychain: SecureStore = SecureStore(),
        lists: PlaylistStore = .onDevice(),
        store: any KeyValueStore = FileStore()
    ) {
        fetch(
            .tv,
            device: DeviceState(
                channelLists: lists.playlists.map(\.id),
                // **The device state is still the source here**, and that is right: It says
                // what this device knew up to today. From the next start on, the ledger says it.
                wantsPortals: AccountState.load(from: keychain).hasPortals,
                portalPerson: DeviceTrait.profile(from: keychain),
                fallbackName: AppLanguageSetting.text(String.LocalizationValue(fallbackName))),
            keychain: keychain, ledgerStore: store, startStore: .standard,
            legacyStore: .standard)
    }

    /// Sets ``Core/ProfilePointer`` to the profile that last watched — **before**
    /// everything that reads a state (see `CineLoungeApp`).
    @MainActor
    static func pointToActive() {
        pointToActive(in: FileStore())
    }
}
