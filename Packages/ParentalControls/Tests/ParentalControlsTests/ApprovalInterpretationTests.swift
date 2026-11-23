import Testing

@testable import ParentalControls

/// Raw texts as they really occur — **and CineLounge does not guess.**
///
/// The server delivers what is in the files: "FSK 16", "16", "DE-16", "R", "TV-MA",
/// "Not Rated", empty. The difference between **no rating** and **not understood**
/// is the whole point of this check.
@Suite("Rating interpretation")
struct ApprovalInterpretationTests {

    @Test("The German spellings are understood")
    func germanForms() {
        for raw in ["16", "FSK 16", "fsk-16", "FSK:16", "DE-16", "ab 16"] {
            #expect(
                ApprovalInterpretation.interpret(raw) == .approval(16),
                "„\(raw)“ sollte 16 ergeben")
        }
    }

    @Test("Every FSK level arrives")
    func allLevels() {
        for tier in [0, 6, 12, 16, 18] {
            #expect(ApprovalInterpretation.interpret("FSK \(tier)") == .approval(tier))
        }
    }

    /// **No rating is not an error but a state.**
    @Test("Empty and nil are no rating")
    func noRating() {
        #expect(ApprovalInterpretation.interpret(nil) == .noRating)
        #expect(ApprovalInterpretation.interpret("") == .noRating)
        #expect(ApprovalInterpretation.interpret("   ") == .noRating)
    }

    /// **What is foreign stays foreign — verbatim.** "R" is 17+ in the USA, 18+ in Canada
    /// and in a self-maintained library possibly a word without meaning.
    @Test("Foreign forms are not guessed but reported")
    func notGuessed() {
        for raw in ["R", "TV-MA", "Not Rated", "NC-17", "PG-13", "Unrated"] {
            #expect(
                ApprovalInterpretation.interpret(raw) == .unrecognized(raw),
                "„\(raw)“ darf nicht geraten werden")
        }
    }

    /// **A manual mapping takes precedence.** Whoever makes it takes responsibility for it.
    @Test("Assigned ratings are understood")
    func mappingTakesPrecedence() {
        #expect(
            ApprovalInterpretation.interpret("TV-MA", assignments: ["TV-MA": 16]) == .approval(16))
    }

    // MARK: - What follows for visibility

    @Test("Equal passes")
    func limitIsInclusive() {
        #expect(AgeLimit.from12.letsPass(12))
        #expect(AgeLimit.from12.letsPass(6))
        #expect(!AgeLimit.from12.letsPass(16))
    }

    /// **Without a limit nothing is filtered at all** — not even what is not understood. Whoever has not set a
    /// limit has not ordered a lock.
    @Test("Without a limit everything stays visible")
    func withoutLimit() {
        #expect(ApprovalInterpretation.shows("FSK 18", at: nil))
        #expect(ApprovalInterpretation.shows("TV-MA", at: nil))
        #expect(ApprovalInterpretation.shows(nil, at: nil))
    }

    /// **A title without a rating gets through.** Turning a missing value into a warning
    /// would be the same guessing, only in the other direction.
    @Test("No rating passes even with a limit")
    func noRatingPassesThrough() {
        #expect(ApprovalInterpretation.shows(nil, at: .from6))
    }

    /// **When in doubt block — but switchable off.** With a catalog with many foreign
    /// ratings, half the library would otherwise be missing, and it would look like a defect.
    @Test("Unrecognized ratings are locked when the switch is on")
    func blockingUnrecognized() {
        #expect(!ApprovalInterpretation.shows("TV-MA", at: .from12, blockUnrecognized: true))
        #expect(ApprovalInterpretation.shows("TV-MA", at: .from12, blockUnrecognized: false))
    }

    @Test("Above the limit is hidden, below passes")
    func limitTakesEffect() {
        #expect(!ApprovalInterpretation.shows("FSK 16", at: .from12))
        #expect(ApprovalInterpretation.shows("FSK 6", at: .from12))
    }
}
