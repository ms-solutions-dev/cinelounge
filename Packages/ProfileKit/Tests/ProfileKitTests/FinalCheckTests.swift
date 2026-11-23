import CloudSync
import Core
import Foundation
import ParentalControls
import Testing

@testable import ProfileKit

/// **The findings of the final review of 2026-09-25, inverted** (strand E).
///
/// The review reproduced them on a copy (`PruefFinalTests`, P1–P4); there "red"
/// meant the finding stands. Here green means it is closed. Every test was red on the
/// state of `3248eba` — the evidence is in the commit.
@Suite("Final check: profile switch, merge, move notes")
@MainActor
struct FinalCheckTests {

    static let server = URL(string: "https://jf.example")!

    let cloudServer = MockCloud()

    func create(_ profile: Profile, in store: InMemoryStore) {
        var ledger = ProfileBook.read(from: store)
        ledger.create(profile)
        ledger.write(in: store)
    }

    func state(_ location: Double, forItem identifier: Profile.Identifier, in store: any KeyValueStore) {
        var ledger = StillLedger.read(from: store, forItem: identifier.rawValue)
        ledger.record(.titlePosition(title: "film", location: location, duration: 7200))
        ledger.write(in: store, forItem: identifier.rawValue)
    }

    func device(_ name: String) -> (cloud: ProfileCloud, store: InMemoryStore) {
        let store = InMemoryStore()
        let hub = CloudHub(
            service: cloudServer.credential("max", name: name), file: nil,
            device: DeviceDescription(identifier: name, name: name, model: "Test rig"))
        let cloud = ProfileCloud(hub: hub, store: store, moveBundle: nil, automatic: false)
        cloud.startStore = nil
        return (cloud, store)
    }

    // MARK: - N-1: Wechsel auf ein Profil ohne Medienserver

    /// **P4 inverted.** Kid has only one channel list; after the switch the
    /// parent's session was still in the Keychain, and the library showed their library.
    @Test("N-1: Switching to a profile without Jellyfin empties the session, not the list")
    func switchWithoutMediaServerClearsSession() throws {
        try ProfilePointer.als(nil) {
            let sharedStore = SecureStore(service: "abschluss.\(UUID().uuidString)")
            defer { try? sharedStore.clearCredentials() }
            try sharedStore.memorize(
                ServerCredentials(
                    serverURL: Self.server, userID: "papa", username: "Papa", accessToken: "marke"))
            try sharedStore.switchTo(server: Self.server, user: "papa")
            var papa = Profile(name: "Papa")
            papa.create(.jellyfin(server: Self.server, userID: "papa", username: "Papa"))
            var childProfile = Profile(name: "Selin", kind: .kind)
            childProfile.create(.channelList(identifier: "kids"))
            var ledger = ProfileBook()
            ledger.create(papa)
            ledger.create(childProfile)
            ledger.switchTo(zu: papa.identifier)

            let outcome = ProfileSwitch.switchTo(
                zu: childProfile.identifier, in: &ledger, keychain: sharedStore,
                deviceStore: InMemoryStore(), ledgerStore: InMemoryStore())

            #expect(outcome.result?.didSwitchSession == false)
            #expect((try? sharedStore.loadCredentials()) == nil, "Selin keeps running with Papa's session")
            #expect(sharedStore.allAccounts().count == 1, "the access list stays — this is not a sign-out")

            // And back to the parent: back without a new login.
            let back = ProfileSwitch.switchTo(
                zu: papa.identifier, in: &ledger, keychain: sharedStore,
                deviceStore: InMemoryStore(), ledgerStore: InMemoryStore())
            #expect(back.result?.didSwitchSession == true)
            #expect(try sharedStore.loadCredentials().userID == "papa")
        }
    }

    // MARK: - N-2: Kind ohne Konto in einem Erwachsenen

    /// **P3 umgekehrt.**
    @Test("N-2: A child without Jellyfin does not get Papa's account on merge")
    func childWithoutAccountGetsNone() {
        var kind = Profile(name: "Selin", kind: .kind)
        kind.create(.channelList(identifier: "kids"))
        var papa = Profile(name: "Papa")
        papa.create(.jellyfin(server: Self.server, userID: "papa", username: "Papa"))
        papa.create(.portals(person: "papa"))
        papa.create(.channelList(identifier: "papas-liste"))

        for result in [
            ProfileMerge.merge(kind, in: papa),
            ProfileMerge.merge(papa, in: kind),
        ] {
            #expect(result.kind == .kind)
            #expect(result.jellyfin == nil, "the child profile gets Papa's Jellyfin")
            #expect(result.portalPerson == nil, "and Papa's server person")
            #expect(result.credentials.contains(.channelList(identifier: "papas-liste")))
        }
    }

