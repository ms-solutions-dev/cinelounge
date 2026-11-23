import Core
import Foundation
import ParentalControls
import ProfileKit
import Testing

@testable import Features

/// **"Block what is not understood" for the active profile — via the rule that the filter
/// asks** (strand G, 2026-09-25).
///
/// Checked at ``ParentalControlsState/rule`` and not at the calculation alone: The
/// finding sat in exactly this connection, in `gelesenesSperrtUnverstandene(forItem:)`.
@MainActor
@Suite("Locking unrecognized items per profile")
struct UnrecognizedLockProfileTests {

    /// A child profile is active; the Keychain is empty except for the PIN.
    private static func setup() -> (ParentalControlsState, InMemoryStore, String) {
        let sharedStore = InMemoryStore()
        _ = Pin(store: sharedStore).set("1234")
        AgeLimit.write(.from12, in: sharedStore, forItem: nil)
        let kind = Profile(name: "Selin", kind: .kind)
        var ledger = ProfileBook()
        ledger.create(kind)
        let ledgerStore = InMemoryStore()
        ledger.write(in: ledgerStore)
        let mode = ChildMode(store: UserDefaults(suiteName: UUID().uuidString)!)
        mode.set(false)
        let state = ParentalControlsState(
            store: sharedStore, childAccounts: ChildAccountList(store: InMemoryStore()),
            profileStore: ledgerStore, childMode: mode)
        return (state, sharedStore, kind.identifier.rawValue)
    }

    @Test("Device off and profile without entry: not locked")
    func deviceFromProfileWithout() {
        let (state, _, _) = Self.setup()
        state.set(blocksUnrecognized: false)

        #expect(state.rule.blocksUnrecognized == false)
        #expect(state.rule.shows(approval: "Nicht geprüft"))
    }

    @Test("Profile yes: locked, even if the device is off")
    func profileYes() {
        let (state, sharedStore, kind) = Self.setup()
        UnrecognizedLock.write(true, in: sharedStore, forItem: kind)
        state.set(blocksUnrecognized: false)

        #expect(state.rule.blocksUnrecognized)
        #expect(state.rule.shows(approval: "Nicht geprüft") == false)
    }

    @Test("Device without entry: locked")
    func deviceWithout() {
        let (state, _, _) = Self.setup()

        #expect(state.rule.blocksUnrecognized)
        #expect(state.rule.shows(approval: "Nicht geprüft") == false)
    }
}
