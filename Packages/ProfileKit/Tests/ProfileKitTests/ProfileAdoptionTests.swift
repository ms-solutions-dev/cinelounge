import CloudSync
import Core
import Foundation
import Testing

@testable import ProfileKit

/// A service that behaves like CloudKit when the accepting party is **the owner**:
/// The metadata names `__defaultOwner__`, `accept` is omitted (participantStatus is already
/// `.accepted`). `metadataSource` is the server at which the link is resolved —
/// the same one (same environment) or another one (Development vs. Production).
struct OwnAccountService: CloudService {
    let basis: MockCloud.Access
    let metadataSource: MockCloud.Access

    func accountStatus() async -> AccountStatus { await basis.accountStatus() }
    func accountChanges() -> AsyncStream<Void> { basis.accountChanges() }
    func create(_ zone: ZoneID) async throws(CloudError) { try await basis.create(zone) }
    func delete(_ zone: ZoneID) async throws(CloudError) { try await basis.delete(zone) }
    func zones(shared: Bool) async throws(CloudError) -> [ZoneID] {
        try await basis.zones(shared: shared)
    }
    func databaseChanges(
        shared: Bool, since tag: Data?
    ) async throws(CloudError)
        -> DatabaseChanges
    { try await basis.databaseChanges(shared: shared, since: tag) }
    func changes(_ zone: ZoneID, since tag: Data?) async throws(CloudError) -> Changes {
        try await basis.changes(zone, since: tag)
    }
    func read(
        _ names: [RecordName], in zone: ZoneID
    ) async throws(CloudError)
        -> [CloudRecord]
    {
        // Like `CKDatabase.records(for:)`: Zone errors come per record, not as a throw.
        do throws(CloudError) { return try await basis.read(names, in: zone) } catch .zoneMissing {
            return []
        }
    }
    func save(
        _ wordings: [CloudRecord], in zone: ZoneID
    ) async throws(CloudError)
        -> [SaveResult]
    { try await basis.save(wordings, in: zone) }
    func delete(_ names: [RecordName], in zone: ZoneID) async throws(CloudError) {
        try await basis.delete(names, in: zone)
    }
    func putPublic(_ message: CloudRecord) async throws(CloudError) {
        try await basis.putPublic(message)
    }
    func readPublic(_ name: RecordName) async throws(CloudError) -> CloudRecord? {
        try await basis.readPublic(name)
    }
    func deletePublic(_ name: RecordName) async throws(CloudError) {
        try await basis.deletePublic(name)
    }
    func subscribe() async throws(CloudError) { try await basis.subscribe() }
    func interpret(push: [AnyHashable: Any]) -> PushInterpretation? { basis.interpret(push: push) }
    func split(_ zone: ZoneID, title: String) async throws(CloudError) -> AccessGrant {
        try await basis.split(zone, title: title)
    }
    func approval(_ zone: ZoneID) async throws(CloudError) -> AccessGrant? {
        try await basis.approval(zone)
    }
    func remove(participant: String, from zone: ZoneID) async throws(CloudError) {
        try await basis.remove(participant: participant, from: zone)
    }
    func endSharing(_ zone: ZoneID) async throws(CloudError) {
        try await basis.endSharing(zone)
    }
    /// Like CloudKit for the owner: `ownerName == __defaultOwner__`.
    func sharingMetadata(_ url: URL) async throws(CloudError) -> ShareMetadata {
        let m = try await metadataSource.sharingMetadata(url)
        return ShareMetadata(
            url: url, zone: ZoneID(name: m.zone.name, owner: ZoneID.ownAccount),
            ownerName: m.ownerName, title: m.title, accepted: true)
    }
    /// `participantStatus == .accepted` → no `accept`, the zone from the metadata.
    func accept(_ metadata: ShareMetadata) async throws(CloudError) -> ZoneID {
        ZoneID(name: metadata.zone.name, owner: ZoneID.ownAccount)
    }
    func leave(_ zone: ZoneID) async throws(CloudError) { try await basis.leave(zone) }
}

/// **Profile from the TV to the phone with the same Apple ID** (on-device test 2026-09-28):
/// First nothing arrived at all, then only the name. Now everything has to arrive 1:1 — and with
/// separate CloudKit environments a clear error instead of an empty profile.
@Suite("Profile adoption: same Apple ID")
@MainActor
struct ProfileAdoptionTests {

    let identifier = Profile.Identifier(rawValue: UUID().uuidString)
    let jellyfin = Access.jellyfin(
        server: URL(string: "http://192.0.2.183:8096")!, userID: "u1", username: "Max")

    func cloud(_ service: any CloudService) -> (ProfileCloud, InMemoryStore) {
        let store = InMemoryStore()
        let hub = CloudHub(
            service: service, file: nil,
            device: DeviceDescription(identifier: UUID().uuidString, name: "x", model: "Test rig"))
        return (ProfileCloud(hub: hub, store: store, moveBundle: nil, automatic: false), store)
    }

    /// The TV with a full profile, reconciled and shared — returns the share link.
    func tv(to server: MockCloud) async throws -> URL {
        let (tv, store) = cloud(server.credential("max"))
        var p = Profile(identifier: identifier, name: "Max", color: .turquoise, avatar: "fuchs")
        p.create(jellyfin)
        var ledger = ProfileBook.read(from: store)
        ledger.create(p)
        ledger.write(in: store)
        var state = StillLedger.read(from: store, forItem: identifier.rawValue)
        state.record(.titlePosition(title: "film1", location: 4350, duration: 7200))
        state.write(in: store, forItem: identifier.rawValue)
        await tv.reconcile(p)
        return try await tv.split(identifier, title: "Max")
    }

    @Test("Everything arrives: profile picture, Jellyfin access, progress")
    func everythingArrives() async throws {
        let server = MockCloud()
        let link = try await tv(to: server)
        let (phone, store) = cloud(server.credential("max"))
        let p = try #require(try await phone.accept(link, fallbackName: "Max"))
        #expect(p.avatar == "fuchs")
        #expect(p.credentials == [jellyfin])
        #expect(
            StillLedger.read(from: store, forItem: p.identifier.rawValue).state.titlePositions["film1"]?
                .location == 4350)
    }

    @Test("A profile of the same name on the phone is merged, no second one")
    func noSecond() async throws {
        let server = MockCloud()
        let link = try await tv(to: server)
        let (phone, store) = cloud(server.credential("max"))
        var ledger = ProfileBook.read(from: store)
        ledger.create(Profile(name: "Max"))
        ledger.write(in: store)
        _ = try await phone.accept(link, fallbackName: "Max")
        #expect(ProfileBook.read(from: store).profile.filter { $0.name == "Max" }.count == 1)
    }

    @Test("Separate environments: clear error, no empty profile")
    func separateEnvironments() async throws {
        let development = MockCloud()
        let production = MockCloud()
        let link = try await tv(to: development)
        let (phone, store) = cloud(
            OwnAccountService(
                basis: production.credential("max"), metadataSource: development.credential("max")))
        await #expect(throws: CloudError.self) { try await phone.accept(link, fallbackName: "Max") }
        #expect(ProfileBook.read(from: store).profile.isEmpty)
        #expect(production.zoneList().isEmpty, "no empty zone created")
    }
}
