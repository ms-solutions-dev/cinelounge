import Foundation
import Testing

@testable import CloudSync

/// The zone as a mirror with a queue against the stand-in: write, up,
/// down, conflict, offline, remote deletion, zone lost.
@Suite("Profilzone")
@MainActor
struct ProfileZoneTests {

    let server = MockCloud()
    let identifier = UUID()

    func message(_ name: String, _ value: String, contentType: String = "Profileinstellung") -> CloudRecord {
        CloudRecord(contentType: contentType, name: name, fields: ["wert": .text(value)])
    }

    func zone(_ user: String = "alice", file: URL? = nil) -> ProfileZone {
        ProfileZone(
            file: file, service: server.credential(user), zone: ZoneID(profile: identifier),
            automatic: false)
    }

    @Test("Writing shows up in the mirror at once, goes up on the pass and arrives on the other device")
    func upload() async throws {
        let iphone = zone()
        iphone.write(message("theme", "indigo"))
        #expect(iphone.read(contentType: "Profileinstellung", name: "theme")?["wert"]?.text == "indigo")
        #expect(iphone.pending == 1 && iphone.state == .neverSynced)
        await iphone.reconcile()
        #expect(iphone.pending == 0)
        guard case .synced = iphone.state else {
            Issue.record("State \(iphone.state)")
            return
        }
        #expect(server.content(ZoneID(profile: identifier, owner: "alice")).count == 1)

        let ipad = zone()
        var reported: [CloudRecord] = []
        let observation = ipad.observe("Profileinstellung") { reported = $0 }
        await ipad.reconcile()
        #expect(ipad.read("Profileinstellung").map(\.name) == ["theme"])
        #expect(reported.count == 1)
        withExtendedLifetime(observation) {}
    }

    @Test("Offline the queue waits; when the server is back, everything goes up")
    func offline() async {
        let z = zone()
        server.reachable = false
        z.write(message("theme", "plum"))
        await z.reconcile()
        #expect(z.state == .unreachable && z.pending == 1)
        server.reachable = true
        await z.reconcile()
        #expect(z.pending == 0)
        #expect(
            server.content(ZoneID(profile: identifier, owner: "alice")).first?["wert"]?.text == "plum")
    }

    @Test("Without an account everything stays local, and the line says so")
    func noAccount() async {
        let z = zone()
        server.setAccount("alice", .noAccount)
        z.write(message("theme", "ink"))
        await z.reconcile()
        #expect(z.state == .noAccount && z.pending == 1)
        #expect(z.read("Profileinstellung").count == 1)
    }

    @Test("Conflict: the newer change wins, for sessions the later end")
    func conflict() async {
        let iphone = zone()
        let ipad = zone()
        iphone.write(message("theme", "indigo"), now: Date(timeIntervalSince1970: 100))
        await iphone.reconcile()
        await ipad.reconcile()
        // Both change, the iPad goes up first — the iPhone has the younger intent.
        ipad.write(message("theme", "plum"), now: Date(timeIntervalSince1970: 200))
        iphone.write(message("theme", "terracotta"), now: Date(timeIntervalSince1970: 300))
        await ipad.reconcile()
        await iphone.reconcile()
        #expect(iphone.read(contentType: "Profileinstellung", name: "theme")?["wert"]?.text == "terracotta")
        #expect(iphone.pending == 0)
        await ipad.reconcile()
        #expect(ipad.read(contentType: "Profileinstellung", name: "theme")?["wert"]?.text == "terracotta")

        // Sessions: the later end wins, even if it is the older change.
        iphone.rule(forItem: "Lesesitzung", .greaterValue("ende"))
        ipad.rule(forItem: "Lesesitzung", .greaterValue("ende"))
        let session = CloudRecord(
            contentType: "Lesesitzung", name: "s1", fields: ["ende": .date(Date(timeIntervalSince1970: 900))])
        iphone.write(session, now: Date(timeIntervalSince1970: 1000))
        await iphone.reconcile()
        await ipad.reconcile()
        var longer = session
        longer["ende"] = .date(Date(timeIntervalSince1970: 1500))
        ipad.write(longer, now: Date(timeIntervalSince1970: 1100))
        var shorter = session
        shorter["ende"] = .date(Date(timeIntervalSince1970: 1200))
        iphone.write(shorter, now: Date(timeIntervalSince1970: 1300))
        await ipad.reconcile()
        await iphone.reconcile()
        #expect(
            iphone.read(contentType: "Lesesitzung", name: "s1")?["ende"]?.date
                == Date(timeIntervalSince1970: 1500))
    }

    @Test("Deleting travels — but not past a waiting write request")
    func delete() async {
        let iphone = zone()
        let ipad = zone()
        iphone.write(message("a", "1", contentType: "Merkeintrag"))
        iphone.write(message("b", "2", contentType: "Merkeintrag"))
        await iphone.reconcile()
        await ipad.reconcile()
        #expect(ipad.read("Merkeintrag").count == 2)
        iphone.deleteAll(contentType: "Merkeintrag")
        await iphone.reconcile()
        // The iPad touched b once more while offline — b stays, a drops.
        ipad.write(message("b", "3", contentType: "Merkeintrag"))
        await ipad.reconcile()
        #expect(ipad.read("Merkeintrag").map(\.name) == ["b"])
        await iphone.reconcile()
        #expect(iphone.read("Merkeintrag").map(\.name) == ["b"])
    }

    @Test("The mirror survives the restart together with queue and token")
    func disk() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "cloud-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        server.reachable = false
        let first = zone(file: file)
        first.write(message("theme", "indigo"))
        await first.reconcile()
        let second = zone(file: file)
        #expect(second.pending == 1 && second.read("Profileinstellung").count == 1)
        server.reachable = true
        await second.reconcile()
        #expect(second.pending == 0)
        let third = zone(file: file)
        #expect(third.state != .neverSynced, "the token and the last pass are on disk")
    }

    @Test("An own zone that does not exist is created — together with the mirror")
    func zoneMissing() async {
        let z = zone()
        z.write(message("theme", "indigo"))
        #expect(server.zoneList().isEmpty)
        await z.reconcile()
        #expect(server.zoneList().count == 1 && z.pending == 0)
    }

    @Test("Export is readable JSON without seal")
    func export() async throws {
        let z = zone()
        z.write(message("theme", "indigo"))
        await z.reconcile()
        let data = try #require(z.export())
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"indigo\"") && !text.contains("siegel"))
    }
}

