import Foundation
import Testing

@testable import Core

/// **Without an entry the default applies — and the field stays empty anyway.**
///
/// Two questions, two answers: The line above the field shows what *is being* tried,
/// the field shows what *is* entered. A shared answer would be wrong at one of the two
/// places — a prefilled address looks like one that somebody has checked.
@Test func withoutEntryTheDefaultAppliesAndFieldStaysEmpty() {
    let store = InMemoryStore()
    #expect(BridgeAddress.load(from: store) == nil)
    // No default any more (2026-09-12): empty means no portals, not "the usual name".
    #expect(BridgeAddress.effective(from: store) == nil)
    #expect(BridgeAddress.isConfigured(in: store) == false)
}

/// An entered address beats the default.
@Test func entryBeatsDefault() {
    let store = InMemoryStore()
    #expect(BridgeAddress.save("192.0.2.9:8099", to: store))
    #expect(BridgeAddress.effective(from: store)?.host() == "192.0.2.9")
}

/// **Typed without a scheme is the normal case**, not the error case.
///
/// On the TV keyboard `http://` is seven keystrokes that nobody means.
@Test func withoutSchemePlainTextIsAssumed() {
    #expect(BridgeAddress.normalize("192.0.2.10:8100")?.scheme == "http")
    #expect(BridgeAddress.normalize("http://192.0.2.10:8100")?.scheme == "http")
}

/// **A mistyped entry does not switch the portals off.**
///
/// On the TV keyboard a typo is the rule. If it were accepted, the area would be
/// empty and the cause would sit in the own input field — where nobody looks.
@Test func unusableLeavesThePreviousInPlace() {
    let store = InMemoryStore()
    #expect(BridgeAddress.save("192.0.2.9:8099", to: store))
    #expect(BridgeAddress.save("   ///   ", to: store) == false)
    #expect(BridgeAddress.load(from: store)?.host() == "192.0.2.9")
}

/// **Clearing means "back to the default" and not "no portals".**
///
/// Whoever clears the field wants the usual name back; there is another way to switch
/// off. A cleared field that shuts the portals down would be a trap.
@Test func clearingRevertsTheEntryAndDoesNotSwitchOff() {
    let store = InMemoryStore()
    #expect(BridgeAddress.save("192.0.2.9:8099", to: store))
    #expect(BridgeAddress.save("", to: store))
    #expect(BridgeAddress.load(from: store) == nil)
    // Clearing takes the address back — and with it the portals.
    #expect(BridgeAddress.effective(from: store) == nil)
}
