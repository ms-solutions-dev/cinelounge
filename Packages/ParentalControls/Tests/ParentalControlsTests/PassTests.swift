import Foundation
import Testing

@testable import ParentalControls

/// A pass is valid for **one** use — and also expires by itself.
@Suite("Pass")
struct PassTests {

    @Test("It opens exactly the door it was given for")
    func onlyOneDoor() {
        var pass = Pass()
        pass.open("einstellungen")
        #expect(pass.applies(forItem: "einstellungen"))
        // Two doors are two questions: Whoever unlocks for Settings has not
        // unlocked the account switch.
        #expect(!pass.applies(forItem: "kontowechsel"))
    }

    @Test("After the grab the door is closed again")
    func consumed() {
        var pass = Pass()
        pass.open("konten")
        pass.consume()
        #expect(!pass.applies(forItem: "konten"))
    }

    /// **Checking does not consume.** SwiftUI evaluates a view several times; a check
    /// that consumes on the side would be a trap at every such place.
    @Test("Asking twice does not consume it")
    func askingDoesNotConsume() {
        var pass = Pass()
        pass.open("konten")
        #expect(pass.applies(forItem: "konten"))
        #expect(pass.applies(forItem: "konten"))
    }

    /// **It expires with time, not only with use.** Whoever enters the PIN and
    /// puts the phone down has not left a door open.
    @Test("After two minutes it asks again")
    func expires() {
        let now = Date()
        var pass = Pass()
        pass.open("konten", um: now)
        #expect(pass.applies(forItem: "konten", um: now.addingTimeInterval(60)))
        #expect(!pass.applies(forItem: "konten", um: now.addingTimeInterval(121)))
    }

    @Test("Without a pass every door is closed")
    func withoutPass() {
        #expect(!Pass().applies(forItem: "einstellungen"))
    }
}
