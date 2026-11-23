import Core
import Foundation
import ParentalControls
import Testing

@testable import ProfileKit

/// **Three changeovers in one move — and the proof that before it was one.**
@Suite("The profile switch")
struct ProfileSwitchTests {

    private static let server = URL(string: "https://vault.example:8096")!

    /// A separate Keychain per check — otherwise it reaches into the device's.
    private static func sharedStore() -> SecureStore {
        SecureStore(service: "probe.\(UUID().uuidString)")
    }

    private static func credential(_ name: String) -> Access {
        .jellyfin(server: server, userID: name.lowercased(), username: name)
    }

    private static func enter(_ sharedStore: SecureStore, _ name: String) {
        try? sharedStore.memorize(
            ServerCredentials(
                serverURL: server, userID: name.lowercased(), username: name,
                accessToken: "marke-\(name)"))
    }

    @Test("The switch changes session and portal header at the same time")
    func bothInOneGo() throws {
        try ProfilePointer.als(nil) {
            let sharedStore = Self.sharedStore()
            let device = InMemoryStore()
            Self.enter(sharedStore, "Max")
            Self.enter(sharedStore, "Zweit")

            var parents = Profile(name: "Max")
            parents.create(Self.credential("Max"))
            parents.create(.portals(person: "person-1"))
            var second = Profile(name: "Zweit")
            second.create(Self.credential("Zweit"))
            second.create(.portals(person: "person-2"))

            var ledger = ProfileBook()
            ledger.create(parents)
            ledger.create(second)

            let result = try #require(
                ProfileSwitch.switchTo(
                    zu: second.identifier, in: &ledger, keychain: sharedStore, deviceStore: device,
                    ledgerStore: InMemoryStore()
                ).result)

            #expect(result.didSwitchSession)
            #expect(try sharedStore.loadCredentials().userID == "zweit")
            #expect(DeviceTrait.profile(from: device) == "person-2")
            #expect(ledger.activeProfile?.name == "Zweit")
        }
    }

    /// **The bug that would exist without this line:** Anyone switching from a profile with a
    /// household person to one without would keep running under the old one's person —
    /// and the server answers readily, just for the wrong one.
    @Test("A profile without a portal person removes the header")
    func headDrops() {
        ProfilePointer.als(nil) {
            let sharedStore = Self.sharedStore()
            let device = InMemoryStore()
            DeviceTrait.saveProfile("person-1", to: device)

            var without = Profile(name: "Ohne")
            var ledger = ProfileBook()
            without.create(.channelList(identifier: "iptv"))
            ledger.create(without)

            let outcome = ProfileSwitch.switchTo(
                zu: without.identifier, in: &ledger, keychain: sharedStore, deviceStore: device,
                ledgerStore: InMemoryStore())

            #expect(outcome.result != nil)
            // Since 2026-09-28 the head belongs to the profile — its compartment is read.
            #expect(
                DeviceTrait.profile(from: ProfileStore(device, forItem: without.identifier.rawValue)) == nil)
        }
    }

    /// **A profile without a Jellyfin server is a valid profile.** The switch has
    /// happened; the library is missing, and the state says so.
    @Test("It switches even without a media server")
    func withoutMediaServer() throws {
        try ProfilePointer.als(nil) {
            let sharedStore = Self.sharedStore()
            var listOnly = Profile(name: "Liste")
            listOnly.create(.channelList(identifier: "iptv"))
            var ledger = ProfileBook()
            ledger.create(listOnly)

            let result = try #require(
                ProfileSwitch.switchTo(
                    zu: listOnly.identifier, in: &ledger, keychain: sharedStore,
                    deviceStore: InMemoryStore(), ledgerStore: InMemoryStore()
                ).result)

            #expect(result.didSwitchSession == false)
            #expect(ledger.state.showsLibrary == false)
            #expect(ledger.state.showsLive)
        }
    }

    /// **If switching the session fails, it is still clear who is sitting in front.**
    /// Otherwise the app would show one person's library under the other's
    /// name.
    @Test("A missing Keychain entry still lets the book switch")
    func sessionMissingBookSwitchesAnyway() throws {
        try ProfilePointer.als(nil) {
            let sharedStore = Self.sharedStore()
            var first = Profile(name: "Erste")
            first.create(Self.credential("Erste"))
            var second = Profile(name: "Zweite")
            second.create(Self.credential("Zweite"))
            var ledger = ProfileBook()
            ledger.create(first)
            ledger.create(second)

            let result = try #require(
                ProfileSwitch.switchTo(
                    zu: second.identifier, in: &ledger, keychain: sharedStore,
                    deviceStore: InMemoryStore(), ledgerStore: InMemoryStore()
                ).result)

            #expect(result.didSwitchSession == false)
            #expect(ledger.activeProfile?.name == "Zweite")
        }
    }

    /// **A switch that nobody stores lasts until the next start.** Then the previous person
    /// is sitting in front again, without anyone having done anything.
    @Test("The switch survives a program run")
    func switchIsFiled() {
        ProfilePointer.als(nil) {
            let bucket = InMemoryStore()
            var first = Profile(name: "Erste")
            first.create(.portals(person: "a"))
            let second = Profile(name: "Zweite")
            var ledger = ProfileBook()
            ledger.create(first)
            ledger.create(second)
            ledger.write(in: bucket)

            _ = ProfileSwitch.switchTo(
                zu: second.identifier, in: &ledger, keychain: Self.sharedStore(),
                deviceStore: InMemoryStore(), ledgerStore: bucket)

            #expect(ProfileBook.read(from: bucket).activeProfile?.name == "Zweite")
        }
    }

    /// **The E85 check: "switch without reloading the posters".**
    ///
    /// It cannot be tested here as "the picture is still there" — this type knows
    /// neither image downloads nor snapshots. What can be tested is the cause: **It touches exactly
    /// one key.** If a cleanup were ever added, there would be a
    /// second one here, and this line turns red before anyone sees an empty shelf
    /// on the TV.
    @Test("The switch touches exactly one key on the device")
    func onlyOneKey() {
        ProfilePointer.als(nil) {
            let transcript = Recorder()
            var first = Profile(name: "Erste")
            first.create(Self.credential("Erste"))
            first.create(.portals(person: "a"))
            let second = Profile(name: "Zweite")
            var ledger = ProfileBook()
            ledger.create(first)
            ledger.create(second)

            _ = ProfileSwitch.switchTo(
                zu: second.identifier, in: &ledger, keychain: Self.sharedStore(),
                deviceStore: transcript, ledgerStore: InMemoryStore())

            // **Since AP47 a second one is read** — the flag "device belongs to a
            // person" decides whether the head is written. Deliberately changed here: It
            // is only read, no cleanup was added.
            // Since 2026-09-28 in the target's compartment (``Core/DeviceTrait``).
            let bucket = { ProfileStore.bucket($0, forItem: second.identifier.rawValue) }
            #expect(transcript.touched == [bucket(DeviceTrait.profileKey), bucket(DeviceTrait.ownKey)])
        }
    }

    // MARK: - The PIN per profile (AP41, row 4)

    /// **The latch sits in the switch and not in front of it.** Putting it in the caller
    /// would mean forgetting it in one of five places — and a lock that is missing in one
    /// place is no lock. The same finding as with the door board in AP40, only one
    /// level higher.
    @Test("A profile with a PIN lets nobody in without it")
    func pinRequired() {
        ProfilePointer.als(nil) {
            let sharedStore = Self.sharedStore()
            var shielded = Profile(name: "Max")
            shielded.create(.portals(person: "a"))
            let pending = Profile(name: "Gast")
            var ledger = ProfileBook()
            ledger.create(pending)
            ledger.create(shielded)
            ProfilePIN(store: sharedStore, forItem: shielded.identifier).set("1234", now: Date())

            let device = InMemoryStore()
            let without = ProfileSwitch.switchTo(
                zu: shielded.identifier, in: &ledger, keychain: sharedStore, deviceStore: device,
                ledgerStore: InMemoryStore())

            #expect(without == .pinRequired)
            // **Checking happens before anything is switched.** A switch that first rewrites the
            // ledger and only then asks for the PIN has already put the foreign name on the
            // screen.
            #expect(ledger.activeProfile?.name == "Gast")
            #expect(DeviceTrait.profile(from: device) == nil)

            let wrong = ProfileSwitch.switchTo(
                zu: shielded.identifier, in: &ledger, keychain: sharedStore, deviceStore: device,
                ledgerStore: InMemoryStore(), pin: "0000")
            #expect(wrong == .wrongPin, "wrong is not missing — and changes nothing either")
            #expect(ledger.activeProfile?.name == "Gast")
            #expect(DeviceTrait.profile(from: device) == nil)

            let correct = ProfileSwitch.switchTo(
                zu: shielded.identifier, in: &ledger, keychain: sharedStore, deviceStore: device,
                ledgerStore: InMemoryStore(), pin: "1234")
            #expect(correct.result?.profile.name == "Max")
        }
    }

    /// **Optional means optional.** A profile without its own PIN does not ask — and a
    /// PIN passed along does not bother it.
    @Test("A profile without a PIN does not ask")
    func noPinNoQuestion() {
        ProfilePointer.als(nil) {
            let sharedStore = Self.sharedStore()
            let person = Profile(name: "Max")
            var ledger = ProfileBook()
            ledger.create(Profile(name: "Erste"))
            ledger.create(person)

            let outcome = ProfileSwitch.switchTo(
                zu: person.identifier, in: &ledger, keychain: sharedStore,
                deviceStore: InMemoryStore(), ledgerStore: InMemoryStore())

            #expect(outcome.result?.profile.name == "Max")
        }
    }

    /// **Two jobs, two keys.** The device PIN opens the locked doors;
    /// a profile PIN locks entry to that profile. One PIN for both would mean
    /// that anyone who protects their own access changes the household's parental controls.
    @Test("The device PIN is not the profile PIN")
    func twoKinds() {
        let sharedStore = Self.sharedStore()
        let person = Profile(name: "Max")
        Pin(store: sharedStore).set("1111")

        #expect(ProfilePIN(store: sharedStore, forItem: person.identifier).isSet == false)
        #expect(Pin(store: sharedStore).matches("1111"))

        ProfilePIN(store: sharedStore, forItem: person.identifier).set("2222", now: Date())
        #expect(Pin(store: sharedStore).matches("1111"))
        #expect(ProfilePIN(store: sharedStore, forItem: person.identifier).matches("2222"))
        #expect(ProfilePIN(store: sharedStore, forItem: person.identifier).matches("1111") == false)
    }

    /// A compartment that remembers which keys were touched at all.
    private final class Recorder: KeyValueStore, @unchecked Sendable {
        private(set) var touched: Set<String> = []
        private var values: [String: String] = [:]

        func set(_ value: String, for key: String) throws {
            touched.insert(key)
            values[key] = value
        }

        func value(for key: String) throws -> String {
            touched.insert(key)
            guard let value = values[key] else { throw SecureStore.Failure.notFound }
            return value
        }

        func remove(_ key: String) throws {
            touched.insert(key)
            values.removeValue(forKey: key)
        }
    }

    /// **The line that would be forgotten everywhere else** (AP42, 2026-09-21). One can switch
    /// from the switcher, from Settings and — on the phone — from setup;
    /// if switching the pointer lived with the callers, the forgetful one would write the
    /// new person's state into the old person's ledger.
    @Test("The switch moves the profile pointer")
    func switchesThePointer() {
        var ledger = ProfileBook()
        let parents = Profile(name: "Eltern")
        let kind = Profile(name: "Kind", kind: .kind)
        ledger.create(parents)
        ledger.create(kind)

        // **In a pointer of its own for this run**, see ``Core/ProfilePointer/als(_:_:)``.
        // The first draft wrote the process-wide one — and turned red because a
        // neighbouring check in the same file also switches.
        ProfilePointer.als(nil) {
            let outcome = ProfileSwitch.switchTo(
                zu: kind.identifier, in: &ledger, keychain: Self.sharedStore(),
                deviceStore: InMemoryStore(), ledgerStore: InMemoryStore())

            #expect(outcome.result != nil)
            #expect(ProfilePointer.active == kind.identifier.rawValue)
        }
    }

    /// **A failed switch must not touch the pointer.** Otherwise the app would read the
    /// state of a person it never switched to.
    @Test("A rejected switch leaves the pointer alone")
    func rejectedLeavesThePointer() {
        var ledger = ProfileBook()
        ledger.create(Profile(name: "Erste"))

        ProfilePointer.als(nil) {
            _ = ProfileSwitch.switchTo(
                zu: .fresh(), in: &ledger, keychain: Self.sharedStore(),
                deviceStore: InMemoryStore(), ledgerStore: InMemoryStore())

            #expect(ProfilePointer.active == nil)
        }
    }

    @Test("An unknown profile changes nothing")
    func unknown() {
        ProfilePointer.als(nil) {
            let device = InMemoryStore()
            DeviceTrait.saveProfile("person-1", to: device)
            var first = Profile(name: "Erste")
            first.create(.portals(person: "person-1"))
            var ledger = ProfileBook()
            ledger.create(first)

            let outcome = ProfileSwitch.switchTo(
                zu: .fresh(), in: &ledger, keychain: Self.sharedStore(), deviceStore: device,
                ledgerStore: InMemoryStore())

            #expect(outcome == .unknown)
            #expect(ledger.activeProfile?.name == "Erste")
            #expect(DeviceTrait.profile(from: device) == "person-1")
        }
    }
}
