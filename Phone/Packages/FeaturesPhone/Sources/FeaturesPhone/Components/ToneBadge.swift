import DesignSystemPhone
import Flows
import SwiftUI

/// **The language corner on the phone** (AP84) — the counterpart to the `AudioCapsule` on the TV.
///
/// Dimensions as ``RatingBadge`` (21 pt tall, type "small"), so that the two
/// form a column one beneath the other; set apart by a line instead of a color of its
/// own, exactly as on the TV.
struct ToneBadge: View {

    let badge: PosterCorner.AudioBadge

    var body: some View {
        Text(verbatim: badge.short)
            .font(TypeLevel.lowercased.font.weight(.bold))
            .tracking(0.5)
            .foregroundStyle(ColorRole.text.color)
            .padding(.horizontal, 6)
            .frame(minHeight: 21)
            .background(Material.tag, in: Capsule())
            .overlay(Capsule().strokeBorder(ColorRole.textMatt.color.opacity(0.7), lineWidth: 1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: badge.spoken))
    }
}
