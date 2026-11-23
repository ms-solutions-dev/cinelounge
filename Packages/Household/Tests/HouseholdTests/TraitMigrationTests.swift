import Core
import Foundation
import PortalKit
import ProfileKit
import Testing

@testable import Household

/// **The CL-Server credential belongs to the profile** (owner, 2026-09-28): A TV
/// paired with the administrator showed up in every new profile as "signed in as" that administrator.
@MainActor
@Suite("The trait moves from the device into the profile")
struct TraitMigrationTests {

    private func ledger(_ profileEntry: [Profile], active: Profile) -> InMemoryStore {
        let store = InMemoryStore()
        var ledger = ProfileBook()
        for profileName in profileEntry { ledger.create(profileName) }
        ledger.switchTo(zu: active.identifier)
        ledger.write(in: store)
        return store
    }

    private func trait(_ device: InMemoryStore, _ profile: Profile) -> String? {
        DeviceTrait.load(from: ProfileStore(device, forItem: profile.identifier.rawValue))
    }

    @Test("A device with a person gives the trait only to the active profile")
    func ownDevice() {
        var max = Profile(name: "Max")
        max.create(.portals(person: "max"))
        var profileA = Profile(name: "Aliye")
        profileA.create(.portals(person: nil))
        let fresh = Profile(name: "Neu")
        let store = ledger([max, profileA, fresh], active: max)
        let device = InMemoryStore()
        try? device.set("m-1", for: DeviceTrait.storageKey)
        try? device.set("1", for: DeviceTrait.ownKey)

        #expect(TraitMigration.migrate(device: device, ledgerStore: store) == 1)
        #expect(trait(device, max) == "m-1")
        #expect(trait(device, profileA) == nil, "otherwise one profile would show up as the other")
        #expect(trait(device, fresh) == nil)
        #expect((try? device.value(for: DeviceTrait.storageKey)) == nil, "the device slot is empty")
    }

    @Test("A shared device gives it to every profile with a CL-Server, each with its own head")
    func sharedDevice() {
        var max = Profile(name: "Max")
        max.create(.portals(person: "max"))
        var profileA = Profile(name: "Aliye")
        profileA.create(.portals(person: "aliye"))
        let without = Profile(name: "Ohne")
        let store = ledger([max, profileA, without], active: max)
        let device = InMemoryStore()
        try? device.set("m-1", for: DeviceTrait.storageKey)

        #expect(TraitMigration.migrate(device: device, ledgerStore: store) == 2)
        #expect(trait(device, profileA) == "m-1")
        #expect(
            DeviceTrait.profile(from: ProfileStore(device, forItem: profileA.identifier.rawValue)) == "aliye")
        #expect(trait(device, without) == nil)
    }

    @Test("Without a profile it stays on the device, without a trait nothing happens")
    func nothingToDo() {
        let device = InMemoryStore()
        #expect(TraitMigration.migrate(device: device, ledgerStore: InMemoryStore()) == nil)
        try? device.set("m-1", for: DeviceTrait.storageKey)
        #expect(TraitMigration.migrate(device: device, ledgerStore: InMemoryStore()) == nil)
        #expect((try? device.value(for: DeviceTrait.storageKey)) == "m-1")
    }

    @Test("An older profile does not fall back to the device for the trait")
    func noRegression() {
        let device = InMemoryStore()
        try? device.set("m-1", for: DeviceTrait.storageKey)
        #expect(DeviceTrait.load(from: ProfileStore(device, forItem: "alt")) == nil)
    }
}

@Suite("Token reconciliation: no token for children")
struct TokenChildTests {
    @Test("The rejection for children is final, others are not")
    func isFinal() {
        #expect(
            TokenReconciliation.isFinal(
                .cancelled(status: 403, code: "mark.not_for_children", values: ["id": "sina"])))
        #expect(!TokenReconciliation.isFinal(.cancelled(status: 401, code: "auth.required", values: [:])))
    }
}
