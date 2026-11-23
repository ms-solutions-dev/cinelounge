import Foundation
import Testing

@testable import Core

/// **Subtitles from the file instead of from the server** (F-035, 2026-10-03): 854 bytes of SRT
/// cost 2¼ minutes because the server read 11 GB for it.
@Suite("Subtitle collector")
struct SubtitleCollectorTests {

    private func makeTrack(_ codec: String, number: Int = 3, header: String? = nil) -> Matroska.Track {
        Matroska.Track(
            number: number, kind: .subtitle, codecID: codec, codecPrivate: header.map { Data($0.utf8) },
            language: "ger", name: nil, isDefault: false, isForced: false,
            width: nil, height: nil, sampleRate: nil, channels: nil,
            defaultDuration: nil, isEncoded: false)
    }

    private func block(_ text: String, ms: Int64, duration: Int64?, track: Int = 3) -> MatroskaReader.Block {
        MatroskaReader.Block(
            track: track, timestamp: ms, isKeyframe: true, duration: duration, frames: [Data(text.utf8)])
    }

    @Test("An SRT line comes with time, without markup, multi-line")
    func srtLine() throws {
        let collector = SubtitleCollector()
        collector.take(
            block("<i>Leihen Sie mir</i>\nIhren Schirm.", ms: 210_500, duration: 2_400),
            track: makeTrack("S_TEXT/UTF8"), scale: 1_000_000)
        let row = try #require(collector.cues(track: 3).first)
        #expect(row.start == 210.5)
        #expect(abs(row.end - 212.9) < 0.0001)
        #expect(row.text == "Leihen Sie mir\nIhren Schirm.")
        #expect(row.placement == .bottom)
    }

    @Test("The same block from two pieces counts once, and the order is right")
    func duplicateBlocksAndOrder() {
        let collector = SubtitleCollector()
        let srt = makeTrack("S_TEXT/UTF8")
        collector.take(block("zwei", ms: 5_000, duration: 1_000), track: srt, scale: 1_000_000)
        collector.take(block("eins", ms: 1_000, duration: 1_000), track: srt, scale: 1_000_000)
        collector.take(block("zwei", ms: 5_000, duration: 1_000), track: srt, scale: 1_000_000)
        #expect(collector.cues(track: 3).map(\.text) == ["eins", "zwei"])
        #expect(collector.state(track: 3) == 2)
    }

    @Test("An ASS block takes its position from the style in the track header")
    func assLineWithStyle() throws {
        let header = """
            [Script Info]
            ScriptType: v4.00+

            [V4+ Styles]
            Format: Name, Fontname, Fontsize, Alignment
            Style: Default,Arial,20,2
            Style: Schild,Arial,20,8

            [Events]
            Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
            """
        let collector = SubtitleCollector()
        let ass = makeTrack("S_TEXT/ASS", header: header)
        collector.take(
            block("7,0,Schild,,0,0,0,,Kanal 6", ms: 60_000, duration: 3_000), track: ass, scale: 1_000_000)
        collector.take(
            block("8,0,Default,,0,0,0,,{\\i1}Hallo{\\i0}, Welt", ms: 61_000, duration: 2_000), track: ass,
            scale: 1_000_000)
        let rows = collector.cues(track: 3)
        try #require(rows.count == 2)
        #expect(rows[0].text == "Kanal 6")
        #expect(rows[0].placement == .top)
        #expect(rows[0].start == 60 && rows[0].end == 63)
        #expect(rows[1].text == "Hallo, Welt")
        #expect(rows[1].placement == .bottom)
    }

    @Test("Image tracks stay with the server")
    func pictureTracksNot() {
        let collector = SubtitleCollector()
        collector.take(block("x", ms: 0, duration: 1), track: makeTrack("S_HDMV/PGS"), scale: 1_000_000)
        #expect(collector.cues(track: 3).isEmpty)
        #expect(!SubtitleCollector.collectible(makeTrack("S_VOBSUB")))
    }
}

@Suite("Subtitle matching")
struct SubtitleAssignmentTests {

    private func mkv(_ number: Int, _ codec: String, _ language: String) -> Matroska.Track {
        Matroska.Track(
            number: number, kind: .subtitle, codecID: codec, codecPrivate: nil,
            language: language, name: nil, isDefault: false, isForced: false,
            width: nil, height: nil, sampleRate: nil, channels: nil,
            defaultDuration: nil, isEncoded: false)
    }

    private func jf(
        _ id: Int, _ format: MediaSource.SubtitleFormat, _ language: String, extern: Bool = false
    )
        -> MediaTrack
    {
        MediaTrack(
            id: "\(id)", kind: .subtitle, title: "", language: language, subtitleFormat: format,
            isExternal: extern)
    }

    /// Exactly the situation of "The Fox of Harbor Lane": three external DVD tracks, one
    /// embedded forced SRT at position 6.
    @Test("Fox of Harbor Lane: the embedded SRT finds its track, the external ones do not count")
    func wolf() {
        let allTracks = [
            jf(0, .vobsub, "de", extern: true), jf(1, .vobsub, "de", extern: true),
            jf(2, .vobsub, "en", extern: true), jf(6, .subrip, "deu"),
        ]
        let file = [mkv(4, "S_TEXT/UTF8", "ger")]
        #expect(
            SubtitleCollector.matroskaTrack(forItem: allTracks[3], all: allTracks, file: file)?.number == 4)
        #expect(SubtitleCollector.matroskaTrack(forItem: allTracks[0], all: allTracks, file: file) == nil)
    }

    @Test("Unequal number of tracks, different format or different language: prefer the server")
    func whenInDoubtNot() {
        let allTracks = [jf(3, .subrip, "deu"), jf(4, .subrip, "eng")]
        #expect(
            SubtitleCollector.matroskaTrack(
                forItem: allTracks[0], all: allTracks, file: [mkv(5, "S_TEXT/UTF8", "ger")])
                == nil)
        #expect(
            SubtitleCollector.matroskaTrack(
                forItem: allTracks[1], all: allTracks,
                file: [mkv(5, "S_TEXT/UTF8", "ger"), mkv(6, "S_HDMV/PGS", "eng")])
                == nil)
        #expect(
            SubtitleCollector.matroskaTrack(
                forItem: allTracks[1], all: allTracks,
                file: [mkv(5, "S_TEXT/UTF8", "eng"), mkv(6, "S_TEXT/UTF8", "ger")]) == nil)
        #expect(
            SubtitleCollector.matroskaTrack(
                forItem: allTracks[1], all: allTracks,
                file: [mkv(5, "S_TEXT/UTF8", "ger"), mkv(6, "S_TEXT/UTF8", "eng")])?.number == 6)
    }
}
