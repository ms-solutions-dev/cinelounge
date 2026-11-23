import Foundation

/// A chapter marker with its time.
///
/// **The time is the promise of the button**, not the name. "Chapter 3" tells nobody
/// anything; "12:04" says where the press leads. That is why it always appears, even when
/// the server delivers a name.
public struct ChapterDetail: Sendable, Equatable, Identifiable {

    /// The position in the list — the server does not number chapters.
    public let id: Int

    /// The name, **if it is one.**
    ///
    /// Many servers write "Chapter 3" into it, and that is the number in another language.
    /// Such names are discarded on building, not on drawing: Otherwise the rule would stand in
    /// every view that shows chapters.
    public let name: String?

    /// Beginn in Sekunden ab Filmanfang.
    public let start: TimeInterval

    /// The still frame that the server pulled for the marker — usually none.
    public let image: URL?

    /// The substitute image from the trickplay grid.
    ///
    /// **The finding of 2026-09-05 on *Bringrarn Piosiaspeit Slausnonspel*:** Of sixteen chapters, **one** carried a
    /// still frame. Jellyfin pulls chapter images in a maintenance task that does not run on
    /// many servers — the trickplay sheets, by contrast, it generates for scrubbing anyway, and
    /// inside lies an image every ten seconds. For every marker there is thus one ready,
    /// without anything having to run on the server.
    public let lookahead: ArcExcerpt?

    /// Whether there is an image at all — no matter from which of the two sources.
    public var hasImage: Bool { image != nil || lookahead != nil }

    public init(
        id: Int, name: String?, start: TimeInterval, image: URL? = nil,
        lookahead: ArcExcerpt? = nil
    ) {
        self.id = id
        self.name = name
        self.start = start
        self.image = image
        self.lookahead = lookahead
    }

    /// "12:04" — and "1:12:04" as soon as the hour is needed.
    ///
    /// **The hour appears only when there is one.** "0:12:04" on a short film reads as an
    /// error; a leading zero that is always there is not information.
    public var timeText: String {
        let whole = Int(start.rounded(.down))
        let hours = whole / 3600
        let minutes = (whole % 3600) / 60
        let seconds = whole % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// Where a cell lies in a sheet of images.
///
/// **As a value and not as three numbers on the view.** Sheet, grid width and cell belong
/// together; passed on separately, mixing up sheet number and image number is only a
/// matter of time — and it is noticed late, because the first sheets happen to be right.
public struct ArcExcerpt: Sendable, Equatable {

    public let sheet: URL
    public let columns: Int
    public let rows: Int
    public let column: Int
    public let row: Int

    public init(sheet: URL, columns: Int, rows: Int, column: Int, row: Int) {
        self.sheet = sheet
        self.columns = columns
        self.rows = rows
        self.column = column
        self.row = row
    }
}
