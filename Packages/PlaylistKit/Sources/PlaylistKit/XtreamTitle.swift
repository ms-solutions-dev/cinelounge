import Foundation

/// Takes apart the titles that Xtream providers use for movies, series and episodes.
///
/// **Why this is necessary.** The catalog of a real provider is written like this:
///
/// ```
/// DE - The Nitzodut Rouflen (2019)
/// 4K-DE - Tutkra Drutkou (2026)
/// DE-JO - Die Frasleihi Frimaspar (2026) (DE) - S01E01 - Episode 1
/// ```
///
/// Measured over all 27558 movies and 7419 series, 34919 of 34977 titles
/// carry such a prefix, 14924 of them `DE`. Unfiltered, almost every
/// row of the overview starts the same way, the alphabet sorts by the prefix instead of
/// by the name, and a search for "Perfect" finds nothing if it
/// compares from the start. For an episode, without splitting, the complete series title
/// including the year appears in each of the twelve rows of a season.
///
/// **The real difficulty is not cutting but
/// not cutting.** 58 of the 34977 titles have no prefix, 10908 no year in
/// brackets. Among them are names that themselves look like a prefix:
///
/// ```
/// Gregre - Sleskai (1983)
/// Skenklut bautsodal Gleipio - A Latmim Rouklislum cisto Wijaibou (2014)
/// The Last Match - Der letzte Fight (1990)
/// Nf - Plikre pukra Trakrai Tiaslaci
/// ```
///
/// An overeager parser turns the first into "Kriegsspiele" and invents
/// the language "Gregre" for it. That is why the rule throughout is: **when in doubt,
/// the title stays.** A name with a prefix is readable, a cut-up
/// one is lost — and nobody notices that something is missing.
///
/// The rules below are worked through on all 34977 titles of the recording.
/// That produced 31 distinct prefixes, and **every one** of them is a
/// provider label (`DE`, `NF`, `TR`, `XXX`, `4K-DE`, `AMZ`, `D+`,
/// `MAX`, `MRVL`, `007`, `AR-SUBS`); not a single movie name was cut.
public struct XtreamTitle: Sendable, Equatable {

    /// The name without prefix, year, origin and episode marker.
    ///
    /// Never empty: if nothing is left after cutting, the
    /// original title appears here. An empty entry in a list of 27558 could
    /// not be found again.
    public let title: String

    /// The year from the bracket at the end, `nil` for 10908 of 34977 titles.
    ///
    /// **Only from brackets**, never from a free-standing number. The reason is in the
    /// catalog: `DE - Fussball WM 2026 Halbfinale: Frankreich Vs Spanien` carries
    /// a year in the middle of the name, and `Zedreseit Runbro 2049` even carries it
    /// as part of the name.
    public let year: Int?

    /// The audio language from the prefix, as far as it names one — `DE`, `TR`, `AR`.
    ///
    /// Only what is an ISO 639-1 language code is recognised. That excludes
    /// `JO`, `DO` (Doku), `NF` and `MAX` (labels of streaming services), which appear in the prefix at
    /// the same position. A list of country codes would be wrong here: `JO`
    /// as a country is Jordan and would thus be an invented language.
    public let language: String?

    /// The prefix as it stood — `DE`, `4K-DE`, `DE-JO`, `XXX`, `007`.
    ///
    /// Carried along so that the split stays **reversible**: from ``tag`` and
    /// ``title`` the original name can be put back together. That is
    /// the way back for the case that a provider uses a label that
    /// looks like a movie name here — then nothing is missing, it merely sits in
    /// a different place.
    public let tag: String?

    /// The country of origin in the last bracket — `(US)`, `(GB)`, `(KR)`.
    ///
    /// **Not a language**, and that is the point: `DE - Driasuski Vajetlor (1985) (US)`
    /// is heard in German and was shot in the USA. Anyone who reads the last bracket as
    /// a language shows "English" for 2707 titles although they are dubbed
    /// in German. Across all 34977 titles, 64 distinct codes occur here,
    /// all of two letters.
    public let originCountry: String?

    public let seasonNumber: Int?
    public let episodeNumber: Int?

    /// The name of the episode after the marker — for `… - S01E01 - Episode 1`
    /// that is `Episode 1`.
    public let episodeTitle: String?

