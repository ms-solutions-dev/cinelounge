import Foundation
import Testing

@testable import CloudSync

/// The hub: zone choice when binding, sharing from account to account, pushes,
/// account switch, device list.
@Suite("Cloud hub")
@MainActor
struct CloudHubTests {

    let server = MockCloud()

    func hub(_ user: String, device: String = "Alice's iPhone") -> CloudHub {
        CloudHub(
            service: server.credential(user, name: user.capitalized), file: nil,
            device: DeviceDescription(identifier: "device-\(device)", name: device, model: "iPhone"))
    }

    func zone(_ user: String) -> ProfileZone {
        ProfileZone(file: nil, service: server.credential(user), automatic: false)
    }

    @Test("Binding: the first device creates the zone, the second with the same name takes it")
    func zoneSelection() async throws {
        let iphone = hub("alice", device: "iPhone")
        let z1 = zone("alice")
        z1.write(CloudRecord(contentType: "Merkeintrag", name: "m1", fields: [:]))
        let k1 = try #require(await iphone.bind(z1, identifier: UUID(), name: "Alice", color: "indigo"))
        #expect(k1.isProfile && !k1.shared)
        #expect(z1.read(contentType: "Profileinstellung", name: "name")?["wert"]?.text == "Alice")

        let ipad = hub("alice", device: "iPad")
        let z2 = zone("alice")
        z2.write(CloudRecord(contentType: "Merkeintrag", name: "m2", fields: [:]))
        let k2 = try #require(await ipad.bind(z2, identifier: UUID(), name: " alice ", color: "plum"))
        #expect(k2 == k1, "the same reader on the same Apple ID")
        #expect(Set(z2.read("Merkeintrag").map(\.name)) == ["m1", "m2"], "both states merged")
        #expect(CloudHub.devices(in: z2).map(\.name).sorted() == ["iPad", "iPhone"])

        // A different name gets a zone of its own.
        let z3 = zone("alice")
        let k3 = try #require(await ipad.bind(z3, identifier: UUID(), name: "Bob", color: nil))
        #expect(k3 != k1 && server.zoneList().count == 2)
    }

    @Test("Without an account the zone stays unbound")
    func withoutAccount() async {
        server.setAccount("alice", .noAccount)
        let z = zone("alice")
        #expect(await hub("alice").bind(z, identifier: UUID(), name: "Alice", color: nil) == nil)
        #expect(z.zone == nil && z.state == .unbound)
    }

    @Test("Sharing: share, accept, read along and write along, revoke")
    func approval() async throws {
        let alice = hub("alice")
        let own = zone("alice")
        let identifier = try #require(
            await alice.bind(own, identifier: UUID(), name: "Alice", color: "indigo"))
        own.write(CloudRecord(contentType: "Lesesitzung", name: "s1", fields: ["ende": .date(Date())]))
        await own.reconcile()
        let approval = try await alice.split(identifier, title: "Alice")
        let url = try #require(approval.url)
        #expect(approval.participant.count == 1 && approval.participant[0].owner)

