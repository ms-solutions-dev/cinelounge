import Core
import Foundation
import ParentalControls
import Testing

@testable import Features

/// A store with a PIN set — otherwise no rule applies.
@MainActor
private func stateWithPin(_ digits: String = "1234", kind: Bool) -> ParentalControlsState {
    let store = InMemoryStore()
    _ = Pin(store: store).set(digits)
    let childAccounts = ChildAccountList(store: InMemoryStore())
    let mode = ChildMode(store: UserDefaults(suiteName: UUID().uuidString)!)
    mode.set(kind)
    return ParentalControlsState(
        store: store, childAccounts: childAccounts, profileStore: InMemoryStore(), childMode: mode)
}

/// **Without a lock every door opens** — and without a question.
///
/// The normal case on the TV: an adult account, no child mode. A sheet that appeared here
/// would be a hurdle without cause.
@MainActor
@Test func withoutLockEveryDoorOpens() {
    let state = stateWithPin(kind: false)
    #expect(state.isAllowed(finished: "kontowechsel"))
    #expect(state.openQuestion == nil)
}

/// **With a lock the locked door asks a question instead of silently doing nothing.**
///
/// A button that does nothing on a press looks broken — that was a package of its own on the
/// TV (E28, dead ends and silent presses).
@MainActor
@Test func withLockTheDoorAsksAQuestion() {
    let state = stateWithPin(kind: true)
    #expect(state.isAllowed(finished: "kontowechsel") == false)
    #expect(state.openQuestion == "kontowechsel")
    #expect(state.reason(forItem: "kontowechsel")?.isEmpty == false)
}

/// **The right PIN opens exactly one door — and the pass is used up afterwards.**
///
/// Twice through the same door means asking twice. A pass that stays would be the gap that
/// was the worst finding on the phone: The child gets the app handed over after the parent
/// and finds everything open.
@MainActor
@Test func onePassCoversOneAction() {
    let state = stateWithPin(kind: true)
    #expect(state.isAllowed(finished: "kontowechsel") == false)
    #expect(state.verify("1234"))
    #expect(state.isAllowed(finished: "kontowechsel"))
    #expect(state.isAllowed(finished: "kontowechsel") == false)
}

/// **A pass applies to one door and not to all.**
///
/// Whoever releases the account switch has not released creating.
@MainActor
@Test func onePassDoesNotCoverEveryDoor() {
    let state = stateWithPin(kind: true)
    #expect(state.isAllowed(finished: "kontowechsel") == false)
    #expect(state.verify("1234"))
    #expect(state.isAllowed(finished: "kontoNeu") == false)
}

/// A wrong PIN opens nothing and leaves the question standing.
@MainActor
@Test func wrongPinOpensNothing() {
    let state = stateWithPin(kind: true)
    #expect(state.isAllowed(finished: "kontowechsel") == false)
    #expect(state.verify("9999") == false)
    #expect(state.openQuestion == "kontowechsel")
    #expect(state.isAllowed(finished: "kontowechsel") == false)
}

/// **Without a stored PIN the lock does not apply** — even for a child account.
///
/// The rule is in ``ProtectionRule/applies``: Without a PIN there would be no way back
/// through a locked door. The lock would then not be a lock but a trap.
@MainActor
@Test func withoutPinTheLockIsNoTrap() {
    let mode = ChildMode(store: UserDefaults(suiteName: UUID().uuidString)!)
    mode.set(true)
    let state = ParentalControlsState(
        store: InMemoryStore(),
        childAccounts: ChildAccountList(store: InMemoryStore()),
        profileStore: InMemoryStore(), childMode: mode)
    #expect(state.rule.applies == false)
    #expect(state.isAllowed(finished: "kontowechsel"))
}

/// **The way out stays open.** A lock without a way out is not a lock but a defect: Whoever
/// forgot the PIN would otherwise never get back to their own device.
@MainActor
@Test func theWayOutStaysOpen() {
    let state = stateWithPin(kind: true)
    #expect(state.isAllowed(finished: "pinVergessen"))
}

// MARK: - Setting (stage 3)

