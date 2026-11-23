import DesignSystem
import Foundation
import SourceProbe
import Testing

@testable import Features

/// **An outlier stands out only if there is a list against which it deviates** —
/// AP25, 2026-09-11.
///
/// **The finding:** The heart stood in seven places for favorites, the **star** in three
/// more for the same thing — while the same star in the Sports area stands for
/// **bookmarking**. On a channel row that meant: the button in the player bar
/// showed a heart, the badge two controls further a star, and the same
/// was meant both times.
///
/// **What is tested is the source text**, because the icon only becomes an icon in the picture. A
/// `systemName` that nobody has cataloged is a decision without a place.
struct IconographyTests {

    /// Pulls the drawn icons out of a source file.
    ///
    /// **Exactly two forms and not "everything in quotation marks after it"** — the first
    /// attempt on 2026-09-11 took the whole rest of the line and reported `search.hint` as a foreign
    /// icon: on `message(systemImage:titleKey:)` the language key stands on
    /// the same line. A test that reports false positives gets switched off.
    ///
    /// 1. `systemName: "haus"` — the literal immediately after it.
    /// 2. `systemImage: applies ? "a" : "b"` — both branches of a ternary expression.
    static func character(in sourceText: String) -> Set<String> {
        let single = try! NSRegularExpression(
            pattern: #"system(?:Name|Image):\s*"([^"]+)""#)
        let triple = try! NSRegularExpression(
            pattern: #"system(?:Name|Image):[^,)]*?\?\s*"([^"]+)"\s*:\s*"([^"]+)""#)

        var names: Set<String> = []
        for row in sourceText.split(separator: "\n") {
            let raw = String(row).trimmingCharacters(in: .whitespaces)
            // In the reasoning, icon names deliberately appear once more.
            guard !raw.hasPrefix("//") else { continue }
            let total = NSRange(raw.startIndex..., in: raw)

            for patterns in [single, triple] {
                for match in patterns.matches(in: raw, range: total) {
                    for group in 1..<match.numberOfRanges {
                        guard let area = Range(match.range(at: group), in: raw) else {
                            continue
                        }
                        names.insert(String(raw[area]))
                    }
                }
            }
        }
        return names
    }

    /// What the registry does not know, the app does not draw either.
    ///
    /// **Two exceptions with reason**, and both are named here instead of as a
    /// folder rule: the Sports rows carry their own badges, and the
    /// area list of Settings carries eleven icons for eleven areas — those belong
    /// to the structure and not to the semantics.
    @Test("Every drawn symbol is in the registry")
    func everySymbolIsInTheRegistry() throws {
        // **Only one exception left** (AP26, 2026-09-11): the area list of
        // Settings carried eleven icons of its own; they have been in the registry since and
        // need no exception any more. The Sports rows carry their own badges
        // and their own test suite.
        let excluded: Set<String> = ["SportView.swift"]
        var foreign: [String: Set<String>] = [:]

        for file in try SourceText.files(in: .features)
        where !excluded.contains(file.name) {
            for name in Self.character(in: file.content) where !Glyph.allNames.contains(name) {
                foreign[file.name, default: []].insert(name)
            }
        }

        #expect(
            foreign.isEmpty,
            """
            Symbols without an entry in ``DesignSystem/Sinnbilder``: \
            \(foreign.map { "\($0.key): \($0.value.sorted().joined(separator: ", "))" }
                .sorted().joined(separator: " · ")).
            Either the symbol belongs in the registry — then it also says there what it \
            means — or it is an outlier and belongs on one of the existing ones.
            """
        )
    }

    /// **Heart and star are no longer written by hand** — and that is the
    /// test that really catches the outlier.
    ///
    /// **The test above does not catch it**, and the counter-check showed that on 2026-09-11:
    /// it asks "is this name in the registry?" — and `"star.fill"` is
    /// there, just as **bookmarking**. A name carries no meaning; whoever writes it by
    /// hand sidesteps the decision that is in the registry.
    ///
    /// **So: these four names no longer occur as a literal.** Whoever draws a heart or
    /// a star takes ``Styling/Glyph/favorite`` or ``Styling/Glyph/bookmark``
    /// — and has to say what is meant. The Sports rows are the named exception:
    /// the star is at home there, and their own test suite guards it.
    @Test("Heart and star come only through the registry now")
    func noHeartAndNoStarByHand() throws {
        let confusable = Set([
            Glyph.favorite.pair.outlined, Glyph.favorite.pair.filled,
            Glyph.bookmark.pair.outlined, Glyph.bookmark.pair.filled,
        ])
        var locations: [String] = []

        for file in try SourceText.files(in: .features) where file.name != "SportView.swift" {
            let found = Self.character(in: file.content).intersection(confusable)
            if !found.isEmpty {
                locations.append("\(file.name): \(found.sorted().joined(separator: ", "))")
            }
        }

        #expect(
            locations.isEmpty,
            """
            Hand-written heart or star: \(locations.sorted().joined(separator: " · ")).
            Both symbols were mixed up for exactly this reason: the heart stood in seven \
            places for favorites, the star in three more for the same thing — and \
            in the sports area for the watchlist. Through ``Sinnbild`` one has to say what one \
            means; a literal leaves it open.
            """
        )
    }

    /// **Heart and star do not mean the same, and the registry says so.**
    ///
    /// One does not "like" a bookmarked game — one does not want to miss it. Two
    /// meanings on one icon would be one too many; the phone project has kept the same separation
    /// since 2026-09-07.
    @Test("Favorite and watchlist are different symbols")
    func favoriteIsNotWatchlist() {
        #expect(Glyph.favorite.pair.outlined == "heart")
        #expect(Glyph.bookmark.pair.outlined == "star")
        #expect(Glyph.favorite.pair.outlined != Glyph.bookmark.pair.outlined)
        #expect(Glyph.favorite.pair.filled != Glyph.bookmark.pair.filled)
    }

    /// **Filled means "applies", outlined means "does not apply"** — and never the color alone.
    @Test("A pair carries its state in its shape")
    func theShapeCarriesTheState() {
        #expect(Glyph.favorite.pair.forItem(true) == "heart.fill")
        #expect(Glyph.favorite.pair.forItem(false) == "heart")
    }
}
