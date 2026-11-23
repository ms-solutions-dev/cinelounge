import Core
import DesignSystemPhone
import SwiftUI

/// A star and a number.
///
/// **The scale lives in the format, not in an abbreviation.** "8.4" is a ten-point scale, "88
/// %" a percentage scale; whoever knows both sees from the symbol which service is meant. An
/// additional "IMDb" in front would cost half the row and tell someone who does not know it
/// just as little. For the screen reader, by contrast, the origin is spelled out — there is
/// room, and there the format is missing as a hint.
///
/// **Gold and not the signal color.** Red carries the counter and the live badge in this app;
/// a second meaning on the same color would make both unreadable.
struct RatingBadge: View {

    let rating: Rating
    var conspicuous = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: Glyph.rating.name)
                .iconSize(conspicuous ? 11 : 9, weight: .semibold)
                .foregroundStyle(ColorRole.progress.color)
            Text(verbatim: rating.text)
                .font(conspicuous ? TypeLevel.label.font : TypeLevel.lowercased.font)
                .foregroundStyle(ColorRole.text.color)
                .monospacedDigit()
        }
        .padding(.horizontal, conspicuous ? 8 : 6)
        .frame(minHeight: conspicuous ? 24 : 21)
        .background(Material.tag, in: Capsule())
        .edge()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(
                AppLanguageSetting.text(.init(rating.originKey))
                    + " " + rating.text))
    }
}