    /// **The same bug on the second path** — the name match at first iCloud contact.
    @Test("N-2: The name match also gives a child no foreign account")
    func nameMatchWithoutForeignAccount() {
        let kind = Profile(name: "Selin", kind: .kind)
        var adult = Profile(name: "Selin")
        adult.create(.jellyfin(server: Self.server, userID: "papa", username: "Papa"))
        let result = ProfileSync.merge(device: [adult], cloud: [kind])
        let childProfile = result.profile.first
        #expect(childProfile?.kind == .kind)
        #expect(childProfile?.jellyfin == nil)
    }

    @Test("N-2: The same identifier is the same person — their own account stays")
    func sameIDKeepsAccount() {
        var device = Profile(name: "Selin")
        device.create(.jellyfin(server: Self.server, userID: "selin", username: "Selin"))
        let cloud = Profile(identifier: device.identifier, name: "Selin", kind: .kind)
        let combined = ProfileSync.fuse(device: device, cloud: cloud)
        #expect(combined.kind == .kind)
        #expect(combined.jellyfin != nil)
    }

    // MARK: - C2-1: Target deleted

    /// **P1 umgekehrt.**
    @Test("C2-1: Note A→B with B deleted — A stays, B does not come back")
    func targetBuried() {
        let store = InMemoryStore()
        let a = Profile(name: "A-Selin", kind: .kind)
        let b = Profile.Identifier.fresh()
        create(a, in: store)
        state(100, forItem: a.identifier, in: store)
        let now = Date()

        let migrated = ProfileMove.episode(
            [
                .init(identifier: a.identifier, target: b, datum: now),
                .init(identifier: b, target: nil, datum: now.addingTimeInterval(60)),
            ], ledgerStore: store, keychain: nil, startStore: nil)

        let ledger = ProfileBook.read(from: store)
        #expect(migrated.isEmpty)
        #expect(
            !ledger.profile.contains { $0.identifier == b }, "A lives on under the deleted identifier B")
        #expect(ledger.profile.contains { $0.identifier == a.identifier })
        #expect(
            StillLedger.read(from: store, forItem: a.identifier.rawValue).state.titlePositions["film"]?
                .location == 100)
    }

    // MARK: - C2-2: Kreis

    /// **P2 umgekehrt.**
    @Test("C2-2: After a two-sided merge both devices carry the same identifier")
    func cycleAfterMutualMerge() {
        let dev1 = InMemoryStore()
        let dev2 = InMemoryStore()
        let a = Profile(name: "Max")
        let b = Profile(name: "Max")
        create(b, in: dev1)
        create(a, in: dev2)
        let now = Date()
        let notes: [ProfileTombstone.ContentEntryRecord] = [
            .init(identifier: a.identifier, target: b.identifier, datum: now),
            .init(identifier: b.identifier, target: a.identifier, datum: now.addingTimeInterval(1)),
        ]
        ProfileMove.episode(notes, ledgerStore: dev1, keychain: nil, startStore: nil)
        ProfileMove.episode(notes, ledgerStore: dev2, keychain: nil, startStore: nil)
        let k1 = ProfileBook.read(from: dev1).profile.map(\.identifier)
        let k2 = ProfileBook.read(from: dev2).profile.map(\.identifier)
        #expect(k1 == k2, "both devices should carry the same identifier")

        let winner = ProfileSync.wins(a.identifier, about: b.identifier) ? a.identifier : b.identifier
        #expect(k1 == [winner])
        let buried = Set(ProfileTombstone.applicable(notes).map { ProfileTombstone.norm($0.identifier) })
        #expect(buried == [ProfileTombstone.norm(winner == a.identifier ? b.identifier : a.identifier)])
    }

    // MARK: - C2-3: Verfall gegen die Serveruhr

    /// **The advanced clock on the device.** Advanced by half a year, and the zone of a
    /// removed profile was irrevocably gone — until then the device's clock sufficed.
    @Test("C2-3: A device clock set ahead deletes no zone and brings back no profile")
    func advancedClockDeletesNothing() async {
        let tv = device("fernseher")
        let grandmother = Profile(name: "Oma")
        create(Profile(name: "Max"), in: tv.store)
        create(grandmother, in: tv.store)
        let then = Date()
        cloudServer.clock = then
        await tv.cloud.syncAll()
        var ledger = ProfileBook.read(from: tv.store)
        ledger.remove(grandmother.identifier)
        ledger.write(in: tv.store)
        tv.cloud.bury(grandmother.identifier, now: then)
        await tv.cloud.household()?.reconcile()
        let grandmaZone = {
            self.cloudServer.zoneList().contains {
                $0.name.hasSuffix(grandmother.identifier.rawValue.lowercased())
            }
        }

        // The device's clock is 181 days ahead, the server's one hour.
        cloudServer.clock = then.addingTimeInterval(3600)
        let advanced = then.addingTimeInterval(181 * 86_400)
        #expect(await tv.cloud.find(now: advanced).isEmpty, "Oma came back")
        await tv.cloud.household()?.reconcile()
        #expect(await tv.cloud.find(now: advanced).isEmpty, "Oma came back")
        await tv.cloud.household()?.reconcile()
        #expect(grandmaZone(), "the zone is deleted although it has been buried for only an hour")

        // A second device with the right clock does not find the removed profile either.
        let phone = device("telefon")
        #expect(
            await !phone.cloud.find(now: then.addingTimeInterval(7200)).contains {
                $0.identifier == grandmother.identifier
            })
    }

    @Test("C2-3: After 180 days on the server the zone goes with the note")
    func expiryOnServer() async {
        let tv = device("fernseher")
        let grandmother = Profile(name: "Oma")
        create(Profile(name: "Max"), in: tv.store)
        create(grandmother, in: tv.store)
        let then = Date()
        cloudServer.clock = then
        await tv.cloud.syncAll()
        var ledger = ProfileBook.read(from: tv.store)
        ledger.remove(grandmother.identifier)
        ledger.write(in: tv.store)
        tv.cloud.bury(grandmother.identifier, now: then)
        await tv.cloud.household()?.reconcile()
        let grandmaZone = {
            self.cloudServer.zoneList().contains {
                $0.name.hasSuffix(grandmother.identifier.rawValue.lowercased())
            }
        }

        let later = then.addingTimeInterval(181 * 86_400)
        cloudServer.clock = later
        // First startup: expired by the device, not yet proven on the server —
        // the clock record goes up.
        #expect(await tv.cloud.find(now: later).isEmpty)
        await tv.cloud.household()?.reconcile()
        // Second startup: The clock record carries the server date, the proof stands.
        #expect(await tv.cloud.find(now: later).isEmpty, "Oma came back after expiry")
        await tv.cloud.household()?.reconcile()
        #expect(!grandmaZone())
        #expect(ProfileTombstone.all(from: tv.store).isEmpty)
        let stillRemote = ProfileTombstone.entries(
            from: tv.cloud.household()?.read(ProfileTombstone.contentType) ?? [])
        #expect(stillRemote.isEmpty)
    }

    @Test("C2-3: A note from the future counts as now")
    func futureCountsAsNow() throws {
        let store = InMemoryStore()
        let now = Date()
        let route = Profile.Identifier.fresh()
        ProfileTombstone.create(route, now: now.addingTimeInterval(400 * 86_400), in: store)
        ProfileTombstone.cleanUp(now: now, in: store)
        #expect(ProfileTombstone.all(from: store).first?.datum == now)
        #expect(
            ProfileTombstone.cleanUp(now: now.addingTimeInterval(181 * 86_400), in: store).map(\.identifier)
                == [route])
    }

    // MARK: - B-2: Sprache von fern

    @Test("B-2: A language arriving via iCloud is reported")
    func remoteLanguageIsReported() async {
        let identifier = Profile.Identifier(rawValue: UUID().uuidString)
        let person = Profile(identifier: identifier, name: "Max")
        func preferenceDevice(_ name: String) -> (ProfileCloud, InMemoryStore) {
            let (cloud, store) = device(name)
            let sharedStore = InMemoryStore()
            cloud.preferenceStore = sharedStore
            create(person, in: store)
            return (cloud, sharedStore)
        }
        let (tv, bundTV) = preferenceDevice("fernseher")
        try? bundTV.set(
            "tr", for: ProfileStore.bucket(AppLanguageSetting.key, forItem: identifier.rawValue))
        await tv.reconcile(person)

        let (phone, bundPhone) = preferenceDevice("telefon")
        let reported = TallyCounter()
        let observers = NotificationCenter.default.addObserver(
            forName: AppLanguageSetting.changed, object: identifier.rawValue, queue: nil
        ) { _ in reported.tally() }
        defer { NotificationCenter.default.removeObserver(observers) }
        await phone.reconcile(person)

        #expect(
            (try? bundPhone.value(
                for: ProfileStore.bucket(AppLanguageSetting.key, forItem: identifier.rawValue)))
                == "tr")
        #expect(reported.value > 0, "the language applies only after a restart")
    }
}

/// A counter that a notification may increment from any thread.
final class TallyCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var state = 0
    func tally() { lock.withLock { state += 1 } }
    var value: Int { lock.withLock { state } }
}
