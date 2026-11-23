import Foundation
import Testing

@testable import FeaturesPhone

/// The letter bar — two traps, both found on the TV.
@Suite("Jump marks")
struct JumpMarkTests {

    /// **Leading articles otherwise pile everything under "D" and "T".** In a German
    /// category half the list then stands under one letter, and the bar has lost its
    /// purpose.
    @Test("The leading article is dropped")
    func articles() {
        #expect(JumpMarks.tag(forItem: "Der Pakuro") == "P")
        #expect(JumpMarks.tag(forItem: "Die Hulmen") == "H")
        #expect(JumpMarks.tag(forItem: "The Mornfield") == "M")
        #expect(JumpMarks.tag(forItem: "Ein Kessel voller Tauben") == "K")
        // No article, no section — "Dervano" does not start with "Der ".
        #expect(JumpMarks.tag(forItem: "Dervano") == "D")
        #expect(JumpMarks.tag(forItem: "Theater") == "T")
    }

    /// **Turkish has no definite article**, and the indefinite one ("bir")
    /// also stands in the middle of a title. Cutting it off would shift titles that were sorted in
    /// correctly — which is why it is not in the list.
    @Test("Turkish titles keep their beginning")
    func turkish() {
        #expect(JumpMarks.tag(forItem: "Bir Yazlık Köy'de") == "B")
    }

    /// **This check stood the other way round until 2026-09-07, and it was half right.**
    ///
    /// It demanded `tag("Çakılo") == "Ç"` — with the finding of 2026-08-07: "`Ç` belongs next to
    /// `C`, `Ö` next to `O`; as raw values both sort **after Z**, and this provider
    /// carries 2.741 Turkish titles." **The finding is correct and still applies.** What was missing was
    /// the counter-check: Whether the tag also designates a **block**.
    ///
    /// **Measured again on 2026-09-07, and it did not.** Sorting is by the folded
    /// key, and that turns `Ölmezo` into `olmezo`. Eight Turkish titles thus lie in the list as
    /// **Ölmezo, Orvan, Ötelik, Ozmar** — and a bar with separate tags
    /// `Ö` and `O` jumps into the middle of a mixed block. The same measurement in German:
    /// "Äolin Fex" stands before "Avelon" and carried the tag `Ä`.
    ///
    /// **So the separate tag falls and not the order.** `Ç` still stands next to
    /// `C` — namely **inside** it, and not after `Z`; the finding of 2026-08-07 is thereby
    /// fulfilled. What is lost is that a Turkish viewer finds `Ç` again as its own letter.
    /// **That is the more honest of two imperfect answers:** A
    /// tag that designates no block is worse than one tag fewer.
    ///
    /// A bar that could do both would need a **Turkish collation** instead of a
    /// folding — and that would then also apply to the German titles of the same list. That is a
    /// package of its own and not a line here.
    @Test("Accented letters fall into one block with their base letter")
    func characterAbove() {
        #expect(JumpMarks.tag(forItem: "Çakılo") == "C")
        #expect(JumpMarks.tag(forItem: "Ölmezo") == "O")
        #expect(JumpMarks.tag(forItem: "Äolin Fex") == "A")
    }

    /// Digits and special characters collect under one character — and it stands **at the end**.
    @Test("Digits and symbols go under the collective symbol")
    func collectiveSymbol() {
        #expect(JumpMarks.tag(forItem: "300") == "#")
        #expect(JumpMarks.tag(forItem: "…und dann") == "#")
        #expect(JumpMarks.tag(forItem: "") == "#")
        let marks = JumpMarks.marks(from: ["300", "Arvelle", "Brindo"])
        #expect(marks == ["A", "B", "#"])
    }

    /// **The finding of 2026-08-07 still applies, just fulfilled more sharply.** It read: `Ç` belongs
    /// next to `C`, `Ö` next to `O` — as raw values both sort **after Z**, and this
    /// provider carries 2.741 Turkish titles.
    ///
    /// Since 2026-09-07 they no longer stand **next to** but **in** their block: Five
    /// titles give three tags instead of five, and each really designates a
    /// contiguous section of the list. After `Z` there is still none.
    @Test("Ç and Ö land in C and O, not after Z")
    func sorting() throws {
        let marks = JumpMarks.marks(from: ["Çakılo", "Cevrin", "Zelvo", "Ölmezo", "Ozmar"])
        #expect(marks == ["C", "O", "Z"], "found: \(marks)")
        let cPosition = try #require(marks.firstIndex(of: "C"))
        let zPosition = try #require(marks.firstIndex(of: "Z"))
        #expect(cPosition < zPosition)
    }

