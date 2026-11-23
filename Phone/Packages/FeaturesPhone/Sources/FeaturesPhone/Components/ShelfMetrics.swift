import CoreGraphics
import DesignSystemPhone
import SwiftUI

/// How wide a tile is in the **horizontal shelf**.
///
/// **The finding (AP4): The width was hard-coded as a number.** `MetricsBoard.phone.poster`
/// is `110 × 165` — computed for 393 points, so for exactly one device. On every other
/// one, nothing matched afterwards, and invisibly so: On the iPhone 16 Pro (402 points)
/// a **16-point sliver** of the fourth poster remained, on a Pro Max (440 points) half
/// of it. That does not look intentional but like a drawing error — and it is not one
/// either: It is the remainder of a division nobody computed.
///
/// **The peek stays, but as a decision.** A shelf without any peek looks as if it
/// were finished; three tiles that fit exactly between the two edges hide that there
/// is more to the right. That is why this file calculates with a peek of
/// **``Styling/MetricsBoard/margin``** — the same twenty points that also sit on the left.
/// That is the number already in the picture, and so the peek reads as a margin and
/// not as a cut-off fourth column.
///
/// ```
/// rand │ Kachel │ spalt │ Kachel │ spalt │ Kachel │ spalt │ Ausblick
///  20  │   w    │  12   │   w    │  12   │   w    │  12   │    20
/// ```
///
/// **Why not in ``Metrics``:** Measures live there, here lives a calculation over the
/// image width — and only whoever is drawing right now knows it. The same separation
/// as with ``TitleGrid/tileWidth(at:wide:)``, with which this file deliberately
/// shares its construction: Measurement happens once at the scroll area, not per shelf.
enum ShelfMetrics {

    /// How many whole tiles should sit side by side.
    ///
    /// **The same numbers as in the grid** (``TitleGrid/columnCount``): Whoever switches
    /// from the library to Home finds the same title at the same size. Two measures for the
    /// same tile would be two image sizes in the store.
    static func visible(_ sizeClass: UserInterfaceSizeClass?) -> Int {
        MetricClass.columns(sizeClass)
    }

    static func visibleWide(_ sizeClass: UserInterfaceSizeClass?) -> Int {
        MetricClass.wideColumns(sizeClass)
    }

    /// The peek at the next tile — **the width of the margin.**
    static var peek: CGFloat { MetricsBoard.phone.margin }

    /// The width of a poster tile (2 : 3) in the shelf.
    ///
    /// - Parameter gesamt: the measured width of the scroll area.
    /// - Parameter breit: whether the layer draws 16 : 9 — then two instead of three.
    static func tileWidth(
        at total: CGFloat, wide: Bool = false, sizeClass: UserInterfaceSizeClass?
    ) -> CGFloat {
        let columns = CGFloat(wide ? visibleWide(sizeClass) : visible(sizeClass))
        let unrestricted = total - MetricsBoard.phone.margin - peek - columns * MetricsBoard.phone.gutter
        // **The lower bound is no ornament.** On a very narrow screen — or in a preview
        // without a measured width — a tile of zero or negative width would otherwise come
        // out, and SwiftUI draws nothing from it without complaining. The same limit as in
        // the grid.
        return max(60, (unrestricted / columns).rounded(.down))
    }

    /// The height that belongs to this width — **from the aspect ratio and not from a
    /// second number.**
    ///
    /// Two independent constants for width and height are two chances to lose the ratio;
    /// here there is only one.
    static func tileHeight(zu width: CGFloat, wide: Bool = false) -> CGFloat {
        let metrics = wide ? MetricsBoard.phone.episode : MetricsBoard.phone.poster
        return (width * metrics.height / metrics.width).rounded()
    }
}
