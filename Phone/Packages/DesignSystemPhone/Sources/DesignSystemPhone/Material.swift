import SwiftUI

/// Bars, sheets and badges are **material**, not a semi-transparent color box.
///
/// The difference is visible and intended: material takes on the background, brightens it and
/// raises the saturation — only that makes it recognizable that something *continues* under
/// the bar. That is why the design also puts content under every bar.
public enum Material {

    /// Reiterleiste, Schwebeleiste, halbhohes Blatt.
    public static let chromeBar: SwiftUI.Material = .ultraThinMaterial

    /// Badges that sit on an image — `1080p`, `DE·JA`, FSK.
    ///
    /// Denser than the bar, and that from a measurement: over the brightest poster color of the
    /// design, the matte lettering at the original opacity achieved only 4.26 : 1. A poster is an
    /// unknown background, and the only remedy is less transparency.
    public static let tag: SwiftUI.Material = .thinMaterial
}

extension View {

    /// The light edge: half a point of popcorn cream at 8 percent, on top.
    ///
    /// Nothing at the bottom — an edge on both sides looks like a box and not like a surface
    /// lying in front of something.
    ///
    /// **Popcorn cream and not white** (AP5, 2026-09-10). The sentence above had always stood there;
    /// what was drawn was `Color.white`. `GESTALTUNG.md` §6.3 explicitly requires `#F7EBD6` at 8
    /// % — that is ``Styling/ColorRole/text`` —, and this is not hair-splitting: white is the
    /// one color that appears in **none** of the three color boards. Under "Contrast" the edge
    /// thereby glowed colder than any text next to it, and under "Midnight" it stayed put
    /// while the rest of the app switched boards.
    ///
    /// **The same lesson as with ``StripeBand`` (E41):** colors come from the board and not
    /// from a design draft, otherwise the app has a second cream color that stays behind on a
    /// switch.
    public func edge() -> some View {
        overlay(alignment: .top) {
            Rectangle()
                .fill(ColorRole.text.color.opacity(0.08))
                .frame(height: 0.5)
        }
    }
}
