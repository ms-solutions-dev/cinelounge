import Core
import DesignSystem
import SwiftUI

/// Watched checkmark and favourite heart in the top corner of a tile.
///
/// **Without the marks the long-press menu would be mute:** anyone who sets "watched"
/// from the grid has to see the effect where they pressed —
/// not only on the detail page. Colour **and** symbol, never colour alone:
/// checkmark and heart differ even with red-green colour blindness and under the
/// TV's picture enhancement. The dark backdrop behind keeps both legible on
/// bright images.
///
/// One building block for poster **and** episode tiles: on the episode lists
/// the checkmark was missing at first — anyone halfway through a season saw no
/// difference there between watched and open.
struct StatusBadges: View {

    let item: MediaItem

    var body: some View {
        if item.isWatched || item.isFavorite {
            HStack(spacing: 8) {
                if item.isWatched {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(ColorRole.success.color)
                }
                if item.isFavorite {
                    Image(systemName: Glyph.favorite.pair.filled)
                        .foregroundStyle(ColorRole.live.color)
                }
            }
            // festeschrift: a stack of icons (watched, favourite), no text.
            .font(.system(size: 30, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(ColorRole.reason.color.opacity(0.65), in: Capsule())
            .padding(10)
        }
    }
}
