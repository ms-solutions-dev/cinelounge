import Foundation

/// The letter jump bar of a long list.
///
/// **Why it has to exist:** In one category the provider carries up to 4.211 titles. Without
/// jump markers that is 383 screens of swiping — and whoever knows the title they are
/// looking for swipes past it three hundred times.
///
/// **Two traps, both found on the TV and taken over here:**
///
/// * **Leading articles are cut off.** Otherwise everything piles up under "D" and "T" —
///   with a German category, half the list then stands under one letter.
/// * **Comparison uses `localizedStandardCompare`**, not character number. `Ç` belongs next
///   to `C` and `Ö` next to `O`; as raw values both sort **after Z**. The finding dates
///   from 2026-08-07 on a Turkish category, and this provider carries 2.741 Turkish titles.
///
/// **Only what is occupied is offered.** A jump into the void is worse than no jump: It
/// looks as if the app had lost the title.
public enum JumpMarks {

    /// Digits and special characters gather under one symbol.
    public static let collectiveSymbol = "#"

    /// The articles that are dropped at the front.
    ///
    /// **German and English, and explicitly not Turkish** — Turkish has no definite article,
    /// and the indefinite one ("bir") also stands in the middle of a title. Cutting it off
    /// would move titles that were sorted in correctly.
    static let articles = ["der ", "die ", "das ", "the ", "a ", "an ", "ein ", "eine "]

    /// **What is sorted by — and precisely when markers are shown.**
    ///
    /// **The finding of 2026-09-05, recalculated on the screen.** The list came from the provider
    /// sorted by the **raw** title, the markers were formed **without article**. That put "Der
    /// Slistope" in the D block carrying the marker **F**. Since in the D block almost
    /// every letter occurs as a truncated start ("Der Zorn…", "Die Brücke…"), most markers
    /// pointed into the same block — and **"T" jumped to "Das Staseit spupleispus Skofainbrand Boujaum", that
    /// is, before "Der Mozujorn". The bar jumped backwards.**
    ///
    /// The real E-to-Z blocks were **not reachable at all** via the bar. On the screen this
    /// does not look like a sorting error but as if the app had lost the title — exactly the
    /// case this file is meant to prevent.
    ///
    /// **One place, one key.** Whoever shows the bar sorts by it; both come from the same
    /// function, and drifting apart is thus no longer possible.
    /// - Parameter sprache: **for tests only.** In operation it is always the running one;
    ///   two callers with different languages would be exactly the drifting apart that this
    ///   file prevents. Without the handle the behaviour could not be tested in Turkish at
    ///   all — and that is where the case that shows it lies.
    public static func key(_ title: String, language: Locale = .current) -> String {
        withoutArticle(title)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: language)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Sorts by the same key from which the markers arise.
    ///
    /// **The key is formed once per title and not twice per comparison.** Until 2026-09-10.
    /// ``key(_:language:)`` stood **in the comparator**: `sorted` needs about 50.000
    /// comparisons for 4.211 titles, and each called the key **twice** — so a good 100.000
    /// foldings for 4.211 different results. Each of them is a `lowercased`, eight prefix
    /// checks, a Unicode folding with locale and a `trimmingCharacters`.
    ///
    /// **Measured on 2026-09-10 on 4.211 titles with articles, umlauts and Turkish characters,
    /// `-O`, five runs:** before **209 ms**, after **18 ms** — and both deliver the same order
    /// title by title. This ran on every redraw of the library; together with the watchlist in
    /// ``LibraryViewModel/order`` it now runs once per catalog.
    ///
    /// **The comparison itself stays `localizedStandardCompare`** and is not replaced by
    /// something cheaper: It is the reason why `Ç` stands next to `C` and not after `Z`, and
    /// this provider carries 2.741 Turkish titles. The saving is made in the preparation, not
    /// in the rule.
    public static func sortedEntries<Value>(
        _ values: [Value], after title: (Value) -> String
    ) -> [Value] {
        values
            .map { (key: key(title($0)), value: $0) }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map(\.value)
    }

    /// The title without leading article.
    public static func withoutArticle(_ title: String) -> String {
        let lowercased = title.lowercased()
        for articles in articles where lowercased.hasPrefix(articles) {
            return String(title.dropFirst(articles.count))
        }
        return title
    }

    /// Under which symbol a title stands.
    ///
    /// **From the key and not from the title** — the finding of 2026-09-07. (AP10), and it is the
    /// same as on 2026-09-05, only one level deeper. Back then **sorting and marker** drifted apart
    /// because one cut off the article and the other did not. Now both cut it off — and still
    /// drifted apart, because ``key(_:language:)`` **folds away the characters above**
    /// and this line kept them.
    ///
    /// **In German it was live and visible on the screen.** "Gladorn Gliokrar" stands, by the key
    /// `aon flux`, **before** "Avatar" — correct —, but carried the marker **Ä**. The bar thus
    /// showed Ä, A, Ö, O, Ü, U: **six markers for three blocks**, and whoever pressed "A"
    /// jumped past "Gladorn Gliokrar", which stood above it.
    ///
    /// **In Turkish it is worse, and that was the reason to look.** The folding maps **both**
    /// capital I's there to the dotless "ı": "İstanbul" becomes `ıstanbul`, "Islak" becomes
    /// `ıslak`. The list therefore mixes them — I, I, İ, I, İ, I — while the bar claimed two
    /// separate blocks. Measured and not assumed.
    ///
    /// **So "one place, one key" now really holds:** Order and marker come from the same
    /// string. The price must be stated honestly in Turkish — "İ" and "I" are two letters there
    /// and get one block here. A bar that separates them would need a Turkish sort order
    /// instead of a folding; a bar that **claims** them and does not separate them is the worse
    /// of the two.
    public static func tag(forItem title: String, language: Locale = .current) -> String {
        guard let first = key(title, language: language).first else { return collectiveSymbol }
        let large = String(first).uppercased()
        return large.rangeOfCharacter(from: .letters) != nil ? large : collectiveSymbol
    }

    /// The occupied markers, sorted language-aware — the collective symbol last.
    public static func marks(from title: [String], language: Locale = .current) -> [String] {
        let taken = Set(title.map { tag(forItem: $0, language: language) })
        return taken.sorted { links, right in
            if links == collectiveSymbol { return false }
            if right == collectiveSymbol { return true }
            return links.localizedStandardCompare(right) == .orderedAscending
        }
    }
}
