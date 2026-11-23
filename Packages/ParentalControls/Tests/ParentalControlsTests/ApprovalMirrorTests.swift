import Testing

@testable import ParentalControls

/// That the two blocks of the sheet are **the same** computation.
///
/// The design shows "Understood" and "Not classified" one below the other. If they were two
/// computations, on the left would be the number from the last sync and on the right the one from this one —
/// and the sum would never add up.
@Suite("Rating mirror")
struct ApprovalMirrorTests {

    /// The shape of the real thing and never its content: This is how servers write ratings.
    static let catalog: [String?] = [
        "FSK 16", "FSK 16", "FSK 12", "12", "ab 0", "TV-MA", "TV-MA", "Not Rated", nil, "",
    ]

    @Test("What can be interpreted is listed with its level")
    func recognized() {
        let mirror = ApprovalMirror.about(Self.catalog)
        let sixteen = mirror.recognized.first { $0.rawText == "FSK 16" }
        #expect(sixteen?.alter == 16)
        #expect(sixteen?.count == 2)
        #expect(mirror.recognized.contains { $0.rawText == "12" && $0.alter == 12 })
        #expect(mirror.recognized.contains { $0.rawText == "ab 0" && $0.alter == 0 })
    }

    /// **"Without rating" is not a failure.** A title without a rating passes; putting it
    /// under "not classified" would turn a missing value into a
    /// warning.
    @Test("No rating counts and is listed among the understood")
    func withoutValue() {
        let mirror = ApprovalMirror.about(Self.catalog)
        let empty = mirror.recognized.first { $0.rawText.isEmpty }
        #expect(empty?.count == 2, "nil and the empty text are the same")
        #expect(!mirror.pending.contains { $0.rawText.isEmpty })
    }

    /// **The most frequent first** — whoever maps wants to make the mapping that has the
    /// most effect.
    @Test("The open list is in working order")
    func order() {
        let mirror = ApprovalMirror.about(Self.catalog)
        #expect(mirror.pending.map(\.rawText) == ["TV-MA", "Not Rated"])
        #expect(mirror.openTitles == 3)
    }

    /// **A mapping moves an entry from right to left** — the whole
    /// entry, with its number. That is exactly the operation the sheet offers.
    @Test("An assignment moves to the understood side")
    func assigned() {
        let mirror = ApprovalMirror.about(Self.catalog, assignments: ["TV-MA": 16])
        #expect(mirror.pending.map(\.rawText) == ["Not Rated"])
        let entry = mirror.recognized.first { $0.rawText == "TV-MA" }
        #expect(entry?.alter == 16)
        #expect(entry?.count == 2)
        #expect(entry?.byHand == true, "a decision, not a reading")
    }

    /// **An empty catalog is information and not a crash.**
    @Test("Without titles the mirror is empty")
    func empty() {
        let mirror = ApprovalMirror.about([])
        #expect(mirror.recognized.isEmpty)
        #expect(mirror.pending.isEmpty)
        #expect(mirror.openTitles == 0)
    }
}