    /// The original title, unchanged.
    public let raw: String

    /// What should appear in a list of episodes.
    ///
    /// The series title does not belong there — it stands above the list. If there is
    /// no episode name of its own, the number stays, because an empty row tells
    /// nothing.
    public var episodeDisplayTitle: String? {
        if let episodeTitle { return episodeTitle }
        guard let episodeNumber else { return nil }
        return "Episode \(episodeNumber)"
    }

    // MARK: - Zerlegen

    public static func parse(_ raw: String) -> XtreamTitle {
        let text = collapsed(raw)

        let episode = splitEpisode(in: text)
        let tagCut = splitTag(in: episode.head)
        // **Square brackets first.** With some providers they sit at the end and are
        // staggered — "Der Slistope [DE] [1981]" —, and the round variants
        // below do not apply there: `splitOrigin` sees "[1981]" at the end instead of "[DE]"
        // and gives up. Only after they are gone do the existing rules work
        // as usual.
        let bracketed = splitBrackets(in: tagCut.rest)
        let originCut = splitOrigin(in: bracketed.rest)
        let yearCut = splitYear(in: originCut.rest)

        let cleaned = collapsed(yearCut.rest)

        return XtreamTitle(
            // If nothing is left after all the cutting, the whole title applies. This
            // affects `DE - (2019)`, for example — rare, but it costs an
            // entry that cannot be found.
            title: cleaned.isEmpty ? text : cleaned,
            year: yearCut.year ?? bracketed.year,
            language: language(inTag: tagCut.tag) ?? bracketed.language,
            tag: tagCut.tag,
            originCountry: originCut.country ?? bracketed.language,
            seasonNumber: episode.season,
            episodeNumber: episode.episode,
            episodeTitle: episode.title,
            raw: raw
        )
    }

    // MARK: - Folgenkennung

    /// Splits off `S01E01` and the episode name.
    ///
    /// The search is for the **last** piece between ` - ` that is exactly one
    /// episode marker. Not the first: series titles contain dashes
    /// themselves — `DE-JO - Brihukol brebrouskel Kribrein - Bagrada Breti dashostirn Vesdrefli (2025)
    /// (DE) - S01E01 - …` is how it appears in the catalog. Whoever splits at the first dash
    /// loses half the series title.
    static func splitEpisode(
        in text: String
    ) -> (head: String, season: Int?, episode: Int?, title: String?) {
        let parts = text.components(separatedBy: separator)
        guard parts.count >= 2 else { return (text, nil, nil, nil) }

        var found: (index: Int, season: Int, episode: Int)?
        for (index, part) in parts.enumerated() {
            if let numbers = seasonEpisode(in: part) {
                found = (index, numbers.season, numbers.episode)
            }
        }

        guard let found, found.index > 0 else { return (text, nil, nil, nil) }

        let head = parts[..<found.index].joined(separator: separator)
        let tail = parts[(found.index + 1)...].joined(separator: separator)
            .trimmingCharacters(in: .whitespaces)

        return (head, found.season, found.episode, tail.isEmpty ? nil : tail)
    }

    /// Reads `S01E01` and nothing else.
    ///
    /// Both numbers must be present and the piece may contain nothing else —
    /// otherwise `Season 2` or a movie title like `K.O.D.A` would be taken along.
    static func seasonEpisode(in part: String) -> (season: Int, episode: Int)? {
        let text = part.trimmingCharacters(in: .whitespaces)
        var digits = Array(text)
        guard let first = digits.first, first == "S" || first == "s" else { return nil }
        digits.removeFirst()

        let seasonDigits = digits.prefix { $0.isNumber }
        guard !seasonDigits.isEmpty, seasonDigits.count <= 3 else { return nil }
        digits.removeFirst(seasonDigits.count)

        guard let marker = digits.first, marker == "E" || marker == "e" else { return nil }
        digits.removeFirst()

        let episodeDigits = digits.prefix { $0.isNumber }
        guard !episodeDigits.isEmpty, episodeDigits.count <= 4,
            episodeDigits.count == digits.count
        else { return nil }

        guard let season = Int(String(seasonDigits)), let episode = Int(String(episodeDigits))
        else { return nil }
        return (season, episode)
    }

