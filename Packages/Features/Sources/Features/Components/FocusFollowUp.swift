import SwiftUI

/// Catches up on side issues once focus **comes to rest** — and not while it
/// is moving.
///
/// **The bug this exists for:** Every tile had
/// `.onChange(of: focus) { Task { … } }` attached for the accent colour, and the library
/// additionally for third-party ratings. An unstructured `Task` is bound to nothing and
/// is **not** cancelled on the next focus step. Anyone who holds the direction button
/// down produces several steps per second — and with them a queue of requests for
/// titles they merely moved past.
///
/// Those share the six connections with the posters. The image the
/// viewer is looking at right now then waits behind twenty requests nobody needs
/// any more. That is exactly "the images arrive late".
///
/// Two changes, both small:
///
/// - **`.task(id:)` instead of `onChange` + `Task`** — SwiftUI cancels the previous task
///   itself on the next value. What is no longer needed stops.
/// - **A short wait in front** — while scrolling through, no request starts at all.
///   Only when focus has rested for a quarter of a second does it count as intended.
/// `Sendable` on the value and on the body: `task(id:)` passes both across the boundary of
/// concurrency, and Swift 6 demands the guarantee for that. For a focus ID
/// — a string — it holds anyway.
struct FocusFollowUp<Value: Equatable & Sendable>: ViewModifier {

    let value: Value
    let action: @MainActor (Value) async -> Void

    /// How long focus has to rest before the catch-up runs.
    ///
    /// 250 ms: shorter than the time it takes to look, and longer than one
    /// step while scrolling through. While scrolling with the button held down, not a
    /// single request is made.
    static var settleTime: Duration { .milliseconds(250) }

    func body(content: Content) -> some View {
        content.task(id: value) {
            try? await Task.sleep(for: Self.settleTime)
            guard !Task.isCancelled else { return }
            await action(value)
        }
    }
}

extension View {
    /// Siehe ``FocusFollowUp``.
    func whenFocusSettles<Value: Equatable & Sendable>(
        on value: Value,
        perform action: @escaping @MainActor (Value) async -> Void
    ) -> some View {
        modifier(FocusFollowUp(value: value, action: action))
    }
}
