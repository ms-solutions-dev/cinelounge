import DesignSystemPhone
import SwiftUI

/// The page title.
///
/// **With `minimumScaleFactor(0.8)` and expressly without a fixed height.** At Dynamic Type
/// XXL `largeTitle` grows to 48 points; unchecked, it pushes the search field and chip row
/// out of view — exactly the controls for which one is on the page. A fixed height would be
/// the wrong bolt: it would not bound the title but cut it off.
///
/// **0.8 and not 0.5.** A title allowed to shrink to half is, at large system type, as small
/// again as at small type — the viewer's setting would thereby be ineffective. A fifth of
/// reduction holds the line without canceling the setting.
struct LargeTitle: View {

    /// Key in the catalog.
    var title: String?
    /// Finished wording — for names that the service supplies.
    var wording: String?

    /// Whether it fills the row.
    ///
    /// **Not in the catalog picker.** There the chevron stands directly behind the word and
    /// belongs with it in **one** hit area; a title that extends to the right edge would push it
    /// there — and thus two centimeters away from the word it refers to.
    var isStretching = true

    var body: some View {
        Group {
            if let wording {
                Text(verbatim: wording)
            } else if let title {
                Text(appKey: title)
            }
        }
        .font(TypeLevel.lead.font)
        .minimumScaleFactor(0.8)
        .lineLimit(1)
        .foregroundStyle(ColorRole.text.color)
        .frame(maxWidth: isStretching ? .infinity : nil, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
    }
}
