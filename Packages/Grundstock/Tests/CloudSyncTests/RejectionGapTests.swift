import Foundation
import Testing

@testable import CloudSync

/// A service that stops the call **in the middle of saving** — for the race
/// "write while the same record is just going up". It also counts how often
/// a record was sent up, so that a tight retry loop shows.
final class Holding: CloudService, @unchecked Sendable {
    let inside: MockCloud.Access
    private let lock = NSLock()
    private var inProgress = false
    private var inFlightContinuation: CheckedContinuation<Void, Never>?
    private var proceedAllowed = false
    private var proceedContinuation: CheckedContinuation<Void, Never>?
    private var isHolding: Bool
    private var sent: [RecordName: Int] = [:]

    /// - Parameter haelt: whether the first save stops until ``next()`` comes.
    init(_ inside: MockCloud.Access, isHolding: Bool = true) {
        self.inside = inside
        self.isHolding = isHolding
    }

    /// How often this record has been sent up so far.
    func attempts(_ name: RecordName) -> Int { lock.withLock { sent[name, default: 0] } }

    func waitForInFlight() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.withLock {
                if inProgress { c.resume() } else { inFlightContinuation = c }
            }
        }
    }

    func next() {
        lock.withLock {
            proceedAllowed = true
            proceedContinuation?.resume()
            proceedContinuation = nil
        }
    }

    func accountStatus() async -> AccountStatus { await inside.accountStatus() }
    func accountChanges() -> AsyncStream<Void> { inside.accountChanges() }
    func create(_ zone: ZoneID) async throws(CloudError) { try await inside.create(zone) }
    func delete(_ zone: ZoneID) async throws(CloudError) { try await inside.delete(zone) }
    func zones(shared: Bool) async throws(CloudError) -> [ZoneID] { try await inside.zones(shared: shared) }
    func databaseChanges(shared: Bool, since tag: Data?) async throws(CloudError) -> DatabaseChanges {
        try await inside.databaseChanges(shared: shared, since: tag)
    }
    func changes(_ zone: ZoneID, since tag: Data?) async throws(CloudError) -> Changes {
        try await inside.changes(zone, since: tag)
    }
    func read(_ names: [RecordName], in zone: ZoneID) async throws(CloudError) -> [CloudRecord] {
        try await inside.read(names, in: zone)
    }
    func save(_ wordings: [CloudRecord], in zone: ZoneID) async throws(CloudError) -> [SaveResult] {
        lock.withLock { for message in wordings { sent[message.id, default: 0] += 1 } }
        let result = try await inside.save(wordings, in: zone)
        let hold = lock.withLock { () -> Bool in
            guard isHolding else { return false }
            isHolding = false
            inProgress = true
            inFlightContinuation?.resume()
            inFlightContinuation = nil
            return true
        }
        if hold {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.withLock {
                    if proceedAllowed { c.resume() } else { proceedContinuation = c }
                }
            }
        }
        return result
    }
    func delete(_ names: [RecordName], in zone: ZoneID) async throws(CloudError) {
        try await inside.delete(names, in: zone)
    }
    func putPublic(_ message: CloudRecord) async throws(CloudError) { try await inside.putPublic(message) }
    func readPublic(_ name: RecordName) async throws(CloudError) -> CloudRecord? {
        try await inside.readPublic(name)
    }
    func deletePublic(_ name: RecordName) async throws(CloudError) { try await inside.deletePublic(name) }
    func subscribe() async throws(CloudError) { try await inside.subscribe() }
    func interpret(push: [AnyHashable: Any]) -> PushInterpretation? { inside.interpret(push: push) }
    func split(_ zone: ZoneID, title: String) async throws(CloudError) -> AccessGrant {
        try await inside.split(zone, title: title)
    }
    func approval(_ zone: ZoneID) async throws(CloudError) -> AccessGrant? { try await inside.approval(zone) }
    func remove(participant: String, from zone: ZoneID) async throws(CloudError) {
        try await inside.remove(participant: participant, from: zone)
    }
    func endSharing(_ zone: ZoneID) async throws(CloudError) { try await inside.endSharing(zone) }
    func sharingMetadata(_ url: URL) async throws(CloudError) -> ShareMetadata {
        try await inside.sharingMetadata(url)
    }
    func accept(_ metadata: ShareMetadata) async throws(CloudError) -> ZoneID {
        try await inside.accept(metadata)
    }
    func leave(_ zone: ZoneID) async throws(CloudError) { try await inside.leave(zone) }
}

