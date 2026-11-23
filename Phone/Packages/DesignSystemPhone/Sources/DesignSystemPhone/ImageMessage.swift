import Synchronization

/// Where the image layer reports what went wrong — **without knowing the error log itself.**
///
/// **Until 2026-09-26 ``ImageLoader`` and ``ImageStore`` called `Diagnose` directly** (AP58,
/// finding A16). That tied the design layer to a package that writes, redacts and sends
/// reports — and a design layer that TV and phone are supposed to share once would drag the
/// phone's error log along onto the TV.
///
/// **The edge is turned around, not cut.** The rule from AP6 still applies: whoever writes a
/// `catch` writes a line into the log. Only this layer no longer knows which log that is —
/// the app target tells it at startup (``derive(on:)``).
///
/// **Without a receiver nothing is lost that was there before**: in checks and previews there
/// was no log with `Diagnose` either, into which anything would have gone.
public enum ImageMessage {

    /// How serious it is — the same three levels the image layer used before.
    public enum Kind: Sendable, Equatable {
        case step, hint, error
    }

    /// What it was about.
    public enum Area: Sendable, Equatable {
        /// An image from the network.
        case network
        /// The store on the device.
        case downloads
    }

    /// A message as it arrives at the receiver.
    ///
    /// **The sentence is finished**, error description included — in the same form that
    /// `Diagnose` built itself before (`Wording: Beschreibung`). The error itself does not travel
    /// along: it is not `Sendable`, and the log read only the description from it anyway.
    public struct UserNotice: Sendable, Equatable {
        public let kind: Kind
        public let area: Area
        public let message: String
    }

    /// **Behind a lock**, because images load from many tasks at once and the app target sets
    /// the receiver on the main thread.
    private static let receiver = Mutex<(@Sendable (UserNotice) -> Void)?>(nil)

    /// Sets where reports go. **Once at startup**, before the first image loads.
    public static func derive(on target: @escaping @Sendable (UserNotice) -> Void) {
        receiver.withLock { $0 = target }
    }

    static func notify(
        _ kind: Kind, _ area: Area, _ message: @autoclosure () -> String,
        _ error: (any Error)? = nil
    ) {
        guard let target = receiver.withLock({ $0 }) else { return }
        let text = error.map { "\(message()): \($0.localizedDescription)" } ?? message()
        target(UserNotice(kind: kind, area: area, message: text))
    }
}
