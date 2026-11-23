import CloudSync
import Core
import Flows
import Foundation
import ParentalControls
import ProfileKit
import SourceProbe
import Testing

@testable import FeaturesPhone

/// **Forgotten device PIN on the phone — the same paths as on the TV** (G3, finding B8).
///
/// Until G3 the Jellyfin password of an account without an age limit unlocked. Checked
/// here is the shared path via a ``CloudSync/MockCloud`` between phone and TV:
/// A running waiting period resolves nothing, a confirmation on the other device resolves — and only then
/// does the PIN drop via ``ShellModel/unlocked()``.
@MainActor
@Suite("B8 · Device PIN forgotten on the phone")
struct ForgotPinPhoneTests {

    let server = MockCloud()

    func cloud(_ name: String) -> ProfileCloud {
        let hub = CloudHub(
            service: server.credential("user"), file: nil,
            device: DeviceDescription(identifier: name, name: name, model: "Test rig"))
        let cloud = ProfileCloud(
            hub: hub, store: InMemoryStore(), moveBundle: InMemoryStore(),
            automatic: false)
        cloud.startStore = nil
        return cloud
    }

    @Test("A running waiting period solves nothing, a confirmation on the other device does")
    func twoWays() async throws {
        let phone = cloud("phone")
        let tv = cloud("tv")
        let flow = PinRecoveryFlow(cloud: phone, lock: .parentalControls, device: "phone")
        flow.request()
        #expect(flow.state.pending)
        #expect(await !flow.redeem(), "a running waiting period is no proof")

        _ = await phone.household()?.reconcile()
        _ = await tv.household()?.reconcile()
        #expect(tv.confirmPinRecovery(forItem: .parentalControls, device: "tv"))
        _ = await tv.household()?.reconcile()

        #expect(await flow.redeem())
        #expect(flow.state == .none)
    }

    @Test("Once resolved, the device PIN falls together with the device lock")
    func unlocked() {
        ProfilePointer.als(nil) {
            let memoryStore = InMemoryStore()
            _ = Pin(store: memoryStore).set("1234")
            let state = ParentalControlsState(
                store: UserDefaults(suiteName: UUID().uuidString)!, keychain: memoryStore)
            state.mode.set(true)
            let wrapper = ShellModel(parentalControls: state)
            #expect(state.rule.applies)
            wrapper.unlocked()
            #expect(!state.isPinSet)
            #expect(!state.mode.on)
            #expect(wrapper.navigator.overlay.last == .parentalControls)
        }
    }

    private static func code(_ name: String) throws -> String {
        try SourceText.read(name, in: .featuresPhone)
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test("No password any more — the way out is the shared one, and only with iCloud")
    func wired() throws {
        let view = try Self.code("PinForgottenView.swift")
        #expect(view.contains("PinRecoveryFlow(cloud: cloud, lock: .parentalControls)"))
        #expect(!view.contains("JellyfinConnection"), "the account password is no way out any more")
        #expect(!view.contains("password"))
        let door = try Self.code("LockedDoor.swift")
        #expect(door.contains("state.isPinSet && ProfileCloud.attached != nil"))
        let placeholder = try Self.code("TabPlaceholder.swift")
        #expect(placeholder.contains("PinForgottenView(cloud: cloud) { model.unlocked() }"))
    }
}