        // The shared iPad on another Apple ID accepts.
        let family = hub("family", device: "iPad")
        let accepted = try await family.accept(url: url)
        #expect(
            accepted.zone.owner == "alice" && accepted.profileName == "Alice"
                && accepted.color == "indigo")
        #expect(accepted.ownerName == "Alice")
        let foreign = ProfileZone(
            file: nil, service: server.credential("family"), zone: accepted.zone, automatic: false)
        _ = await family.bind(foreign, identifier: UUID(), name: "Alice", color: nil)
        #expect(foreign.read("Lesesitzung").map(\.name) == ["s1"])
        #expect(CloudHub.devices(in: foreign).count == 2)
        foreign.write(CloudRecord(contentType: "Lesesitzung", name: "s2", fields: ["ende": .date(Date())]))
        await foreign.reconcile()
        // The owner gets the push for their private database and fetches.
        alice.register(own)
        #expect(await alice.process(push: ["mock-shared": false]))
        #expect(Set(own.read("Lesesitzung").map(\.name)) == ["s1", "s2"])
        #expect(await alice.process(push: ["foreign": true]) == false)

        // Participant list at the owner, then revoking: the iPad loses the zone.
        let list = try #require(try await alice.approval(identifier))
        #expect(list.invited.map(\.identifier) == ["family"])
        try await alice.remove(participant: "family", from: identifier)
        family.register(foreign)
        _ = await family.process(push: ["mock-shared": true])
        #expect(foreign.state == .lost)
        await foreign.reconcile()
        #expect(foreign.state == .lost, "a foreign zone is not recreated")
        #expect(own.read("Lesesitzung").count == 2, "the data stays with the owner")
    }

    @Test("The participant leaves the share; the owner ends it entirely")
    func leave() async throws {
        let alice = hub("alice")
        let own = zone("alice")
        let identifier = try #require(await alice.bind(own, identifier: UUID(), name: "Alice", color: nil))
        let url = try #require(try await alice.split(identifier, title: "Alice").url)
        let family = hub("family")
        let accepted = try await family.accept(url: url)
        try await family.leave(accepted.zone)
        #expect(try await alice.approval(identifier)?.invited.isEmpty == true)
        let otherProfile = hub("bob")
        _ = try await otherProfile.accept(url: url)
        try await alice.endSharing(identifier)
        #expect(try await alice.approval(identifier) == nil)
        #expect(try await server.credential("bob").zones(shared: true).isEmpty)
    }

    @Test("Naming devices: a person's name stays, the system name does not come back")
    func nameDevices() async throws {
        let iphone = hub("alice", device: "iPhone")
        let z = zone("alice")
        _ = try #require(await iphone.bind(z, identifier: UUID(), name: "Alice", color: nil))
        let identifier = iphone.device.identifier
        #expect(CloudHub.devices(in: z).first?.named == false)
        // Another device of the same zone renames the iPhone.
        iphone.nameDevice(identifier, name: " Alice's phone ", in: z)
        await z.reconcile()
        let entry = try #require(CloudHub.devices(in: z).first { $0.identifier == identifier })
        #expect(entry.name == "Alice's phone" && entry.named)
        // The iPhone registers again later — with the assigned name, not "iPhone".
        z.write(
            CloudRecord(
                contentType: CloudHub.deviceType, name: identifier,
                fields: [
                    "name": .text("Alice's phone"), "modell": .text("iPhone"), "benannt": .bool(true),
                    "zuletzt": .date(Date().addingTimeInterval(-7200)),
                ]))
        iphone.writeDevice(in: z)
        let following = try #require(CloudHub.devices(in: z).first { $0.identifier == identifier })
        #expect(following.name == "Alice's phone" && following.named)
        #expect(Date().timeIntervalSince(following.recent) < 60, "only the last-seen time moves")
        // An unknown device does not get a record merely by being renamed.
        iphone.nameDevice("foreign", name: "Something", in: z)
        #expect(CloudHub.devices(in: z).count == 1)
        // An empty name changes nothing.
        iphone.nameDevice(identifier, name: "   ", in: z)
        #expect(CloudHub.devices(in: z).first?.name == "Alice's phone")
    }

    @Test(
        "Participants and devices: the creator of the device record is the participant, and it can be named"
    )
    func participantDevices() async throws {
        let alice = hub("alice", device: "iPhone")
        let own = zone("alice")
        let identifier = try #require(await alice.bind(own, identifier: UUID(), name: "Alice", color: nil))
        let url = try #require(try await alice.split(identifier, title: "Alice").url)
        let family = hub("family", device: "iPad")
        let accepted = try await family.accept(url: url)
        let foreign = ProfileZone(
            file: nil, service: server.credential("family"), zone: accepted.zone, automatic: false)
        _ = await family.bind(foreign, identifier: UUID(), name: "Alice", color: nil)
        await own.reconcile()
        let approval = try #require(try await alice.approval(identifier))
        let participant = try #require(approval.invited.first)
        #expect(CloudHub.devices(from: participant.identifier, in: own).map(\.name) == ["iPad"])
        #expect(CloudHub.devices(from: "alice", in: own).map(\.name) == ["iPhone"])
        #expect(CloudHub.participantName(participant.identifier, in: own) == nil)
        alice.nameParticipant(participant.identifier, name: "The parents", in: own)
        await own.reconcile()
        #expect(CloudHub.participantName(participant.identifier, in: own) == "The parents")
        // The participant sees their name too — and the creator stays when rewriting.
        await foreign.reconcile()
        #expect(CloudHub.participantName(participant.identifier, in: foreign) == "The parents")
        alice.nameDevice(family.device.identifier, name: "The parents' iPad", in: own)
        await own.reconcile()
        #expect(
            CloudHub.devices(from: participant.identifier, in: own).map(\.name) == ["The parents' iPad"])
        alice.nameParticipant(participant.identifier, name: "", in: own)
        #expect(CloudHub.participantName(participant.identifier, in: own) == nil)
    }

    @Test("Account switch: signed out means no account, signed in fetches again")
    func accountSwitch() async throws {
        let alice = hub("alice")
        await alice.start()
        #expect(alice.account == .available)
        let z = zone("alice")
        _ = await alice.bind(z, identifier: UUID(), name: "Alice", color: nil)
        alice.register(z)
        server.setAccount("alice", .noAccount)
        await alice.accountChanged()
        #expect(alice.account == .noAccount && z.state == .noAccount)
        server.setAccount("alice", .available)
        await alice.accountChanged()
        guard case .synced = z.state else {
            Issue.record("State \(z.state)")
            return
        }
    }

    @Test("A share link is one from icloud.com/share")
    func shareLink() {
        #expect(CloudHub.isShareLink(URL(string: "https://www.icloud.com/share/0abc#Alice")!))
        #expect(!CloudHub.isShareLink(URL(string: "storyshelf://einrichten?komga=x")!))
    }
}
