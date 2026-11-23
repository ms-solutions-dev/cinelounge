import Core
import Foundation
import Testing

@testable import PortalKit

/// The order in which search results appear.
///
/// **The finding of 2026-09-12:** searching for "quill" should show the series that exists
/// in serieshub, but it was not shown at all; instead there was content that cannot be
/// related to "quill". The cases here are taken from that report — real titles from the
/// server's response.
@Suite("The order of search hits")
struct SearchRankTests {

    private func piece(_ title: String, row: String? = nil) -> MediaItem {
        var s = MediaItem(id: "x|\(title)|a", kind: .series, title: title)
        s.parentTitle = row
        return s
    }

    /// **The reported case.** 3tal and Ahorn together deliver sixty-five news snippets about a
    /// radar system; Serieshub delivers the series.
    @Test("The series ranks above the news item")
    func theReportedCase() {
        let match: [(portal: String, piece: MediaItem)] = [
            ("3tal", piece("Ahorn24")),
            ("ahorn", piece("Feierabendbild - Der Süden")),
            ("ahorn", piece("Ahorn24")),
            ("serieshub", piece("Quill")),
            ("serieshub", piece("Back Quill")),
            ("serieshub", piece("Squill")),
        ]
        let ordered = SearchRank.ordered(match, needle: "quill")
        #expect(ordered.first?.title == "Quill")
        // "Back Quill" contains the word, "Squill" too — both above the news items.
        // By length: Squill (6) before Back Quill (10).
        #expect(ordered.prefix(3).map(\.title) == ["Quill", "Squill", "Back Quill"])
        #expect(
            ordered.last?.title.contains("Ahorn24") == true
                || ordered.last?.title.contains("Feierabendbild") == true)
    }

    /// The tiers one by one, so that the order can be recomputed and does not merely appear to work.
    @Test("The tiers")
    func slots() {
        #expect(SearchRank.tier(title: "Quill", row: nil, needle: "quill") == 0)
        #expect(SearchRank.tier(title: "Folge 1", row: "Quill", needle: "quill") == 1)
        // **Start and middle are the same tier** (since 2026-09-12): length then decides the order,
        // and that is the more honest measure.
        #expect(SearchRank.tier(title: "Quill Season 2", row: nil, needle: "quill") == 2)
        #expect(SearchRank.tier(title: "Back Quill", row: nil, needle: "quill") == 2)
        #expect(
            SearchRank.tier(title: "Quill-System kommt nach Kaufbeuren", row: nil, needle: "quill") == 2)
        #expect(SearchRank.tier(title: "Ahorn24", row: "Ahorn24", needle: "quill") == 4)
    }

    /// **Whoever searches for "krimireihe" means the series** — and its episodes are called "Folge 41:
    /// Kreidespur". Without the series row, an episode of the searched series would sit behind a
    /// news item.
    @Test("The series counts like the title")
    func rowCounts() {
        let match: [(portal: String, piece: MediaItem)] = [
            ("3tal", piece("Krimireihe Steinzeit")),
            ("ahorn", piece("Folge 41: Kreidespur", row: "Die Almwache")),
            ("ahorn", piece("Folge 7: Der Fall", row: "Krimireihe")),
        ]
        let ordered = SearchRank.ordered(match, needle: "krimireihe")
        #expect(ordered.first?.parentTitle == "Krimireihe")
    }

    /// **Official only on a tie.** Preferring them in general brought exactly the news snippets
    /// to the top — that was the bug.
    @Test("The media library wins only the tie")
    func officialOnlyOnTie() {
        let equal: [(portal: String, piece: MediaItem)] = [
            ("animehub", piece("Salt Compass")),
            ("ahorn", piece("Salt Compass")),
        ]
        #expect(
            SearchRank.ordered(equal, needle: "one piece", official: ["ahorn"]).first?.id
                .hasPrefix("x|Salt Compass") == true)

        // And conversely: an official portal with a worse title match stays at the back.
        let unequal: [(portal: String, piece: MediaItem)] = [
            ("ahorn", piece("Ahorn24")),
            ("serieshub", piece("Quill")),
        ]
        #expect(
            SearchRank.ordered(unequal, needle: "quill", official: ["ahorn"]).first?.title
                == "Quill")
    }

    /// Three languages, and the Turkish İ becomes `i̇` with a dot under `lowercased()`.
    @Test("Accents and spelling do not count")
    func normalization() {
        #expect(SearchRank.tier(title: "Kométa", row: nil, needle: "kometa") == 0)
        #expect(SearchRank.tier(title: "QUILL", row: nil, needle: "quill") == 0)
        #expect(SearchRank.tier(title: "  Quill  ", row: nil, needle: "quill") == 0)
    }

    /// **On a true tie the service's order stays.** A portal answers in the order it finds
    /// sensible itself; discarding it without reason would be a degradation nobody sees.
    ///
    /// Equal standing means: same tier **and** same length. Three ten-character titles —
    /// with titles of different lengths this would not test stability but length sorting.
    @Test("A true tie does not change the order")
    func stable() {
        let match: [(portal: String, piece: MediaItem)] = [
            ("serieshub", piece("Back Quill")),
            ("serieshub", piece("Quill Xtra")),
            ("serieshub", piece("Zzz Arrowz")),
        ]
        #expect(
            SearchRank.ordered(match, needle: "quill").map(\.title)
                == ["Back Quill", "Quill Xtra", "Zzz Arrowz"])
    }

    /// **Length decides before the portal** — otherwise "Quill-System kommt nach
    /// Kaufbeuren" (Ahorn, official) would again sit above "Back Quill" (Serieshub).
    @Test("The shorter title wins, even against an official portal")
    func lengthBeforeOfficial() {
        let match: [(portal: String, piece: MediaItem)] = [
            ("ahorn", piece("Quill-System kommt nach Kaufbeuren", row: "Ahorn24")),
            ("serieshub", piece("Squill")),
        ]
        #expect(
            SearchRank.ordered(match, needle: "quill", official: ["ahorn"]).first?.title
                == "Squill")
    }
}
