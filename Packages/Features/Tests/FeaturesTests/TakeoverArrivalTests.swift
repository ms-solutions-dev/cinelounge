import Core
import Foundation
import ParentalControls
import PlaylistKit
import SecondScreen
import Testing

@testable import Features

/// **Does what the phone sent arrive?** — AP22, created on 2026-09-11.
///
/// **Why these checks live here and not in `ZweitschirmTests`.** The silent
/// error lay between two packages: ``SecondScreen/Takeover`` wrote, and
/// ``ParentalControlsState`` read — just not the same thing. Each side on its own was
/// green, and both together were wrong. `Features` is the only place in the tree where
/// both ends are visible at the same time; a check that knows only one end would
/// never have found this error and did not for three weeks.
@MainActor
private func setup() -> (Takeover, SecureStore, UserDefaults) {
    let name = "probe.\(UUID().uuidString)"
    let sharedStore = SecureStore(service: name)
    let store = UserDefaults(suiteName: name) ?? .standard
    let takeover = Takeover(
        keychain: sharedStore,
        listen: PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore()),
        trust: CertificateTrustStore(store: InMemoryStore()),
        store: store)
    return (takeover, sharedStore, store)
}

/// **The handoff's age limit arrives on the TV.**
///
/// **Before 2026-09-11 this check was red** — on the last line. The PIN
/// arrived (both sides Keychain), child mode arrived (both sides
/// `UserDefaults`), the limit did not: written as `Int` into `UserDefaults`,
/// read as a string from the Keychain. On the TV, child mode was then on,
/// PIN set, no limit — and ``ParentalControls/ProtectionRule/shows(approval:)``
/// starts, without a limit, with "everything passes". **The filter ran and filtered nothing.**
@MainActor
@Test func adoptedLimitArrivesOnTV() {
    let (takeover, sharedStore, store) = setup()

    let phonePin = Pin(store: InMemoryStore())
    #expect(phonePin.set("4711"))

    takeover.matches(
        code: SetupBundle(
            parentalControls: .init(active: true, pin: phonePin.extract, ageLimit: 12)))

    // Exactly the holder that the TV UI builds — the same store, the same
    // device lock. Only the Keychain is a separate one, so that the check does not reach into
    // the one of the running device.
    let state = ParentalControlsState(
        store: sharedStore,
        childAccounts: ChildAccountList(store: InMemoryStore()),
        childMode: ChildMode(store: store))

    #expect(state.rule.isPinSet)
    #expect(state.rule.deviceLocked)
    #expect(state.rule.applies)
    #expect(state.limit == .from12)

    // And so the filter really filters: "from 16" lies above the adopted limit.
    #expect(state.rule.shows(approval: "FSK 12"))
    #expect(state.rule.shows(approval: "FSK 16") == false)
}

/// **What was assigned by hand also applies to the rule.**
///
/// **Before 2026-09-11 this check was red**, and on the TV the error looked like
/// an empty server: ``ParentalControlsState`` built the ``ProtectionRule`` without
/// `assignments:`, `blocksUnrecognized` **does** have the default — so with a limit set
/// every library with `R`, `TV-MA` or `PG-13` dropped out **completely**. No error,
/// no message, just nothing.
@MainActor
@Test func manualAssignmentsReachTheRule() {
    let store = InMemoryStore()
    #expect(Pin(store: store).set("1234"))
    AgeLimit.write(.from16, in: store)

    // Without an assignment "TV-MA" is not understood — and what is not understood blocks.
    var approvals = UnrecognizedRatings()
    approvals.arrange("TV-MA", to: 16)
    approvals.save(to: store)

    let state = ParentalControlsState(
        store: store,
        childAccounts: ChildAccountList(store: InMemoryStore()),
        childMode: {
            let mode = ChildMode(store: UserDefaults(suiteName: UUID().uuidString)!)
            mode.set(true)
            return mode
        }())

    #expect(state.rule.applies)
    #expect(state.rule.assignments["TV-MA"] == 16)
    #expect(state.rule.shows(approval: "TV-MA"))

    // What nobody assigned still drops out — the default stays "when in doubt,
    // show less". The assignment is a permission and not a switch-off.
    #expect(state.rule.shows(approval: "NC-17") == false)
}
