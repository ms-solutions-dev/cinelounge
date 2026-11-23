import Foundation
import Testing

@testable import Core

/// ASS and SSA — the subtitles with layout.
@Suite("Reading ASS subtitles")
struct ASSSubtitlesTests {

    static func fixture() throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/dialog", withExtension: "ass"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// **On a real track from the library**, not on a constructed one.
    @Test("A real track is read completely")
    func realTrack() throws {
        let cues = ASSSubtitles.parse(try Self.fixture())

        // 297 dialogue lines are in the file; none may be lost.
        #expect(cues.count == 297)
        #expect(cues.allSatisfy { $0.end > $0.start })
        #expect(zip(cues, cues.dropFirst()).allSatisfy { $0.start <= $1.start })
        // This track carries only dialogue — everything at the bottom.
        #expect(cues.allSatisfy { $0.placement == .bottom })
        // And no empty lines: A time window without text covered nothing but itself for two
        // seconds.
        #expect(cues.allSatisfy { !$0.text.isEmpty })
    }

    /// **The text comes last and may contain commas.** In this file the title card
    /// does. Anyone who rigidly splits at every comma loses every sentence with
    /// an enumeration, and in the middle of a word at that.
    @Test("Commas in the text survive parsing")
    func commasInTextSurvive() throws {
        let cues = ASSSubtitles.parse(try Self.fixture())
        let found = cues.first { $0.text.contains("DER SPI") }
        #expect(found?.text == "DER SPI, AN DEM TUD\nEIN LIAFRIOTRAS NIAJI")
        #expect(abs((found?.start ?? 0) - 165.33) < 0.001)
    }

    @Test("Hard breaks become line breaks")
    func lineBreaks() throws {
        let cues = ASSSubtitles.parse(try Self.fixture())
        #expect(cues.contains { $0.text.contains("\n") })
        // And the identifier itself appears nowhere on the picture any more.
        #expect(cues.allSatisfy { !$0.text.contains("\\N") })
    }

    // MARK: - Layout

    static let withSigns = """
        [Script Info]
        ScriptType: v4.00+

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, Alignment, MarginV
        Style: Default,Arial,40,2,20
        Style: Schild,Arial,40,8,20

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:05.00,Default,,0,0,0,,Unten gesprochen
        Dialogue: 0,0:00:02.00,0:00:04.00,Schild,,0,0,0,,OBEN AM HAUS
        Dialogue: 0,0:00:06.00,0:00:07.00,Default,,0,0,0,,{\\an8}Auch oben
        Dialogue: 0,0:00:08.00,0:00:09.00,Default,,0,0,0,,{\\p1}m 0 0 l 100 0 100 100{\\p0}
        Comment: 0,0:00:10.00,0:00:11.00,Default,,0,0,0,,Abgeschaltet
        """

    /// **The reason ASS is a case of its own at all.** The same file carries dialogue at
    /// the bottom and signs at the top; anyone who draws everything at the bottom lays
    /// the lettering over the dialogue and makes both unreadable.
    @Test("Signs go on top, dialogue at the bottom")
    func placementFromStyleAndOverride() {
        let cues = ASSSubtitles.parse(Self.withSigns)

        #expect(cues.first { $0.text == "Unten gesprochen" }?.placement == .bottom)
        // From the style …
        #expect(cues.first { $0.text == "OBEN AM HAUS" }?.placement == .top)
        // … and from the instruction in the middle of the text, which overrules the style.
        #expect(cues.first { $0.text == "Auch oben" }?.placement == .top)
    }

    /// **Vector drawings are not text.** Shown as text, columns of numbers appeared in
    /// the middle of the picture — so they are dropped entirely.
    @Test("Drawings are discarded, not displayed")
    func drawingsAreDropped() {
        let cues = ASSSubtitles.parse(Self.withSigns)
        #expect(!cues.contains { $0.text.contains("m 0 0 l") })
        // Abgeschaltete Zeilen ebenso.
        #expect(!cues.contains { $0.text == "Abgeschaltet" })
        #expect(cues.count == 3)
    }

    /// **SSA numbers the positions differently from ASS.** The same number means
    /// something different in the two versions; anyone who overlooks that pushes the
    /// dialogue to the top in old files.
    @Test("The legacy version counts differently, and that is respected")
    func legacyAlignmentDiffers() {
        let old = """
            [Script Info]
            ScriptType: v4.00

            [V4 Styles]
            Format: Name, Fontname, Fontsize, Alignment
            Style: Default,Arial,40,2
            Style: Oben,Arial,40,6

            [Events]
            Format: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
            Dialogue: Marked=0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Unten
            Dialogue: Marked=0,0:00:03.00,0:00:04.00,Oben,,0,0,0,,Oben
            """
        let cues = ASSSubtitles.parse(old)

        #expect(cues.count == 2)
        #expect(cues.first { $0.text == "Unten" }?.placement == .bottom)
        // In ASS 6 would be the middle, in SSA it is the top.
        #expect(cues.first { $0.text == "Oben" }?.placement == .top)
    }

    /// **The order of the fields is in the file, not in the format.**
    /// Anyone who assumes fixed positions reads the end time as the style in some files.
    @Test("Swapped fields are still read correctly")
    func fieldOrderIsRead() {
        let unusual = """
            [Events]
            Format: Start, End, Text
            Dialogue: 0:00:01.50,0:00:03.25,Nur drei Felder
            """
        let cues = ASSSubtitles.parse(unusual)
        #expect(cues.count == 1)
        #expect(cues.first?.start == 1.5)
        #expect(cues.first?.end == 3.25)
        #expect(cues.first?.text == "Nur drei Felder")
    }

    // MARK: - Nachschlagen

    /// **Unlike with plain text, more than one line can apply.** ASS lays dialogue and
    /// sign on top of each other; anyone who takes only the first loses one or the
    /// other depending on the order.
    @Test("Two lines at once, separated by height")
    func overlappingLines() {
        let cues = ASSSubtitles.parse(Self.withSigns)
        let lines = cues.lines(at: 3)

        #expect(lines[.bottom] == "Unten gesprochen")
        #expect(lines[.top] == "OBEN AM HAUS")
        // And between the lines there is nothing.
        #expect(cues.lines(at: 5.5).isEmpty)
    }

    @Test("Even with thousands of lines nothing is searched, it is looked up")
    func lookupIsFast() throws {
        let cues = ASSSubtitles.parse(try Self.fixture())
        let target = try #require(cues.last)

        let lines = cues.lines(at: (target.start + target.end) / 2)
        #expect(lines[.bottom] == target.text)
        #expect(cues.lines(at: 0).isEmpty)
    }
}
