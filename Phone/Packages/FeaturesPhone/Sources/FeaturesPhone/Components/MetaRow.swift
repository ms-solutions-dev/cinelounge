import DesignSystemPhone
import SwiftUI

/// Year · age rating · genre — and whatever else sits side by side in one line.
///
/// **The separator dots belong between the parts, not on them.** A dot that sticks to
/// the preceding part stays when that part is missing — and then the line starts with a
/// lone separator. Here the parts are filtered first and then joined; a missing year
/// leaves no trace.
///
/// **One line, never two.** With seven genres it would otherwise overflow and push the
/// description down out of the box. What does not fit is truncated — the order makes
/// sure the important part comes first.
struct MetaRow: View {

    let split: [String]
    var color: Color = ColorRole.textMatt.color

    var body: some View {
        let text = split.filter { !$0.isEmpty }.joined(separator: DelimiterChars.point)
        if !text.isEmpty {
            Text(verbatim: text)
                .font(TypeLevel.label.font)
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}
