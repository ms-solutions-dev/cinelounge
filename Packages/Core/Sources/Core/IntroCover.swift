import Foundation
import Observation

/// **When the cards come over the intro** — rule K and rule L of the concept
/// (`design/konzept-AP51-intro.md`, section 3), as one place with state.
///
/// **A cap and not an appointment.** The cap opens on the **first** of three
/// events, and none of them waits for another:
///
/// 1. **The target view can draw** (``reportGlyphReady()``) — in a household with
///    several profiles "Who's watching?" appears in milliseconds, and exactly then the
///    cards come. An intro that waited for `cardsAt` here would extend every start by five
///    seconds, and nobody would report that as a bug.
/// 2. **The deadline has passed** — if loading takes longer, the intro does not wait either. The
///    cards come with their placeholders; a clip that repeats until the data
///    is there would again be a loading spinner, just with popcorn.
/// 3. **Someone skips** (``skip()``) — that ends only the picture. Loading
///    does not hang on the cap, but runs underneath from the start.
///
/// **The clock is passed in** (`sleeper`) and has a default: That way the
/// connection can be tested — cards *earlier* on short loading, *on time* on long —
/// without the test waiting five seconds or depending on the machine's timing.
@MainActor
@Observable
public final class IntroCover {

    /// Why the cap is open.
    public enum Reason: Equatable, Sendable {
        /// The target view could draw before the deadline had passed (rule K).
        case glyphReady
        /// The deadline had passed, loading had not finished yet (rule L).
        case deadline
        /// Select or Menu — only the picture is gone.
        case skipped
    }

    /// `nil` as long as the cap is closed.
    public private(set) var pending: Reason?

    /// The latest time until the cards, from the first picture shown.
    public let deadline: Duration

    @ObservationIgnored private let sleeper: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var following: [() -> Void] = []

    /// - Parameters:
    ///   - frist: See ``IntroCatalog/Clip/cardsDeadline`` and
    ///     ``IntroCatalog/stillFrameDeadline(on:calendar:available:)``.
    ///   - schlafe: Waits the given duration; throws on cancellation.
    public init(deadline: Duration, sleeper: @escaping @Sendable (Duration) async throws -> Void) {
        self.deadline = deadline
        self.sleeper = sleeper
    }

    /// A cap on the ordinary clock — for the view.
    ///
    /// **A separate name instead of a default at construction:** Anyone who builds the cap in a
    /// test should not be able to forget the clock.
    public static func withClock(deadline: Duration) -> IntroCover {
        IntroCover(deadline: deadline) { duration in try await Task.sleep(for: duration) }
    }

    /// Starts the deadline. A second call does nothing.
    public func start() {
        guard watcher == nil, pending == nil else { return }
        let sleeper = self.sleeper
        let deadline = self.deadline
        watcher = Task { [weak self] in
            do {
                try await sleeper(deadline)
            } catch {
                // bewusst still: The deadline ends early only by cancellation, and then
                // the cap is already open.
                return
            }
            self?.open(.deadline)
        }
    }

    /// The target view can draw its first screenful.
    public func reportGlyphReady() { open(.glyphReady) }

    /// Select or Menu: the picture is gone, immediately.
    public func skip() { open(.skipped) }

    /// Calls `action` as soon as the cap opens — **immediately** if it is already open.
    ///
    /// For everything that would appear **over** the intro and thereby cover it: "Who's watching?"
    /// in the multi-profile household (cross-check 2026-09-24).
    public func afterUncovering(_ action: @escaping () -> Void) {
        if pending != nil { action() } else { following.append(action) }
    }

    /// **The first reason stands.** A ready-to-draw signal after the deadline changes nothing
    /// any more — there is nothing left to open.
    private func open(_ reason: Reason) {
        guard pending == nil else { return }
        pending = reason
        watcher?.cancel()
        watcher = nil
        let now = following
        following = []
        for action in now { action() }
    }
}
