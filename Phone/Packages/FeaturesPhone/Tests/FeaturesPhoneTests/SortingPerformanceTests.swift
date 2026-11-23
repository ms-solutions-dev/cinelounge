import Foundation
import Testing

@testable import FeaturesPhone

/// Sorting against a catalog **in the shape of a real one**.
///
/// **Why the shapes of a dump and not freely invented ones** (AP3): A sorting check
/// against shapes one makes up checks the rule of making things up. The extract keeps the
/// shapes the house library really had, with every title replaced by an invented one —
/// "Der Skitkli bof Gaviame - Rai Basvaufe" (article at the front **and** back, hyphen),
/// "Das Jublar bla Miokre" (article plus umlaut in the third word),
/// "The Bamude Pliv-Runbro 2: Hotr kl Krapria" (colon, digit in the middle),
/// "Hiske bl Bratklei" (no article, but an "on" that is not one).
///
/// **The extract is dated and carries its origin in the file.** A test suite that
/// claims a source without saying which one is a made-up list with a better reputation.
///
/// **What is expressly NOT checked here is the duration.** A time limit in a
/// check run that runs next to a release build eventually goes red because the
/// machine was busy — and a guard that raises false alarms is worse than
/// none (same lesson as with the airplane-mode start, E56). The measurement is in the
/// roadmap as a number and in ``JumpMarks/sortedEntries(_:after:)``; what is stated here is that the faster
/// method delivers **the same** result.
@Suite("Sorting on the catalog extract")
struct SortingPerformanceTests {

    private struct Extract: Decodable {
        /// Stored keys keep their original (German) names — renaming them would
        /// make data written by earlier versions unreadable (AP85 B4).
        private enum CodingKeys: String, CodingKey {
            case origin = "woher"
            case count = "anzahl"
            case title = "titel"
        }

        let origin: String
        let count: Int
        let title: [String]
    }

    private func catalog() throws -> [String] {
        let url = try #require(
            Bundle.module.url(
                forResource: "bestand_titel", withExtension: "json",
                subdirectory: "Fixtures"),
            "the extract must be in the bundle as a test fixture")
        let extract = try JSONDecoder().decode(Extract.self, from: Data(contentsOf: url))
        #expect(extract.count == extract.title.count, "the count in the file must match")
        return extract.title
    }

    /// **The actual purpose of this check.** Since 2026-09-10 the key is built once
    /// per title instead of twice per comparison. That is only a speed-up and
    /// not a change if the same order comes out title by title.
    @Test("The faster method orders exactly like the slow one")
    func sameResultAsBefore() throws {
        let title = try catalog()

        let fast = JumpMarks.sortedEntries(title, after: { $0 })
        let slow = title.sorted {
            JumpMarks.key($0).localizedStandardCompare(JumpMarks.key($1))
                == .orderedAscending
        }

        #expect(fast == slow)
    }

    /// The article drops off at the front and only at the front — checked against the extract, because
    /// this very extract contains the cases where it is decided.
    ///
    /// The entries are the long ones that begin with "Der" — "Der Pächter der Brücken - Die
    /// Wanderer" and its kin, with a second article in the middle. They are chosen by shape and not
    /// by name, and the expected tag is the first letter of the word after the article, read from
    /// the entry and not written down: the public export gives the titles other words, and with
    /// them other letters — what is checked is that the tag is not the article's "D".
    @Test("The article drops at the front and stays in the middle")
    func articleOnlyAtFront() throws {
        let title = try catalog()
        let ordered = JumpMarks.sortedEntries(title, after: { $0 })

        let millKeepers = ordered.filter {
            $0.hasPrefix("Der ") && $0.split(separator: " ").count >= 4
        }
        try #require(!millKeepers.isEmpty, "the extract must contain this case")

        for entry in millKeepers {
            let afterArticle = try #require(entry.split(separator: " ").dropFirst().first?.first)
            let expected = String(afterArticle).uppercased()
            #expect(
                JumpMarks.tag(forItem: entry) == expected,
                "\u{201E}\(entry)\u{201C} belongs under \(expected) and not under D")
        }
    }

    /// **The tag comes from the key and not from the title** (E51). On the
    /// extract that means: no title stands in a block whose tag the bar does not
    /// offer at all — a jump into nothing is worse than no jump.
    @Test("Every title falls into a block the bar offers")
    func noMarkIntoNothing() throws {
        let title = try catalog()
        let isOffered = Set(JumpMarks.marks(from: title))

        for entry in title {
            #expect(
                isOffered.contains(JumpMarks.tag(forItem: entry)),
                "\u{201E}\(entry)\u{201C} carries a mark that is missing from the bar")
        }
    }
}
