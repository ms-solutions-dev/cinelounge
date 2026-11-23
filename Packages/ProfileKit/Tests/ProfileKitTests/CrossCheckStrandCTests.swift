import CloudSync
import Core
import Foundation
import ParentalControls
import Testing

@testable import ProfileKit

/// **The reproductions of the cross-check of strand C, turned around** (strand C2, 2026-09-25).
///
/// The review reproduced every finding as a test suite that **shows** the bug. Here
/// stands the same event with the expectation that should hold — every test was red on the
/// state of `0c9d4db` and is no longer after the fix.
///
/// **The IDs are fixed and not randomly generated.** In the name match, since C2 the
/// lexicographically smaller ID wins (``ProfileSync/wins(_:about:)``); with randomly generated
/// IDs every run would check only one of the two directions, and which one would be
/// decided by chance. That is why the tests where it matters run **in both**.
@Suite("Counter-check strand C: move, tombstone, winner")
@MainActor
struct CrossCheckStrandCTests {

    let server = MockCloud()

    static let lowercased = Profile.Identifier(rawValue: "00000000-0000-4000-8000-000000000001")
    static let large = Profile.Identifier(rawValue: "FFFFFFFF-0000-4000-8000-000000000002")

    func device(
        _ name: String, store: InMemoryStore = InMemoryStore(), sharedStore: InMemoryStore? = nil,
        folder: URL? = nil
    ) -> (cloud: ProfileCloud, store: InMemoryStore) {
        let hub = CloudHub(
            service: server.credential("max"), file: nil,
            device: DeviceDescription(identifier: name, name: name, model: "Test rig"))
        let cloud = ProfileCloud(
            hub: hub, store: store, moveBundle: sharedStore, mirrorFolder: folder,
            automatic: false)
        cloud.startStore = nil
        return (cloud, store)
    }

    func create(_ profile: Profile, in store: InMemoryStore) {
        var ledger = ProfileBook.read(from: store)
        ledger.create(profile)
        ledger.write(in: store)
    }

    func state(
        _ title: String, _ location: Double, forItem identifier: Profile.Identifier, in store: InMemoryStore
    ) {
        var ledger = StillLedger.read(from: store, forItem: identifier.rawValue)
        ledger.record(.titlePosition(title: title, location: location, duration: 7200))
        ledger.write(in: store, forItem: identifier.rawValue)
    }

    func location(_ title: String, _ identifier: Profile.Identifier, _ store: InMemoryStore) -> Double? {
        StillLedger.read(from: store, forItem: identifier.rawValue).state.titlePositions[title]?.location
    }

    func identifiers(_ store: InMemoryStore) -> [Profile.Identifier] {
        ProfileBook.read(from: store).profile.map(\.identifier)
    }

    // MARK: - R1 / R1b: kein Pendeln, ein Sieger

