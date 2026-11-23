import DesignSystemPhone
import SwiftUI

/// A group of rows as a **card** — with a header above.
///
/// **The finding of 2026-09-07:** the prototype draws every group as a card (`.eb-card`:
/// surface, radius 12, 0.5-point light edge). What was built was a bare `VStack` on the
/// background with hairlines — **nine rows over 531 points without a single change of
/// material.** That was the main reason the area felt "rigid". The light edge had long
/// existed as ``DesignSystemPhone/edge()``; it occurred zero times in the whole settings
/// area, and thirteen times in the rest of the project.
///
/// **The header belongs to the card and not between two cards.** A section header that stands
/// freely between two surfaces visibly belongs to neither; here it stands above its own and
/// is thus its heading.
///
/// **Dividers only inside.** Between two cards the spacing separates, and two separators on
/// top of each other are one too many.
struct SettingsCard<Content: View>: View {

    /// Key in the catalog — `nil` for a card without a heading.
    var header: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let header {
                Text(appKey: header)
                    .font(TypeLevel.label.font.weight(.semibold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(ColorRole.textMatt.color)
                    .padding(.horizontal, 4)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            // **The full width and not that of the content (2026-09-07, seen in the simulator).**
            // ``SwipeCommands`` lays the row and its hidden commands side by side — together wider than
            // the screen. Without this line the card grew to that width along and stood out to the right
            // beyond the screen edge; only with it does ``clipShape`` crop the commands at the card
            // edge, and exactly from there they are meant to slide out.
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ColorRole.surface.color)
            .clipShape(RoundedRectangle(cornerRadius: MetricsBoard.phone.cardRadius))
            .edge()
            // **The card tells its rows how far to indent — and not every row for itself.** On 2026-09-07 in
            // `AboutView` a ``ValueRow`` (14) and a ``DisclosureRow`` (20) stood one beneath the other in
            // the same card; their texts started seven points offset. See
            // ``SwiftUI/EnvironmentValues/rowInset``.
            .environment(\.rowInset, Metrics.cardInset)
        }
        .padding(.horizontal, MetricsBoard.phone.margin)
        .padding(.bottom, MetricsBoard.phone.section)
    }
}

/// The framed icon column — **28 × 28 on a raised surface.**
///
/// **The finding of 2026-09-07:** what was built was a bare SF Symbol in `frame(width: 22)`. Nine
/// gray glyphs of very different optical mass in one gray column — `play.fill` next to
/// `dot.radiowaves.left.and.right` — make no column but unrest. A frame evens out the masses,
/// because it is no longer the glyph that gives the shape but the tile.
///
/// **Color only where it is a secondary encoding.** `GESTALTUNG.md` §1 forbids color as the
/// **sole** carrier of information; next to a word and a value it is the third item of
/// information and therefore allowed. That is why exactly the one icon carries a tint whose
/// row reports something missing — and no other.
struct IconTile: View {

    let icon: String
    var tint: Color?

    var body: some View {
        Image(systemName: icon)
            .iconSize(14)
            .foregroundStyle(tint ?? ColorRole.textMatt.color)
            .frame(width: 28, height: 28)
            .background(
                tint?.opacity(0.16) ?? ColorRole.surfaceHigh.color,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .accessibilityHidden(true)
    }
}
