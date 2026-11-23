import DesignSystemPhone
import SwiftUI

/// 44 points round, on material — and with its state in the fill.
///
/// **Why the state belongs in the fill and not in the label:** "Mark as not watched"
/// does not fit in 63 points, and abbreviated ("n. w.") it fits twice as badly. A
/// filled button says "is set", an outlined one "is not" — the same rule as for the
/// active tab and for the same reason: With deuteranopia `rotHell` and `textQuiet`
/// sit at 1.02 : 1, and color alone carries nothing here.
///
/// **The symbol changes too**, outlined versus filled. The shape is the difference
/// you also see without color — and the screen reader receives it as a trait, not as
/// a second name.
struct RoundButton: View {

    let icon: Glyph.Pair
    /// Key in the catalog — it describes the **thing**, not the action.
    let label: String
    var on = false
    /// A small badge at the edge — the trailer's language (AP78). `nil`: none.
    var tag: String?
    let action: () -> Void

    init(
        icon: Glyph.Pair, label: String, on: Bool = false,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.label = label
        self.on = on
        self.action = action
    }

    /// For buttons without a state — sources, trailer, more.
    init(
        icon: String, label: String, tag: String? = nil,
        action: @escaping () -> Void
    ) {
        self.init(
            icon: Glyph.Pair(icon, icon), label: label,
            action: action)
        self.tag = tag
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon.zu(active: on))
                .iconSize(17, weight: .semibold)
                .foregroundStyle(on ? ColorRole.deep.color : ColorRole.text.color)
                .frame(width: Metrics.target, height: Metrics.target)
                .background {
                    if on {
                        Circle().fill(ColorRole.brandLight.color)
                    } else {
                        Circle().fill(ColorRole.surface.color)
                        Circle().strokeBorder(ColorRole.outline.color, lineWidth: 0.5)
                    }
                }
                .contentShape(Circle())
                .overlay(alignment: .bottomTrailing) {
                    if let tag {
                        Text(verbatim: tag)
                            .font(TypeLevel.lowercased.font.weight(.bold))
                            .foregroundStyle(ColorRole.deep.color)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(ColorRole.text.color, in: Capsule())
                            .offset(x: 4, y: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(appKey: label))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}