    /// R1: One device, three starts. **The ID oscillated** — the next start found
    /// the migrated one's zone again because it got no tombstone.
    @Test("R1 One device, three starts: the identifier does not oscillate", arguments: [true, false])
    func r1_noOscillation(cloudWins: Bool) async throws {
        let kPh = cloudWins ? Self.lowercased : Self.large
        let kTv = cloudWins ? Self.large : Self.lowercased
        let winner = Self.lowercased

        let phone = device("telefon")
        create(Profile(identifier: kPh, name: "Max"), in: phone.store)
        state("film", 1000, forItem: kPh, in: phone.store)
        await phone.cloud.syncAll()

        let folder = FileManager.default.temporaryDirectory.appending(
            path: "c2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tv = device("fernseher", folder: folder)
        create(Profile(identifier: kTv, name: "Max"), in: tv.store)
        state("film", 4000, forItem: kTv, in: tv.store)
        await tv.cloud.syncAll()

        // Start 1
        tv.cloud.adopt(await tv.cloud.find())
        #expect(identifiers(tv.store) == [winner], "start 1: the smaller identifier wins")
        await tv.cloud.syncAll()

        // A third device of the same Apple ID finds only the winner — the tombstone
        // in the household zone, not only the one on the TV.
        await tv.cloud.household()?.reconcile()
        let third = device("dritte")
        #expect((await third.cloud.find()).map(\.identifier) == [winner], "the abandoned zone is found")

        // Start 2 and 3 — new app run, same mirror folder.
        for _ in 0..<2 {
            let fresh = device("fernseher", store: tv.store, folder: folder)
            let found = await fresh.cloud.find()
            #expect(found.isEmpty, "the loser's zone is found again")
            fresh.cloud.adopt(found)
            await fresh.cloud.syncAll()
            #expect(identifiers(tv.store) == [winner], "the identifier oscillates")
        }
        // The earlier place wins, and nothing is left under the loser.
        #expect(location("film", winner, tv.store) == 1000)
        #expect(StillLedger.read(from: tv.store, forItem: (cloudWins ? kTv : kPh).rawValue) == StillLedger())
    }

    /// R1b: Two devices, both already up. **They swapped their IDs** instead of
    /// agreeing — each took the other's.
    @Test("R1b Two devices agree on the same identifier", arguments: [true, false])
    func r1b_agreement(tvFirst: Bool) async {
        let phone = device("telefon")
        create(Profile(identifier: Self.large, name: "Max"), in: phone.store)
        await phone.cloud.syncAll()
        let tv = device("fernseher")
        create(Profile(identifier: Self.lowercased, name: "Max"), in: tv.store)
        await tv.cloud.syncAll()

        let row = tvFirst ? [tv, phone] : [phone, tv]
        for g in row { g.cloud.adopt(await g.cloud.find()) }
        #expect(identifiers(tv.store) == [Self.lowercased])
        #expect(identifiers(phone.store) == [Self.lowercased], "the devices swap their identifiers")
    }

    // MARK: - R2: Tombstone with target on the other device

    @Test("R2 Merge on the TV: the phone follows, the progress reaches the merged profile")
    func r2_tombstoneTargetApplied() async throws {
        let tv = device("fernseher")
        let papa = Profile(name: "Papa")
        let max = Profile(name: "Max")
        create(max, in: tv.store)
        create(papa, in: tv.store)
        await tv.cloud.syncAll()

        let phone = device("telefon")
        phone.cloud.adopt(await phone.cloud.find())
        await phone.cloud.syncAll()
        #expect(Set(identifiers(phone.store)) == [papa.identifier, max.identifier])

        let outcome = ProfileMerge.perform(
            papa.identifier, in: max.identifier, ledgerStore: tv.store, keychain: InMemoryStore(),
            startStore: nil, cloud: tv.cloud)
        guard case .merged = outcome else {
            Issue.record("not merged: \(outcome)")
            return
        }
        await tv.cloud.household()?.reconcile()
        await tv.cloud.syncAll()

        // Phone: the silent push on the household zone — it already catches up.
        await phone.cloud.household()?.reconcile()
        #expect(identifiers(phone.store) == [max.identifier], "Papa is still on the phone")
        await phone.cloud.syncAll()

        // A player that still books under the parent (it was already running when the note came).
        state("film", 3000, forItem: papa.identifier, in: phone.store)
        await phone.cloud.syncAll()

        await tv.cloud.syncAll()
        #expect(
            location("film", max.identifier, tv.store) == 3000,
            "the progress never reaches the merged profile")
    }

    // MARK: - R3 / R4: Absturz zwischen Buch und Umzug

    /// R3: First contact. **Since C2 the note comes before the book** — a crash afterwards
    /// leaves note and book, and the next run catches up the move.
    @Test("R3 First contact: crashed after note and book — the next run catches up")
    func r3_crashBetweenBookAndMove() async throws {
        let (cloud, store) = device("fernseher")
        let here = Profile(identifier: Self.large, name: "Max")
        create(here, in: store)
        state("film", 4000, forItem: here.identifier, in: store)
        let top = Profile(identifier: Self.lowercased, name: "max")

        // What ``ProfileCloud/adopt(_:)`` does up to the crash: note, then book.
        ProfileTombstone.create(here.identifier, target: top.identifier, in: store)
        _ = ProfileSync.adopt(cloud: [top], in: store)
        #expect(identifiers(store) == [top.identifier])

        // Next start: the same cloud profiles come again.
        _ = cloud.adopt([top])
        #expect(location("film", top.identifier, store) == 4000, "the move is not repeatable")
        #expect(StillLedger.read(from: store, forItem: here.identifier.rawValue) == StillLedger())
    }

