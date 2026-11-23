import Core
import DesignSystemPhone
import SwiftUI

/// The series color as the tile's edge.
///
/// On the TV it carries the focus ring. Here there is no focus — and instead of leaving
/// the color unused, it carries a one-point border and a glow downward. That is the
/// difference between a shelf of images and a shelf of tiles that belong to their
/// images.
struct EdgeGlow: ViewModifier {

    /// Hue and saturation as computed from the poster.
    let color: (hue: Double, saturation: Double)?
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(edge, lineWidth: 1)
            }
            .shadow(color: glow, radius: 12, y: 6)
    }

    private var palette: AccentPalette? {
        color.map { AccentPalette(hue: $0.hue, saturation: $0.saturation) }
    }

    private var edge: Color {
        guard let palette else { return ColorRole.line.color.opacity(0.5) }
        return Color(palette, .bright).opacity(0.48)
    }

    private var glow: Color {
        guard let palette else { return .clear }
        return Color(palette, .base).opacity(0.55)
    }
}

extension View {
    /// Applies the edge glow around a tile.
    func edgeGlow(_ color: (hue: Double, saturation: Double)?, radius: CGFloat) -> some View {
        modifier(EdgeGlow(color: color, radius: radius))
    }
}
