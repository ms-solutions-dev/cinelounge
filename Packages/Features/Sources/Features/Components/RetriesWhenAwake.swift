import SwiftUI

/// Loads again as soon as the app comes back — but only if something went wrong last time.
///
/// **The second part of the answer to "No response. Is the server running?".** The first
/// was to stop reporting an abort as a server outage; that makes the
/// message disappear that should never have appeared. What remains is the case in which it
/// rightly appeared: the TV sleeps for an hour, the network was gone in that time, a
/// request ran into the timeout.
///
/// Then the view stands there with its error message and **waits for nobody**. Its
/// `task` does not run again, because the view never disappeared. That is exactly why
/// only signing out and back in helped: that rebuilds everything. A viewer who has to
/// press a button to clear a fault that is long over takes the app
/// for broken — and is not entirely wrong.
///
/// Deliberately **only after a failure**: a wake-up after which everything was fine
/// should reload nothing. Otherwise every time the TV is switched on costs a full round
/// of requests for content that is already there.
struct RetriesWhenAwake: ViewModifier {

    let isFailed: Bool
    let reload: () async -> Void

    @Environment(\.scenePhase) private var phase

    func body(content: Content) -> some View {
        content.onChange(of: phase) { previous, current in
            // `previous` is part of it: tvOS reports `active` on first appearance too,
            // and there the view already has its `task` running. Without this
            // condition the first load would run twice.
            guard previous != .active, current == .active, isFailed else { return }
            Task { await reload() }
        }
    }
}

extension View {
    /// Siehe ``RetriesWhenAwake``.
    func retriesWhenAwake(isFailed: Bool, reload: @escaping () async -> Void) -> some View {
        modifier(RetriesWhenAwake(isFailed: isFailed, reload: reload))
    }
}
