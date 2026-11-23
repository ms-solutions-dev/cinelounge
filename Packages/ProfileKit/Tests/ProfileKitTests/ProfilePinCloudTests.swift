import CloudSync
import Core
import Foundation
import ParentalControls
import Testing

@testable import ProfileKit

/// The profile PIN via iCloud (AP52, owner decision 12) — **two devices on one
/// ``CloudSync/MockCloud``**, without network and without an account.
///
/// Every check here has had its control test on the connection: Without the PIN branch in
/// ``ProfileCloud/download(_:)`` nothing arrives on the second device, without
/// ``ProfileCloud/passOnPin(_:from:)`` nothing goes upward, with the type among the cleared ones
/// an old device clears it, with plain text instead of a derivation the digits show up in the
/// raw bytes.
@Suite("The profile PIN in the cloud")
@MainActor
struct ProfilePinCloudTests {

    let server = MockCloud()
    let person = Profile(name: "Max")

    /// Fixed times — **also so that no time of day happens to contain "4711" in the raw bytes.**
    let early = Date(timeIntervalSince1970: 1_000_000)
    let late = Date(timeIntervalSince1970: 2_000_000)

    struct Device {
        let cloud: ProfileCloud
        let store: InMemoryStore
        let sharedStore: any KeyValueStore
        var pin: (Profile.Identifier) -> ProfilePIN { { ProfilePIN(store: sharedStore, forItem: $0) } }
    }

    func device(_ name: String, sharedStore: any KeyValueStore = InMemoryStore()) -> Device {
        let store = InMemoryStore()
        let hub = CloudHub(
            service: server.credential("max"), file: nil,
            device: DeviceDescription(identifier: name, name: name, model: "Test rig"))
        let cloud = ProfileCloud(
            hub: hub, store: store, moveBundle: sharedStore, automatic: false)
        cloud.startStore = nil
        var ledger = ProfileBook.read(from: store)
        ledger.create(person)
        ledger.write(in: store)
        return Device(cloud: cloud, store: store, sharedStore: sharedStore)
    }

    /// What the server holds in the profile's zone.
    func top() throws -> [CloudRecord] {
        let name = try #require(ProfileMapping.zone(forItem: person.identifier)).name
        let zone = try #require(server.zoneList().first { $0.name == name })
        return server.content(zone)
    }

    func run(_ device: Device) async {
        await device.cloud.reconcile(person)
    }

    func set(
        _ digits: String, old: String? = nil, to device: Device, now: Date
    )
        -> ProfilePINMaintenance.SwitchOutcome
    {
        ProfilePINMaintenance.set(
            digits, old: old, forItem: person.identifier, keychain: device.sharedStore,
            cloud: device.cloud, now: now)
    }

    // MARK: - Round trip

    /// **The sentence from the decision:** set on the TV, required on the second device —
    /// checked on the latch itself (``ProfileSwitch``), not on a helper value.
    @Test("Set on the TV, required on the second device")
    func setIsRequired() async throws {
        let tv = device("fernseher")
        #expect(set("4711", to: tv, now: early) == .isSet)
        await run(tv)

        let keychain = SecureStore(service: "probe.\(UUID().uuidString)")
        defer { ProfilePIN(store: keychain, forItem: person.identifier).forget() }
        let phone = device("telefon", sharedStore: keychain)
        await run(phone)

        let (without, using) = ProfilePointer.als(nil) {
            var ledger = ProfileBook.read(from: phone.store)
            let without = ProfileSwitch.switchTo(
                zu: person.identifier, in: &ledger, keychain: keychain,
                deviceStore: InMemoryStore(), ledgerStore: phone.store)
            let using = ProfileSwitch.switchTo(
                zu: person.identifier, in: &ledger, keychain: keychain,
                deviceStore: InMemoryStore(), ledgerStore: phone.store, pin: "4711")
            return (without, using)
        }
        #expect(without == .pinRequired, "the TV's PIN must be required on the other device")
        #expect(try #require(using.result).profile.identifier == person.identifier)
    }

