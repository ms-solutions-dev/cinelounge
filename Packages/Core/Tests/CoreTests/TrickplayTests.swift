import Foundation
import Testing

@testable import Core

/// The values come from the server: thumbnails 320 pixels wide,
/// a hundred of them per sheet in a grid of ten by ten, one picture every ten
/// seconds. With a runtime of 22 minutes that gives 132 pictures on two sheets.
///
/// What is tested here above all is the sheet change. A bug in it shows up late when
/// trying it out, because the first hundred pictures happen to be right — and
/// after that the scrub preview shows pictures from the wrong spot throughout.
@Suite("Thumbnails while scrubbing")
struct TrickplayTests {

    static var episode: Trickplay {
        Trickplay(
            width: 320,
            height: 180,
            tileColumns: 10,
            tileRows: 10,
            interval: 10,
            thumbnailCount: 132,
            sheetBase: URL(string: "https://media.example:8096/Videos/abc/Trickplay/320")!
        )
    }

    /// A non-square grid so that swapping columns and rows
    /// gets noticed. With ten by ten it would go unnoticed.
    static var wideSheet: Trickplay {
        Trickplay(
            width: 320,
            height: 180,
            tileColumns: 8,
            tileRows: 5,
            interval: 10,
            thumbnailCount: 132,
            sheetBase: URL(string: "https://media.example:8096/Videos/abc/Trickplay/320")!
        )
    }

    @Test("A timestamp resolves to the thumbnail beneath it")
    func indexFromTime() {
        // Rounded down, not rounded: at 19 seconds the picture of second 10 belongs
        // there, not that of second 20 — otherwise the preview shows a spot that
        // is still to come.
        let play = Self.episode

        #expect(play.thumbnailIndex(at: 0) == 0)
        #expect(play.thumbnailIndex(at: 9.9) == 0)
        #expect(play.thumbnailIndex(at: 10) == 1)
        #expect(play.thumbnailIndex(at: 95) == 9)
    }

    @Test("Beyond the end the last available image is returned")
    func beyondEnd() {
        // When scrubbing to the end a gap would be worse than a picture that
        // is one second off. Without the clamp the display reaches for
        // a sheet that does not exist, and the preview stays black.
        let play = Self.episode

        #expect(play.thumbnailIndex(at: 1320) == 131)
        #expect(play.thumbnailIndex(at: 99_999) == 131)
    }

    @Test("A negative timestamp gives the first image")
    func negativeTime() {
        // Some engines briefly report a position below zero on opening. A
        // negative index would yield negative fractions, and the sheet would then sit
        // entirely outside the frame.
        #expect(Self.episode.thumbnailIndex(at: -3) == 0)
    }

    @Test("The sheet change falls exactly after the hundredth image")
    func sheetBoundary() {
        // The most common arithmetic error: confusing the sheet number and the
        // picture number, or an off-by-one count. Both show pictures from the
        // wrong spot as soon as the first sheet is full.
        let play = Self.episode

        #expect(play.perSheet == 100)
        #expect(play.sheetIndex(forThumbnail: 99) == 0)
        #expect(play.sheetIndex(forThumbnail: 100) == 1)
        #expect(play.sheetIndex(forThumbnail: 131) == 1)
    }

    @Test("The cell jumps back to the top-left corner at the sheet change")
    func cellAtSheetBoundary() {
        // If the remainder is not formed, the cell of the 100th picture sits
        // arithmetically in the eleventh row — outside the sheet, and the preview stays empty.
        let play = Self.episode

        #expect(play.cell(forThumbnail: 99) == (column: 9, row: 9))
        #expect(play.cell(forThumbnail: 100) == (column: 0, row: 0))
        #expect(play.cell(forThumbnail: 101) == (column: 1, row: 0))
    }

