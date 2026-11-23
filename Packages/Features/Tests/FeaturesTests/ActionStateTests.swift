import DesignSystem
import Testing

@testable import Features

/// **What an action says while it is running** — AP46, 2026-09-23.
///
/// The finding came while converting the diagnostics and was the same six times: An
/// action carried its state as a ternary in the label — "Measure"/"Measuring…",
/// "Send"/"Sending…", "Save"/"Saved", "Find server"/"Searching…". Two of the six places
/// attached an `a11y.state.busy` by hand, four did not.
@Suite("The state of an action")
struct ActionStateTests {

    /// **Two symbols for the same state, and that was the most expensive of the three
    /// finds.**
    ///
    /// In the catalog there was `hourglass` for measuring and `arrow.up.circle` for
    /// sending. Whoever knows both screens does not know which of the two means "running
    /// right now" — and `arrow.up.circle` looks like "upload now", that is, like a prompt
    /// instead of a piece of information.
    @Test("Whatever is running shows the hourglass — regardless of what it shows at rest")
    func runningAlwaysShowsHourglass() {
        #expect(
            ActionRow.character(at: .isRunning, fallback: "speedometer") == Glyph.hourglass.name)
        #expect(
            ActionRow.character(at: .isRunning, fallback: "square.and.arrow.up")
                == Glyph.hourglass.name)
        // Even without a symbol of its own: The run brings its own.
        #expect(ActionRow.character(at: .isRunning, fallback: nil) == Glyph.hourglass.name)
    }

    @Test("At rest the action's symbol applies, and without one there is none")
    func idleShowsOwn() {
        #expect(ActionRow.character(at: .ready, fallback: "speedometer") == "speedometer")
        #expect(ActionRow.character(at: .ready, fallback: nil) == nil)
    }

    @Test("Done shows the checkmark")
    func doneShowsCheckmark() {
        #expect(
            ActionRow.character(at: .done, fallback: "speedometer")
                == Glyph.done.pair.filled)
    }

    @Test("The wording changes with the state")
    func wordingChanges() {
        let title = "settings.measure"
        let run = "settings.measuring"
        #expect(
            ActionRow.key(at: .ready, title: title, statusTitle: run) == title)
        #expect(
            ActionRow.key(at: .isRunning, title: title, statusTitle: run) == run)
    }

    /// **An action with only one word keeps its word.**
    ///
    /// "Sign out" has no running form. If the label then fell back to an empty key, there
    /// would be nothing there in the middle of the operation — and a button without a label
    /// looks like an error, not like a running action. It shows the hourglass and keeps its
    /// word.
    @Test("Without a running form the title stays")
    func withoutRunningFormTitleStays() {
        let title = "common.signOut"
        #expect(
            ActionRow.key(at: .isRunning, title: title, statusTitle: nil) == title)
        #expect(
            ActionRow.key(at: .done, title: title, statusTitle: nil) == title)
    }

    /// **The most important difference in the whole type**, and it is invisible.
    ///
    /// `isRunning` and `locked` both discard the press and neither looks like "press me".
    /// For the screen reader they must nevertheless say **different** sentences: "running
    /// right now" means wait, "not available" means enter something first. If it were the
    /// same sentence, an empty field would sound like a running measurement — and one
    /// would wait for something that never comes.
    @Test("Running and locked do not say the same")
    func runningAndLockAreTwoStatements() {
        let run = ActionRow.info(at: .isRunning)
        let lock = ActionRow.info(at: .locked)
        #expect(run != nil)
        #expect(lock != nil)
        #expect(run != lock)
    }

    /// **A button that cannot do anything still says what it would do.**
    ///
    /// "Saved" on an empty field would be a receipt for something that has not happened —
    /// and the catalog has exactly this pairing: ``PortalSettings`` labels the same button
    /// "Save" and "Saved" and disables it as long as the field is empty.
    @Test("Locked keeps the title and its own symbol")
    func lockKeepsTitleAndSymbol() {
        #expect(
            ActionRow.key(
                at: .locked, title: "settings.saveKey", statusTitle: "settings.keySaved")
                == "settings.saveKey")
        #expect(ActionRow.character(at: .locked, fallback: "checkmark") == "checkmark")
    }

    /// Whoever is ready or done needs no addition: That is in the label.
    @Test("Ready and done carry no state announcement")
    func readyAndDoneStaySilent() {
        #expect(ActionRow.info(at: .ready) == nil)
        #expect(ActionRow.info(at: .done) == nil)
    }
}