/// **Without a PIN nothing applies — with a PIN everything applies.**
///
/// That is why this screen exists at all: Before stage 3 there was no way to set a PIN on
/// the TV. ``ProtectionRule/applies`` demands one, however, and so the four locked doors and
/// the filter stood there and did nothing.
@MainActor
@Test func onlyThePinArmsTheLock() {
    let mode = ChildMode(store: UserDefaults(suiteName: UUID().uuidString)!)
    mode.set(true)
    let state = ParentalControlsState(
        store: InMemoryStore(),
        childAccounts: ChildAccountList(store: InMemoryStore()),
        profileStore: InMemoryStore(), childMode: mode)

    #expect(state.rule.applies == false)
    state.setPin("2468")
    #expect(state.rule.applies)
    #expect(state.isAllowed(finished: "kindersicherung") == false)
}

/// **The way out takes the device lock with it.**
///
/// If it stayed, the device would still be in child mode after the reset, only without a
/// key — exactly the trap the rule "only with a PIN" protects against.
@MainActor
@Test func theWayOutTakesTheDeviceLockAlong() {
    let mode = ChildMode(store: UserDefaults(suiteName: UUID().uuidString)!)
    let state = ParentalControlsState(
        store: InMemoryStore(),
        childAccounts: ChildAccountList(store: InMemoryStore()),
        profileStore: InMemoryStore(), childMode: mode)

    state.setPin("2468")
    state.setDeviceLock(true)
    #expect(state.rule.applies)

    state.clearPin()
    #expect(state.rule.isPinSet == false)
    #expect(state.rule.deviceLocked == false)
    #expect(state.isAllowed(finished: "kindersicherung"))
}

/// **The device lock applies without a child account.**
///
/// An Apple TV in a child's room is locked no matter who is signed in — a child account, on
/// the other hand, brings its limit everywhere. Both routes suffice on their own.
@MainActor
@Test func deviceLockAppliesEvenWithoutChildAccount() {
    let mode = ChildMode(store: UserDefaults(suiteName: UUID().uuidString)!)
    let state = ParentalControlsState(
        store: InMemoryStore(),
        childAccounts: ChildAccountList(store: InMemoryStore()),
        profileStore: InMemoryStore(), childMode: mode)

    state.setPin("2468")
    #expect(state.rule.applies == false)
    state.setDeviceLock(true)
    #expect(state.rule.applies)
}

/// **A changed PIN applies immediately, the old one no longer.**
@MainActor
@Test func changedPinAppliesImmediately() {
    let mode = ChildMode(store: UserDefaults(suiteName: UUID().uuidString)!)
    mode.set(true)
    let state = ParentalControlsState(
        store: InMemoryStore(),
        childAccounts: ChildAccountList(store: InMemoryStore()),
        profileStore: InMemoryStore(), childMode: mode)

    state.setPin("1111")
    #expect(state.matchesPin("1111"))
    state.setPin("2222")
    #expect(state.matchesPin("1111") == false)
    #expect(state.matchesPin("2222"))
}

// MARK: - The age limit (stage 5)

@MainActor
private func stateWithLimit() -> (ParentalControlsState, InMemoryStore) {
    let store = InMemoryStore()
    let mode = ChildMode(store: UserDefaults(suiteName: UUID().uuidString)!)
    mode.set(true)
    let state = ParentalControlsState(
        store: store,
        childAccounts: ChildAccountList(store: InMemoryStore()),
        profileStore: InMemoryStore(), childMode: mode)
    state.setPin("1234")
    return (state, store)
}

/// **Without a chosen limit the filter filters nothing** — and that is not negligence but
/// the rule: ``ApprovalInterpretation/shows(_:at:blockUnrecognized:assignments:)`` begins with
/// `guard let limit else { return true }`.
///
/// The check records that until a level is chosen the lock **applies but filters nothing**
/// — two different things that are easily taken for one.
@MainActor
@Test func withoutLimitLockAppliesAndFiltersNothing() {
    let (state, _) = stateWithLimit()
    #expect(state.rule.applies)
    #expect(state.limit == nil)
    #expect(state.rule.shows(approval: "18"))
}

