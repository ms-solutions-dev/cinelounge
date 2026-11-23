import Foundation
import Testing

@testable import CloudSync

/// **A deleted zone does not come back** (2026-09-27): the owner had chosen "Delete Data"
/// in the iOS settings on the iPhone, and the profile still stood in the
/// app — the next call recreated the zone and wrote the mirror back up.
/// Every other device did the same after one had deleted the zone.
@Suite("Profile zone: deleted zones")
@MainActor
struct ZoneDeletionTests {

    let server = MockCloud()
    let identifier = UUID()

    var own: ZoneID { ZoneID(profile: identifier) }
    var serverZone: ZoneID { ZoneID(profile: identifier, owner: "alice") }

    func message(_ name: String, _ value: String) -> CloudRecord {
        CloudRecord(contentType: "Profileinstellung", name: name, fields: ["wert": .text(value)])
    }

    func zone(file: URL? = nil) -> ProfileZone {
        ProfileZone(file: file, service: server.credential("alice"), zone: own, automatic: false)
    }

    /// A zone that has already been on the server once.
    func synced(file: URL? = nil) async -> ProfileZone {
        let z = zone(file: file)
        z.write(message("name", "Alice"))
        await z.reconcile()
        #expect(server.zoneList().count == 1)
        return z
    }

    @Test("Deleted by the user: no recreation, the mirror is gone, and it is reported")
    func byUser() async {
        let z = await synced()
        var reported: [ZoneRemoval] = []
        z.onRemoval = { reported.append($0) }
        server.deleteByUser(own, user: "alice")

        z.write(message("farbe", "indigo"))
        await z.reconcile()

        #expect(server.zoneList().isEmpty, "the zone is not recreated")
        #expect(z.read("Profileinstellung").isEmpty, "the mirror is discarded")
        #expect(z.state == .lost && z.removed == .byUser && z.pending == 0)
        #expect(reported == [.byUser])

        // A further call no longer goes to the server and does not report again.
        z.write(message("farbe", "plum"))
        await z.reconcile()
        #expect(server.zoneList().isEmpty && reported == [.byUser])
    }

    /// Even a device that has never seen the zone does not simply recreate one deleted
    /// by the user — Apple requires asking first.
    @Test("Deleted by the user, on a new device: no recreation either")
    func byUserNewDevice() async {
        _ = await synced()
        server.deleteByUser(own, user: "alice")
        let fresh = zone()
        fresh.write(message("name", "Alice"))
        await fresh.reconcile()
        #expect(server.zoneList().isEmpty && fresh.removed == .byUser)
    }

    /// **The control test against the old code:** another device of the same Apple ID deletes
    /// the zone (like "Delete All iCloud Data" in the app); this one only sees
    /// `zoneNotFound` and, until now, revived it with its mirror.
    @Test("Deleted remotely: do not revive, mirror stays, locked, reported")
    func fromRemote() async throws {
        let iphone = await synced()
        var reported: [ZoneRemoval] = []
        iphone.onRemoval = { reported.append($0) }
        try await server.credential("alice").delete(own)

        iphone.write(message("farbe", "indigo"))
        await iphone.reconcile()

        #expect(server.zoneList().isEmpty)
        #expect(iphone.state == .lost && iphone.removed == .fromRemote)
        #expect(iphone.read("Profileinstellung").count == 2, "what lies here is up to the app")
        #expect(reported == [.fromRemote])
    }

    @Test("The lock survives the restart")
    func lockOnDisk() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "wolke.json")
        _ = await synced(file: file)
        try await server.credential("alice").delete(own)
        let first = zone(file: file)
        await first.reconcile()
        #expect(first.removed == .fromRemote)

        let second = zone(file: file)
        #expect(second.state == .lost && second.removed == .fromRemote)
        second.write(message("farbe", "indigo"))
        await second.reconcile()
        #expect(server.zoneList().isEmpty)
    }

    /// A mirror from before this rule carries no "confirmed" — its token says so.
    @Test("An older mirror with a token counts as confirmed")
    func oldSnapshot() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "wolke.json")
        _ = await synced(file: file)
        // Remove the field, as an older mirror did not have it.
        var json = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(json["bestaetigt"] != nil)
        json["bestaetigt"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: file)

        try await server.credential("alice").delete(own)
        let z = zone(file: file)
        await z.reconcile()
        #expect(server.zoneList().isEmpty && z.removed == .fromRemote)
    }

    @Test("The first pass of a new profile still creates the zone")
    func firstPass() async {
        let z = zone()
        z.write(message("name", "Neu"))
        await z.reconcile()
        #expect(server.zoneList().count == 1 && z.removed == nil)
    }

    /// After the app's decision it continues empty — even after a deletion by
    /// the user. Only what was written afterwards goes up.
    @Test("Discarding starts empty from scratch and recreates the zone")
    func discard() async {
        let z = await synced()
        server.deleteByUser(own, user: "alice")
        z.onRemoval = { _ in z.discard() }
        await z.reconcile()
        #expect(z.removed == nil && server.zoneList().isEmpty)

        z.write(message("farbe", "indigo"))
        await z.reconcile()
        #expect(server.content(serverZone).map(\.name) == ["farbe"], "only the new one, not the old name")
        guard case .synced = z.state else {
            Issue.record("State \(z.state)")
            return
        }
    }

    /// The silent push brings the deletion before a call notices it.
    @Test("The hub reports a deleted own zone from the database changes")
    func fromTheDatabase() async {
        let hub = CloudHub(
            service: server.credential("alice"), file: nil,
            device: DeviceDescription(identifier: "tv", name: "TV", model: "AppleTV"))
        let z = await synced()
        hub.register(z)
        await hub.checkDatabases()
        var reported: [ZoneRemoval] = []
        z.onRemoval = { reported.append($0) }

        server.deleteByUser(own, user: "alice")
        await hub.checkDatabases()
        #expect(reported == [.byUser] && z.read("Profileinstellung").isEmpty)
    }

    /// The device that itself deleted and started over does not lock itself out on its own push.
    ///
    @Test("After its own restart the push about the deletion does not lock")
    func ownRestart() async throws {
        let hub = CloudHub(
            service: server.credential("alice"), file: nil,
            device: DeviceDescription(identifier: "tv", name: "TV", model: "AppleTV"))
        let z = await synced()
        hub.register(z)
        await hub.checkDatabases()
        try await hub.delete(own)
        z.discard()
        await hub.checkDatabases()
        #expect(z.removed == nil)
    }

    @Test("Releasing the binding lifts the lock")
    func releaseLiftsLock() async {
        let z = await synced()
        server.deleteByUser(own, user: "alice")
        await z.reconcile()
        #expect(z.removed == .byUser)
        z.unbind()
        #expect(z.removed == nil && z.state == .unbound)
    }
}
