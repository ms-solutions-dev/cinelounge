import SwiftUI

/// Button without any design of its own.
///
/// Needed because tvOS puts a light box behind the focused element even with `.plain`.
/// It covers the own focus ring and ruins
/// every tuned colouring. Here the button brings only its
/// content — the highlight comes exclusively from ``FocusHighlight``.
public struct BareButtonStyle: ButtonStyle {

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // Give way briefly when pressed, so that the selection is tangible.
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == BareButtonStyle {
    /// Button without system design — the highlight is taken over by ``FocusHighlight``.
    public static var bare: BareButtonStyle { BareButtonStyle() }
}

extension View {

    /// Uses the own button style and switches off the focus effect of the system.
    ///
    /// Both belong together: the style alone is not enough, because tvOS draws the
    /// light box independently of it.
    public func bareFocusableButton() -> some View {
        buttonStyle(.bare).focusEffectDisabled()
    }
}