/// With a chosen level, what lies above it drops out.
@MainActor
@Test func withLimitAnythingAboveDropsOut() {
    let (state, _) = stateWithLimit()
    state.set(limit: .from12)
    #expect(state.rule.shows(approval: "6"))
    #expect(state.rule.shows(approval: "12"))
    #expect(state.rule.shows(approval: "16") == false)
}

/// **"Without limit" is not the same as "from 0".**
///
/// The difference is that between "not blocked at all" and "everything blocked except
/// FSK 0" — two ends of the same row. Whoever turned the missing value into a 0 would turn
/// the default into the strictest setting.
@MainActor
@Test func withoutLimitIsNotFromZero() {
    let (state, _) = stateWithLimit()
    state.set(limit: .from0)
    #expect(state.rule.shows(approval: "6") == false)

    state.set(limit: nil)
    #expect(state.limit == nil)
    #expect(state.rule.shows(approval: "6"))
}

/// **The default for misunderstood values is "block".** When in doubt, show less — and the
/// doubt is narrowly defined: A missing rating gets through, only a misunderstood one drops
/// out.
@MainActor
@Test func misunderstoodLocksItself() {
    let (state, _) = stateWithLimit()
    state.set(limit: .from12)

    #expect(state.rule.blocksUnrecognized)
    #expect(state.rule.shows(approval: "Nicht geprüft") == false)
    #expect(state.rule.shows(approval: nil))

    state.set(blocksUnrecognized: false)
    #expect(state.rule.shows(approval: "Nicht geprüft"))
}

// MARK: - What survives a restart

/// **Child mode survives the restart** — otherwise it would be a switch for one session and
/// not a lock.
///
/// Checked on a **second** store instance on the same area: That is the restart, as far as a
/// check can reproduce it. A holder that only reads its own marker would pass this check
/// even if it never wrote anything.
@MainActor
@Test func childModeSurvivesRestart() {
    let area = UUID().uuidString
    let store = InMemoryStore()

    let previous = ParentalControlsState(
        store: store,
        childAccounts: ChildAccountList(store: InMemoryStore()),
        profileStore: InMemoryStore(), childMode: ChildMode(store: UserDefaults(suiteName: area)!))
    previous.setPin("1234")
    previous.setDeviceLock(true)

    let after = ParentalControlsState(
        store: store,
        childAccounts: ChildAccountList(store: InMemoryStore()),
        profileStore: InMemoryStore(), childMode: ChildMode(store: UserDefaults(suiteName: area)!))

    #expect(after.rule.deviceLocked)
    #expect(after.rule.isPinSet)
    #expect(after.rule.applies)
}

/// **The age limit survives the restart as well** — and "without limit" too.
///
/// The second part is the harder one: A store that turns a missing value into a 0 on
/// reading would pass the first part and, at the restart, turn the default into the strictest
/// setting.
@MainActor
@Test func limitSurvivesRestartAndNoLimitToo() {
    let store = InMemoryStore()
    let area = UUID().uuidString
    func state() -> ParentalControlsState {
        ParentalControlsState(
            store: store,
            childAccounts: ChildAccountList(store: InMemoryStore()),
            profileStore: InMemoryStore(), childMode: ChildMode(store: UserDefaults(suiteName: area)!)
        )
    }

    let previous = state()
    previous.set(limit: .from12)
    #expect(state().limit == .from12)

    previous.set(limit: nil)
    #expect(state().limit == nil)
}

/// **There is deliberately no attempt counter**, and this check holds the decision fast so
/// that it is not "retrofitted" later.
///
/// Four digits are 10,000 possibilities, and every entry on the remote costs seconds —
/// whoever wants to guess needs days. A lock after three failed attempts would reliably hit
/// the parent who mistyped, and they would then have a device that no longer obeys them. The
/// protection against onlookers is the **shuffled keyboard** in the ``PinSheet``, which is
/// re-rolled after every failed attempt — not a counter.
@MainActor
@Test func thereIsNoAttemptCounter() {
    let state = stateWithPin(kind: true)
    for _ in 0..<20 {
        #expect(state.isAllowed(finished: "kontowechsel") == false)
        #expect(state.verify("0000") == false)
    }
    // The right PIN still goes through afterwards — nobody is locked out.
    #expect(state.verify("1234"))
    #expect(state.isAllowed(finished: "kontowechsel"))
}
