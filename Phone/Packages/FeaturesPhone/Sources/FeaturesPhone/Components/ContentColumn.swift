import DesignSystemPhone
import SwiftUI

/// The content of a settings page in a readable column — **AP7, 2026-09-23.**
///
/// **The finding came from the iPad.** A settings row carries the caption on the left and the
/// value right-aligned. On an iPad Pro 13″ that is 1032 points of row width, so "Ratings" and
/// "no key" stood up to **1700 pixels** apart — two pieces of information that belong
/// together at opposite ends of the screen.
///
/// **One building block and not thirteen times two lines.** That many pages lie under
/// `Einstellungen/`, and typing the same change thirteen times is thirteen chances to forget
/// one — the one you forget only shows up on the device. Guarded by
/// ``settingsPagesUseContentColumn()``, so that the fourteenth page gets it too.
///
/// **Capping and centering belong together, and that is not style but a scar.** A cap without
/// a `.frame(maxWidth: .infinity)` next to it leaves the position to the parent, and it pins
/// to the left: the column would then stick to the left edge and look worse than the too-wide
/// list before. **In this app exactly that has already happened twice** — most recently at
/// the ``StateBlock``, where "What are you looking for?" sat at x ≈ 400 instead of 1032.
///
/// **`?? .infinity` instead of a case distinction.** In the compact class
/// ``MetricClass/contentCap(_:)`` returns nothing; "at most infinity" is there the same as
/// no cap, and on the phone literally nothing changes.
struct ContentColumn: ViewModifier {

    /// The size class of the page that applies the building block.
    ///
    /// **Passed in and not read here:** a `ViewModifier` has its own environment, and whoever
    /// applies it already has the class anyway — fetching it twice would mean keeping two sources
    /// for the same question.
    let sizeClass: UserInterfaceSizeClass?

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: MetricClass.contentCap(sizeClass) ?? .infinity)
            .frame(maxWidth: .infinity)
    }
}

extension View {

    /// Puts this content into the column of a settings page — see ``ContentColumn``.
    func contentColumn(_ sizeClass: UserInterfaceSizeClass?) -> some View {
        modifier(ContentColumn(sizeClass: sizeClass))
    }
}
