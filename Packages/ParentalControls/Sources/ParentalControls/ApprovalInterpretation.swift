import Foundation

/// From the server's raw text to a number — **and CineLounge does not guess.**
///
/// `MediaItem.ageRating` is **displayed** in four places and was **checked** in none.
/// The server delivers what is in the files, and that is not standardised: "FSK 16",
/// "16", "DE-16", "R", "TV-MA", "Not Rated", empty — everything is possible, even
/// nothing.
///
/// **The difference between "no rating" and "not understood" is the whole point.**
/// A title without a rating has none; a title with "TV-MA" has one that this app cannot
/// classify. Throwing the two together would mean either letting too much through or
/// removing too much — and in both cases nobody would know why. What was not understood
/// is collected by ``UnrecognizedRatings``, and the parent decides.
///
/// **Nothing is guessed, and that is a decision against convenience.** "R" is 17+ in the
/// USA, 18+ in Canada, and in a Jellyfin library possibly a self-assigned word. A table
/// for it would be an assertion about foreign strings — the same mistake that
/// ``LanguageVersions`` in the phone project warns against elsewhere.
public enum ApprovalInterpretation {

    /// What a raw text turned into.
    public enum Interpretation: Sendable, Equatable {
        /// Understood — the number is the minimum age.
        case approval(Int)
        /// The title carries **no** rating. Not an error, but a state.
        case noRating
        /// The title carries a rating that this app does not classify — verbatim.
        case unrecognized(String)
    }

    /// **Only what is unambiguous.** The list is short and stays short.
    ///
    /// Enumerated and not pattern-matched: a pattern over "everything with a number in it"
    /// would hit "Season 16" as well as "FSK 16", and a library that assigns its ratings
    /// itself writes anything there.
    ///
    /// **The German forms are listed here, the foreign ones are not** — and not from
    /// narrowness: "FSK 16" means the same everywhere, "R" does not. Whoever wants to map a
    /// foreign form does so by hand in the sheet ``UnrecognizedRatings``; then the mapping
    /// stands where someone took responsibility for it.
    static let known: [String: Int] = [
        "0": 0, "6": 6, "12": 12, "16": 16, "18": 18,
        "FSK0": 0, "FSK6": 6, "FSK12": 12, "FSK16": 16, "FSK18": 18,
        "DE0": 0, "DE6": 6, "DE12": 12, "DE16": 16, "DE18": 18,
        // Jellyfin writes some German ratings with the suffix "ab" ("from").
        "AB0": 0, "AB6": 6, "AB12": 12, "AB16": 16, "AB18": 18,
    ]

    /// Interprets a raw text.
    ///
    /// - Parameter zuordnungen: What the parent mapped by hand. They take **precedence** over
    ///   the built-in list: whoever set "TV-MA" to 16 means 16, even if this app believed it
    ///   knew otherwise.
    public static func interpret(_ raw: String?, assignments: [String: Int] = [:]) -> Interpretation {
        let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .noRating }

        if let from = assignments[text] { return .approval(from) }

        // Normalised: upper case, no spaces, hyphens and colons removed. "FSK 16", "fsk-16" and
        // "FSK:16" are the same rating, and three list entries for it would be three chances to
        // forget one.
        let key = text.uppercased().filter { $0.isLetter || $0.isNumber }
        if let alter = known[key] { return .approval(alter) }
        return .unrecognized(text)
    }

    /// Whether this title may appear at this limit.
    ///
    /// - Parameter sperreUnverstandene: What happens to what could not be interpreted.
    ///   **Default: block** — when in doubt, show less. It can be switched off because with
    ///   a catalog containing many foreign ratings half the library would otherwise be
    ///   missing and it would look as if the app were broken.
    ///
    /// **Without a limit nothing is filtered at all** — not even what is not understood.
    /// Whoever has set no limit has not ordered a lock.
    ///
    /// **"No rating" gets through.** A title without a rating is no statement about its
    /// content; removing it would turn a missing value into a warning. Whoever does not want
    /// that sets the limit and switches on the second rule for channels — the situation
    /// there is different (see ``ChannelLock``).
    public static func shows(
        _ raw: String?, at limit: AgeLimit?, blockUnrecognized: Bool = true,
        assignments: [String: Int] = [:]
    ) -> Bool {
        guard let limit else { return true }
        switch interpret(raw, assignments: assignments) {
        case .approval(let alter): return limit.letsPass(alter)
        case .noRating: return true
        case .unrecognized: return !blockUnrecognized
        }
    }
}
