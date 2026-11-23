import Core
import Foundation
import Testing

@testable import ProfileKit

/// **The arrangement of the Home screen belongs to the person** (AP41, row 7).
@Suite("The shelf order per profile")
struct ProfileShelvesTests {

    /// **The bug that existed before:** one file per device. Whoever rearranged their rows
    /// rearranged everyone else's.
    @Test("Two profiles have two orders")
    func twoArrangements() {
        let bucket = InMemoryStore()
        let parents = Profile(name: "Eltern")
        let kind = Profile(name: "Kind", kind: .kind)

        ShelfPreferences(order: ["live", "resume"])
            .save(to: bucket, forItem: parents.identifier.rawValue)
        ShelfPreferences(order: ["resume", "neu:jellyfin:kinder"])
            .save(to: bucket, forItem: kind.identifier.rawValue)

        #expect(
            ShelfPreferences.load(from: bucket, forItem: parents.identifier.rawValue).order
                == ["live", "resume"])
        #expect(
            ShelfPreferences.load(from: bucket, forItem: kind.identifier.rawValue).order
                == ["resume", "neu:jellyfin:kinder"])
    }

    /// **Here everyone gets the same one, unlike the channel lists.** A
    /// shelf order takes nothing away from anyone and is what everyone already had.
    @Test("The device's order goes to all profiles")
    func adoptionForAll() {
        let bucket = InMemoryStore()
        ShelfPreferences(order: ["live", "resume", "portale"]).save(to: bucket)
        var ledger = ProfileBook()
        let parents = Profile(name: "Eltern")
        let kind = Profile(name: "Kind", kind: .kind)
        ledger.create(parents)
        ledger.create(kind)

        #expect(ProfileShelves.adopt(ledger, store: bucket) == 2)

        for person in [parents, kind] {
            #expect(
                ShelfPreferences.load(from: bucket, forItem: person.identifier.rawValue).order
                    == ["live", "resume", "portale"])
        }
        // **The device baseline stays** — it is the state before the first
        // setup, and as long as no profile exists, the app keeps reading it.
        #expect(ShelfPreferences.load(from: bucket).order == ["live", "resume", "portale"])
    }

    @Test("A changed order is not overwritten")
    func neverOverwrite() {
        let bucket = InMemoryStore()
        ShelfPreferences(order: ["live"]).save(to: bucket)
        var ledger = ProfileBook()
        let person = Profile(name: "Max")
        ledger.create(person)
        ShelfPreferences(order: ["resume"]).save(to: bucket, forItem: person.identifier.rawValue)

        #expect(ProfileShelves.adopt(ledger, store: bucket) == 0)

        #expect(
            ShelfPreferences.load(from: bucket, forItem: person.identifier.rawValue).order
                == ["resume"])
    }

    @Test("Without an order on the device nothing happens")
    func withoutDeviceOrder() {
        let bucket = InMemoryStore()
        var ledger = ProfileBook()
        ledger.create(Profile(name: "Max"))

        #expect(ProfileShelves.adopt(ledger, store: bucket) == 0)
    }

    /// **Each profile gets its own file** — the file name carries the identifier.
    @Test("The key carries the profile identifier")
    func keyCarriesID() {
        let person = Profile(name: "Max")
        #expect(ShelfOrder.key(forItem: nil) == "shelves")
        #expect(
            ShelfOrder.key(forItem: person.identifier.rawValue)
                == "shelves." + person.identifier.rawValue)
    }
}
