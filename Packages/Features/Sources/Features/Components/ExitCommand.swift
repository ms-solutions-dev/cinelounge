import SwiftUI

/// The Menu button, but only when there is something to do.
///
/// **The reason for the condition is a trap that has snapped shut twice.**
/// `onExitCommand` consumes the button as soon as it is attached — even when
/// the body does nothing. An empty handler is therefore not a no-op but a
/// dead end: during playback the button no longer ended the film, and in the
/// sidebar there was no way out of the app any more. Both without an error message,
/// because a button that triggers nothing looks like a broken button.
///
/// That is why the modifier is **left out** when there is nothing to intercept, instead of
/// having a body that does nothing. The button then passes through and does what
/// tvOS intends for it.
private struct ExitCommand: ViewModifier {

    let isActive: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if isActive {
            content.onExitCommand(perform: action)
        } else {
            content
        }
    }
}

extension View {

    /// Intercepts the Menu button as long as ``isActive`` holds.
    ///
    /// The reasoning for the condition lives on the type — it belongs to the call site and
    /// not merely to the implementation: anyone who pins `isActive` to `true` takes away the
    /// view's way back.
    func exitCommand(isActive: Bool, action: @escaping () -> Void) -> some View {
        modifier(ExitCommand(isActive: isActive, action: action))
    }
}