    // MARK: - Vorsatz

    /// Splits off the provider's prefix, or leaves the title untouched.
    ///
    /// The separating dash is the **first** one that has a space on at least one
    /// side. This condition handles the compound prefixes by itself:
    /// in `4K-DE - Tutkra Drutkou` the dash inside `4K-DE` has no space,
    /// the separating one after it does. It also handles the typos of the
    /// catalog — `4K-DE- Nordlicht`, `DE -Sturmfalke Z` — without treating them
    /// specially.
    ///
    /// A piece counts as a prefix only if it contains **exclusively**
    /// capital letters, digits, `+` and `-` and is at least two characters
    /// long. Both are needed, and both are backed by real names:
    ///
    /// - Without the capitalisation requirement, `Nf - Plikre pukra Trakrai Tiaslaci` and
    ///   `Gregre - Sleskai` would both fall victim to the cut.
    /// - Without the minimum length, `M - Ein Dorf hält den Atem an` would lose its
    ///   name and keep only the subtitle.
    ///
    /// What remains is a known residual risk: a movie that is really called
    /// `ZDK - Hafenkante Lyon` loses its `ZDK` to ``tag``. No such case is known
    /// from the catalog — checked over 34977 titles —, and
    /// because ``tag`` is preserved, the damage is reversible.
    static func splitTag(in text: String) -> (tag: String?, rest: String) {
        let characters = Array(text)

        for index in characters.indices where characters[index] == "-" {
            let hasSpaceBefore = index > 0 && characters[index - 1] == " "
            let hasSpaceAfter = index + 1 < characters.count && characters[index + 1] == " "
            guard hasSpaceBefore || hasSpaceAfter else { continue }

            let candidate = String(characters[..<index]).trimmingCharacters(in: .whitespaces)
            let rest = String(characters[(index + 1)...]).trimmingCharacters(in: .whitespaces)

            // The decision is made at the first dash with a space and the search does not
            // continue: if it does not fit, it is part of the name — and everything
            // after it all the more so.
            guard isTag(candidate), !rest.isEmpty else { return (nil, text) }
            return (candidate, rest)
        }

        return (nil, text)
    }

    static func isTag(_ candidate: String) -> Bool {
        guard candidate.count >= 2, candidate.count <= 15 else { return false }
        guard candidate.contains(where: { $0.isLetter || $0.isNumber }) else { return false }

        // Explicitly ASCII only: `Ä` counts as a capital letter, and a title like
        // `ÜBER - Die Fähre` would otherwise be a prefix. The same narrowness for digits —
        // `isNumber` also matches `½` and Arabic digits.
        return candidate.allSatisfy { character in
            guard character.isASCII else { return false }
            return character.isNumber
                || (character.isLetter && character.isUppercase)
                || character == "+" || character == "-"
        }
    }

    /// The language code from the prefix.
    ///
    /// The prefix can combine several details — `4K-DE` is resolution and
    /// language, `DE-JO` language and provider. The first part that is
    /// a language code is taken.
    static func language(inTag tag: String?) -> String? {
        guard let tag else { return nil }
        for part in tag.split(separator: "-") where languageCodes.contains(part.lowercased()) {
            return String(part)
        }
        return nil
    }

    /// Language codes per ISO 639-1, as far as they occur with such providers.
    ///
    /// Deliberately a list and not a rule "two capital letters": in the same
    /// position there are `NF`, `DO`, `JO`, `CR`, `A+` and `D+`, and those are not
    /// languages. Without the list every Netflix title would get the language "NF".
    static let languageCodes: Set<String> = [
        "de", "en", "tr", "ar", "fr", "it", "es", "nl", "pl", "ru", "pt", "ro", "sv", "da",
        "no", "fi", "cs", "sk", "sl", "hu", "el", "he", "hi", "ja", "ko", "zh", "uk", "bg",
        "sr", "hr", "bs", "sq", "fa", "ku", "az", "lt", "lv", "et", "ka", "hy", "ms", "id",
        "th", "vi", "ur", "bn", "ta",
    ]

    // MARK: - Herkunft und Jahr

