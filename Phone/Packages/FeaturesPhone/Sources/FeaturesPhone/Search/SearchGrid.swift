import DesignSystemPhone
import SwiftUI

/// How the search hits lie on the iPad — **a grid instead of a list** (AP7,
/// 2026-09-23).
///
/// **The finding from the iPad Pro 13″ (1032 × 1376 points):** a hit there is a 44 × 63
/// point recognition image and a title in a **1032 point wide**
/// row — about **90 percent of every row stays empty**, and the same eleven hits fit
/// into 2.8 times the area of an iPhone.
///
/// **On the phone it nevertheless stays a list, and that is no convenience.**
/// ``ResultRow`` justifies its form with the verb: in the library you browse, in
/// the search you look things up, and when looking things up you read from left to right. The
/// verb has **not** changed on the iPad — the area has changed, and only
/// that. Recalculated for both devices:
///
/// - **393 points (iPhone):** three tiles per row at 110 points, each with a two-line
///   caption about 220 points tall — **six** hits in view instead of eleven. In addition, information is lost
///   per hit: the row carries section, episode count and portal state
///   **side by side**, a tile only 110 points wide carries them stacked or not
///   at all. Fewer hits **and** less per hit — the trade pays off nowhere.
/// - **1032 points (iPad):** six tiles per row at 155 points, four rows in view —
///   **24** hits instead of eleven, and the empty 90 percent is gone.
///
/// The same calculation, two results: that is why the size class decides and not the
/// view. An iPad at half width (Split View, Stage Manager) gets the
/// compact class and thereby the list — correct, it has the area of a phone there.
///
/// **Nothing is lost in the change of form.** ``PosterTile`` draws
/// ``TileContent/beside`` as a second line — exactly the row's side information —, and
/// ``ResultTile`` places the portal state on it as a badge. A grid that
/// concealed the login requirement of a hit would have been the worse trade.
///
/// **The numbers are in ``MetricClass`` and not here.** The column count is the same
/// as in the library's ``TitleGrid``, and it has to be: both draw posters,
/// and two poster widths that round up differently to the cache step would hold the same
/// image twice in memory. Guarded by ``searchTileFallsBackToShelfLevel()``.
struct SearchGrid: Equatable {

    /// How many tiles stand side by side.
    let columns: Int

    /// How wide a tile is — **calculated and not set.**
    ///
    /// The same reasoning as at ``TitleGrid/tileWidth(at:wide:)``: with an
    /// `aspectRatio` in the grid cell the posters would not stand on one line, because
    /// a two-line caption makes the cell taller and the image area follows
    /// it. A grid would become a staircase.
    let cellWidth: CGFloat

    /// The dimensions for a measured width — **`nil` means: the list stays.**
    ///
    /// `nil` is the answer for every class except *regular*, including the still
    /// unknown one: whoever does not know how wide they are draws the narrow version.
    static func forItem(width total: CGFloat, sizeClass: UserInterfaceSizeClass?) -> SearchGrid? {
        guard sizeClass == .regular else { return nil }
        let columns = MetricClass.columns(sizeClass)
        // **Two margins and nothing else.** The library grid additionally subtracts the grab strip
        // of the A–Z bar on the right; the search has no bar, and subtracting
        // it here as a precaution would mean introducing a second tile width and thereby a
        // second image size. It is the same calculation that ``MetricClass``
        // bases its column count on.
        let unrestricted =
            total - 2 * MetricsBoard.phone.margin - CGFloat(columns - 1) * MetricsBoard.phone.gutter
        let width = max(60, (unrestricted / CGFloat(columns)).rounded(.down))
        return SearchGrid(columns: columns, cellWidth: width)
    }

    /// The columns for the ``SwiftUI/LazyVGrid``.
    ///
    /// **`.flexible()` and no fixed width**, although ``cellWidth`` is fixed: the
    /// tile sets its width itself, and fixed columns alongside it would produce a visible offset
    /// between cell and content on a rounding difference.
    var grid: [GridItem] {
        [GridItem](repeating: GridItem(.flexible(), spacing: MetricsBoard.phone.gutter), count: columns)
    }
}

/// A hit as a tile — **with the portal state as a badge on it.**
///
/// **The state may survive the change of form.** ``ResultRow`` puts it before the
/// secondary line, because what stops you from pressing comes before what
/// lies behind the press. A tile has no secondary line for that — so it lies as a badge in the upper
/// **left** corner: the upper right one is taken by ``PosterTile``, where counters,
/// rating or the watched checkmark sit, and two pieces of information in one corner are seen as one.
///
/// **With a plate under the badge.** It lies on the poster and not on the base colour;
/// without a plate, light text would stand over an arbitrarily light image. ``CounterBadge`` and
/// ``RatingBadge`` do the same in the opposite corner, and for the same
/// reason: an image whose brightness nobody knows does not carry bare text.
struct ResultTile: View {

    let match: Match
    let width: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PosterTile(content: match.tile, width: width)
                .overlay(alignment: .topLeading) { tag }
                // **One element and not two.** ``PosterTile`` already combines its children
                // and sets a caption of its own; the badge lies above it and would otherwise be a second stop
                // announcing the same hit a second time.
                .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var tag: some View {
        if let state = match.state, !state.isReady {
            StateBadge(state: state)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(ColorRole.reason.color.opacity(0.82), in: Capsule())
                .padding(5)
        }
    }
}
