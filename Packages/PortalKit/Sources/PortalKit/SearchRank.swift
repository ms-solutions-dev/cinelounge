import Core
import Foundation

/// In which order search hits from several portals appear.
///
/// **The finding of 2026-09-12, reported by the client:** "quill" exists on Serieshub but is
/// not shown; instead there is content that cannot be related to "quill". On screen there were six
/// BR24 reports about a radar system called *Quill* — and the series *Quill*, which Serieshub
/// delivers as the **first** hit, did not appear.
///
/// **The cause was sorting by the portal's name.** The hits were concatenated in portal-alphabetical
/// order: 3sat, animehub, ard … serieshub last. For "quill", 3sat and ARD together
/// deliver sixty-five news snippets in which the word occurs somewhere; the four real series stood
/// behind them and thus out of sight. A portal's name is no statement about the quality of a hit —
/// it was merely the only order that cost nothing.
///
/// **Now it is ordered by how well the title fits.** A title named exactly like the search term
/// stands above one that contains it, and that above one in which the word occurred only in the
/// description. That is the question the searcher asked.
public enum SearchRank {

    /// How well a hit fits the search term — **smaller is better.**
    ///
    /// As a number and not as an enumeration, because it is sorted and not branched on. The gaps are
    /// deliberately coarse: between "is called so" and "starts like this" lies one level, and finer
    /// grades would be a claim about meaning that does not follow from a title comparison.
    static func tier(title: String, row: String?, needle: String) -> Int {
        let word = normalized(needle)
        guard !word.isEmpty else { return 5 }
        let name = normalized(title)

        if name == word { return 0 }
        // **The series counts like the title** — whoever searches "krimireihe" means the series, and its
        // episodes are called "Folge 41: Kreidespur". Without this line an episode of the searched series
        // would stand behind a news report.
        if let row, normalized(row) == word { return 1 }
        if name.contains(word) { return 2 }
        if let row, normalized(row).contains(word) { return 3 }
        // The rest: the word was in the description, in the channel or somewhere else. It is a hit and not
        // a good one.
        return 4
    }

    // **There was a level for "starts with the word", and it was dropped on 2026-09-12** It stood between
    // "is called so" and "contains it" and thereby put "Quill-System kommt nach Kaufbeuren" above
    // "Squill": the sentence starts with the word, the short title only contains it. But a sentence
    // that begins with the search term is no better hit than a title that consists almost only of it —
    // and the length does exactly that as a second measure, without a level of its own and without the
    // exception it would have needed ("the start counts only for short titles").

    /// **Without accents, without case, without margins.**
    ///
    /// `localizedLowercase` and not `lowercased()`: otherwise the Turkish İ becomes `i̇` with a dot, and
    /// the app speaks three languages. Folding is additionally diacritic, so that "Casfra" finds
    /// "Kométa".
    static func normalized(_ text: String) -> String {
        text.folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: .current
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Bring hits from several portals into an order.
    ///
    /// **Stable within a level**, and that is intended: what the service named first stays in front. A
    /// portal answers in the order it considers sensible itself, and discarding that order without
    /// reason would be a degradation that nobody sees.
    ///
    /// **With equal level the length of the title decides, and that is the second attempt**
    /// (2026-09-12). The first let the official portals win after the level — and thereby "Quill-System
    /// kommt nach Kaufbeuren" (ARD) stood above "Back Quill" (Serieshub) again: both **contain** the
    /// word, so same level, and the media library won. The same mistake, only one level deeper.
    ///
    /// The length is the more honest measure: a short title that consists almost only of the search term
    /// is a better hit than a sentence in which the word occurs. Ten characters against thirty-four, and
    /// no statement about portals needed.
    ///
    /// **Official portals decide only after that** — and thereby exactly the case the rule was meant
    /// for: if the *same* title is in a media library and at a portal script, level and length are equal, and
    /// the media library wins. With different titles it no longer comes into play.
    public static func ordered(
        _ match: [(portal: String, piece: MediaItem)], needle: String,
        official: Set<String> = []
    ) -> [MediaItem] {
        match.enumerated()
            .map { slot, entry in
                (
                    tier: tier(
                        title: entry.piece.title, row: entry.piece.parentTitle,
                        needle: needle),
                    length: normalized(entry.piece.title).count,
                    official: official.contains(entry.portal) ? 0 : 1,
                    slot: slot,
                    piece: entry.piece
                )
            }
            .sorted {
                if $0.tier != $1.tier { return $0.tier < $1.tier }
                if $0.length != $1.length { return $0.length < $1.length }
                if $0.official != $1.official { return $0.official < $1.official }
                return $0.slot < $1.slot
            }
            .map(\.piece)
    }
}
