import Core
import Foundation
import ParentalControls
import ProfileKit
import Testing

@testable import Features

/// **The kind of a profile must bring a limit** — AP45, 2026-09-23.
///
/// **The finding from the concept:** `ProfileKit.kind` was decoration. Counting showed `kind == .kind`
/// being read in exactly three places — ``ProfileRow``, ``AccountSwitcher``, `ProfileView` —, and
/// all three drew a **badge** with it. Not a single place derived a
/// rule from it.
///
/// Instead, ``ParentalControlsState`` decided via the **old account list**
/// (`childAccounts.isChild(…)`), which AP41 had actually replaced. Whoever created a
/// child profile since 2026-09-21 got a badge and **no limit** — the lock believed
/// an adult was sitting in front.
///
/// **The old list stays alongside and is not replaced.** It carries the
/// households that were set up before AP41; dropping it would mean opening a
/// lock there that someone set deliberately. They are therefore joined with **OR**:
/// a child profile is one, and a child account stays one.
///
/// **The direction is the safe one** — it locks, it does not open. Still, the behavior
/// changes for everyone who has created a child profile so far, without
/// having asked for it. That belongs in the daily note of AP48.
@MainActor
@Test("A child profile brings a limit, even without an entry in the old account list")
func childProfileBringsLimit() {
    let store = InMemoryStore()
    _ = Pin(store: store).set("1234")

    // The profile book lives in the file store and not in the Keychain — see
    // `App/Sources/ProfileStartup.swift`. Here a separate one, so that the test reads nothing from the
    // device.
    let profileStore = InMemoryStore()
    var kind = Profile(name: "Selin")
    kind.kind = .kind
    var ledger = ProfileBook()
    // ``ProfileBook/create(_:)`` makes the first profile the active one by itself — otherwise
    // a device would state there with one profile that nobody sits in front of.
    ledger.create(kind)
    ledger.write(in: profileStore)

    let state = ParentalControlsState(
        store: store,
        childAccounts: ChildAccountList(store: InMemoryStore()),
        profileStore: profileStore,
        childMode: ChildMode(store: UserDefaults(suiteName: UUID().uuidString)!))

    #expect(state.rule.accountKind == .kind)
    #expect(state.rule.applies)
}

/// **An adult profile brings none** — otherwise the check above would be worthless, because
/// it would also be green with a lock for everyone.
@MainActor
@Test("An adult profile brings no limit")
func adultProfileBringsNoLimit() {
    let store = InMemoryStore()
    _ = Pin(store: store).set("1234")

    let profileStore = InMemoryStore()
    var ledger = ProfileBook()
    let adult = Profile(name: "Max")
    ledger.create(adult)
    ledger.write(in: profileStore)

    let state = ParentalControlsState(
        store: store,
        childAccounts: ChildAccountList(store: InMemoryStore()),
        profileStore: profileStore,
        childMode: ChildMode(store: UserDefaults(suiteName: UUID().uuidString)!))

    #expect(state.rule.accountKind == .adult)
}
