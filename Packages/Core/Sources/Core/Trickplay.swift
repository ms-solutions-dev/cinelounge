import Foundation

/// The picture preview while scrubbing.
///
/// The server does not store individual pictures for this, but **sheets**: one
/// large image file in which many small preview pictures lie in a grid. That is
/// the reason this type computes more than it stores — from a timestamp, first the
/// file and then the cell within it must be determined.
///
/// The reason for the sheets: For a film with ten seconds between frames, a
/// thousand preview pictures result. A thousand individual requests while scrubbing
/// would be unusable; one sheet covers a hundred of them with one request.
public struct Trickplay: Sendable, Equatable {

    /// Breite eines einzelnen Vorschaubildes in Bildpunkten.
    public let width: Int
    public let height: Int

    /// How many preview pictures lie side by side and one above the other per sheet.
    public let tileColumns: Int
    public let tileRows: Int

    /// Interval between two preview pictures in seconds.
    ///
    /// The server reports it in milliseconds; here it is in seconds, because every
    /// calculation here works with seconds. The conversion happens exactly once, when
    /// reading it in.
    public let interval: TimeInterval

    public let thumbnailCount: Int

    /// Address of a sheet, without the number at the end.
    ///
    /// For the Jellyfin server it ends in `Trickplay/320`; `/0.jpg`, `/1.jpg` and so
    /// on are appended. The number counts **sheets**, not preview pictures — a mix-up
    /// that leads to pictures from the wrong place and is noticed late when trying it
    /// out, because the first sheets happen to match.
    public let sheetBase: URL

    public init(
        width: Int,
        height: Int,
        tileColumns: Int,
        tileRows: Int,
        interval: TimeInterval,
        thumbnailCount: Int,
        sheetBase: URL
    ) {
        self.width = width
        self.height = height
        self.tileColumns = max(1, tileColumns)
        self.tileRows = max(1, tileRows)
        self.interval = max(0.001, interval)
        self.thumbnailCount = thumbnailCount
        self.sheetBase = sheetBase
    }

    /// Vorschaubilder je Bogen.
    public var perSheet: Int { tileColumns * tileRows }

    /// Where in the film a preview picture lies.
    ///
    /// If asked beyond the end, the last existing one is returned instead of nothing:
    /// When scrubbing to the end, a gap would be worse than a picture that is off by a
    /// second.
    public func thumbnailIndex(at time: TimeInterval) -> Int {
        let raw = Int((max(0, time) / interval).rounded(.down))
        return min(raw, max(0, thumbnailCount - 1))
    }

    /// The sheet on which a preview picture lies.
    public func sheetIndex(forThumbnail index: Int) -> Int {
        max(0, index) / perSheet
    }

    /// The cell within the sheet.
    public func cell(forThumbnail index: Int) -> (column: Int, row: Int) {
        let local = max(0, index) % perSheet
        return (column: local % tileColumns, row: local / tileColumns)
    }

    /// The address of the sheet on which this timestamp lies.
    public func sheetURL(at time: TimeInterval) -> URL {
        let sheet = sheetIndex(forThumbnail: thumbnailIndex(at: time))
        return sheetBase.appending(path: "\(sheet).jpg")
    }

    /// The fraction by which a sheet has to be shifted and enlarged so that the
    /// desired cell sits in the frame.
    ///
    /// As fractions and not in pixels, because the display chooses the frame freely —
    /// the preview is wider while scrubbing than in a list.
    public func cellFraction(forThumbnail index: Int) -> (x: Double, y: Double) {
        let position = cell(forThumbnail: index)
        return (
            x: Double(position.column) / Double(tileColumns),
            y: Double(position.row) / Double(tileRows)
        )
    }
}