/// The gaps around ``SaveResult/rejected(_:)`` — reproduced on the review evening
/// 2026-09-25, each first red against the state of `9746265`.
@Suite("Profile zone: gaps in the single-record rejection")
@MainActor
struct RejectionGapTests {

    let server = MockCloud()
    let identifier = UUID()

    var serverZone: ZoneID { ZoneID(profile: identifier, owner: "alice") }
    let newcomer = RecordName(contentType: "Newcomer", name: "n")

    func message(_ name: String, _ value: String, contentType: String = "Newcomer") -> CloudRecord {
        CloudRecord(contentType: contentType, name: name, fields: ["wert": .text(value)])
    }

    func zone(file: URL? = nil, service: (any CloudService)? = nil) -> ProfileZone {
        ProfileZone(
            file: file, service: service ?? server.credential("alice"), zone: ZoneID(profile: identifier),
            automatic: false)
    }

    func value(_ z: ProfileZone) -> String? { z.read(contentType: "Newcomer", name: "n")?["wert"]?.text }

    func serverValue() -> String? { server.content(serverZone).first { $0.name == "n" }?["wert"]?.text }

    /// Gap 1: the schema arrives, the app keeps running, nobody touches the record —
    /// a call that brings changes from the server tries it again.
    @Test("Schema delivered later, no restart, no change: the next pass with news carries it up")
    func noChangeNoRestart() async {
        server.refuse(contentType: "Newcomer")
        let z = zone()
        z.write(message("n", "new"))
        await z.reconcile()
        #expect(z.rejected[newcomer] != nil && server.content(serverZone).isEmpty)

        server.refuse(contentType: "Newcomer", reason: nil)
        z.write(message("x", "1", contentType: "Profileinstellung"))
        await z.reconcile()
        await z.reconcile()
        #expect(serverValue() == "new", "without a restart and without a change to the record it stays down")
        #expect(z.rejected.isEmpty && z.pending == 0)
    }

    /// Gap 1, without news: after the ``ProfileZone/retryInterval`` deadline the
    /// record goes up again on the next call — not before, and never more than once per call.
    @Test("Without news: retry only after the deadline, and at most once per pass")
    func afterTheDeadline() async {
        server.refuse(contentType: "Newcomer")
        let gate = Holding(server.credential("alice"), isHolding: false)
        let z = zone(service: gate)
        var now = Date()
        z.clock = { now }
        z.write(message("n", "new"))
        await z.reconcile()
        #expect(gate.attempts(newcomer) == 1)

        await z.reconcile()
        #expect(gate.attempts(newcomer) == 1, "no hammering within the deadline")

        now += ProfileZone.retryInterval
        await z.reconcile()
        #expect(
            gate.attempts(newcomer) == 2, "exactly one attempt after the deadline, no loop within the pass")
        #expect(z.rejected[newcomer] != nil && z.pending == 0)

