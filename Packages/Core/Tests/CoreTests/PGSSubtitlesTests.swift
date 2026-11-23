import Foundation
import Testing

@testable import Core

/// Tests against a **real** server response: the first eight
/// display units of the German PGS track of Ink Ledger S01E01, cut raw from the
/// `Stream.pgssub` endpoint — not an example built by hand.
struct PGSSubtitlesTests {

    private func fixture() throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/ink-ledger-s01e01", withExtension: "pgssub")
        )
        return try Data(contentsOf: url)
    }

    @Test("The real track yields images with plausible windows")
    func parsesRealTrack() throws {
        let cues = PGSSubtitles.parse(try fixture())

        // Eight units are display sets and their clears — several
        // closed windows must come out.
        #expect(cues.count >= 3)

        for cue in cues {
            #expect(cue.canvasWidth == 1920, "Blu-ray canvas")
            #expect(cue.canvasHeight == 1080)
            #expect(cue.width > 0 && cue.width <= cue.canvasWidth)
            #expect(cue.height > 0 && cue.height <= cue.canvasHeight)
            #expect(cue.x >= 0 && cue.x + cue.width <= cue.canvasWidth)
            #expect(cue.y >= 0 && cue.y + cue.height <= cue.canvasHeight)
            #expect(cue.end > cue.start, "no window without a duration")
            #expect(
                cue.rgba.count == cue.width * cue.height * 4,
                "RGBA must cover the full area"
            )
        }

        // The windows come sorted and begin in the first piece of the film.
        #expect(cues == cues.sorted { $0.start < $1.start })
        #expect(cues[0].start < 300)
    }

    @Test("The images are not empty — visible pixels with coverage")
    func imagesCarryVisiblePixels() throws {
        let cues = PGSSubtitles.parse(try fixture())
        let first = try #require(cues.first)

        // A subtitle image consists largely of a transparent margin and
        // a visible lettering — both must occur.
        var opaque = 0
        var transparent = 0
        var index = 3
        while index < first.rgba.count {
            if first.rgba[index] > 200 { opaque += 1 }
            if first.rgba[index] == 0 { transparent += 1 }
            index += 4
        }
        #expect(opaque > 100, "the lettering is missing")
        #expect(transparent > 100, "the transparent margin is missing")
    }

    @Test("The image lookup finds the spot and stays silent in between")
    func lookupFindsTheWindow() throws {
        let cues = PGSSubtitles.parse(try fixture())
        let first = try #require(cues.first)

        let middle = (first.start + first.end) / 2
        #expect(!cues.images(at: middle).isEmpty)
        #expect(cues.images(at: first.start - 1).isEmpty)
    }

    @Test("The color math hits white, black and transparent")
    func paletteMathIsSound() {
        let white = PGSSubtitles.rgba(y: 235, cr: 128, cb: 128, alpha: 255)
        #expect(white.r > 250 && white.g > 250 && white.b > 250 && white.a == 255)

        let black = PGSSubtitles.rgba(y: 16, cr: 128, cb: 128, alpha: 255)
        #expect(black.r == 0 && black.g == 0 && black.b == 0)

        #expect(PGSSubtitles.rgba(y: 235, cr: 128, cb: 128, alpha: 0).a == 0)
    }
}
