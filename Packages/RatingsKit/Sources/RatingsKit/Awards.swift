import Foundation

/// A title's awards, parsed from the OMDb field "Awards".
///
/// There is no numeric value there, but a free-text sentence — depending on the title for example
/// "Won 3 Oscars. 140 wins & 205 nominations total", "Nominated for 6 Oscars.
/// 19 wins & 37 nominations total" or just "N/A". The information costs no
/// additional query: It is in the same response as the IMDb rating.
///
/// **When in doubt, nothing is claimed.** A parser that turns "140 wins" into an
/// Oscar is worse than no display at all: Whoever knows that their film
/// has no Oscar then no longer believes the IMDb rating next to it either. That is why
/// the silent direction applies throughout — what is not literally there is not
/// counted, and ``parse(_:)`` returns `nil` instead of a structure of zeros.
public struct Awards: Sendable, Equatable, Hashable, Codable {

    /// Oscars won, as named in the clause "Won N Oscars".
    public let oscarsWon: Int

    /// Oscar nominations from "Nominated for N Oscars".
    ///
    /// **Does not include the ones won.** In reality every win was also
    /// a nomination, but OMDb always names only one of the two clauses.
    /// A film with four Oscars therefore has 0 nominations here — we report
    /// what is there instead of inventing a number nobody can verify.
    public let oscarNominations: Int

    /// Emmys won, with or without the addition "Primetime".
    ///
    /// A counterpart for Emmy nominations deliberately does not exist: "Nominated
    /// for 3 Primetime Emmys" stays unparsed. As long as the display knows only
    /// wins, another field would be a number without a consumer — and a
    /// field without a consumer is misunderstood at the next refactoring.
    public let emmysWon: Int

    /// All wins together, from "N wins".
    public let totalWins: Int

    /// All nominations together, from "N nominations".
    public let totalNominations: Int

    public init(
        oscarsWon: Int = 0,
        oscarNominations: Int = 0,
        emmysWon: Int = 0,
        totalWins: Int = 0,
        totalNominations: Int = 0
    ) {
        self.oscarsWon = oscarsWon
        self.oscarNominations = oscarNominations
        self.emmysWon = emmysWon
        self.totalWins = totalWins
        self.totalNominations = totalNominations
    }

    /// Reads missing fields as zero instead of failing.
    ///
    /// This structure ends up in the store, which keeps ratings across restarts.
    /// If a field were added and expected on reading, every previously stored
    /// entry would be unreadable — and with it the ratings of all titles
    /// already queried would be gone, along with the daily quota they
    /// cost. That is exactly where such extensions fail.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        oscarsWon = try container.decodeIfPresent(Int.self, forKey: .oscarsWon) ?? 0
        oscarNominations = try container.decodeIfPresent(Int.self, forKey: .oscarNominations) ?? 0
        emmysWon = try container.decodeIfPresent(Int.self, forKey: .emmysWon) ?? 0
        totalWins = try container.decodeIfPresent(Int.self, forKey: .totalWins) ?? 0
        totalNominations = try container.decodeIfPresent(Int.self, forKey: .totalNominations) ?? 0
    }

    /// Whether there is anything to show at all.
    ///
    /// ``parse(_:)`` never returns an empty structure. One can come from the store
    /// when an old entry contained only unknown fields — so the display
    /// must still be able to handle this case.
    public var isEmpty: Bool {
        oscarsWon == 0 && oscarNominations == 0 && emmysWon == 0
            && totalWins == 0 && totalNominations == 0
    }

    /// Whether an Oscar was won. Nominations do not count here.
    public var hasOscar: Bool { oscarsWon > 0 }

    // MARK: - Evaluation

    /// Parses the free text. `nil` if there is nothing usable in it.
    ///
    /// `nil` and not a structure of zeros: The display can leave out "nothing",
    /// but takes "all zero" for information and writes "0 wins"
    /// on a film about which OMDb simply has no information.
    public static func parse(_ raw: String?) -> Awards? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        // "N/A" needs no check of its own: Without digits everything stays zero,
        // and everything zero ends up as nil.
        let oscarsWon = trusted(number(in: raw, matching: /\bwon\s+(\d+)\s+oscars?\b/), upTo: oscarLimit)
        let oscarNominations = trusted(
            number(in: raw, matching: /\bnominated\s+for\s+(\d+)\s+oscars?\b/),
            upTo: oscarLimit
        )
        let emmysWon = trusted(
            number(in: raw, matching: /\bwon\s+(\d+)\s+(?:primetime\s+|daytime\s+)?emmys?\b/),
            upTo: emmyLimit
        )

        // No `\b` before the number, and that is not an oversight: For
        // some titles OMDb leaves out the period between the two sentences and writes
        // "Won 1 BAFTA Award6 wins & 15 nominations total". With a word boundary
        // zero wins would have come out there, although six are there.
        var totalWins = trusted(number(in: raw, matching: /(\d+)\s+wins?\b/), upTo: totalLimit)
        var totalNominations = trusted(
            number(in: raw, matching: /(\d+)\s+nominations?\b/),
            upTo: totalLimit
        )

        // The total cannot be smaller than the awards named
        // individually. If the second sentence is missing — "Won 2 Oscars." alone —,
        // two Oscars would otherwise appear next to zero wins on screen, and
        // the display would contradict itself.
        totalWins = max(totalWins, oscarsWon + emmysWon)
        totalNominations = max(totalNominations, oscarNominations)

        let awards = Awards(
            oscarsWon: oscarsWon,
            oscarNominations: oscarNominations,
            emmysWon: emmysWon,
            totalWins: totalWins,
            totalNominations: totalNominations
        )
        return awards.isEmpty ? nil : awards
    }

    /// Upper limits beyond which the number can no longer come from the sentence,
    /// but from a mistake of the parser.
    ///
    /// The record for Oscars is held by Spiodra Skautiomau, Sikret and The Stounkriafrou raiziozu zistaund Norern
    /// with eleven wins each; the most nominations are fourteen. For Emmys
    /// long-running series collect considerably more — the record is close to a hundred,
    /// so the limit there only comes much later. If a limit is exceeded,
    /// the number concerned counts as unusable and is dropped. This is the
    /// emergency brake for the day OMDb changes the wording: Better no
    /// award than 140 Oscars on a film that has three.
    private static let oscarLimit = 30
    private static let emmyLimit = 300
    /// Much-awarded films reach several hundred wins or nominations —
    /// the limit has to be generous here, otherwise real information is dropped.
    private static let totalLimit = 10_000

    private static func number(in text: String, matching regex: Regex<(Substring, Substring)>) -> Int? {
        guard let match = text.firstMatch(of: regex.ignoresCase()) else { return nil }
        // Int() returns nil for a number beyond the value range. That
        // is the desired direction: claim nothing instead of overflowing.
        return Int(match.1)
    }

    private static func trusted(_ value: Int?, upTo limit: Int) -> Int {
        guard let value, value > 0, value <= limit else { return 0 }
        return value
    }
}