    @Test("Columns and rows are not swapped")
    func rowsAndColumns() {
        // With a square grid a swap goes unnoticed; with eight
        // by five it shows immediately. The pictures lie row by row.
        let play = Self.wideSheet

        #expect(play.perSheet == 40)
        #expect(play.cell(forThumbnail: 7) == (column: 7, row: 0))
        #expect(play.cell(forThumbnail: 8) == (column: 0, row: 1))
        #expect(play.cell(forThumbnail: 12) == (column: 4, row: 1))
        #expect(play.cell(forThumbnail: 40) == (column: 0, row: 0))
        #expect(play.sheetIndex(forThumbnail: 40) == 1)
    }

    @Test("The address of the sheet follows the timestamp")
    func sheetAddress() {
        let play = Self.episode

        #expect(play.sheetURL(at: 995).lastPathComponent == "0.jpg")
        #expect(play.sheetURL(at: 1000).lastPathComponent == "1.jpg")
        // Beyond the end it stays at the last sheet instead of requesting
        // a third one that the server does not have.
        #expect(play.sheetURL(at: 99_999).lastPathComponent == "1.jpg")
    }

    @Test("The fraction points to the top-left corner of the cell")
    func fractions() {
        // Fractions and not pixels, because the frame is larger when scrubbing than
        // in a list. A reference to the centre of the cell would shift the sheet by one
        // half cell — the picture would then consist of two halves.
        let play = Self.episode
        let fraction = play.cellFraction(forThumbnail: 12)

        #expect(fraction.x == 0.2)
        #expect(fraction.y == 0.1)
        #expect(play.cellFraction(forThumbnail: 0) == (x: 0, y: 0))
        #expect(play.cellFraction(forThumbnail: 100) == (x: 0, y: 0))
    }

    @Test("An interval of zero does not crash")
    func zeroInterval() {
        // The server reports the interval in milliseconds; if the value is missing, zero
        // arrives. A division by zero yields infinity, and the conversion to Int
        // ends the program — not an error but a crash in the middle of scrubbing.
        let play = Trickplay(
            width: 320,
            height: 180,
            tileColumns: 10,
            tileRows: 10,
            interval: 0,
            thumbnailCount: 132,
            sheetBase: URL(string: "https://media.example:8096/Trickplay/320")!
        )

        #expect(play.interval > 0)
        #expect(play.thumbnailIndex(at: 5) == 131)
        #expect(play.thumbnailIndex(at: 0) == 0)
    }

    @Test("Nonsensical grid values give a grid of a single cell")
    func degenerateGrid() {
        // Zero columns would divide by zero in every cell. A sheet with a
        // single cell is wrong but computable — the preview then shows the
        // picture of a whole sheet instead of ending the program.
        let play = Trickplay(
            width: 320,
            height: 180,
            tileColumns: 0,
            tileRows: -3,
            interval: 10,
            thumbnailCount: 132,
            sheetBase: URL(string: "https://media.example:8096/Trickplay/320")!
        )

        #expect(play.perSheet == 1)
        #expect(play.cell(forThumbnail: 7) == (column: 0, row: 0))
        #expect(play.sheetIndex(forThumbnail: 7) == 7)

        let fraction = play.cellFraction(forThumbnail: 7)
        #expect(fraction.x.isFinite)
        #expect(fraction.y.isFinite)
    }

    @Test("Without thumbnails the index stays at zero")
    func withoutThumbnails() {
        // The server occasionally reports a sheet but no count. Without the
        // lower bound minus one would come out, and the display would reach for a cell
        // to the upper left of the sheet.
        let play = Trickplay(
            width: 320,
            height: 180,
            tileColumns: 10,
            tileRows: 10,
            interval: 10,
            thumbnailCount: 0,
            sheetBase: URL(string: "https://media.example:8096/Trickplay/320")!
        )

        #expect(play.thumbnailIndex(at: 500) == 0)
        #expect(play.sheetIndex(forThumbnail: play.thumbnailIndex(at: 500)) == 0)
    }
}
