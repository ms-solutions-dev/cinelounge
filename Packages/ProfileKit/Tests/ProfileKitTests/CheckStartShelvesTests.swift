import Core
import Foundation
import Testing

@testable import ProfileKit

/// Check agent `start`: Taking over the device order must not revive a reset
/// profile order on every start.
struct CheckStartShelvesTests {

    @Test("A shelf shown again in the profile stays visible after the next start")
    func resetOrderStays() {
        let bucket = InMemoryStore()
        var device = ShelfPreferences()
        device.setVisible(false, for: "zuletztHinzugefuegt")
        device.save(to: bucket)
        var ledger = ProfileBook()
        let person = Profile(name: "Max")
        ledger.create(person)
        let identifier = person.identifier.rawValue

        // Start 1: the profile gets the device's order.
        ProfileShelves.adopt(ledger, store: bucket)
        #expect(!ShelfPreferences.load(from: bucket, forItem: identifier).isVisible("zuletztHinzugefuegt"))

        // The viewer shows the shelf again in their profile.
        var own = ShelfPreferences.load(from: bucket, forItem: identifier)
        own.setVisible(true, for: "zuletztHinzugefuegt")
        own.save(to: bucket, forItem: identifier)
        #expect(ShelfPreferences.load(from: bucket, forItem: identifier).isVisible("zuletztHinzugefuegt"))

        // Start 2.
        ProfileShelves.adopt(ledger, store: bucket)
        #expect(
            ShelfPreferences.load(from: bucket, forItem: identifier).isVisible("zuletztHinzugefuegt"),
            "the device order overwrote the profile's choice again")
    }
}
