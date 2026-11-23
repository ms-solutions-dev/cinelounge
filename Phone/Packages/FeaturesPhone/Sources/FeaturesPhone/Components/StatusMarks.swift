import Core
import DesignSystemPhone
import SwiftUI

/// **Top left: watched and favorite** — the same corner as on the TV (2026-09-29).
///
/// The owner has fixed the poster corners for both devices: top right one piece of
/// information (open episodes, otherwise the rating), top left a capsule with checkmark
/// and heart, depending on what applies. Until then the checkmark stood on the right
/// on the phone — and only when there was no rating —, and a favorite could not be
/// seen on the poster at all.
struct StatusMarks: View {

    let seen: Bool
    let favorite: Bool

    var body: some View {
        if seen || favorite {
            HStack(spacing: 3) {
                if seen {
                    Image(systemName: Glyph.done.pair.filled)
                        .iconSize(11, weight: .bold)
                        .foregroundStyle(ColorRole.success.color)
                        .accessibilityLabel(Text(appKey: "tile.watched"))
                }
                if favorite {
                    Image(systemName: Glyph.favorite.pair.filled)
                        .iconSize(11, weight: .bold)
                        .foregroundStyle(ColorRole.live.color)
                }
            }
            .padding(.horizontal, 5)
            .frame(minWidth: 21, minHeight: 21)
            .background(Material.tag, in: Capsule())
        }
    }
}
