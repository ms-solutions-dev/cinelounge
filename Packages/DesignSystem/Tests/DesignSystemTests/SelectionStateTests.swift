import SwiftUI
import Testing

@testable import DesignSystem

/// **What a focus target says about its state** — AP30, 2026-09-11.
///
/// The words live in one place so that "on" means "on" everywhere. Previously
/// the same string concatenation stood twice in the source, and two places for the same information
/// drift apart at the first new state.
struct SelectionStateTests {

    private func spoken(_ state: SelectionState) -> String {
        state.announcementText.map { String(describing: $0) } ?? ""
    }

    /// **The unselected option stays silent, the switched-off switch does not.**
    ///
    /// That is the one difference on which the whole division hangs: "not
    /// selected" on nine of ten rows of a list is information that one ignores after
    /// the third time. "Off" on a switch is half the answer to the
    /// question for which one went there.
    @Test("A choice is silent when it is not made — a switch never is")
    func silenceAndSpeech() {
        #expect(spoken(.chosen(false)).isEmpty)
        #expect(spoken(.chosen(true)).contains("a11y.state.selected"))
        // “On”, “Off” and “paused” have lived in the shared catalog since the final step of AP58
        // and already resolve here — in the check run without an app bundle a key of the app would instead
        // show up raw (see `a11y.state.selected`).
        #expect(spoken(.on(false)).contains("\"off\""))
        #expect(spoken(.on(true)).contains("\"on\""))
        #expect(spoken(.none).isEmpty)
        #expect(spoken(.key(nil)).isEmpty)
        #expect(spoken(.key("common.paused")).contains("\"paused\""))
    }

    /// **An empty word is not a state but a gap.**
    ///
    /// ``SelectionState/word(_:)`` carries what comes from the server — the name of an audio track,
    /// of a language. If it is missing, reading "" aloud would be worse than staying silent.
    @Test("An empty word is not read aloud")
    func emptyWord() {
        #expect(spoken(.word(nil)).isEmpty)
        #expect(spoken(.word("")).isEmpty)
        #expect(spoken(.word("Deutsch")).contains("Deutsch"))
    }

    /// **Only the choice among several is "selected".**
    ///
    /// A switched-on switch is not — the screen reader would otherwise speak of
    /// a selection where there is no second row at all.
    @Test("The trait follows the choice, not the switch")
    func attributeStatement() {
        #expect(SelectionState.chosen(true).isSelected)
        #expect(!SelectionState.chosen(false).isSelected)
        #expect(!SelectionState.on(true).isSelected)
        #expect(!SelectionState.key("a11y.state.selected").isSelected)
    }

    /// **States that do not exclude each other stand side by side.**
    ///
    /// "Live" in the sidebar is selected at startup, expanded and currently
    /// syncing. None of the three may displace the others — and what has nothing to say
    /// drops out instead of leaving a gap with a comma.
    @Test("Several states stand side by side, empty ones drop out")
    func combined() {
        let all = String(
            describing: SelectionState.combined([
                .chosen(true), .key("a11y.state.expanded"),
                .key("a11y.state.syncing"),
            ]))
        #expect(all.contains("a11y.state.selected"))
        #expect(all.contains("a11y.state.expanded"))
        #expect(all.contains("a11y.state.syncing"))
        // **And in this order, with exactly two separators.**
        //
        // Checked on the built-in string and not on the comma (2026-09-11): a
        // `Text` describes itself with an appended `modifiers: []`, and that too contains
        // a ", ". The first version of this test therefore counted four parts for three
        // words — and for a single word a separator that did not exist.
        #expect(all.contains("a11y.state.selected, a11y.state.expanded, a11y.state.syncing"))

        // A single word stands there without a separator …
        let one = String(describing: SelectionState.combined([.none, .chosen(true), .none]))
        #expect(one.contains("\"a11y.state.selected\""))

        // … and from nothing but empty states nothing at all results, not "", , ".
        let nothing = String(describing: SelectionState.combined([.none, .chosen(false)]))
        #expect(nothing.contains("verbatim(\"\")"))
    }
}
