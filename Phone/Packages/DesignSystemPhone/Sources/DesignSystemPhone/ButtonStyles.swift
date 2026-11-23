import SwiftUI

/// The loud button — Play, Continue, Resume.
///
/// Fifty points tall and therefore above the target size on its own. The pressed state lives
/// in the opacity, not in the size: a button that shrinks when pressed moves out from under
/// the finger.
public struct LoudButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TypeLevel.header.font)
            .foregroundStyle(ColorRole.text.color)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(
                ColorRole.tag.color, in: RoundedRectangle(cornerRadius: MetricsBoard.phone.fieldRadius)
            )
            .edge()
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

/// The quiet button — the second option next to the loud one.
///
/// Material instead of color, with the outline from ``ColorBoard/outline``: WCAG 1.4.11
/// requires 3 : 1 for the border of a control, and it is the border that is raised, not the
/// fill.
public struct QuietButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TypeLevel.header.font)
            .foregroundStyle(ColorRole.text.color)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(
                Material.chromeBar, in: RoundedRectangle(cornerRadius: MetricsBoard.phone.fieldRadius)
            )
            .overlay {
                RoundedRectangle(cornerRadius: MetricsBoard.phone.fieldRadius)
                    .strokeBorder(ColorRole.outline.color, lineWidth: 0.5)
            }
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

/// The round button on an image — Back, Sources, More.
///
/// Forty-four points in diameter. The icon inside stays small; the area is the target, not
/// the drawing.
public struct RoundButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TypeLevel.header.font)
            .foregroundStyle(ColorRole.text.color)
            .frame(width: Metrics.target, height: Metrics.target)
            .background(Material.chromeBar, in: Circle())
            .edge()
            .contentShape(Circle())
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

/// A chip in a filter row.
///
/// The active chip is **filled**, not merely a different color — the same rule as for the
/// active tab, and for the same reason.
public struct ChipButtonStyle: ButtonStyle {
    private let active: Bool

    public init(active: Bool) { self.active = active }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TypeLevel.footer.font.weight(.semibold))
            .foregroundStyle(active ? ColorRole.text.color : ColorRole.textMatt.color)
            .padding(.horizontal, Metrics.cardInset)
            .frame(minHeight: Metrics.target)
            .background(
                active ? AnyShapeStyle(ColorRole.tag.color) : AnyShapeStyle(ColorRole.surface.color),
                in: Capsule()
            )
            .overlay {
                Capsule().strokeBorder(active ? ColorRole.tag.color : ColorRole.outline.color, lineWidth: 0.5)
            }
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

extension ButtonStyle where Self == LoudButtonStyle {
    public static var loud: LoudButtonStyle { LoudButtonStyle() }
}

extension ButtonStyle where Self == QuietButtonStyle {
    public static var quiet: QuietButtonStyle { QuietButtonStyle() }
}

extension ButtonStyle where Self == RoundButtonStyle {
    public static var rounded: RoundButtonStyle { RoundButtonStyle() }
}

extension ButtonStyle where Self == ChipButtonStyle {
    public static func chip(active: Bool) -> ChipButtonStyle { ChipButtonStyle(active: active) }
}
