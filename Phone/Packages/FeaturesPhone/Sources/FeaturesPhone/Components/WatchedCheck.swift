import DesignSystemPhone
import SwiftUI

/// The checkmark on a watched tile.
///
/// On material and not on a color fill: it lies over a poster, and a colored circle on it
/// eventually meets a poster of the same color.
struct WatchedCheck: View {

    var body: some View {
        Image(systemName: Glyph.done.pair.filled)
            .iconSize(13, weight: .bold)
            .foregroundStyle(ColorRole.success.color)
            .frame(width: 21, height: 21)
            .background(Material.tag, in: Circle())
            .accessibilityLabel(Text(appKey: "tile.watched"))
    }
}