/// Product decision 15: a record that only the server rejects (type or field
/// missing from the production schema) does not drag its batch down and does not block the
/// queue.
@Suite("Profile zone: single-record rejection")
@MainActor
struct ProfileZoneRejectionTests {

    let server = MockCloud()
    let identifier = UUID()

    var serverZone: ZoneID { ZoneID(profile: identifier, owner: "alice") }
    let newcomer = RecordName(contentType: "Newcomer", name: "n")

    func message(_ name: String, _ value: String, contentType: String = "Profileinstellung") -> CloudRecord {
        CloudRecord(contentType: contentType, name: name, fields: ["wert": .text(value)])
    }

    func zone(file: URL? = nil) -> ProfileZone {
        ProfileZone(
            file: file, service: server.credential("alice"), zone: ZoneID(profile: identifier),
            automatic: false)
    }

    @Test(
        "A type without a schema affects only its own record: the others are up, it is noted, the queue is free"
    )
    func onlyItsRecord() async {
        server.refuse(contentType: "Newcomer")
        let z = zone()
        z.write(message("a", "1"))
        z.write(message("n", "new", contentType: "Newcomer"))
        z.write(message("b", "2"))
        await z.reconcile()

        #expect(server.content(serverZone).map(\.name) == ["a", "b"])
        #expect(z.pending == 0, "the rejected record does not block the queue")
        #expect(z.rejected[newcomer] != nil, "and it is noted, not silently gone")
        #expect(z.read(contentType: "Newcomer", name: "n")?["wert"]?.text == "new", "it stays in the mirror")
        guard case .synced = z.state else {
            Issue.record("State \(z.state)")
            return
        }

        // The next call runs through instead of getting stuck on the same record.
        z.write(message("a", "3"))
        await z.reconcile()
        #expect(server.content(serverZone).first { $0.name == "a" }?["wert"]?.text == "3")
        #expect(z.pending == 0)

        // Whoever deletes the record themselves no longer wants it — the note drops with it.
        z.delete(contentType: "Newcomer", name: "n")
        #expect(z.rejected.isEmpty)
    }

    @Test("After the schema deployment the record goes up on the next write, the note is dropped")
    func nextWrite() async {
        server.refuse(contentType: "Newcomer")
        let z = zone()
        z.write(message("n", "new", contentType: "Newcomer"))
        await z.reconcile()
        #expect(z.rejected[newcomer] != nil && server.content(serverZone).isEmpty)

        server.refuse(contentType: "Newcomer", reason: nil)
        z.write(message("n", "neuer", contentType: "Newcomer"))
        await z.reconcile()
        #expect(server.content(serverZone).first?["wert"]?.text == "neuer")
        #expect(z.rejected.isEmpty && z.pending == 0)
    }

    @Test("The note survives the restart, and the restart tries the record once more")
    func restart() async {
        let file = FileManager.default.temporaryDirectory.appending(path: "cloud-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        server.refuse(contentType: "Newcomer")
        let first = zone(file: file)
        first.write(message("n", "new", contentType: "Newcomer"))
        await first.reconcile()
        #expect(first.pending == 0)

        server.refuse(contentType: "Newcomer", reason: nil)
        let second = zone(file: file)
        #expect(second.rejected[newcomer] != nil && second.pending == 1)
        await second.reconcile()
        #expect(server.content(serverZone).map(\.name) == ["n"])
        #expect(second.rejected.isEmpty && second.pending == 0)
    }

    /// ultra, 2026-09-27: a call carries up at most conflict rounds × batch records. What
    /// lies beyond that was previously still called "synced".
    @Test("More records than one pass carries: reconciled only when the queue is empty")
    func largeMove() async throws {
        let z = zone()
        let count = ProfileZone.conflictRounds * ProfileZone.burst + 50
        for i in 0..<count { z.write(message("s\(i)", "\(i)")) }
        await z.reconcile()
        #expect(z.pending == 0)
        guard case .synced = z.state else {
            Issue.record("State \(z.state)")
            return
        }
        #expect(server.content(ZoneID(profile: identifier, owner: "alice")).count == count)
    }

    @Test("Share link only from icloud.com, not from similar hosts")
    func shareLinkHost() throws {
        let real = try #require(URL(string: "https://www.icloud.com/share/abc"))
        let bare = try #require(URL(string: "https://icloud.com/share/abc"))
        let wrong = try #require(URL(string: "https://evilicloud.com/share/abc"))
        #expect(CloudHub.isShareLink(real))
        #expect(CloudHub.isShareLink(bare))
        #expect(!CloudHub.isShareLink(wrong))
    }
}
