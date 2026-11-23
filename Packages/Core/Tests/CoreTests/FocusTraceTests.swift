import Foundation
import Testing

@testable import Core

/// The key book (F-008, 2026-09-04): Effects name their press.
struct PressLedgerTests {
    @Test("An effect inside the window names the press, a late one does not")
    func effectsNameTheirPress() {
        Diagnostics.keyPressed("↑")
        let now = Date()
        #expect(Diagnostics.sincePress(now).hasSuffix("after ↑"))
        #expect(Diagnostics.sincePress(now.addingTimeInterval(Diagnostics.pressWindow + 1)) == "no key")
    }
}
