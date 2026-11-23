import Diagnose
import Foundation
import NetworkStatus
import Observation

/// Whether the home network is currently reachable **directly** — the second piece of information next to
/// ``NetworkWatch``.
///
/// **Two watches, two different questions**, and that is not uncontrolled growth:
///
/// * ``NetworkWatch`` — *what kind of network is connected?* (Wi-Fi, cellular, none, expensive)
/// * This one — *am I on the same network as my media server?*
///
/// The first does not answer the second, and that was exactly the finding (AP6):
/// ``NetworkWatch`` says "Wi-Fi" also in a foreign house. The sentence has stood since forever in
/// ``NetworkStatus/LocationStatement``: *"A foreign Wi-Fi is also Wi-Fi."* (Until 2026-09-13 a
/// third one stood beside it, the ``Quellenwache`` — "does anyone answer?" —, and it said
/// "answers" even through the tunnel. It is gone; see ``BarState``.)
///
/// **It asks nobody.** The decision is made at the interfaces of this device and
/// the server's address — no fetch, no time consumed, no connection counting against
/// the one permitted account. Only if the address is a **name** is it
/// resolved; `jellyfin.example` does that only on the own network anyway.
///
/// **Without an answer it stays silent.** ``NetworkStatus/LocationStatement/Location/unknown`` is the
/// default value and not `home`: until 2026-09-10. `home` was hard-coded in three places in the
/// source, and whoever was out and about with it read a statement about their network that came from one
/// line of code.
@MainActor
@Observable
public final class LocationMonitor {

    public private(set) var location: LocationStatement.Location = .unknown

    private let state: SetupState
    private let determine: @Sendable (URL?) async -> LocationStatement.Location

    /// - Parameter bestimme: **injectable from outside**, so that the order of two
    ///   answers can be tested; in the program ``NetworkStatus/LocationDetermination``.
    public init(
        state: SetupState = SetupState(),
        determine: @escaping @Sendable (URL?) async -> LocationStatement.Location = {
            await LocationDetermination.location(forItem: $0)
        }
    ) {
        self.state = state
        self.determine = determine
    }

    /// The number of the most recent question — **only its answer counts** (check Shell H11).
    @ObservationIgnored private var runNumber = 0

    /// Looks up where we are.
    ///
    /// **Called on every network change and not on a clock.** A change of place is
    /// an event: you leave the house, the Wi-Fi drops, cellular takes over.
    /// A query every thirty seconds would find out the same and would run
    /// twenty-nine times without cause in the process.
    ///
    /// **An outdated answer is discarded** (check Shell H11, 2026-09-27). Two
    /// network changes in quick succession ask two questions; a name resolution blocks for
    /// different lengths of time, and the older answer may have arrived after the newer one and
    /// overwritten it.
    public func verify() async {
        runNumber &+= 1
        let mine = runNumber
        let fresh = await determine(state.jellyfin?.serverURL)
        guard mine == runNumber, fresh != location else { return }
        Diagnose.step(.network, "Location: \(location.rawValue) → \(fresh.rawValue)")
        location = fresh
    }
}
