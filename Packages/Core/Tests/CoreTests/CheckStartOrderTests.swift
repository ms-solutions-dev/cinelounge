import Foundation
import Testing

@testable import Core

/// Check agent `start`: moving a shelf must not delete the places of shelves that
/// are currently absent.
struct CheckStartOrderTests {

    @Test("A portal folder that is currently silent keeps its place when other shelves are moved")
    func absentShelfStaysInTheOrder() {
        var preferences = ShelfPreferences(order: ["animehub||/beliebt", "resume", "live"])
        // The portal does not answer today — its shelf is missing from the list.
        preferences.move("live", up: true, within: ["resume", "live"])
        #expect(preferences.order.contains("animehub||/beliebt"), "order: \(preferences.order)")
    }
}
