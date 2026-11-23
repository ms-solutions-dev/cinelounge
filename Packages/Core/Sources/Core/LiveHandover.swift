import Foundation

/// The handoff point for running live remuxers — between preview and
/// playback, and between two previews.
///
/// **Why it exists** (on-device finding 2026-08-16, proven by response status): The
/// provider allows ONE connection, and its panel keeps the slot occupied for seconds after
/// an abort. Anyone who stops the preview session and immediately reconnects
/// for the same or the next channel gets `403` — "A
/// HABER HD" failed exactly that way: The preview was still running, playback ran
/// four times against the panel and ran into the buffer timeout.
///
/// Nothing is stopped here, it is **parked**: The next live consumer picks
/// the session up. If it is the same channel, it keeps playing on the standing session
/// — instant start, no new connection. If it is a different one, the
/// parked session is torn down FIRST and then connected — the slot is thereby
/// at least freed in the right order, instead of in a race.
///
/// If nobody picks it up, the deadline cleans up: A parked session that nobody
/// wants would otherwise be exactly the zombie that steals the slot from the next channel.
@MainActor
public final class LiveHandover {

    public static let shared = LiveHandover()

    /// How long a parked session waits for its taker.
    ///
    /// Two seconds: The path from "preview disappears" to "playback
    /// builds its remuxer" is a view change and takes milliseconds;
    /// anything beyond that means nobody is coming any more.
    public static let ttl: Duration = .seconds(2)

    /// A session ready for pickup: the source it hangs on, its handle and
    /// the local playlist under which it delivers.
    public struct Parked {
        public let source: URL
        public let session: LiveRemuxSession
        public let playlist: URL

        public init(source: URL, session: LiveRemuxSession, playlist: URL) {
            self.source = source
            self.session = session
            self.playlist = playlist
        }
    }

    /// How the deadline is waited out: in operation `Task.sleep`, in checks
    /// a deadline that the test itself lets expire.
    ///
    /// **Why adjustable** (2026-09-26, W1): A check that held a 40 ms deadline
    /// against ten seconds of wall clock failed in the shipping build under
    /// load. The cleaner needs the main actor, and another test held it
    /// longer than the wall-clock limit. The deadline itself was never the
    /// problem, only its measurement.
    public typealias Waiting = @Sendable (Duration) async throws -> Void

    private var parked: Parked?
    private var reaper: Task<Void, Never>?
    private let ttl: Duration
    private let waiting: Waiting

    /// - Parameters:
    ///   - ttl: Adjustable only for checks.
    ///   - warten: Adjustable only for checks; otherwise `Task.sleep`.
    public init(
        ttl: Duration = LiveHandover.ttl,
        waiting: @escaping Waiting = { try await Task.sleep(for: $0) }
    ) {
        self.ttl = ttl
        self.waiting = waiting
    }

    /// Parks a running session for the next taker.
    ///
    /// One that is already parked is torn down in the process — nobody would hold two at the
    /// same time at the provider anyway.
    public func park(_ handover: Parked) {
        abandon()
        parked = handover
        let ttl = ttl
        let waiting = waiting
        reaper = Task { [weak self] in
            try? await waiting(ttl)
            guard !Task.isCancelled else { return }
            self?.abandon()
        }
    }

    /// Picks up the parked session — or clears it away if it belongs to the
    /// wrong channel.
    ///
    /// **In every case the handoff point is empty afterwards.** The taker who
    /// wants a DIFFERENT channel benefits anyway: The foreign session is
    /// now torn down BEFORE it connects — not while doing so.
    public func claim(for source: URL) -> Parked? {
        reaper?.cancel()
        reaper = nil
        guard let held = parked else { return nil }
        parked = nil
        if held.source == source { return held }
        held.session.stop()
        return nil
    }

    /// Tears down the parked session without anyone taking it over.
    public func abandon() {
        reaper?.cancel()
        reaper = nil
        parked?.session.stop()
        parked = nil
    }

    /// Only for checks: Whether something is currently ready.
    public var holdsSomething: Bool { parked != nil }

    /// Only for checks: The cleaner of the currently parked session, so that
    /// a check waits for its end instead of for the wall clock.
    var cleaner: Task<Void, Never>? { reaper }
}
