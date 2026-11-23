import DesignSystemPhone
import SwiftUI

/// Numbers that have to differ on the iPad from the phone — **AP7, 2026-09-23.**
///
/// **The finding this file came from:** The app had two size logics side by side, and on
/// the iPad the wrong one won everywhere. Where the tile size was computed from the
/// measured screen width ("three per row", ``ShelfMetrics`` and ``TitleGrid``), it grew
/// to **323 points** — 2.9 times the design device, 8.6 times in area. Where it was
/// fixed (``DesignSystemPhone/Metrics/poster``), it stayed right and the **count** grew:
/// That is exactly what the shelves on the detail page do, and they were the only ones
/// that looked good.
///
/// **A poster has its own readable size; a screen width does not.** "n per row" makes
/// the size a function of the device; a fixed size makes the **count** a function of
/// the device — and that is exactly what should buy more area.
///
/// **Why not in ``DesignSystemPhone/Metrics``:** Its header guarantees 393 × 852. A number
/// with two values is no longer a guarantee but a case distinction — the same separation
/// that ``ShelfMetrics`` already justifies for itself ("Measures live there, a
/// calculation lives here").
///
/// **The decision is made by size class and never by device.** Split View and Stage
/// Manager give the iPad the *compact* class with an unchanged device identifier; a
/// `UIDevice.userInterfaceIdiom` would be wrong there immediately. The model is
/// StoryShelf's `Kachelmass`, which went through the same pass on 2026-09-19.
///
/// **And every number here is computed against the cache step.** The ``ImageLoader`` keys
/// on URL **and** size, and ``DesignSystemPhone/ImageSizes`` rounds up to multiples
/// of 80 pixels: 150 and 160 points of poster width both land on the **same** step, so
/// they sit in the store as **one** variant. Two numbers that round up differently
/// would hold the same image twice. Guarded by
/// ``posterCountsFallOnSameTier()``.
enum MetricClass {

    /// The width of a poster tile in the horizontally scrolling shelf.
    static func shelfPosterWidth(_ width: UserInterfaceSizeClass?) -> CGFloat {
        width == .regular ? 160 : MetricsBoard.phone.poster.width
    }

    /// How many columns the title grid has.
    ///
    /// **A fixed number and explicitly not an `.adaptive` grid** — that was the first draft
    /// and it was wrong. ``TitleGrid`` objects to an adaptive grid that it would compute
    /// "three at 393 points and four at 440"; the objection is **more** right than the
    /// draft gave it credit for. Recalculated:
    ///
    /// - At 393 points, 353 are free after the margins. Today's fixed grid puts the cell at
    ///   `(353 − 2 × 12) / 3 = 109.67` — **just under** 110. A lower bound of 110 would
    ///   therefore give **two** columns there.
    /// - At 320 points (iPhone SE), only two fit with *any* usable lower bound.
    ///   Today it is three, at 85 points.
    ///
    /// An adaptive grid would have changed the layout on devices for which nobody wanted
    /// anything changed. The column count per size class does not: On the phone literally
    /// everything stays, and on the iPad the **count** grows.
    ///
    /// Six columns on a 13″ iPad Pro give a cell of
    /// `(992 − 5 × 12) / 6 ≈ 155` points — the same cache step as the shelf's 160.
    static func columns(_ width: UserInterfaceSizeClass?) -> Int {
        width == .regular ? 6 : 3
    }

    /// How many columns a grid of **wide** tiles has (16 : 9).
    ///
    /// **Two in compact, and that stays** — three 16 : 9 tiles side by side are barely
    /// recognizable as an image at 393 points. On the iPad, two of them would each be
    /// **496 points** wide; four give about 245 and so are in the same order of magnitude
    /// as on the phone, just more of them.
    static func wideColumns(_ width: UserInterfaceSizeClass?) -> Int {
        width == .regular ? 4 : 2
    }

    /// The width of the header box for background image and wordmark.
    ///
    /// **``DesignSystemPhone/Metrics/headerBox`` is set to 400 "sized for the widest
    /// device" — since 2026-09-19 that is wrong.** The box is drawn about 992 points wide
    /// on a 13″ iPad Pro, and 400 was requested: The image arrived at 800 pixels and was
    /// stretched to 1984. **This is the one place where the iPad currently looks worse
    /// than the iPhone**, not just more generous.
    static func headerBox(_ width: UserInterfaceSizeClass?) -> CGFloat {
        width == .regular ? 760 : Metrics.headerBox
    }

    /// The text column next to the poster on the detail page.
    ///
    /// **On the iPad the detail page header put 345 points of empty gradient above the
    /// title**, and the description ran across the full width. Side by side instead of
    /// stacked: poster on the left, text on the right in a column narrow enough to read.
    /// `0` means "no column" — on the phone the header stays as it was.
    static func detailColumn(_ width: UserInterfaceSizeClass?) -> CGFloat {
        width == .regular ? 520 : 0
    }

    /// The maximum width of a primary button.
    ///
    /// ``Knopfstile`` sets `maxWidth: .infinity` — on the iPad that produced a 945-point
    /// "Play" bar. A button you can take in at one glance ends before that.
    static func buttonWidth(_ width: UserInterfaceSizeClass?) -> CGFloat? {
        width == .regular ? 360 : nil
    }

    /// The maximum width of the content of a sheet or a settings list.
    ///
    /// At a height of 1376 points, `Metrics.sheetHalf`/`sheetSmall` produced sheets of 867 and
    /// 619 points that stayed 85 percent empty; in the settings, value and label were up to
    /// 1700 points apart.
    static func contentCap(_ width: UserInterfaceSizeClass?) -> CGFloat? {
        width == .regular ? 700 : nil
    }

    /// How many motifs the profile picture chooser shows in one row (AP49).
    ///
    /// **Four on the phone, six on the iPad** — that is what the concept says (addendum N3).
    /// At 393 points, four are about 80 points per circle and so large enough to recognize
    /// a face; sixteen motifs are then exactly four rows. On the iPad, four columns give
    /// circles of 150 points and more, and the chooser needs more scrolling to survey than
    /// it is worth.
    static func profileImageColumns(_ width: UserInterfaceSizeClass?) -> Int {
        width == .regular ? 6 : 4
    }

    /// How tall the cover image above a profile is (AP49, concept addendum N2).
    ///
    /// **Taller than a strip and shorter than a poster.** The motif is square, the header
    /// wide; what is shown is a band around the face. On the phone, 160 points leave the
    /// circle, the name and the first account row still visible below the band in the half
    /// sheet; on the iPad the wider area carries a taller band without the motif turning
    /// into a strip.
    static func titleImageHeight(_ width: UserInterfaceSizeClass?) -> CGFloat {
        width == .regular ? 240 : 160
    }

    /// The maximum width body text may run.
    ///
    /// On the iPad, descriptions ran across 992 points with about 120 characters per line;
    /// 60 to 80 read well. **On the phone this cap never applies** — the same construction
    /// as StoryShelf's `readingWidth`.
    static let readingWidth: CGFloat = 720
}