    /// **Only occupied letters.** A jump into nothing is worse than no jump — it
    /// looks as if the app had lost the title.
    @Test("Unused letters do not appear")
    func onlyOccupied() {
        let marks = JumpMarks.marks(from: ["Arvelle", "Brindo", "Arvelle II"])
        #expect(marks == ["A", "B"])
    }
}

/// Tag and order — **the same string, even with foreign characters.**
///
/// **The finding of 2026-09-07. (AP10).** The roadmap suspected a Turkish case and
/// demanded "ten lines of test suite that decide it". They decided it — and
/// found a second one on the way that was **live in German**.
@Suite("Jump marks across languages")
struct JumpMarkLanguagesTests {

    private static let tr = Locale(identifier: "tr_TR")
    private static let de = Locale(identifier: "de_DE")

    /// **The German case, and it was on screen.** "Äolin Fex" sorts by the
    /// key `aolin fex` before "Avelon" — correct —, but carried the tag **Ä**. The bar
    /// showed Ä, A, Ö, O, Ü, U: six tags for three blocks. Whoever pressed "A" jumped past
    /// "Äolin Fex", which stood above it.
    @Test("Umlauts get the mark of their base letter")
    func umlauts() {
        #expect(JumpMarks.tag(forItem: "Äolin Fex", language: Self.de) == "A")
        #expect(JumpMarks.tag(forItem: "Über den Dünenkamm", language: Self.de) == "U")
        #expect(JumpMarks.tag(forItem: "Ödwinkel", language: Self.de) == "O")
        #expect(
            JumpMarks.marks(from: ["Äolin Fex", "Avelon", "Über den Dünenkamm"], language: Self.de)
                == ["A", "U"],
            "Three titles, two blocks — and no mark that does not exist")
    }

    /// **The Turkish case, measured and not assumed.** The folding maps there
    /// **both** capital I to the dotless "ı": "İskelo" becomes `ıskelo`, "Islavu"
    /// becomes `ıslavu`. The list therefore mixes them, and a bar with two blocks claimed
    /// a separation that does not exist in the order.
    ///
    /// **The price is stated expressly in the check:** In Turkish "İ" and "I" are two
    /// letters and get **one** block here. That is the more honest of two
    /// imperfect answers — the other would be a bar that shows two blocks and jumps into
    /// a mixed list.
    @Test("In Turkish both capital I letters share one block")
    func turkishI() {
        let title = ["İskelo", "Islavu", "İrmela Durak", "Izmora"]
        let marks = title.map { JumpMarks.tag(forItem: $0, language: Self.tr) }
        #expect(Set(marks).count == 1, "One block and not two, found: \(Set(marks))")
        #expect(JumpMarks.marks(from: title, language: Self.tr) == marks.first.map { [$0] })
    }

    /// **The rule from which both cases follow.** It is the actual check: Every
    /// tag must be the first letter of the key by which sorting is done. Whoever holds that
    /// can no longer produce the two cases above at all — nor the next one that
    /// nobody foresaw.
    @Test("Every mark is the beginning of the key used for sorting")
    func markFollowsTheKey() {
        let title = [
            "Äolin Fex", "Über den Dünenkamm", "Der Fürstenhain", "İstanbul", "Islak",
            "Ödwinkel", "300", "…und dann kam Polly",
        ]
        for language in [Self.de, Self.tr] {
            for entry in title {
                let sortKey = JumpMarks.key(entry, language: language)
                let tag = JumpMarks.tag(forItem: entry, language: language)
                guard tag != JumpMarks.collectiveSymbol else {
                    #expect(
                        sortKey.first?.isLetter != true,
                        "\(entry) carries the collective symbol but starts with a letter")
                    continue
                }
                let hint = "\(entry) / \(language.identifier): mark \(tag), key \(sortKey)"
                #expect(sortKey.uppercased().hasPrefix(tag), "\(hint)")
            }
        }
    }
}
