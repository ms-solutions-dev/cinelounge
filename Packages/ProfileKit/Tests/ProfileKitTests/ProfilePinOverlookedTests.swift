import CloudSync
import Core
import Foundation
import ParentalControls
import Testing

@testable import ProfileKit

/// **An overlooked PIN loses, and a rounds value from the cloud has limits** (check of
/// 2026-09-25 evening, findings 2 and 3).
///
/// Control test: Without ``ProfilePIN/ContentEntryRecord/overlooks(_:)`` in ``ProfilePIN/ContentEntryRecord/resolves(from:)``
/// and in ``ProfilePINMapping/rule`` the iPad's PIN opens a parent's profile on the TV;
/// without ``ProfilePIN/roundsRange`` the mapping reads two billion rounds.
@Suite("Profile PIN: overlooked PIN and round range")
@MainActor
struct ProfilePinOverlookedTests {

    let server = MockCloud()
    let person = Profile(name: "Papa")
    let early = Date(timeIntervalSince1970: 1_000_000)
    let late = Date(timeIntervalSince1970: 2_000_000)

    struct Device {
        let cloud: ProfileCloud
        let sharedStore: any KeyValueStore
    }

    func device(_ name: String) -> Device {
        let store = InMemoryStore()
        let sharedStore = InMemoryStore()
        let hub = CloudHub(
            service: server.credential("max"), file: nil,
            device: DeviceDescription(identifier: name, name: name, model: "Test rig"))
        let cloud = ProfileCloud(
            hub: hub, store: store, moveBundle: sharedStore, automatic: false)
        cloud.startStore = nil
        var ledger = ProfileBook.read(from: store)
        ledger.create(person)
        ledger.write(in: store)
        return Device(cloud: cloud, sharedStore: sharedStore)
    }

    func pin(_ g: Device) -> ProfilePIN { ProfilePIN(store: g.sharedStore, forItem: person.identifier) }

    func set(
        _ digits: String, old: String? = nil, to g: Device, now: Date
    )
        -> ProfilePINMaintenance.SwitchOutcome
    {
        ProfilePINMaintenance.set(
            digits, old: old, forItem: person.identifier, keychain: g.sharedStore, cloud: g.cloud,
            now: now)
    }

    func pinRecord(rounds: Int) -> CloudRecord {
        CloudRecord(
            contentType: ProfilePINMapping.contentType, name: ProfilePINMapping.name,
            fields: [
                "zeit": .date(late), "keine": .bool(false),
                "salz": .data(Data(repeating: 1, count: 16)),
                "abdruck": .data(Data(repeating: 2, count: 32)),
                "runden": .integer(rounds),
            ], changed: late)
    }

    // MARK: - Finding 2

    /// **The case from the check:** A parent sets a PIN on the TV, the iPad has not yet
    /// reconciled and accepts a "first" PIN with a later clock. After the reconciliation the parent's PIN
    /// applies everywhere, and the iPad carries it too.
    @Test("Outdated device: a first PIN does not beat the cloud's overlooked one")
    func firstPinLosesToCloud() async {
        let tv = device("fernseher")
        let ipad = device("ipad")
        await ipad.cloud.reconcile(person)

        #expect(set("4711", to: tv, now: early) == .isSet)
        await tv.cloud.reconcile(person)

        #expect(!pin(ipad).isSet)
        #expect(set("0000", to: ipad, now: late) == .isSet)

        await ipad.cloud.reconcile(person)
        await tv.cloud.reconcile(person)
        await ipad.cloud.reconcile(person)

        for g in [tv, ipad] {
            #expect(pin(g).matches("4711"), "Papa's PIN must apply everywhere")
            #expect(!pin(g).matches("0000"), "the overlooking PIN opens Papa's profile")
        }
    }

    /// **Whoever knows the PIN keeps changing it** — the basis is then the time of the entry
    /// it replaced, and the later change applies everywhere.
    @Test("A change made with the old PIN prevails")
    func changeWithAgeApplies() async {
        let tv = device("fernseher")
        let ipad = device("ipad")
        _ = set("4711", to: tv, now: early)
        await tv.cloud.reconcile(person)
        await ipad.cloud.reconcile(person)
        #expect(pin(ipad).matches("4711"))

        #expect(set("1234", old: "4711", to: ipad, now: late) == .isSet)
        await ipad.cloud.reconcile(person)
        await tv.cloud.reconcile(person)

        #expect(pin(tv).matches("1234"))
        #expect(pin(ipad).matches("1234"))
    }

    @Test("Overlooked means: PIN against PIN without having known the other state")
    func overlookedRule() throws {
        let value = try #require(ProfilePIN.verifier(forItem: "4711"))
        let papa = ProfilePIN.ContentEntryRecord(verifier: value, time: early)
        let blind = ProfilePIN.ContentEntryRecord(verifier: value, time: late)
        let knowing = ProfilePIN.ContentEntryRecord(verifier: value, time: late, basis: early)
        let tombstone = ProfilePIN.ContentEntryRecord(verifier: nil, time: late)

        #expect(blind.overlooks(papa))
        #expect(!blind.resolves(from: papa))
        #expect(!knowing.overlooks(papa))
        #expect(knowing.resolves(from: papa))
        #expect(!tombstone.overlooks(papa), "a tombstone stays under \"the younger wins\"")
        #expect(tombstone.resolves(from: papa))
    }

    /// **The zone decides the same way as the device** — otherwise the server would hold one
    /// and the device the other.
    @Test("The merge rule sides with the server when the local copy overlooked it")
    func ruleOnServer() throws {
        let value = try #require(ProfilePIN.verifier(forItem: "4711"))
        let server = ProfilePINMapping.message(
            forItem: ProfilePIN.ContentEntryRecord(verifier: value, time: early))
        let blind = ProfilePINMapping.message(
            forItem: ProfilePIN.ContentEntryRecord(verifier: value, time: late))
        let knowing = ProfilePINMapping.message(
            forItem: ProfilePIN.ContentEntryRecord(verifier: value, time: late, basis: early))

        let againstBlind = ProfilePINMapping.rule.merge(blind, server)
        #expect(ProfilePINMapping.entry(from: [againstBlind])?.time == early)
        let againstKnowing = ProfilePINMapping.rule.merge(knowing, server)
        #expect(ProfilePINMapping.entry(from: [againstKnowing])?.time == late)
        #expect(ProfilePINMapping.entry(from: [againstKnowing])?.basis == early)
    }

    // MARK: - Finding 3

    @Test(
        "A round value outside the range makes the record unreadable",
        arguments: [
            2_000_000_000, ProfilePIN.rounds * 5 + 1, ProfilePIN.rounds / 2 - 1, 0, -1,
        ])
    func roundsOutside(rounds: Int) {
        #expect(ProfilePINMapping.entry(from: [pinRecord(rounds: rounds)]) == nil)
    }

    @Test("The rounds on set are in range, and the record stays readable")
    func roundsInRange() throws {
        #expect(ProfilePIN.roundsRange.contains(ProfilePIN.rounds))
        let entry = try #require(
            ProfilePINMapping.entry(from: [pinRecord(rounds: ProfilePIN.rounds)]))
        #expect(entry.verifier?.rounds == ProfilePIN.rounds)
    }
}
