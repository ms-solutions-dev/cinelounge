import Foundation

/// **The clock under a one-time code: ticks every second and reports when it has expired**
/// (AP58 R5, finding Z1, 2026-09-26).
///
/// A QR code that stays on a TV while nobody is in the room no longer proves proximity —
/// it is a note on the door. Every ``HandoffKey`` therefore applies for three
/// minutes, and when they are up, the screen puts up a **new** one instead of
/// leaving an expired one standing. **Until 2026-09-26 this loop existed twice on the TV** — in
/// the handoff and in the pairing of the remote —, and only one of the two asked beforehand
/// whether the screen was still waiting at all.
///
/// **Once per second**: finer would be a motion nobody reads, coarser would leave the
/// number standing still while it changes.
@MainActor
public final class CodeClock {

    /// The running tick — **so that a check can wait for it** instead of guessing when it is
    /// done.
    public private(set) var run: Task<Void, Never>?

    private let sleep: @Sendable (Duration) async -> Void
    private let clock: @Sendable () -> Date

    /// - Parameters:
    ///   - schlafen: The wait as a dependency — a check that sleeps three minutes never runs.
    ///   - uhr: What time it is. In operation the system clock.
    public init(
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sleep = sleep
        self.clock = clock
    }

    /// Counts for one code — **a new call stops the previous one.**
    ///
    /// - Parameters:
    ///   - solange: Whether the screen is still waiting for this code. If it is done or
    ///     has failed, the clock stops quietly instead of putting up a new code nobody needs.
    ///   - tick: The remaining time in seconds, once per tick.
    ///   - abgelaufen: Once, when the code no longer applies — **start over and not
    ///     "expired"**: A TV that shows an error message after three minutes
    ///     demands a key press for something nobody did wrong.
    public func run(
        forItem key: HandoffKey,
        whileTrue: @escaping @MainActor () -> Bool = { true },
        tick: @escaping @MainActor (TimeInterval) -> Void,
        expired: @escaping @MainActor () -> Void
    ) {
        hold()
        let sleep = sleep
        let clock = clock
        run = Task {
            while !Task.isCancelled {
                await sleep(.seconds(1))
                guard !Task.isCancelled, whileTrue() else { return }
                let now = clock()
                tick(key.remainingTime(um: now))
                guard key.applies(um: now) else {
                    expired()
                    return
                }
            }
        }
    }

    /// Stops the clock — when leaving the screen and before every new code.
    public func hold() {
        run?.cancel()
        run = nil
    }
}
