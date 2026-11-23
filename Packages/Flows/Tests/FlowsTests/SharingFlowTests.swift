import CloudSync
import Core
import Foundation
import ProfileKit
import Testing

@testable import Flows

/// **"Devices & Sharing" as one flow for TV and phone** (AP58 R2, finding P4).
///
/// Until R2 it existed twice in views, without a check. What is tested here is what hangs on the flow:
/// ending sharing revokes the person token, a failure revokes nothing and
/// says so, Back empties the mailbox, and the device's fetch path takes effect.
///
/// Counter-check: without `await revoke(profile.identifier)` in ``SharingFlow/finish()``
/// ``endingRevokes()`` turns red.
@MainActor
@Suite("Devices & Sharing: the shared flow")
struct SharingFlowTests {

    let server = MockCloud()
    let person = Profile(
        identifier: .init(rawValue: "3A7A0000-0000-4000-8000-00000000BEEF"), name: "Alex")

    /// Records whose token was revoked.
    final class Revocations {
        var identifiers: [Profile.Identifier] = []
    }

    func cloud() -> ProfileCloud {
        let store = InMemoryStore()
        let hub = CloudHub(
            service: server.credential("alex"), file: nil,
            device: DeviceDescription(identifier: "tv", name: "tv", model: "Test rig"))
        let cloud = ProfileCloud(
            hub: hub, store: store, moveBundle: InMemoryStore(), automatic: false)
        cloud.startStore = nil
        var ledger = ProfileBook.read(from: store)
        ledger.create(person)
        ledger.write(in: store)
        return cloud
    }

    func flow(
        _ cloud: ProfileCloud, profile: Profile?, pullMode: SharingFlow.PullMode = .code,
        recording: Revocations
    ) -> SharingFlow {
        SharingFlow(
            profile: profile, cloud: cloud, pullMode: pullMode, device: "Test rig",
            revoke: { recording.identifiers.append($0) })
    }

    @Test("Ending sharing revokes the person token of this profile")
    func endingRevokes() async throws {
        let cloud = cloud()
        await cloud.reconcile(person)
        _ = try await cloud.split(person.identifier, title: person.name)
        let recording = Revocations()
        let flow = flow(cloud, profile: person, recording: recording)
        await flow.loadSharing()
        #expect(flow.approval != nil)

        await flow.finish()
        #expect(recording.identifiers == [person.identifier])
        #expect(flow.approval == nil)
        #expect(flow.error == nil)
    }

    @Test("A failure revokes nothing and says so")
    func failureDoesNotRevoke() async {
        let cloud = cloud()
        let withoutZone = Profile(identifier: .init(rawValue: "k-ohne-zone"), name: "Ohne")
        let recording = Revocations()
        let flow = flow(cloud, profile: withoutZone, recording: recording)
        await flow.finish()
        #expect(recording.identifiers.isEmpty)
        #expect(flow.error != nil)
    }

    @Test("The TV fetches with a code, the phone with the camera")
    func pullMode() async {
        let cloud = cloud()
        let tv = flow(cloud, profile: nil, pullMode: .code, recording: Revocations())
        tv.start(.isFetching)
        #expect(tv.page == .isFetching)
        #expect(tv.pairing?.code != nil, "the TV shows a code")

        let phone = flow(cloud, profile: person, pullMode: .camera, recording: Revocations())
        phone.start(.isFetching)
        #expect(phone.pairing?.code == nil, "the phone scans and shows nothing")

        #expect(await phone.back() == false, "back to the overview")
        #expect(phone.page == .overview)
        #expect(phone.pairing == nil)
        #expect(await tv.back(), "fetch only: back closes")
        #expect(await phone.back(), "from the overview it closes")
    }

    @Test("Sixteen characters in groups of four")
    func readable() {
        #expect(SharingFlow.readable("ABCDEFGHIJKLMNOP") == "ABCD EFGH IJKL MNOP")
        #expect(SharingFlow.readable("ABCDE") == "ABCD E")
    }
}