    @Test("Once removed it is gone over there too — as a tombstone, not as a gap")
    func removedIsGone() async throws {
        let tv = device("fernseher")
        let phone = device("telefon")
        _ = set("4711", to: tv, now: early)
        await run(tv)
        await run(phone)
        #expect(phone.pin(person.identifier).isSet)

        let outcome = ProfilePINMaintenance.remove(
            old: "4711", forItem: person.identifier, keychain: tv.sharedStore,
            cloud: tv.cloud, now: late)
        #expect(outcome == .removed)
        await run(tv)
        await run(phone)

        #expect(!phone.pin(person.identifier).isSet)
        #expect(phone.pin(person.identifier).entry?.verifier == nil)
        #expect(phone.pin(person.identifier).entry?.time == late)
        let top = try top()
        #expect(
            ProfilePINMapping.entry(from: top)?.isSet == false,
            "\"no PIN\" is stored as a record in the cloud and not as an absence")
    }

    /// **Changed offline against each other:** Both know the same PIN and change it without
    /// knowing about each other. The change that was in the cloud first wins — the
    /// other overlooked it (``ProfilePIN/ContentEntryRecord/overlooks(_:)``, check of 2026-09-25
    /// evening). Until then the younger one won.
    @Test("Changed against each other offline, the first one in the cloud wins", arguments: [true, false])
    func firstChangeApplies(newerFirst: Bool) async {
        let tv = device("fernseher")
        let phone = device("telefon")
        _ = set("1111", to: tv, now: early)
        await run(tv)
        await run(phone)
        _ = set("2222", old: "1111", to: tv, now: early.addingTimeInterval(60))
        _ = set("3333", old: "1111", to: phone, now: late)

        if newerFirst {
            await run(phone)
            await run(tv)
        } else {
            await run(tv)
            await run(phone)
        }
        await run(tv)
        await run(phone)

        let applies = newerFirst ? "3333" : "2222"
        let fails = newerFirst ? "2222" : "3333"
        for device in [tv, phone] {
            #expect(device.pin(person.identifier).matches(applies))
            #expect(!device.pin(person.identifier).matches(fails))
        }
    }

    /// **A first PIN set offline against each other:** Neither has seen the other's
    /// (``ProfilePIN/ContentEntryRecord/overlooks(_:)``, check of 2026-09-25 evening). The one that was
    /// in the cloud first wins — until then the younger one won, and so a
    /// device that merely had not reconciled beat a PIN that had long been distributed.
    @Test("Set against each other offline, the first one in the cloud wins", arguments: [true, false])
    func firstInCloudApplies(newerFirst: Bool) async {
        let tv = device("fernseher")
        let phone = device("telefon")
        _ = set("1111", to: tv, now: early)
        _ = set("2222", to: phone, now: late)

        if newerFirst {
            await run(phone)
            await run(tv)
        } else {
            await run(tv)
            await run(phone)
        }
        await run(tv)
        await run(phone)

        let applies = newerFirst ? "2222" : "1111"
        let fails = newerFirst ? "1111" : "2222"
        for device in [tv, phone] {
            #expect(device.pin(person.identifier).matches(applies))
            #expect(!device.pin(person.identifier).matches(fails))
        }
    }

    @Test("A younger tombstone beats an older PIN — and vice versa")
    func tombstoneVersusPin() async {
        let tv = device("fernseher")
        let phone = device("telefon")
        _ = set("1111", to: tv, now: early)
        await run(tv)
        await run(phone)

        // Offline: the TV removes late, the phone changes earlier.
        ProfilePINMaintenance.redeem(
            forItem: person.identifier, keychain: tv.sharedStore, cloud: tv.cloud,
            now: late)
        _ = set(
            "3333", old: "1111", to: phone, now: early.addingTimeInterval(60))
        await run(phone)
        await run(tv)
        await run(phone)

        #expect(!tv.pin(person.identifier).isSet)
        #expect(!phone.pin(person.identifier).isSet, "the younger tombstone applies everywhere")
    }

    // MARK: - Old versions

    /// **The lesson from AP49:** A version clears every record in ``ProfileCloud/ownTypes``
    /// that it does not write. The PIN type therefore belongs only among the read ones.
    @Test("The PIN type is read and never cleaned up")
    func neverCleaned() {
        #expect(!ProfileCloud.ownTypes.contains(ProfilePINMapping.contentType))
        #expect(!ProfileCloud.allTypes.contains(ProfilePINMapping.contentType))
        #expect(ProfileCloud.readTypes.contains(ProfilePINMapping.contentType))
    }

    /// A device that does not manage the PIN (``ProfileCloud/moveBundle`` `== nil`), and one
    /// that, like an old version, clears every record of its types that it does not know — **the
    /// PIN is still there afterwards.**
    @Test("An old device does not clean up the record")
    func oldDevice() async throws {
        let tv = device("fernseher")
        _ = set("4711", to: tv, now: early)
        await run(tv)

        let hub = CloudHub(
            service: server.credential("max"), file: nil,
            device: DeviceDescription(identifier: "alt", name: "alt", model: "Test rig"))
        let legacyStore = InMemoryStore()
        var ledger = ProfileBook()
        ledger.create(person)
        ledger.write(in: legacyStore)
        let old = ProfileCloud(
            hub: hub, store: legacyStore, moveBundle: nil, automatic: false)
        await old.reconcile(person)
        await old.reconcile(person)

        // A version from before AP52: It clears everything in its types that it does not write.
        let zone = try #require(old.zone(forItem: person.identifier))
        let theirs = ProfileMapping.wordings(forItem: person, now: early).map(\.id)
        for contentType in ProfileCloud.allTypes {
            for message in zone.read(contentType) where !theirs.contains(message.id) {
                zone.delete(contentType: contentType, name: message.name)
            }
        }
        await zone.reconcile()

        let later = device("zweiter-fernseher")
        await run(later)
        #expect(later.pin(person.identifier).matches("4711"))
    }

    // MARK: - No plaintext

    /// **The raw bytes, not the intention:** everything that was ever written to the Keychain,
    /// and every record on the server — as text, as JSON and as bytes.
    @Test("Neither store nor cloud carries the digits")
    func noPlaintext() async throws {
        let sharedStore = Recorder()
        let tv = device("fernseher", sharedStore: sharedStore)
        _ = set("4711", to: tv, now: early)
        await run(tv)
        _ = set("4711", old: "4711", to: tv, now: late)
        await run(tv)
        #expect(tv.pin(person.identifier).matches("4711"))

        let digits = Data("4711".utf8)
        #expect(!sharedStore.written.isEmpty)
        for text in sharedStore.written {
            #expect(!text.contains("4711"), "Plaintext in the Keychain: \(text)")
            let entry = try JSONDecoder().decode(ProfilePIN.ContentEntryRecord.self, from: Data(text.utf8))
            #expect(entry.verifier?.digest.range(of: digits) == nil)
            #expect(entry.verifier?.salt.count == ProfilePIN.saltLength)
        }

        let top = try top()
        let pinRecords = top.filter { $0.contentType == ProfilePINMapping.contentType }
        #expect(pinRecords.count == 1)
        for message in top {
            let json = try JSONEncoder().encode(message)
            #expect(json.range(of: digits) == nil, "Plaintext in the record \(message.contentType)")
            for value in message.fields.values {
                if case .data(let bytes) = value { #expect(bytes.range(of: digits) == nil) }
                if case .text(let text) = value { #expect(!text.contains("4711")) }
            }
        }
        let message = try #require(pinRecords.first)
        #expect(message.encrypted == ProfilePINMapping.isSecret, "salt and digest encrypted")
    }

    /// **The same PIN set twice yields two values** — otherwise comparing two records
    /// would reveal whether it stayed the same.
    @Test("Every set rolls a new salt")
    func newSalt() throws {
        let sharedStore = InMemoryStore()
        let pin = ProfilePIN(store: sharedStore, forItem: person.identifier)
        let one = try #require(pin.set("4711", now: early)?.verifier)
        let two = try #require(pin.set("4711", now: late)?.verifier)
        #expect(one.salt != two.salt)
        #expect(one.digest != two.digest)
        #expect(one.rounds == ProfilePIN.rounds)
        #expect(pin.matches("4711"))
    }

    // MARK: - Changing and removing

    @Test("Changing and removing require the old PIN")
    func oldRequired() {
        let tv = device("fernseher")
        #expect(set("1234", to: tv, now: early) == .isSet)
        #expect(set("5678", to: tv, now: late) == .oldWrong)
        #expect(set("5678", old: "0000", to: tv, now: late) == .oldWrong)
        #expect(
            ProfilePINMaintenance.remove(
                old: "0000", forItem: person.identifier, keychain: tv.sharedStore,
                cloud: tv.cloud, now: late) == .oldWrong)
        #expect(tv.pin(person.identifier).matches("1234"), "nothing changed")

        #expect(set("12a4", old: "1234", to: tv, now: late) == .invalid)
        #expect(set("5678", old: "1234", to: tv, now: late) == .isSet)
        #expect(tv.pin(person.identifier).matches("5678"))
    }

    // MARK: - Forgot PIN

    /// **Household-wide:** The way out is due, the PIN falls — on the TV, in the
    /// cloud and thus on the phone; and the request is gone.
    @Test("Forgot PIN clears household-wide")
    func forgottenHouseholdWide() async {
        let tv = device("fernseher")
        let phone = device("telefon")
        _ = set("4711", to: tv, now: early)
        await run(tv)
        await run(phone)
        #expect(phone.pin(person.identifier).isSet)

        tv.cloud.requestPinRecovery(forItem: .profile(person.identifier), device: "fernseher")
        #expect(tv.cloud.pinState(forItem: .profile(person.identifier)).pending)

        ProfilePINMaintenance.redeem(
            forItem: person.identifier, keychain: tv.sharedStore, cloud: tv.cloud,
            now: late)
        #expect(!tv.pin(person.identifier).isSet)
        #expect(tv.cloud.pinState(forItem: .profile(person.identifier)) == .none)

        // **Only the zone, not a whole sync pass of the TV:** The tombstone has to be in the mirror
        // already when releasing — a sync pass would otherwise write it upward afterwards and
        // obscure that the release itself cleared only on the device.
        await tv.cloud.zone(forItem: person.identifier)?.reconcile()
        await run(phone)
        #expect(!phone.pin(person.identifier).isSet, "the PIN is dropped on the other device too")
    }

    // MARK: - Finding und Zusammenlegen

    /// **A profile that was just found is protected immediately** — not only after the first sync pass.
    @Test("A found profile brings its PIN along")
    func foundWithPin() async {
        let phone = device("telefon")
        _ = set("4711", to: phone, now: early)
        await run(phone)

        let hub = CloudHub(
            service: server.credential("max"), file: nil,
            device: DeviceDescription(identifier: "tv", name: "tv", model: "Test rig"))
        let sharedStore = InMemoryStore()
        let tv = ProfileCloud(
            hub: hub, store: InMemoryStore(), moveBundle: sharedStore, automatic: false)
        tv.startStore = nil
        let found = await tv.find()
        #expect(found.map(\.identifier) == [person.identifier])
        tv.adopt(found)
        #expect(ProfilePIN(store: sharedStore, forItem: person.identifier).matches("4711"))
    }

    /// **The leaving profile's PIN moves only if the remaining one has none** — and "none"
    /// includes a tombstone: The moved PIN must be younger than it, otherwise
    /// the tombstone would beat it in the cloud.
    @Test("When merging, the PIN moves only to an unprotected profile")
    func merge() async {
        let away = Profile(name: "Gast")
        let tv = device("fernseher")
        var ledger = ProfileBook.read(from: tv.store)
        ledger.create(away)
        ledger.write(in: tv.store)

        // The remaining profile (viewer A) had a PIN and removed it — a tombstone.
        _ = set("1111", to: tv, now: early)
        _ = ProfilePINMaintenance.remove(
            old: "1111", forItem: person.identifier, keychain: tv.sharedStore,
            cloud: tv.cloud, now: late)
        await run(tv)
        ProfilePIN(store: tv.sharedStore, forItem: away.identifier).set("2222", now: early)

        let outcome = ProfileMerge.perform(
            away.identifier, in: person.identifier, pins: [away.identifier: "2222"],
            ledgerStore: tv.store, keychain: tv.sharedStore, startStore: nil,
            cloud: tv.cloud)
        #expect(outcome.merged)
        #expect(tv.pin(person.identifier).matches("2222"))
        #expect(tv.pin(away.identifier).entry == nil, "nothing remains under the dead identifier")

        await run(tv)
        let phone = device("telefon")
        await run(phone)
        #expect(phone.pin(person.identifier).matches("2222"), "the moved one beats the tombstone")

        // And if the remaining one has one, it stays his.
        let third = Profile(name: "Dritter")
        ledger = ProfileBook.read(from: tv.store)
        ledger.create(third)
        ledger.write(in: tv.store)
        ProfilePIN(store: tv.sharedStore, forItem: third.identifier).set("3333", now: late)
        _ = ProfileMerge.perform(
            third.identifier, in: person.identifier,
            pins: [third.identifier: "3333", person.identifier: "2222"],
            ledgerStore: tv.store, keychain: tv.sharedStore, startStore: nil,
            cloud: tv.cloud)
        #expect(tv.pin(person.identifier).matches("2222"))
        #expect(!tv.pin(person.identifier).matches("3333"))
    }

    // MARK: - Separate from parental controls

    /// **The device PIN stays as it was** — no profile path touches its keys.
    @Test("Setting, removing and releasing the profile PIN leave the device PIN untouched")
    func devicePinUntouched() async {
        let sharedStore = Recorder()
        let tv = device("fernseher", sharedStore: sharedStore)
        Pin(store: sharedStore).set("9999")
        let devicePin = sharedStore.snapshot()
        #expect(devicePin.count == 3, "digest, salt and date of the device PIN")
        sharedStore.forgetTouched()

        _ = set("4711", to: tv, now: early)
        _ = ProfilePINMaintenance.remove(
            old: "4711", forItem: person.identifier, keychain: sharedStore, cloud: tv.cloud,
            now: late)
        ProfilePINMaintenance.redeem(
            forItem: person.identifier, keychain: sharedStore, cloud: tv.cloud,
            now: late.addingTimeInterval(1))
        await run(tv)

        #expect(Pin(store: sharedStore).matches("9999"))
        #expect(sharedStore.snapshot() == devicePin)
        #expect(!sharedStore.touched.isEmpty)
        #expect(
            sharedStore.touched.allSatisfy { $0.hasPrefix(ProfilePIN.basis + ".") },
            "the profile paths touch only profile keys: \(sharedStore.touched)")
    }
}

extension ProfileMerge.SwitchOutcome {
    fileprivate var merged: Bool {
        if case .merged = self { return true }
        return false
    }
}

/// A compartment that keeps every written value and every touched key.
final class Recorder: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    /// Everything that was ever written outside the device PIN.
    private(set) var written: [String] = []
    private(set) var touched: Set<String> = []

    /// The device PIN's keys with their values.
    func snapshot() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return values.filter { $0.key.hasPrefix("childLock.") }
    }

    func forgetTouched() {
        lock.lock()
        defer { lock.unlock() }
        touched = []
    }

    func set(_ value: String, for key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
        if !key.hasPrefix("childLock.") { written.append(value) }
        touched.insert(key)
    }

    func value(for key: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let value = values[key] else { throw SecureStore.Failure.notFound }
        return value
    }

    func remove(_ key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values[key] = nil
        touched.insert(key)
    }
}
