import CloudSync
import Core
import Foundation
import ProfileKit
import Testing

@testable import Flows

/// **Where a profile runs** — the device list under "Devices & Sharing" (2026-10-01).
///
/// The finding: ``CloudSync/CloudHub`` can hold devices, and StoryShelf shows them. In
/// CineLounge the zones were created in ``ProfileKit/ProfileCloud/zone(forItem:)`` and never passed
/// the point at which a device registers itself — the list would have stayed empty.
///
/// Counter-check: without `hub.writeDevice(in: zone)` in
/// ``ProfileKit/ProfileCloud/reconcile(_:now:)`` ``thisDeviceIsListed()`` turns red.
@MainActor
@Suite("Devices & Sharing: the device list")
struct DeviceListTests {

    let server = MockCloud()
    let person = Profile(
        identifier: .init(rawValue: "3A7A0000-0000-4000-8000-00000000CAFE"), name: "Alex")

    func cloud(device: String, model: String) -> ProfileCloud {
        let store = InMemoryStore()
        let hub = CloudHub(
            service: server.credential("alex"), file: nil,
            device: DeviceDescription(identifier: device, name: device, model: model))
        let cloud = ProfileCloud(
            hub: hub, store: store, moveBundle: InMemoryStore(), automatic: false)
        cloud.startStore = nil
        var ledger = ProfileBook.read(from: store)
        ledger.create(person)
        ledger.write(in: store)
        return cloud
    }

    func flow(_ cloud: ProfileCloud) -> SharingFlow {
        SharingFlow(
            profile: person, cloud: cloud, pullMode: .code, device: "Test rig", revoke: { _ in })
    }

    @Test("After the sync this device is in the list — marked as this one")
    func thisDeviceIsListed() async {
        let tv = cloud(device: "tv", model: "Apple TV")
        await tv.reconcile(person)

        let flow = flow(tv)
        await flow.loadSharing()

        #expect(flow.devices.map(\.identifier) == ["tv"])
        #expect(flow.devices.first?.model == "Apple TV")
        #expect(flow.thisDevice == "tv")
    }

    @Test("A second device of the same profile appears on the first")
    func secondDevice() async {
        let tv = cloud(device: "tv", model: "Apple TV")
        let phone = cloud(device: "iphone", model: "iPhone")
        await tv.reconcile(person)
        await phone.reconcile(person)
        await tv.reconcile(person)

        let flow = flow(tv)
        await flow.loadSharing()

        #expect(Set(flow.devices.map(\.identifier)) == ["tv", "iphone"])
    }

    @Test("Renaming sticks — even if the device registers itself again afterwards")
    func renamingSticks() async {
        let tv = cloud(device: "tv", model: "Apple TV")
        let phone = cloud(device: "iphone", model: "iPhone")
        await tv.reconcile(person)
        await phone.reconcile(person)
        await tv.reconcile(person)

        let flow = flow(tv)
        await flow.loadSharing()
        await flow.rename(device: "iphone", name: "  Alex's iPhone ")
        #expect(flow.devices.first { $0.identifier == "iphone" }?.name == "Alex's iPhone")

        await phone.reconcile(person)
        await tv.reconcile(person)
        flow.loadDevices()
        #expect(flow.devices.first { $0.identifier == "iphone" }?.name == "Alex's iPhone")
    }

    @Test("Without a zone no devices and no crash")
    func withoutZone() async {
        let tv = cloud(device: "tv", model: "Apple TV")
        let foreign = Profile(identifier: .init(rawValue: "k-ohne-zone"), name: "Ohne")
        let flow = SharingFlow(
            profile: foreign, cloud: tv, pullMode: .code, device: "Test rig", revoke: { _ in })
        await flow.loadSharing()
        await flow.rename(device: "tv", name: "whatever")
        #expect(flow.devices.isEmpty)
    }
}
