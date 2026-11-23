import Foundation

/// What of the own library can be found under which title.
///
/// **What it is needed for:** A person's career comes from a
/// film database and consists mostly of titles the viewer does not
/// own. Next to every row, however, it should say whether **they** have it — and whoever
/// has it should be able to open it from there.
///
/// **The match runs in memory, not over the network** — and that is the
/// actual decision. The obvious implementation would be to ask the media server
/// for every row; for a filmography with two hundred entries
/// that would be two hundred requests for a feature at the margin. The catalog is
/// therefore collected **once** and looked up afterwards.
///
/// **Matching is by title and year**, because there is nothing better: The
/// media server does keep foreign identifiers on a title, but not those of the
/// film database the career comes from. The comparison is therefore
/// deliberately generous — it forgives case, punctuation,
/// leading articles and a year of deviation, because two databases
/// surprisingly often disagree on the release year of a film.
public struct LibraryIndex: Sendable {

    /// Title key → identifier in the media server.
    private var byTitle: [String: [(year: Int?, id: String)]] = [:]

    public init(_ items: [MediaItem] = []) {
        for item in items {
            byTitle[Self.key(item.title), default: []].append((item.year, item.id))
        }
    }

    public var isEmpty: Bool { byTitle.isEmpty }

    /// The identifier in the library — or `nil` if the title is not there.
    ///
    /// With several titles of the same name the year decides. If there are several even then,
    /// the first wins: Two versions of the same film under the same
    /// name and year are the same thing, and which of them is opened makes no
    /// difference to the viewer.
    public func itemID(forTitle title: String, year: Int?) -> String? {
        guard let candidates = byTitle[Self.key(title)], !candidates.isEmpty else { return nil }

        // Without a year on one of the two sides only the title remains — then the
        // first hit counts. That is the weaker statement, but still
        // better than "don't have it" for something that stands on the shelf.
        guard let year else { return candidates.first?.id }

        // Exact first, then a year off. Separate and not in one pass,
        // so that an exact hit never loses against an approximate one.
        if let exact = candidates.first(where: { $0.year == year }) { return exact.id }
        if let near = candidates.first(where: { candidate in
            guard let candidateYear = candidate.year else { return false }
            return abs(candidateYear - year) <= 1
        }) {
            return near.id
        }

        return nil
    }

    /// The key under which a title is stored and looked up.
    ///
    /// What is dropped here is grounded in real catalogs:
    ///
    /// - **Case**, because no catalog keeps it uniform.
    /// - **Punctuation and special characters**, because `Jeipik-Bousjinflut` and `Jeipik Bousjinflut`
    ///   are the same, as are `NEIDUKLI·Q` and `NEIDUKLI-Q`.
    /// - **A leading article**, because libraries like to sort under "Trailaut glintiorn Kimuskom,
    ///   Der" while film databases do not.
    /// - **Multiple spaces**, which arise when the characters are removed.
    ///
    /// Diacritics stay: Merging `Trakaigreil` and `Trakaigreil` would be possible in
    /// the same motion, but it would produce no hit that did not exist
    /// anyway — catalog titles carry their accents.
    static func key(_ title: String) -> String {
        var text = title.lowercased()

        for article in ["the ", "der ", "die ", "das ", "a ", "an "] where text.hasPrefix(article) {
            text = String(text.dropFirst(article.count))
            break
        }

        let cleaned = text.map { character -> Character in
            character.isLetter || character.isNumber ? character : " "
        }

        return String(cleaned)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }
}