        server.refuse(contentType: "Newcomer", reason: nil)
        await z.reconcile()
        #expect(serverValue() == nil, "the deadline runs from the last attempt")
        now += ProfileZone.retryInterval
        await z.reconcile()
        #expect(serverValue() == "new")
        #expect(z.rejected.isEmpty && z.pending == 0)
    }

    /// Gap 2: another device writes the same record after the schema is there.
    /// The rejected state is a pending write request — the rule of the
    /// type applies, here ``MergeRule/newer``: the own, younger state wins.
    @Test("Downloading against a rejected, newer state: the own one wins and goes up")
    func downloadOwnNewer() async {
        server.refuse(contentType: "Newcomer")
        let file = FileManager.default.temporaryDirectory.appending(path: "cloud-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let iphone = zone(file: file)
        iphone.write(message("n", "local"), now: Date().addingTimeInterval(100))
        await iphone.reconcile()
        #expect(iphone.rejected[newcomer] != nil)

        server.refuse(contentType: "Newcomer", reason: nil)
        let ipad = zone()
        ipad.write(message("n", "foreign"))
        await ipad.reconcile()
        #expect(serverValue() == "foreign")

        await iphone.reconcile()
        #expect(value(iphone) == "local", "the newer state that never went up is gone")
        #expect(serverValue() == "local", "and it goes up in the same pass")
        #expect(iphone.rejected.isEmpty && iphone.pending == 0)
        #expect(zone(file: file).pending == 0, "the restart queues nothing more")
    }

    /// Gap 2, the other way round: the foreign state is younger and overwrites the one that
    /// never made it up — the note drops, nothing stays orphaned.
    @Test("Downloading against a rejected, older state: the foreign one wins, the note is dropped")
    func downloadForeignNewer() async {
        server.refuse(contentType: "Newcomer")
        let file = FileManager.default.temporaryDirectory.appending(path: "cloud-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let iphone = zone(file: file)
        iphone.write(message("n", "local"), now: Date().addingTimeInterval(-100))
        await iphone.reconcile()
        #expect(iphone.rejected[newcomer] != nil)

        server.refuse(contentType: "Newcomer", reason: nil)
        let ipad = zone()
        ipad.write(message("n", "foreign"))
        await ipad.reconcile()

        await iphone.reconcile()
        #expect(value(iphone) == "foreign")
        #expect(serverValue() == "foreign")
        #expect(iphone.rejected.isEmpty, "the note is still there although the record is now the foreign one")
        #expect(zone(file: file).pending == 0, "the restart queues the overwritten record again")
    }

    /// Gap 2, remote deletion: a rejected state is a pending
    /// write request and wins like any other against the other device's deletion.
    @Test("Remote deletion against a rejected state: the wish stays and goes up")
    func remoteDeletion() async {
        let iphone = zone()
        iphone.write(message("n", "old"))
        await iphone.reconcile()
        #expect(serverValue() == "old")

        server.refuse(contentType: "Newcomer")
        iphone.write(message("n", "local"))
        await iphone.reconcile()
        #expect(iphone.rejected[newcomer] != nil)

        server.refuse(contentType: "Newcomer", reason: nil)
        let ipad = zone()
        await ipad.reconcile()
        ipad.delete(contentType: "Newcomer", name: "n")
        await ipad.reconcile()
        #expect(server.content(serverZone).isEmpty)

        await iphone.reconcile()
        #expect(value(iphone) == "local")
        #expect(serverValue() == "local")
        #expect(iphone.rejected.isEmpty && iphone.pending == 0)
    }

    /// Gap 3: the record is changed while its old state is just coming
    /// back rejected — the newer change stays a request and goes up within the same call.
    @Test("Writing during the pass: the newer change does not fall out of the queue with the rejection")
    func raceWriteInFlight() async {
        server.refuse(contentType: "Newcomer")
        let gate = Holding(server.credential("alice"))
        let z = zone(service: gate)
        z.write(message("n", "old"))
        let run = Task { await z.reconcile() }
        await gate.waitForInFlight()
        server.refuse(contentType: "Newcomer", reason: nil)
        z.write(message("n", "new"))
        #expect(z.pending == 1)
        gate.next()
        await run.value

        #expect(serverValue() == "new", "the value new never goes up")
        #expect(z.rejected.isEmpty && z.pending == 0)
    }

    /// The same race with deletion: the record is gone, the rejection of its old
    /// state must not leave an orphaned note.
    @Test("Deleting during the pass: no orphaned note")
    func raceDeleteInFlight() async {
        server.refuse(contentType: "Newcomer")
        let gate = Holding(server.credential("alice"))
        let z = zone(service: gate)
        z.write(message("n", "old"))
        let run = Task { await z.reconcile() }
        await gate.waitForInFlight()
        z.delete(contentType: "Newcomer", name: "n")
        gate.next()
        await run.value

        #expect(value(z) == nil)
        #expect(z.rejected.isEmpty, "note for a record that no longer exists")
        #expect(z.pending == 0)
    }
}
