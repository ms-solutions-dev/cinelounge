import DesignSystemPhone
import SwiftUI

/// How far along one is in a title.
///
/// In gold and **not** in the accent color: on a tile the bar lies over a poster whose color
/// nobody knows. The accent color would vanish there on every second image — gold holds 10.42
/// : 1 against the background and enough against any poster color.
struct ProgressBar: View {

    /// 0 bis 1.
    let portion: Double
    var height: CGFloat = 3

    var body: some View {
        GeometryReader { space in
            ZStack(alignment: .leading) {
                Rectangle().fill(ColorRole.text.color.opacity(0.18))
                Rectangle()
                    .fill(ColorRole.progress.color)
                    .frame(width: space.size.width * min(max(portion, 0), 1))
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
        .accessibilityLabel(Text(appKey: "tile.progress"))
        .accessibilityValue(Text(verbatim: "\(Int(min(max(portion, 0), 1) * 100)) %"))
    }
}
