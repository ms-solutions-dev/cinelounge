import Foundation

/// A short ID for a submitted diagnostic report.
///
/// **What for** (AP17): Today, submitting reports back the **file name** that
/// the server assigned. That answers the question "is it there?" — but
/// not the one that matters: the viewer sits in the living room, support
/// has a folder full of reports, and a phone sits between them. What has to
/// get through there is short, unambiguous and **readable aloud**.
///
/// ## Why this alphabet
///
/// Confusable characters are out: **0 and O**, **1, I and L**, **8 and
/// B**, **5 and S**, **2 and Z**. Someone reading an ID out over the phone
/// reads it once — and a "zero or O?" costs more than the four characters
/// the alphabet loses by it. **24** characters remain; with six
/// positions that is about **191 million** possibilities. This is not a
/// security question but a distinction question: two reports
/// from the same viewer must not carry the same ID.
///
/// ## What it is NOT
///
/// **Not a secret and not a key.** It appears in plain text in the report and
/// on screen; anyone who knows it knows only a string of characters. The report
/// itself still lies where it lay — on your own server.
///
/// **And not permanent.** A new one per submission: two reports from the same
/// device are two events, and an ID that applies to both helps
/// nobody find the second.
public enum DiagnosticID {

    /// The characters an ID consists of — without anything confusable.
    ///
    /// Reading digits and letters separately would make it shorter; mixed
    /// it is shorter **and** readable aloud, because no character has two names.
    public static let alphabet = Array("34679ACDEFGHJKMNPQRTVWXY")

    /// How many positions the ID has, without the hyphen.
    public static let locations = 6

    /// Builds a new ID — `XXXX-XX`.
    ///
    /// **The hyphen sits after four characters**, because a group of six
    /// falls apart when read aloud and two groups of three look like a
    /// phone number. Four plus two reads as a word and a
    /// suffix.
    public static func fresh() -> String {
        format(String((0..<locations).map { _ in alphabet.randomElement() ?? "X" }))
    }

    /// Inserts the hyphen — separate, so the tests can build an ID with
    /// known characters instead of rolling dice.
    static func format(_ raw: String) -> String {
        let character = Array(raw)
        guard character.count == locations else { return raw }
        return String(character.prefix(4)) + "-" + String(character.suffix(2))
    }

    /// The header line with which the ID appears in the report.
    ///
    /// **A line of its own and at the very top**: anyone searching a folder full of reports
    /// searches with a tool that finds lines — not with their
    /// eyes. The fixed prefix turns the search into a hit.
    public static let prefix = "Diagnostic ID: "

    public static func headerLine(_ identifier: String) -> String { prefix + identifier }

    /// Reads the ID back out of a report — for the test and for
    /// anyone who wants to know whether they have the right one in front of them.
    public static func fromReport(_ text: String) -> String? {
        for row in text.split(separator: "\n", omittingEmptySubsequences: false)
        where row.hasPrefix(prefix) {
            let value = row.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
