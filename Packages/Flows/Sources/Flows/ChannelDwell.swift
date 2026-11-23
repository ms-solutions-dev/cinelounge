import Foundation

/// A channel enters the history only **once it has run for a while.**
///
/// **The finding (on-device test 2026-09-28):** Every channel switch in the player wrote at once to
/// the ``Flows/ChannelHistory`` — even zapping for two seconds. With ordering
/// by "last watched", such channels then stood at the front of "Continue Watching".
///
/// **One place, one job:** The next switch cancels the previous one; whoever closes the player
/// before the time is up is not remembered (`stillRunning`).
///
/// **In `Flows`, so that the phone has the same rule** (2026-09-28): There only
/// the Live tab wrote to the history, and immediately on tap — a channel from the
/// Home screen, from favourites or search and every switch in the player were missing.
@MainActor
public enum ChannelDwell {

    /// How long a channel must run before it counts as watched.
    static let duration: Duration = .seconds(20)

    private static var running: Task<Void, Never>?

    public static func memorize(_ name: String, stillRunning: @escaping @MainActor () -> Bool) {
        running?.cancel()
        running = Task { @MainActor in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, stillRunning() else { return }
            ChannelHistory().memorize(name)
        }
    }
}
