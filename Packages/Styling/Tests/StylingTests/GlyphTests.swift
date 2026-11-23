import SourceProbe
import Testing

@testable import Styling

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// **One meaning per icon, one icon per meaning** — as a check and not as a
/// resolution in the header comment (AP58, report B finding 11).
///
/// The counterpart to the exception pattern of `scripts/colors.py`: A double assignment is only
/// permitted if it is listed with a reason in ``Glyph/sameSymbols`` — and this list must
/// not claim anything that does not hold.
@Suite("The glyph register")
struct GlyphTests {

    @Test("No symbol carries two meanings without a reason")
    func noDoubleAssignment() {
        let wrong = Glyph.forbiddenDoubleAssignments()
        #expect(
            wrong.isEmpty,
            "Double assignment: \(wrong.map { "\($0.key) = \($0.value.map(\.rawValue).sorted())" })")
    }

    @Test("Every permitted double assignment really exists", arguments: Glyph.sameSymbols)
    func exemptionHolds(entry: Glyph.SameSymbol) {
        #expect(entry.meanings.count > 1)
        for meaning in entry.meanings {
            #expect(
                meaning.allSymbols.contains(entry.character),
                "\(meaning) no longer carries \(entry.character) — the row has to go")
        }
    }

    /// **The phone tab exception** (decision 24): Every row really holds — the
    /// tab shows the pair of a different meaning, and only because its own
    /// lacks the filled version.
    @Test("Every tab exception really exists", arguments: Glyph.Tab.exemptions)
    func tabExemptionHolds(entry: Glyph.Tab.Exemption) {
        #expect(entry.tab == entry.shows.pair)
        #expect(entry.meaning.name != entry.shows.name)
        #expect(entry.meaning.pair.outlined == entry.meaning.pair.filled)
        #expect(Glyph.Tab.all.contains(entry.tab))
    }

    @Test("Favorite is the heart, bookmark the star, rating the half star")
    func heartAndStar() {
        #expect(Glyph.favorite.pair == Glyph.Pair("heart", "heart.fill"))
        #expect(Glyph.bookmark.pair == Glyph.Pair("star", "star.fill"))
        #expect(Glyph.rating.allSymbols == ["star.leadinghalf.filled"])
    }

    /// Decision 24: The series no longer carries the channel's icon, and the empty
    /// catalog is the compartment on both devices.
    @Test("Series, channel and empty catalog per decision 24")
    func decisionTwentyFour() {
        #expect(Glyph.series.name != Glyph.channels.name)
        #expect(Glyph.emptyCatalog.name == "tray")
    }

    /// Decision 10 (2026-09-25): Channel lists carry `play.tv`, Live the antenna.
    @Test("Channel lists and Live per decision 10")
    func decisionTen() {
        #expect(Glyph.channelList.name == "play.tv")
        #expect(Glyph.live.name == "dot.radiowaves.left.and.right")
    }

    @Test("Each tab has a real pair")
    func tabs() {
        #expect(Glyph.Tab.all.count == 5)
        for pair in Glyph.Tab.all {
            #expect(pair.outlined != pair.filled)
            #expect(pair.zu(active: true) == pair.filled)
            #expect(pair.forItem(false) == pair.outlined)
        }
    }

    /// Runs on the Mac, against the macOS catalog — that catches typos, but
    /// not icons that are too new (for that ``fromMinimumVersion(name:)``).
    ///
    /// **Without an exception list** (check finding B6 of 2026-09-27): Until then
    /// `exclamationmark.server` stood here as "device only". It is in no SF Symbols catalog,
    /// and nobody used the meaning for it (`serverStoerung`); both are gone.
    @Test("Every symbol resolves", arguments: Glyph.allNames.sorted())
    func resolves(name: String) {
        #if canImport(UIKit)
            #expect(UIImage(systemName: name) != nil, "\(name) does not exist")
        #elseif canImport(AppKit)
            #expect(
                NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                "\(name) does not exist")
        #endif
    }

    /// **Present on the device with tvOS/iOS 18** — not only on the Mac that runs the check.
    @Test("Every symbol exists from the minimum version", arguments: Glyph.allNames.sorted())
    func fromMinimumVersion(name: String) throws {
        let catalog = try #require(GlyphSet.systemSet, "name_availability.plist is missing")
        let problem = catalog.defect(name)
        #expect(problem == nil, "\(problem ?? "")")
    }

    /// The counter-check: An icon from SF Symbols 7 (tvOS/iOS 26) fails, one from
    /// the 2024 catalog (tvOS/iOS 18.0) does not, and an invented one does not either.
    @Test("The version check detects a symbol that is too new")
    func versionTakesEffect() throws {
        let catalog = try #require(GlyphSet.systemSet)
        let youngest = try #require(catalog.years.first { $0.value == "2025" }?.key)
        #expect(catalog.defect(youngest) != nil)
        #expect(catalog.defect("server.rack") == nil)
        #expect(catalog.defect("exclamationmark.server") != nil)
        let rebuilt = GlyphSet(
            years: ["a": "2024", "b": "2024.1"],
            variants: ["2024": ["tvOS": "18.0", "iOS": "18.0"], "2024.1": ["tvOS": "18.1", "iOS": "18.1"]])
        #expect(rebuilt.defect("a") == nil)
        #expect(rebuilt.defect("b") != nil)
    }
}
