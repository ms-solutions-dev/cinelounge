import Foundation

/// What the app **really** makes of the ratings in a catalog — both halves.
///
/// The design shows two blocks: "Understood" and "Not classified". Both are the same
/// computation over the same catalog, and it would be a mistake to keep them separately â
/// then the left would show a number from the last sync and the right one from this one.
///
/// **Separate from ``UnrecognizedRatings``, because one stays and the other does not.**
/// The mappings belong to the device and survive every sync; this mirror belongs to the
/// catalog and is a different one at the next load. What lives for different lengths of
/// time does not belong in the same value.
///
/// **The understood side is the more important of the two.** It is the evidence: "FSK 16
/// → from 16, 41 titles" can be verified, and whoever sets a limit sees beforehand what
/// it will cost. Without it only the list of failures would be there, and the mapping
/// "TV-MA → from 16" would be an input into the unknown.
public struct ApprovalMirror: Sendable, Equatable {

    /// A raw text, how often it occurred, and what became of it.
    public struct ContentEntryRecord: Sendable, Equatable, Identifiable {

        /// What the server wrote. **Empty means "no rating"** — the title carries no rating, and
        /// that is something different from one that nobody understands.
        public let rawText: String

        public let count: Int

        /// The minimum age, if there is one. `nil` means: not classified.
        public let alter: Int?

        /// Whether the mapping comes from a hand.
        ///
        /// **It is in the sheet next to it**, because it has a different reliability: "FSK
        /// 16 → from 16" is a reading, "TV-MA → from 16" is a person's decision. Whoever wants
        /// to withdraw it later must be able to find it.
        public let byHand: Bool

        public var id: String { rawText }

        public init(rawText: String, count: Int, alter: Int?, byHand: Bool = false) {
            self.rawText = rawText
            self.count = count
            self.alter = alter
            self.byHand = byHand
        }
    }

    /// What could be interpreted — the evidence page.
    public let recognized: [ContentEntryRecord]

    /// What is open. **The order is the working order:** the most frequent first.
    public let pending: [ContentEntryRecord]

    /// How many titles hang on the open ratings — the number in the heading.
    public var openTitles: Int { pending.reduce(0) { $0 + $1.count } }

    public init(recognized: [ContentEntryRecord] = [], pending: [ContentEntryRecord] = []) {
        self.recognized = recognized
        self.pending = pending
    }

    /// Counts a whole catalog.
    ///
    /// **One pass for both sides.** Two passes over 32,000 titles would not only be twice as
    /// expensive, they could also diverge: a mapping can be added between them, and then a raw
    /// text would appear in both lists.
    ///
    /// **"No rating" is counted too and goes to the understood.** A title without a rating is
    /// no statement about its content — it passes
    /// (``ApprovalInterpretation/shows(_:at:blockUnrecognized:assignments:)``), and the row in the
    /// sheet says so explicitly instead of concealing it.
    public static func about(
        _ rawTexts: [String?], assignments: [String: Int] = [:]
    ) -> ApprovalMirror {
        var counted: [String: Int] = [:]
        for raw in rawTexts {
            counted[key(forItem: raw), default: 0] += 1
        }
        return about(counted: counted, assignments: assignments)
    }

    /// The key under which a raw text is counted — **empty means "no rating".**
    ///
    /// Public, because counting and interpreting have been separate since 11.09.2026:
    /// whoever goes through a catalog counts along and does not carry the 32,000 raw texts
    /// through the app. Both sides must form the same key, otherwise one would count
    /// "FSK 16 " and the other "FSK 16".
    public static func key(forItem rawText: String?) -> String {
        (rawText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The same computation over a **finished count.**
    ///
    /// **Separate, because counting happens where the catalog passes through anyway**
    /// (AP29, 11.09.2026): `Flows.CatalogIndex` collects the catalog for the
    /// filmography; the ratings fall off in the process. A second pass would not only be twice
    /// as expensive — it could also diverge, and then a raw text would appear in both
    /// lists.
    public static func about(
        counted: [String: Int], assignments: [String: Int] = [:]
    ) -> ApprovalMirror {
        var interpreted: [String: (count: Int, alter: Int?, byHand: Bool)] = [:]
        var withoutValue = 0

        for (raw, count) in counted {
            switch ApprovalInterpretation.interpret(raw, assignments: assignments) {
            case .noRating:
                withoutValue += count
            case .approval(let alter):
                let text = key(forItem: raw)
                interpreted[text] = (
                    (interpreted[text]?.count ?? 0) + count, alter, assignments[text] != nil
                )
            case .unrecognized(let text):
                interpreted[text] = ((interpreted[text]?.count ?? 0) + count, nil, false)
            }
        }

        var recognized = interpreted.filter { $0.value.alter != nil }
            .map {
                ContentEntryRecord(
                    rawText: $0.key, count: $0.value.count, alter: $0.value.alter,
                    byHand: $0.value.byHand)
            }
        // By level and then by raw text: the evidence page is read like a table, and a table
        // that jumps around by frequency cannot be checked.
        recognized.sort { links, right in
            (links.alter ?? 0) == (right.alter ?? 0)
                ? links.rawText < right.rawText : (links.alter ?? 0) < (right.alter ?? 0)
        }
        if withoutValue > 0 {
            recognized.append(ContentEntryRecord(rawText: "", count: withoutValue, alter: nil))
        }

        let pending = interpreted.filter { $0.value.alter == nil }
            // Most frequent first — whoever maps wants to make the mapping that has the most effect.
            // With equal counts alphabetical, so that the list does not jump between two calls.
            .sorted {
                $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count
            }
            .map { ContentEntryRecord(rawText: $0.key, count: $0.value.count, alter: nil) }

        return ApprovalMirror(recognized: recognized, pending: pending)
    }
}
