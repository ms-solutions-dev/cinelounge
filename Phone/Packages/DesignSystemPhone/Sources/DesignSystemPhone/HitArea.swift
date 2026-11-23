import SwiftUI

extension View {

    /// Makes the area 44 × 44 without enlarging the icon.
    ///
    /// The most serious finding of the usability review lay here: in the player "Back" was 22 ×
    /// 22, CC, AirPlay and More 21 × 21 each, the scrubber handle of the timeline 12 × 12 — and
    /// after three seconds the player hides everything. Seventeen places were below the
    /// threshold.
    ///
    /// **The touchable area is not the visible size.** `contentShape` is the part that one
    /// forgets: without it only what is drawn is touchable, and the frame remains air.
    public func target() -> some View {
        frame(minWidth: Metrics.target, minHeight: Metrics.target)
            .contentShape(Rectangle())
    }

    /// Enlarges the hit area of a text in the middle of a line without shifting the line break.
    ///
    /// The padding is canceled again by an equally large negative margin: the area grows, the
    /// picture stays.
    public func textHitTarget(horizontal: CGFloat = 10, vertical: CGFloat = 12) -> some View {
        padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .contentShape(Rectangle())
            .padding(.horizontal, -horizontal)
            .padding(.vertical, -vertical)
    }
}
