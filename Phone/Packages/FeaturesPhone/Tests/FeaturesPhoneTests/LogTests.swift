import Testing

@testable import FeaturesPhone

/// What the log screen promises.
///
/// **The occasion was a number that lied.** The diagnosis showed "Entries: 1" while the
/// submitted report had 239 lines — a different ledger was counted than the one that
/// is submitted. What is checked is therefore exactly the decomposition from which the new numbers
/// arise.
@Suite("Log")
struct LogTests {

    @Test("An empty trace yields no row, not an empty one")
    func emptyTrace() {
        #expect(LogModel.decomposed("").isEmpty)
        #expect(LogModel.decomposed("\n\n\n").isEmpty)
    }

    /// **Newest on top.** A trace file is appended at the end; whoever shows it in reading
    /// direction shows the app start at the top and at the very bottom what is being looked for.
    @Test("The newest comes first")
    func newestOnTop() {
        let rows = LogModel.decomposed("erste\nzweite\ndritte")
        #expect(rows == ["dritte", "zweite", "erste"])
    }

    /// **The number must be the same as the number of rows shown** — otherwise
    /// again a number stands above something other than what stands next to it.
    @Test("The number in the segment counts the rows that are there")
    @MainActor
    func countMatchesRows() {
        let model = LogModel()
        let raw = "a\nb\nc\n"
        #expect(LogModel.decomposed(raw).count == 3)
        #expect(model.rows.isEmpty, "unloaded is empty and not guessed")
    }

    /// **By character and not by words.** ``ContentEntryRecord/row`` sets "✗" for a
    /// failure; checking for German words would lose the highlighting in the two
    /// other languages.
    @Test("Notable is what carries a marker")
    @MainActor
    func anomaly() {
        let model = LogModel()
        #expect(model.isNotable("06.09. 21:53:11  Wiedergabe  ✗  abgebrochen"))
        #expect(!model.isNotable("06.09. 21:53:11  Wiedergabe  ·  gestartet"))
    }
}
