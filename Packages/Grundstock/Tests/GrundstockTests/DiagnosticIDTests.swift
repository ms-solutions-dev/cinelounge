import Foundation
import Testing

@testable import Grundstock

/// **The identifier is read aloud, not skimmed** (AP17, 2026-09-02).
///
/// Between the viewer in the living room and support lies a phone call.
/// Everything checked here decides whether the character string
/// survives this path.
@Suite("Diagnostic ID")
struct DiagnosticIDTests {

    /// **Confusable characters are out.** A "zero or O?" on the phone
    /// costs more than the four characters the alphabet loses by it.
    @Test("The alphabet contains no easily confused character")
    func alphabetHasNoConfusables() {
        let forbidden: Set<Character> = ["0", "O", "1", "I", "L", "8", "B", "5", "S", "2", "Z"]
        let used = Set(DiagnosticID.alphabet)

        #expect(used.isDisjoint(with: forbidden))
        // And enough must remain to tell them apart: 24 characters with
        // six positions are about 191 million possibilities.
        #expect(DiagnosticID.alphabet.count >= 20)
        #expect(Set(DiagnosticID.alphabet).count == DiagnosticID.alphabet.count)
    }

    @Test("The identifier has the form XXXX-XX")
    func shapeIsFourTwo() {
        let identifier = DiagnosticID.fresh()

        #expect(identifier.count == DiagnosticID.locations + 1)
        #expect(Array(identifier)[4] == "-")
        #expect(
            identifier.filter { $0 != "-" }.allSatisfy(DiagnosticID.alphabet.contains),
            "\(identifier) carries a character outside the alphabet")
    }

    /// **A new one per submission.** Two reports from the same device are two
    /// cases; an identifier that applies to both helps nobody find
    /// the second one.
    @Test("Two identifiers are almost never the same")
    func twoAreVirtuallyNeverEqual() {
        let many = Set((0..<500).map { _ in DiagnosticID.fresh() })
        // With 191 million possibilities and 500 draws the
        // probability of a duplicate is 0.065 percent. What is required
        // is therefore not "all different" but "almost all" — otherwise
        // the check would one day fail without anything being broken.
        #expect(many.count >= 495)
    }

    // MARK: - Im Bericht

    /// **A line of its own with a fixed prefix**: whoever searches a folder full of reports
    /// searches with a tool that finds lines.
    @Test("The identifier is a line of its own and is found again")
    func lineIsFoundAgain() {
        let identifier = DiagnosticID.fresh()
        let report = """
            CineLounge — Diagnostics
            Created: sometime
            \(DiagnosticID.headerLine(identifier))
            Version: 1.0

            ═══ Errors ═══
            nothing
            """

        #expect(DiagnosticID.fromReport(report) == identifier)
    }

    @Test("Without an identifier the report returns none")
    func withoutIDNoneIsReported() {
        #expect(DiagnosticID.fromReport("CineLounge — Diagnostics\nVersion: 1.0") == nil)
        // An empty line after the prefix is not an identifier either.
        #expect(DiagnosticID.fromReport("Diagnostic ID:   ") == nil)
    }

    /// The hyphen sits after four characters — checked on an identifier with
    /// known characters so that the check does not roll dice.
    @Test("The hyphen sits after four characters")
    func hyphenSitsAfterFour() {
        #expect(DiagnosticID.format("ACDEFG") == "ACDE-FG")
        // Whatever does not have the right length is left untouched — an
        // invented separation would be worse than none at all.
        #expect(DiagnosticID.format("ACD") == "ACD")
    }
}
