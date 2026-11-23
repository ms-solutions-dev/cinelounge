import CoreGraphics

/// The shared dimension roles — **names shared, values per device.**
///
/// **The values cannot be converted** and therefore stand separately: The TV
/// calculates with 1920 × 1080 points at three metres, the phone with 393 × 852 at thirty
/// centimetres. A poster is 240 points wide there and 110 here. **What is shared are the
/// roles**: Until 2026-09-26 they were called `cardRadius`/`rowGap` on the TV, on the phone
/// `eckradiusKarte`/`gutter`, and the phone had separated the image corner from the
/// card corner since AP4, the TV had not (report B finding 18).
///
/// What only one device knows (focus, thumb limit, tab bar, title logo) stays in its
/// platform layer.
public struct MetricsBoard: Sendable, Equatable {

    // MARK: Radii

    /// Every surface in which an image lies — poster, episode image, cast photo.
    public let imageRadius: CGFloat
    /// Cards and boards without an image.
    public let cardRadius: CGFloat
    /// Outlined surfaces in which something stands or is entered — fields, tiles of
    /// Settings. On the phone `eckradiusKachel`, on the TV `tileRadius`.
    public let fieldRadius: CGFloat
    /// Sheets that open from below or over the content.
    public let sheetRadius: CGFloat

    // MARK: Spacing

    /// Distance to the edge of the screen. On the TV the safe zone, outside of which some
    /// devices crop.
    public let margin: CGFloat
    /// Between two cards of a row.
    public let gutter: CGFloat
    /// Zwischen zwei Regalen.
    public let section: CGFloat

    // MARK: Tiles

    /// 2 : 3.
    public let poster: CGSize
    /// 16 : 9.
    public let episode: CGSize
    /// Durchmesser eines Personenkreises.
    public let person: CGFloat

    public init(
        imageRadius: CGFloat, cardRadius: CGFloat, fieldRadius: CGFloat, sheetRadius: CGFloat,
        margin: CGFloat, gutter: CGFloat, section: CGFloat,
        poster: CGSize, episode: CGSize, person: CGFloat
    ) {
        self.imageRadius = imageRadius
        self.cardRadius = cardRadius
        self.fieldRadius = fieldRadius
        self.sheetRadius = sheetRadius
        self.margin = margin
        self.gutter = gutter
        self.section = section
        self.poster = poster
        self.episode = episode
        self.person = person
    }

    /// The dimensions of a device.
    public static func forItem(_ platform: UIPlatform) -> MetricsBoard {
        switch platform {
        case .tv: tv
        case .phone: phone
        }
    }

    /// 1920 × 1080 points at three metres. Image and card share the corner (12) here — the
    /// TV never separated them, and keeping them separate does not mean changing them.
    public static let tv = MetricsBoard(
        imageRadius: 12, cardRadius: 12, fieldRadius: 16, sheetRadius: 28,
        margin: 80, gutter: 40, section: 56,
        poster: CGSize(width: 240, height: 360), episode: CGSize(width: 420, height: 236),
        person: 168)

    /// 393 × 852 points at thirty centimetres, from `GESTALTUNG.md` §3.
    public static let phone = MetricsBoard(
        imageRadius: 10, cardRadius: 10, fieldRadius: 14, sheetRadius: 20,
        margin: 20, gutter: 12, section: 20,
        poster: CGSize(width: 110, height: 165), episode: CGSize(width: 200, height: 112),
        person: 64)
}
