import Core
import Foundation

#if canImport(UIKit)
    import UIKit
#endif

/// The player's idle lock — writes only when something changes.
///
/// **As a small type of its own and not as a line in the tick**, so that ``keepsAwake(_:)``
/// can be tested without UIKit and the tick does not write to the system every second.
@MainActor
final class IdleLock {
    private var isHolding = false

    /// Whether the screen should stay awake in this engine state.
    ///
    /// **Pause releases it** — whoever stops and puts the phone away does not want to lose
    /// battery. Loading and buffering keep it awake, otherwise it would go off when switching
    /// channels.
    nonisolated static func keepsAwake(_ status: PlaybackStatus) -> Bool {
        switch status {
        case .playing, .opening, .buffering: true
        case .idle, .paused, .ended, .failed: false
        }
    }

    func hold(_ awake: Bool) {
        guard awake != isHolding else { return }
        isHolding = awake
        #if canImport(UIKit)
            UIApplication.shared.isIdleTimerDisabled = awake
        #endif
    }
}