    /// R4: Merging by hand, crash after note and book.
    @Test("R4 Merge: crashed after the book — a second call completes it")
    func r4_mergeCrash() throws {
        let store = InMemoryStore()
        let sharedStore = InMemoryStore()
        let papa = Profile(name: "Papa")
        let max = Profile(name: "Max")
        create(max, in: store)
        create(papa, in: store)
        state("film", 900, forItem: papa.identifier, in: store)
        ProfilePIN(store: sharedStore, forItem: papa.identifier).set("1234", now: Date())

        // What fuehreAus does up to the crash: note, then book without the parent.
        ProfileTombstone.create(papa.identifier, target: max.identifier, in: store)
        var ledger = ProfileBook.read(from: store)
        ledger.remove(papa.identifier)
        ledger.write(in: store)

        let outcome = ProfileMerge.perform(
            papa.identifier, in: max.identifier, pins: [papa.identifier: "1234"], ledgerStore: store,
            keychain: sharedStore, startStore: nil, cloud: nil)
        guard case .merged = outcome else {
            Issue.record("not completed: \(outcome)")
            return
        }
        #expect(StillLedger.read(from: store, forItem: papa.identifier.rawValue) == StillLedger())
        #expect(location("film", max.identifier, store) == 900)
        #expect(!ProfilePIN(store: sharedStore, forItem: papa.identifier).isSet)
        #expect(ProfilePIN(store: sharedStore, forItem: max.identifier).isSet)
        #expect(ProfileTombstone.all(from: store).map(\.identifier) == [papa.identifier])
    }

    // MARK: - R5 (Befund 4): der Medienserver des Kindes

    @Test("R5 Child merges into adult: kind child and the child's Jellyfin")
    func r5_childKeepsServerAccount() {
        let srv = URL(string: "https://vault.example:8096")!
        var papa = Profile(name: "Papa")
        papa.create(.jellyfin(server: srv, userID: "papa", username: "Papa"))
        var kind = Profile(name: "Selin", kind: .kind)
        kind.create(.jellyfin(server: srv, userID: "selin", username: "Selin"))
        let combined = ProfileMerge.merge(kind, in: papa)
        #expect(combined.kind == .kind)
        #expect(combined.jellyfin == kind.jellyfin, "the child would see the father's library")
        #expect(combined.identifier == papa.identifier)
    }

    // MARK: - R6: das Journal

    @Test("R6 Move twice: the journal does not double")
    func r6_journalSimple() {
        let store = InMemoryStore()
        let a = Profile.Identifier.fresh()
        let b = Profile.Identifier.fresh()
        state("film", 100, forItem: a, in: store)
        state("film", 50, forItem: b, in: store)
        let source = StillLedger.read(from: store, forItem: a.rawValue)
        ProfileMove.migrate(from: a, after: b, ledgerStore: store, keychain: nil, startStore: nil)
        let n1 = StillLedger.read(from: store, forItem: b.rawValue).journal.count
        // The source once more, as it stood before being emptied (crash, retry).
        source.write(in: store, forItem: a.rawValue)
        ProfileMove.migrate(from: a, after: b, ledgerStore: store, keychain: nil, startStore: nil)
        #expect(StillLedger.read(from: store, forItem: b.rawValue).journal.count == n1)
    }

    // MARK: - R7: Network outage (was green, stays as a guard)

    @Test("R7 Network outage while finding: nothing found, then everything")
    func r7_networkDropout() async {
        let tv = device("fernseher")
        create(Profile(name: "Max"), in: tv.store)
        create(Profile(name: "Oma"), in: tv.store)
        await tv.cloud.syncAll()
        let phone = device("telefon")
        server.reachable = false
        let found = await phone.cloud.find()
        server.reachable = true
        #expect(found.isEmpty)
        #expect(await phone.cloud.find().count == 2)
    }
}