    /// Splits off a two-letter country code in brackets at the end.
    ///
    /// Exactly two capital letters only: across all 34977 titles all 64
    /// occurring codes are two letters. Allowing three characters would hit brackets
    /// like `(OVA)`, which mean something else.
    static func splitOrigin(in text: String) -> (country: String?, rest: String) {
        guard text.hasSuffix(")"),
            let open = text.lastIndex(of: "(")
        else { return (nil, text) }

        let inner = text[text.index(after: open)..<text.index(before: text.endIndex)]
        guard inner.count == 2,
            inner.allSatisfy({ $0.isLetter && $0.isUppercase && $0.isASCII })
        else { return (nil, text) }

        return (String(inner), String(text[..<open]).trimmingCharacters(in: .whitespaces))
    }

    /// Cuts off **square** brackets at the end — year and language code.
    ///
    /// **The finding from 2026-09-05 on the phone:** the library showed titles like
    /// "Der Slistope [DE] [1981]" and "24 Wifroraum skaskel Y-Zaulail: Schlacht der Entsc…" —
    /// the markers ate eleven characters of a column that truncates anyway, and
    /// the year was missing from the second line, where there is room for it.
    ///
    /// **Only at the end, only square, only two patterns.** Four digits between 1880 and 2200
    /// are a year, two to three capital letters a language code. Everything else in
    /// square brackets stays: `[Director's Cut]` and `[4K]` are information, and
    /// a guessed rule would take them away. The same caution as with the round brackets,
    /// whose notes are below.
    ///
    /// **Repeated, because they occur staggered.** One pass would cut off "[1981]"
    /// and leave "[DE]" standing.
    static func splitBrackets(in text: String) -> (year: Int?, language: String?, rest: String) {
        var rest = text.trimmingCharacters(in: .whitespaces)
        var year: Int?
        var language: String?

        while rest.hasSuffix("]"), let open = rest.lastIndex(of: "[") {
            let inner = String(rest[rest.index(after: open)..<rest.index(before: rest.endIndex)])
            let before = String(rest[..<open]).trimmingCharacters(in: .whitespaces)

            if inner.count == 4, let number = Int(inner), number > 1880, number < 2200,
                inner.allSatisfy(\.isNumber)
            {
                if year == nil { year = number }
            } else if (2...3).contains(inner.count),
                inner.allSatisfy({ $0.isLetter && $0.isUppercase && $0.isASCII })
            {
                if language == nil { language = inner }
            } else {
                break
            }
            // **Only cut if something is left.** A title that consists only of
            // markers would be nameless afterwards — and a nameless entry
            // cannot be found.
            guard !before.isEmpty else { break }
            rest = before
        }

        return (year, language, rest)
    }

    /// Splits off the year in brackets.
    ///
    /// The **last** bracket with four digits is taken. The one title in the
    /// catalog with two such brackets — `DE (2009) - Linbosflo Houfaidrern  (2002)` —
    /// thus gets 2002, and the first bracket stays in the name. That is
    /// the more honest of two solutions: which of the two numbers is the
    /// release year, the title does not reveal.
    static func splitYear(in text: String) -> (year: Int?, rest: String) {
        let characters = Array(text)
        var found: (year: Int, open: Int, close: Int)?

        var open: Int?
        for index in characters.indices {
            switch characters[index] {
            case "(":
                open = index
            case ")":
                guard let start = open else { continue }
                open = nil
                let inner = String(characters[(start + 1)..<index])
                guard inner.count == 4, let year = Int(inner), year > 1880, year < 2200,
                    inner.allSatisfy(\.isNumber)
                else { continue }
                found = (year, start, index)
            default:
                continue
            }
        }

        guard let found else { return (nil, text) }

        let rest = String(characters[..<found.open]) + String(characters[(found.close + 1)...])
        return (found.year, rest.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Kleinigkeiten

    /// What stands between the prefix and the title.
    static let separator = " - "

    /// Collapses repeated whitespace.
    ///
    /// Necessary because the catalog contains it: `DE - Grüße vom Leuchtturm  (1972)`
    /// has two spaces before the bracket. After the year is taken out,
    /// a gap would otherwise remain at the end, which stands out as an error on the TV.
    static func collapsed(_ text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
