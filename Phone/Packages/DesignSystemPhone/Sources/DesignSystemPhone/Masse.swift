import CoreGraphics
import Styling

/// All dimensions in points on 393 × 852 — the screen of an iPhone 15/16.
///
/// This is the one file that holds the thirty-centimeter assumption. Its counterpart on the
/// TV works with 1920 × 1080 at three meters; the numbers are therefore **not** convertible
/// into each other but set separately. A poster is 240 points wide there and 110 here.
///
/// All values come from `entwuerfe/GESTALTUNG.md` §3.
///
/// - Important: **Since AP58 (2026-09-26)** the roles both devices know (margin, gap,
///   section, radii, tiles) live in ``Styling/MetricsBoard/phone``. What remains here is only
///   what the phone alone knows (bars, thumb limit, targets, insets).
public enum Metrics {

    // MARK: - Spacing

    /// Between two rows of **one** grid.
    ///
    /// **Not ``Styling/MetricsBoard/section``**, although it happens to look similar: the gap
    /// between two shelves separates two topics, the one between two grid rows separates nothing
    /// — it only keeps the caption of one row clear of the tile of the next.
    public static let rowGap: CGFloat = 16

    // MARK: - Tiles

    /// The width at which a background image for the header area is fetched.
    ///
    /// Sized for the widest device and not the current one: the box is as wide as the screen
    /// between the margins, and on an iPhone 16 Pro Max that is 400 points. An image fetched at
    /// 353 and stretched to fit there would be visible; the rounding in ``ImageSizes`` puts
    /// both on the same step anyway.
    public static let headerBox: CGFloat = 400

    /// The height at which a title logo is **drawn**.
    ///
    /// Logos come in every aspect ratio. They are therefore drawn to the same **height** — a wide
    /// wordmark is then narrow and light, a square emblem tall and heavy, and that is as it
    /// should be.
    ///
    /// **Requests, by contrast, are made by width** (finding of 2026-09-05). Jellyfin's `maxWidth`
    /// caps the width; with this number a wordmark came from the server 180 pixels wide and was
    /// drawn up to 900. The request therefore goes through ``headerBox``, and this number now
    /// applies only to the drawing height.
    public static let titleLettering: CGFloat = 60

    // MARK: - Rows

    /// Logo 44, 14 above and below, two lines of text.
    ///
    /// One of the few fixed heights: here a line bounds a tile, and `GESTALTUNG.md` §2 explicitly
    /// allows that.
    public static let channelRow: CGFloat = 72

    /// A channel row **without a program** — 44-point logo, 8 above and below.
    ///
    /// **Twelve points less, and they add up.** 7,126 of the 7,746 channels carry no program;
    /// their row has one piece of information less to carry. The hit area stays at 44 — what is
    /// saved is white space, not target.
    public static let channelRowNarrow: CGFloat = 60

    /// A row in the sheet — checkmark, icon, name, number.
    ///
    /// Fixed because it bounds a tile; 59 is above the target size of 44 on its own. At larger
    /// type it grows beyond `minHeight` instead of clipping the text.
    public static let choiceRow: CGFloat = 59

    /// The inset **inside** a card — measured from the card edge.
    ///
    /// **Six points less than ``Styling/MetricsBoard/margin``, and that is not a contradiction.**
    /// The card itself already sits 20 points from the screen edge; together that is 34, and
    /// another 20 would be 40 — a text block that becomes noticeably narrower at 393 points of
    /// width. It is set via ``SwiftUI/EnvironmentValues/rowInset`` and not in the rows.
    public static let cardInset: CGFloat = 14

    /// The horizontal inner padding of a **pill** — chip, search field, location row, chapter
    /// row, sort row.
    ///
    /// **Recounted on 2026-09-10. (AP4): six places, the same twelve six times, typed in six times.**
    /// That is the kind of number where one change hits five places and leaves the sixth standing
    /// — and nobody sees it, because two points of difference on a pill only show in comparison.
    ///
    /// **Not ``Styling/MetricsBoard/gutter``, although both are twelve.**
    /// ``Styling/MetricsBoard/gutter`` is the distance *between* two things, this is the space
    /// *in* one. Whoever merges them changes a grid spacing next time and shifts the caption of
    /// every chip along with it.
    public static let pillInset: CGFloat = 12

    // MARK: - Bars

    /// Standard height of the tab bar without the home-button zone.
    public static let tabBar: CGFloat = 49
    /// The zone below the tab bar where the home indicator sits.
    public static let homeIndicatorZone: CGFloat = 34
    /// 13 + Knopf 50 + 15.
    public static let floatingBar: CGFloat = 78
    /// Where the floating bar sits above the bottom edge.
    public static let floatingBarBottom: CGFloat = 83

    /// How far a floating button sits above a floating bar.
    ///
    /// **Measured from the safe area**, like the floating bar itself: it ends
    /// ``floatingBarBottom`` above it, and ``Styling/MetricsBoard/margin`` on top of that is the
    /// same distance a button without a bar keeps from the tab bar. Whoever takes
    /// ``bottomInsetWithBar`` instead counts the tab bar a second time — see
    /// ``ScrollSurface/bottomClearance``.
    public static let aboveFloatingBar: CGFloat = floatingBarBottom + MetricsBoard.phone.margin

    /// Inset at the bottom end of every scrolling list.
    ///
    /// Without it the last row disappears behind the tab bar — and nobody misses it, because it
    /// was never visible.
    public static let bottomInset: CGFloat = 83
    /// The same inset where a floating bar is present as well.
    public static let bottomInsetWithBar: CGFloat = 161

    // MARK: - Targets

    /// The smallest hit area.
    ///
    /// **Decoupled from the visuals.** An icon may stay 21 points and still be 44 × 44 hittable.
    /// Enlarging a target never means enlarging its icon — see ``SwiftUICore/View/target()``.
    public static let target: CGFloat = 44
    /// Mindestabstand zwischen zwei getrennten Zielen.
    public static let targetSpacing: CGFloat = 8

    // MARK: - Sheets

    /// Fraction of the image height for the sources sheet.
    ///
    /// A **fraction**, not a number: a fixed 536 points would, at Dynamic Type XXL, not bound a
    /// tile but the whole screen.
    public static let sheetHalf: CGFloat = 0.63
    /// Fraction for the smaller sheet of the source picker.
    public static let sheetSmall: CGFloat = 0.45

    // MARK: - Special

    /// Fixed height of the title area on the Home and detail screens.
    ///
    /// Only about one title in twenty has a drawn wordmark; the replacement is set text and at
    /// three lines becomes 109 points tall instead of 40 to 68. Without a fixed height everything
    /// below would shift as soon as you page through a shelf.
    public static let titleArea: CGFloat = 140

    /// From here the thumb reaches.
    ///
    /// Everything that is pressed often lies below it — without exception. That includes
    /// selection menus: a menu that opens from the large title lies between y = 152 and 480 and
    /// thus entirely above it.
    public static let thumbReachLimit: CGFloat = 560
}
