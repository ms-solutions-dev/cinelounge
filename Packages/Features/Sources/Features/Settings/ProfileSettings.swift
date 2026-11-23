import Core
import DesignSystem
import PlaylistKit
import ProfileKit
import SwiftUI

/// **Profiles — an area of its own under Device** (AP46, owner decision 1, 2026-09-25).
///
/// **It leads to the existing profile management and builds no second one.** Until 2026-09-25.
/// ``ProfileView`` stood at the top of "Account", above the certificates and the sign-out — three
/// things of which only one concerns people. What is in it (create,
/// merge, PIN escape) belongs to the profile management itself; this area is its
/// entrance.
///
/// **A row with a value in front and not the list on the first level.** The row says
/// what is in it ("3 · Alex"), and gives the area a first target that belongs to it: the
/// focus binding of the profile management is its own, and an area that hands its first target
/// over to a foreign view has none any more as soon as someone rebuilds it. Its card
/// carries **no effect**: the row leads into the management and changes nothing itself
/// (``CardSpec/validity``).
///
/// **The PIN sheet as full screen and not as an overlay** — it must cover what is
/// behind it. `fullScreenCover` does not exist on macOS, and `Features` also compiles
/// there, solely for the test suite; hence the platform conditional.
struct ProfileSettings: View {

    /// Called after every switch — with the new session, or with `nil` if the
    /// profile has no media server (N-1, see ``AccountSwitcher/session(after:load:)``).
    let onSwitched: (ServerCredentials?) -> Void
    /// Leads into the setup to give the active profile an access.
    let onAddAccess: () -> Void

    /// The profiles of this TV. As `@StateObject`, because the list must survive
    /// the switch: ``ProfileView`` writes into it, and a holder rebuilt on every
    /// body would read the store on every focus movement.
    /// **With the device's list catalog**, so a removed profile takes its channel lists
    /// with it (on-device test build 1332, finding 1).
    @StateObject private var profile = ProfileModel(deviceLists: { .onDevice() })

    /// The parental controls in force. **Here and not in ``ProfileView``:** the sheet
    /// lays over the whole area, and every action in it goes through a door.
    @StateObject private var lock = ParentalControlsState()
    @Environment(\.settingsEntryRequest) private var entryRequest

    var body: some View {
        // **The management right away, without a row in front** (AP59 N3, 2026-09-30): there used to be a
        // "Manage profiles" row in front of the management — in the "Profiles" area a second door
        // with the same name. ``ProfileView`` reports the entry itself, and the Menu button
        // leads back into the area list as in every area.
        ProfileView(
            model: profile, lock: lock, onSwitched: onSwitched,
            onAddAccess: onAddAccess, entryRequest: entryRequest
        )
        .preference(
            key: SettingsFirstEntryKey.self,
            value: profile.active?.rawValue ?? profile.profile.first?.identifier.rawValue
        )
        .onAppear { profile.load() }
        .modifier(ShelfCatchUp(lock: lock, profile: profile))
        #if os(tvOS)
            .fullScreenCover(
                isPresented: Binding(
                    get: { lock.openQuestion != nil },
                    set: { if !$0 { lock.cancel() } }
                )
            ) {
                PinDoorSheet(lock: lock)
            }
        #endif
    }

    /// The value on the row — **how many, and who is watching right now.**
    ///
    /// Without an active profile only the number: a name that does not apply would be an assertion.
    nonisolated static func value(count: Int, active: String?) -> String {
        guard let active, !active.isEmpty else { return "\(count)" }
        return "\(count) · \(active)"
    }
}
