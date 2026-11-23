import DesignSystemPhone
import SwiftUI

/// When there is no logo: set in three lines, in the fixed title area.
///
/// **Fixed area, so that the page below does not jump.** Only about one title in twenty has a
/// drawn wordmark; the replacement is set text and at three lines becomes 109 points tall
/// instead of 40 to 68. Without a fixed height everything below would shift as soon as you
/// page through a shelf — and in the header area of Home you do page.
///
/// **It shrinks instead of wrapping — up to a limit.** `minimumScaleFactor` alone turned a
/// long title into an unreadable line; three lines at 80 percent size carry "The Skeitbuwol cofrel klonjaska
/// Skeigria: The Stodourn of the Ring" without either.
struct PlaceholderTitle: View {

    let title: String
    /// The fixed height — **only where something below has to stay put.**
    ///
    /// In the header area of Home one pages, and without a fixed height the attribute line would
    /// slide by one line with every title. On the detail page nobody pages; there a fixed height
    /// would be a gap beneath short titles.
    var height: CGFloat?

    var body: some View {
        Text(verbatim: title)
            .font(TypeLevel.lead.font)
            .minimumScaleFactor(0.8)
            .lineLimit(3)
            .foregroundStyle(ColorRole.text.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height, alignment: height == nil ? .leading : .bottomLeading)
    }
}
