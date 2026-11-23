import Core
import DesignSystem
import PlaylistKit
import ProfileKit
import SwiftUI

/// **Other devices** — everything that connects this device with a second one (AP59 N7, 2026-09-30).
///
/// Until then the three paths stood as buttons in the profile management, between "Add
/// profile" and "Merge": giving or fetching a profile via iCloud, the handoff from the
/// phone on the home network, the iPhone as a remote. None of them is a property of a
/// person; they belong to the device — and whoever looked for "Remote" did not find it under
/// "Profiles". **Every path keeps its door** (parental controls), the same as before.
struct OtherDevicesSettings: View {

    /// The profiles of this TV — needed for "Devices & Sharing", which always passes on the
    /// active profile. The same construction as in ``ProfileSettings``.
    @StateObject private var profile = ProfileModel(deviceLists: { .onDevice() })
    @StateObject private var lock = ParentalControlsState()

    @FocusState private var focus: String?
    @Environment(\.settingsEntryRequest) private var entryRequest

    @State private var pairingProfile: Profile?
    @State private var isReceiving = false
    @State private var isPairingRemote = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // **Pairing stands behind the same door as the account switch.** Whoever hands over a
            // profile hands over their state, their access and their parental controls.
            if ProfileCloud.attached != nil, let active = profile.activeProfile {
                DisclosureRow(
                    title: "pairing.title", value: active.name,
                    card: CardSpec(
                        header: "pairing.title", statementWording: active.name,
                        explanation: "settings.devices.pairingHint"),
                    identifier: "koppeln", focus: $focus
                ) {
                    guard lock.isAllowed(finished: "wolke") else { return }
                    pairingProfile = active
                }
            }
            // **The wire for a device without iCloud** (AP44) — it receives and replaces
            // nothing.
            DisclosureRow(
                title: "profiles.fromPhone",
                card: CardSpec(header: "profiles.fromPhone", explanation: "settings.devices.handoverHint"),
                identifier: "vomHandy", focus: $focus
            ) {
                guard lock.isAllowed(finished: "uebergabeEmpfang") else { return }
                isReceiving = true
            }
            DisclosureRow(
                title: "remote.pair.button",
                card: CardSpec(header: "remote.pair.button", explanation: "settings.devices.remoteHint"),
                identifier: "fernkopplung", focus: $focus
            ) {
                guard lock.isAllowed(finished: "uebergabeEmpfang") else { return }
                isPairingRemote = true
            }
        }
        .frame(maxWidth: 900, alignment: .leading)
        .preference(key: SettingsFirstEntryKey.self, value: firstIdentifier)
        .onChange(of: entryRequest) { _, _ in focus = firstIdentifier }
        .onAppear { profile.load() }
        #if os(tvOS)
            .fullScreenCover(isPresented: $isReceiving) {
                HandoffReceiveView(
                    cancel: { isReceiving = false },
                    done: {
                        isReceiving = false
                        profile.load()
                    })
            }
            .fullScreenCover(isPresented: $isPairingRemote) {
                RemotePairingView { isPairingRemote = false }
            }
            .fullScreenCover(item: $pairingProfile) { profileName in
                if let cloud = ProfileCloud.attached {
                    CloudSheet(profile: profileName, cloud: cloud) {
                        pairingProfile = nil
                        profile.load()
                    }
                }
            }
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

    /// The topmost entry — "Devices & Sharing" where that exists, otherwise the handoff.
    private var firstIdentifier: String {
        ProfileCloud.attached != nil && profile.activeProfile != nil ? "koppeln" : "vomHandy"
    }
}
