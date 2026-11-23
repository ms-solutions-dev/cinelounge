import Core
import Foundation
import ParentalControls
import Testing

@testable import Features

/// **The manual assignment of foreign ratings** — AP29, 2026-09-11.
///
/// What is checked is the calculation behind it, not the sheet: What the mirror makes of a
/// **count**, whether a manual assignment changes the side, and whether it then really lets
/// things through.
struct ApprovalSheetTests {

    /// **The counting pass and the interpretation are separate — and compute the same thing.**
    ///
    /// The separation is necessary because the counting happens where the catalog runs through
    /// anyway (``Flows/CatalogIndex``). Two routes to the same number are exactly the place
    /// where it drifts apart.
    @Test("Counted or raw — the same mirror")
    func countAndRawTextsAgree() {
        let rawTexts: [String?] = ["FSK 16", "FSK 16", "TV-MA", nil, "", "FSK 12"]
        let counted = ["FSK 16": 2, "TV-MA": 1, "": 2, "FSK 12": 1]

        let fromRaw = ApprovalMirror.about(rawTexts)
        let fromCounts = ApprovalMirror.about(counted: counted)

        #expect(fromRaw == fromCounts)
    }

    /// **"No rating" is not a misunderstood value.**
    ///
    /// A title without a rating is no statement about its content — it gets through. Throwing
    /// both together would mean giving a child account an almost empty library, because on the
    /// media server by no means every title carries a rating.
    @Test("A missing and a not-understood rating are two different things")
    func withoutEntryIsNotMisunderstood() {
        let mirror = ApprovalMirror.about(counted: ["": 7, "TV-MA": 3])

        #expect(mirror.pending.map(\.rawText) == ["TV-MA"])
        #expect(mirror.openTitles == 3)
        #expect(mirror.recognized.contains { $0.rawText.isEmpty && $0.count == 7 })
    }

    /// **A manual assignment changes the side — and carries its origin with it.**
    ///
    /// "FSK 16 → from 16" is a reading, "TV-MA → from 16" the decision of a human. Whoever wants
    /// to undo it must be able to find it.
    @Test("Mapped entries stand with the understood ones, marked as set by hand")
    func assignmentSwitchesPage() throws {
        let counted = ["TV-MA": 31, "FSK 16": 41]

        let previous = ApprovalMirror.about(counted: counted)
        #expect(previous.pending.map(\.rawText) == ["TV-MA"])

        let after = ApprovalMirror.about(counted: counted, assignments: ["TV-MA": 16])
        #expect(after.pending.isEmpty)

        let entry = try #require(after.recognized.first { $0.rawText == "TV-MA" })
        #expect(entry.alter == 16)
        #expect(entry.byHand)

        // And the reading next to it remains a reading.
        let read = try #require(after.recognized.first { $0.rawText == "FSK 16" })
        #expect(!read.byHand)
    }

    /// **And afterwards the rule really lets things through** — the assignment is not cosmetics.
    ///
    /// The finding of 2026-09-10 was: A server with `TV-MA` delivered almost nothing with a limit
    /// set, because `blocksUnrecognized` has the default "yes". That is exactly what this line
    /// checks — blocked before, not after.
    @Test("A mapping opens what was locked before")
    func assignmentOpens() {
        let locked = ProtectionRule(
            deviceLocked: true, accountKind: .kind, isPinSet: true, limit: .from16,
            blocksUnrecognized: true)
        #expect(!locked.shows(approval: "TV-MA"))

        let pending = ProtectionRule(
            deviceLocked: true, accountKind: .kind, isPinSet: true, limit: .from16,
            blocksUnrecognized: true, assignments: ["TV-MA": 16])
        #expect(pending.shows(approval: "TV-MA"))

        // **And an assignment that is too high keeps blocking.** "TV-MA → from 18" at limit 16 is
        // an answer and not a free pass.
        let tooHigh = ProtectionRule(
            deviceLocked: true, accountKind: .kind, isPinSet: true, limit: .from16,
            blocksUnrecognized: true, assignments: ["TV-MA": 18])
        #expect(!tooHigh.shows(approval: "TV-MA"))
    }

    /// **The working order is the frequency** — whoever assigns wants to make the assignment
    /// that has the most effect.
    @Test("The most frequent comes first")
    func mostFrequentFirst() {
        let mirror = ApprovalMirror.about(counted: ["NR": 1, "TV-MA": 31, "R": 12])
        #expect(mirror.pending.map(\.rawText) == ["TV-MA", "R", "NR"])
    }
}
