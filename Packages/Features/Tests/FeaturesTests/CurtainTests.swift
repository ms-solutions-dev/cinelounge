import Core
import Foundation
import ParentalControls
import Testing

@testable import Features

/// **The door stays with the action, the curtain hangs on the focus** — AP23, 2026-09-11.
///
/// Before this package only the button body of the section list checked. But the section
/// also follows the mere **focus change**, and unchecked: Whoever wandered through
/// the list in child mode got "Parental controls" with the adult switch and "Account"
/// with the account list to see. The door stood, and next to it the wall was made of glass.
@MainActor
private func stateInChildMode(_ digits: String = "1234") -> ParentalControlsState {
    let store = InMemoryStore()
    _ = Pin(store: store).set(digits)
    let mode = ChildMode(store: UserDefaults(suiteName: UUID().uuidString)!)
    mode.set(true)
    return ParentalControlsState(
        store: store, childAccounts: ChildAccountList(store: InMemoryStore()),
        profileStore: InMemoryStore(), childMode: mode)
}

/// **The decisive promise: Asking costs nothing.**
///
/// The obvious remedy was to call `isAllowed(finished:)` on focus change — and it is
/// wrong, because the pass lapses in the process. This check records that `isHidden`
/// is the other kind of question: any number of times, without effect. SwiftUI evaluates a view
/// several times per render pass; a question with a side effect would be a trap there.
@MainActor
@Test func coveredAsksWithoutConsuming() {
    let state = stateInChildMode()

    for _ in 0..<20 {
        #expect(state.isHidden("kindersicherung"))
    }
    // No sheet, no open question — just information.
    #expect(state.openQuestion == nil)

    // And the pass that exists afterwards is intact: The door opens.
    state.queryPending("kindersicherung")
    #expect(state.openQuestion == "kindersicherung")
    #expect(state.verify("1234"))
    for _ in 0..<20 {
        #expect(state.isHidden("kindersicherung") == false)
    }
    #expect(state.isAllowed(finished: "kindersicherung"))
}

/// **A child account wanders through the whole section list without a PIN
/// being asked** — and does not see the locked sections while doing so.
///
/// **Since 2026-09-20 there are five instead of two** (AP40): Channel lists, portals and Live
/// fell through a `default` to "open" although the shared door board locks them.
/// This check carried that along — it enumerated what was, and not what applies.
///
/// That is the package's "done when" promise, verbatim. It combines both halves:
/// wandering asks nothing (otherwise the list would be unusable), and yet there is
/// a curtain in front of exactly two sections.
@MainActor
@Test func wanderingAsksNothingAndStillShowsNothing() {
    let state = stateInChildMode()

    var covered: [SettingsSection] = []
    for area in SettingsSection.allCases {
        let door = SettingsView.door(forItem: area)
        if state.isHidden(door) { covered.append(area) }
    }

    #expect(state.openQuestion == nil, "Moving through the list asked for a PIN")
    #expect(Set(covered) == [.playlists, .portals, .live, .childLock, .account, .profiles])
}

/// **Without an effective lock nothing is covered.**
///
/// The normal case on the TV: an adult account, no child mode. A curtain that
/// appeared here would be a hurdle without cause — in front of every second section.
@MainActor
@Test func withoutLockNoCurtainHangs() {
    let store = InMemoryStore()
    _ = Pin(store: store).set("1234")
    let state = ParentalControlsState(
        store: store, childAccounts: ChildAccountList(store: InMemoryStore()),
        profileStore: InMemoryStore(),
        childMode: ChildMode(store: UserDefaults(suiteName: UUID().uuidString)!))

    for area in SettingsSection.allCases {
        #expect(state.isHidden(SettingsView.door(forItem: area)) == false)
    }
}

/// **`queryPending` does not open anything that is already open.**
///
/// The button on the curtain is meant to show the sheet — not to consume the pass
/// that it may just have obtained itself. Without this line, a second press
/// on an already lifted curtain would have asked for the PIN again.
@MainActor
@Test func askAfterAsksNoQuestionWithoutReason() {
    let state = stateInChildMode()
    state.queryPending("kindersicherung")
    #expect(state.verify("1234"))

    state.queryPending("kindersicherung")
    #expect(state.openQuestion == nil)
}
