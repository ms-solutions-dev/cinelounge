import Core
import SwiftUI

/// The focus state as a reusable building block.
///
/// Deliberately bundled in one place: if every view styles its own focus, the
/// scaling and the ring drift apart across the app — and that is immediately
/// noticeable on a large screen.
public struct FocusHighlight: ViewModifier {

    let isFocused: Bool
    let scale: CGFloat
    let accent: Color

    public init(
        isFocused: Bool,
        scale: CGFloat = Tokens.Focus.cardScale,
        accent: Color = ColorRole.tag.color
    ) {
        self.isFocused = isFocused
        self.scale = scale
        self.accent = accent
    }

    public func body(content: Content) -> some View {
        content
            .scaleEffect(isFocused ? scale : 1)
            // **No frame around the image.** It used to sit as an overlay on the
            // poster, and because a poster fills its frame and is cropped in the process,
            // the line sat visibly *inside* the image —
            // it looked like a bug, not like a highlight.
            //
            // Instead, two means that Apple also uses for posters:
            // the element grows, and a more distinct shadow sits beneath it.
            // Neither needs an edge, so neither can slip out of place.
            //
            // On top of that, a soft glow in the accent color — it sits **outside** around the
            // element and does not touch the image.
            // **No shadow at rest.** There used to be one with radius 26 — on
            // *every* card at once. A shadow is a blur, hence a
            // separate drawing pass per element; with fifty tiles on the
            // Home screen that was fifty, none of which showed anything: black at
            // half opacity on a background of `#120A09` is not visible
            // on the TV. In focus it is one, at most two during the cross-fade.
            //
            // The highlight thereby becomes **more distinct**, not weaker: the
            // difference between "no shadow" and "radius 60" is larger than the one
            // between 26 and 60.
            //
            // Deliberately done through the values and not through a conditional modifier: a
            // modifier that comes and goes on a focus change rebuilds the subtree —
            // the same feedback loop that froze the interface in the sidebar. The
            // chain stays the same here, only the numbers change.
            .shadow(
                color: accent.opacity(isFocused ? 0.5 : 0),
                radius: isFocused ? 34 : 0
            )
            .shadow(
                color: .black.opacity(isFocused ? 0.75 : 0),
                radius: isFocused ? Tokens.Focus.shadowRadius : 0,
                y: isFocused ? Tokens.Focus.shadowY : 0
            )
            .animation(Tokens.Focus.animation, value: isFocused)
    }
}

extension View {

    /// Highlights the element when it has focus.
    ///
    /// Without a corner radius: there is no frame anymore that would need one. The
    /// parameter was still here after the frame was removed — a
    /// parameter that does nothing misleads the next reader.
    public func focusHighlight(
        _ isFocused: Bool,
        scale: CGFloat = Tokens.Focus.cardScale,
        accent: Color = ColorRole.tag.color
    ) -> some View {
        modifier(FocusHighlight(isFocused: isFocused, scale: scale, accent: accent))
    }
}

/// Passes the accent color of the series currently shown through the views.
///
/// Through the environment instead of as a parameter: otherwise every intermediate view would have to pass the
/// color along, even if it does nothing with it itself.
extension EnvironmentValues {
    /// The default value sits next to the property, not in a separate type
    /// twenty lines further down (AP15, 2026-09-02: `@Entry` instead of a hand-written
    /// `EnvironmentKey` — the only such place in the project).
    ///
    /// Still **computed and not constant**: a constant would freeze the
    /// brand color of the theme that applied at first access — a switch
    /// would get stuck here. `@Entry` stores the expression as a computed default
    /// and thereby keeps exactly this behavior.
    @Entry public var accentPalette: AccentPalette = .brand
}
