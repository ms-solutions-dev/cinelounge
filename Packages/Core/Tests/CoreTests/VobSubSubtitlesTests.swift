import Foundation
import Testing

@testable import Core

/// VobSub — the subtitles of the DVD, 428 tracks in the catalog.
///
/// **Tested on a real track from the server**, not a built one: 92
/// kilobytes, 45 packets, German subtitles of a Jade Comet episode.
@Suite("Reading VobSub subtitles")
struct VobSubSubtitlesTests {

    static func fixture() throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/jadecomet", withExtension: "sub"))
        return try Data(contentsOf: url)
    }

    /// **One display unit spans several packets.** In this track
    /// 4403 bytes are spread over three; whoever assumes one unit per packet
    /// decodes fragments and gets stripes instead of text.
    @Test("Units are assembled across packet boundaries")
    func unitsSpanPackets() throws {
        let units = VobSubSubtitles.units(in: try Self.fixture())

        #expect(!units.isEmpty)
        // The first unit states its length in the first two bytes, and that
        // must be reached.
        let first = try #require(units.first)
        let announced =
            Int(first.data[first.data.startIndex]) << 8
            | Int(first.data[first.data.startIndex + 1])
        #expect(first.data.count >= announced)
        #expect(announced > 4000, "This unit spans several packets")
        // Times run upward.
        #expect(zip(units, units.dropFirst()).allSatisfy { $0.pts <= $1.pts })
    }

    @Test("A real track yields images with time and position")
    func realTrackBecomesImages() throws {
        let cues = VobSubSubtitles.parse(try Self.fixture())

        #expect(cues.count >= 10)
        #expect(cues.allSatisfy { $0.end > $0.start })
        #expect(zip(cues, cues.dropFirst()).allSatisfy { $0.start <= $1.start })

        for cue in cues {
            #expect(cue.width > 0 && cue.height > 0)
            #expect(cue.rgba.count == cue.width * cue.height * 4)
            // Inside the canvas, otherwise the player would draw off to the side.
            #expect(cue.x >= 0 && cue.x + cue.width <= cue.canvasWidth)
            #expect(cue.y >= 0 && cue.y + cue.height <= cue.canvasHeight)
            // **This track is not DVD-sized.** The areas reach up to
            // 1443×975; whoever assumes 720×576 draws the text enlarged to
            // double across the picture.
            #expect(cue.canvasWidth == 1920 && cue.canvasHeight == 1080)
        }
    }

    /// **A picture consisting only of transparent pixels is none.**
    /// That is exactly what a decoding error would look like: everything runs through, there is just
    /// nothing on the screen.
    @Test("The images really carry lettering")
    func imagesCarryInk() throws {
        let cues = VobSubSubtitles.parse(try Self.fixture())
        let first = try #require(cues.first)

        var opaque = 0
        for index in stride(from: 3, to: first.rgba.count, by: 4)
        where first.rgba[first.rgba.startIndex + index] > 0 {
            opaque += 1
        }
        let share = Double(opaque) / Double(first.width * first.height)
        // Text covers a fraction of the area — not nothing and not
        // everything. Either would be a sign that the run lengths are off.
        #expect(share > 0.01, "not a single visible pixel")
        #expect(share < 0.9, "the whole field is filled")
    }

    /// **The lines come interleaved** — even ones in one block, odd ones in
    /// a second. Whoever reads them one after the other fills the upper half and
    /// leaves the lower one empty.
    @Test("Both fields are filled")
    func bothFieldsAreDecoded() throws {
        let cues = VobSubSubtitles.parse(try Self.fixture())
        let cue = try #require(cues.first)

        var evenLines = 0
        var oddLines = 0
        for line in 0..<cue.height {
            let start = cue.rgba.startIndex + line * cue.width * 4
            var hasInk = false
            for column in 0..<cue.width where cue.rgba[start + column * 4 + 3] > 0 {
                hasInk = true
                break
            }
            if hasInk { line % 2 == 0 ? (evenLines += 1) : (oddLines += 1) }
        }
        #expect(evenLines > 0, "the upper field is empty")
        #expect(oddLines > 0, "the lower field is empty")
    }

    /// **The `.idx` sits in the track header of the MKV file.** The server does not
    /// hand it out (400), the file does — and there are the colour palette and
    /// canvas size, which would otherwise both have to be guessed.
    @Test("Palette and canvas come from the track header")
    func indexFromCodecPrivate() throws {
        let idx = """
            # VobSub index file
            size: 720x576
            palette: 000000, 7e7e7e, eb8080, 101010, 8080f0
            langidx: 0
            """
        let read = try #require(Matroska.vobSubIndex(inCodecPrivate: Data(idx.utf8)))

        #expect(read.width == 720)
        #expect(read.height == 576)
        #expect(read.palette.count == 5)
        // **The colours are stored as YCbCr and are converted.** `eb8080` is
        // white; read unconverted it would be a dull blue-grey.
        #expect(read.palette[2] == 0x00EB_EBEB)
        // **And `000000` is not black there.** In YCbCr it means luma
        // zero with full blue and red subtraction — converted, a dark green.
        // A DVD writes black as `101010`. The entry does not matter because
        // it is the transparent background; but whoever omits the conversion
        // turns white into a dull blue-grey.
        #expect(read.palette[0] == 0x0000_8700)
    }

    /// Without a colour palette nothing is guessed; the usual split is
    /// taken — white text on a black outline.
    @Test("Without a palette the subtitle stays readable")
    func defaultPaletteIsUsed() throws {
        let cues = VobSubSubtitles.parse(try Self.fixture())
        let cue = try #require(cues.first)

        var white = 0
        for index in stride(from: 0, to: cue.rgba.count, by: 4) {
            let base = cue.rgba.startIndex + index
            if cue.rgba[base + 3] > 0, cue.rgba[base] > 200, cue.rgba[base + 1] > 200,
                cue.rgba[base + 2] > 200
            {
                white += 1
            }
        }
        #expect(white > 0, "no white lettering in the image")
    }
}
