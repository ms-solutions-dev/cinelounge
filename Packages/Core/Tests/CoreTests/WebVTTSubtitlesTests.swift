import Foundation
import Testing

@testable import Core

/// Checks against the format that Jellyfin actually delivers — the examples
/// have the shape of a real response (`/Videos/…/Subtitles/4/Stream.vtt`), with the
/// lines of the film replaced by invented ones, not that of the WebVTT standard.
struct WebVTTSubtitlesTests {

    @Test("A real Jellyfin response is read completely")
    func parsesRealJellyfinOutput() {
        // With everything the real file carries: byte order mark,
        // region line in the header, cue settings after the end time,
        // italic markup and music note characters.
        let raw = """
            \u{FEFF}WEBVTT

            Region: id:subtitle width:80% lines:3 regionanchor:50%,100% viewportanchor:50%,90%

            00:01:30.120 --> 00:01:32.240 region:subtitle line:90%
            ♪ <i>Am Ufer warten</i>

            00:01:32.320 --> 00:01:36.160 region:subtitle line:90%
            ♪ Die Boote ziehen weiter ♪

            """
        let cues = WebVTTSubtitles.parse(raw)

        #expect(cues.count == 2)
        // With tolerance: `1 * 60 + 32.24` carries the usual floating-point remainder.
        #expect(abs(cues[0].start - 90.12) < 0.001)
        #expect(abs(cues[0].end - 92.24) < 0.001)
        #expect(cues[0].text == "♪ Am Ufer warten", "markup is removed")
        #expect(cues[1].text == "♪ Die Boote ziehen weiter ♪")
    }

    @Test("Multi-line cues stay one line with a break")
    func multiLineCuesKeepTheirBreak() {
        let raw = """
            WEBVTT

            00:10.000 --> 00:12.500
            Erste Zeile
            zweite Zeile
            """
        let cues = WebVTTSubtitles.parse(raw)

        #expect(cues.count == 1)
        #expect(cues[0].start == 10)
        #expect(cues[0].text == "Erste Zeile\nzweite Zeile")
    }

    @Test("Identifiers above the timings and notes carry no text")
    func identifiersAndNotesAreSkipped() {
        // Some tools number every cue — the number is not a
        // subtitle. And what stands before the first cue belongs to the header.
        let raw = """
            WEBVTT

            NOTE Diese Zeile ist ein Kommentar

            1
            00:05.000 --> 00:06.000
            Hallo
            """
        let cues = WebVTTSubtitles.parse(raw)

        #expect(cues.count == 1)
        #expect(cues[0].text == "Hallo")
    }

    @Test("Timestamps work with and without hours, period and comma")
    func timestampsCoverBothShapes() {
        #expect(WebVTTSubtitles.timestamp("01:02:03.500") == 3723.5)
        #expect(WebVTTSubtitles.timestamp("02:03.500") == 123.5)
        #expect(WebVTTSubtitles.timestamp("02:03,500") == 123.5, "comma as in the SRT heritage")
        #expect(WebVTTSubtitles.timestamp("kaputt") == nil)
    }

    @Test("Character entities are resolved")
    func entitiesAreDecoded() {
        #expect(WebVTTSubtitles.clean("Kit &amp; Mops &lt;3") == "Kit & Mops <3")
        #expect(WebVTTSubtitles.clean("<b>laut</b> &quot;Zitat&quot;") == "laut \"Zitat\"")
    }

    @Test("The cue lookup finds the position and stays silent in between")
    func lookupFindsTheWindowAndTheGaps() {
        let cues = [
            SubtitleCue(start: 10, end: 12, text: "eins"),
            SubtitleCue(start: 15, end: 18, text: "zwei"),
            SubtitleCue(start: 18, end: 20, text: "drei"),
        ]

        #expect(cues.text(at: 11) == "eins")
        #expect(cues.text(at: 13) == nil, "nothing runs between two cues")
        #expect(cues.text(at: 15) == "zwei", "the start belongs to the cue")
        #expect(cues.text(at: 18) == "drei", "the end already belongs to the next")
        #expect(cues.text(at: 25) == nil)
        #expect([SubtitleCue]().text(at: 5) == nil, "an empty track does not crash")
    }
}
