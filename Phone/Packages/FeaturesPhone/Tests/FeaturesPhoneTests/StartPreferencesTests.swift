import Core
import Foundation
import Testing

@testable import FeaturesPhone

// MARK: - Dieselben Regalnamen wie am Fernseher (AP40, 20.09.2026)

/// **An arrangement saved before the renaming stays an arrangement.**
///
/// The finding of 2026-09-19: The shelves were called `weiterSchauen`, `heuteLive`,
/// `ausDenPortalen` here and `resume`, `live`, `portals` over there. An order that travels
/// in the handoff bundle to the TV was a list of unknown words there — and
/// `arrange(_:)` skips what does not exist. So it vanished silently.
@Test("Old shelf names are translated when carried over")
func oldShelfNamesMigrate() throws {
    let keychain = InMemoryStore()
    try keychain.set("weiterSchauen\nheuteLive\nausDenPortalen", for: "home.shelfOrder")
    let file = InMemoryStore()

    #expect(StartPreferences.adopt(from: keychain, in: file))

    #expect(
        StartPreferences.load(from: file).order.map(\.rawValue)
            == ["resume", "live", "portale"])
}

/// **The file holds the new names and not the old ones.**
///
/// The board in ``Shelf/Identifier/alteNamen`` stays, because a device may
/// never take this step — but what has once been taken over is translated. Otherwise the
/// alignment would hang forever on a translation at read time, and whoever one day
/// removed it would take the viewer's arrangement away.
@Test("What ends up in the file carries the new names")
func savesNewNames() throws {
    let keychain = InMemoryStore()
    try keychain.set("weiterSchauen\nheuteLive", for: "home.shelfOrder")
    let file = InMemoryStore()

    StartPreferences.adopt(from: keychain, in: file)

    #expect(ShelfOrder.read(from: file).order == ["resume", "live"])
    // **And the Keychain is empty afterwards** — a second truth left standing
    // would be read again by the next version.
    #expect((try? keychain.value(for: "home.shelfOrder")) == nil)
}

/// **A name without a counterpart stays untouched.** The TV has no shelf
/// "recently added"; a name that designates nothing over there needs no alignment.
@Test("Foreign and own names stay as they are")
func unknownStays() {
    #expect(Shelf.Identifier(stored: "zuletztHinzugefuegt").rawValue == "zuletztHinzugefuegt")
    #expect(Shelf.Identifier(stored: "neu:jellyfin:filme:42").rawValue == "neu:jellyfin:filme:42")
}
