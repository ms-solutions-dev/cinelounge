import Foundation

/// **A movie that is an episode** — "Laitkrutbai Gezougros 5.Bölüm" (2026-10-01).
///
/// Some Xtream providers also list episodes as movies, with no link to the series
/// that sits next to them in the series catalog ("Laitkrutbai Gezougros |TR"). The only connection is the name;
/// this is where it is spelled out how it is read.
enum SequelFilm {

    /// At the end: "5.Bölüm", "Folge 5", "Episode 12", "S01E05" — with or without a separator before it.
    private static let sequelPattern =
        #"(?i)\s*[-–:|]?\s*(?:\d+\s*\.?\s*(?:bölüm|bolum|folge|episode|ep\.?|teil)|(?:bölüm|bolum|folge|episode|ep\.?|teil)\s*\d+|s\d{1,2}\s*e\d{1,3})\s*$"#

    /// The series name before the episode marker — `nil` if the title carries none.
    static func seriesName(from title: String) -> String? {
        guard let area = title.range(of: sequelPattern, options: .regularExpression) else {
            return nil
        }
        let name = title[..<area.lowerBound].trimmingCharacters(
            in: .whitespaces.union(.punctuationCharacters))
        return name.isEmpty ? nil : name
    }

    /// The comparison key of a name.
    ///
    /// **What the provider appends is dropped:** language at the front or back ("TR|", "|TR",
    /// "| TR 2024"), a year in parentheses. Then only letters and digits remain, without accents
    /// and with Turkish ı as i — "Nausautbei: Sliblaisaun Zeprian" and "Nausautbei - Sliblaisaun
    /// Zeprian |TR" yield the same key.
    static func key(_ name: String) -> String {
        var rest = name
        for (patterns, fallback) in [
            (#"^\s*[A-Za-z]{2,4}\s*\|\s*"#, ""),
            (#"\s*\|\s*[^|]{1,8}$"#, ""),
            (#"\s*\(\d{4}\)\s*$"#, ""),
        ] {
            rest = rest.replacingOccurrences(of: patterns, with: fallback, options: .regularExpression)
        }
        let folded = rest.replacingOccurrences(of: "ı", with: "i")
            .replacingOccurrences(of: "İ", with: "i")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return String(
            String.UnicodeScalarView(folded.unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
    }
}
