import DesignSystemPhone
import SwiftUI

/// The number on a tile.
///
/// **Numbers always carry their unit.** "71 unwatched", not "71" — a bare number on
/// a tile is a question and not an answer. The text therefore arrives ready-made
/// and is not assembled here.
struct CounterBadge: View {

    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(TypeLevel.lowercased.font)
            .foregroundStyle(ColorRole.text.color)
            .padding(.horizontal, 6)
            .frame(minWidth: 21, minHeight: 21)
            .background(ColorRole.tag.color, in: Capsule())
            .edge()
    }
}
