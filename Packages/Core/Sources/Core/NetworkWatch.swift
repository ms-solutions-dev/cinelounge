import Foundation
import Network

/// Whether this device is on the network at all — **one file and not a package.**
///
/// **Why it exists** (AP25, 2026-09-11). In the whole tree there was not a single
/// `NWPathMonitor`. The consequence was on the screen: a TV without a network cable
/// and a TV with the server switched off looked **the same** — both reported "No
/// answer from the media server. Is it running, and is the TV on the same network?"
/// In the first case one then searches on the wrong device.
///
/// **A third of the phone counterpart, and the rest is not missing.** `NetworkStatus`
/// there carries airplane mode, cellular, "load only on Wi-Fi" and a bandwidth
/// memory. A TV has no airplane mode and no cellular; what remains is the one
/// question that changes something here.
///
/// **The subnet comparison for "at home" is explicitly not included.** It is the
/// part that the schedule names alongside — and on the phone it answers the question
/// "am I at home or on the road via the tunnel?". **A TV does not leave the house.**
/// The comparison would have no caller here, and a built lever without a caller is
/// exactly the finding this package fights against. ``NetworkScan/ownNetwork()``
/// delivers address and mask, in case someone should need it after all.
///
/// **It claims nothing about the server.** "Connected" means: this device has a way
/// into the network. Whether the media server is running is told only by a request
/// to it — and over a tunnel it answers from anywhere. That is why the guard is a
/// **negation**: it may say "that cannot work at all", never "that should work".
public final class NetworkWatch: @unchecked Sendable {

    /// The one guard of this program.
    ///
    /// **One and not one per view.** `NWPathMonitor` holds its own thread; ten of them
    /// would be ten threads for information that is the same for all.
    public static let shared = NetworkWatch()

    private let lock = NSLock()
    private var watcher: NWPathMonitor?
    private var reachable = true

    /// Whether this device has a way into the network.
    ///
    /// **Default `true`, and that is the safe direction.** As long as the guard is not
    /// running or has not yet reported anything, the app should behave as before:
    /// whoever defaulted to `false` here would show "no connection" for a moment at
    /// start over a network that has long been there.
    public var connected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return reachable
    }

    public init() {}

    /// Starts listening. Calling it several times has no consequence.
    public func start() {
        lock.lock()
        guard watcher == nil else {
            lock.unlock()
            return
        }
        let incoming = NWPathMonitor()
        watcher = incoming
        lock.unlock()

        incoming.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let fresh = path.status == .satisfied
            lock.lock()
            let previous = reachable
            reachable = fresh
            lock.unlock()
            // **Every change goes into the log** (on-device test build 1332, finding 11 — on the
            // TV the same as on the phone): a loss is always in the report, the return with
            // verbose recording; with the interfaces, so that a tunnel can be seen.
            guard previous != fresh else { return }
            let message = Self.logLine(
                connected: fresh, interfaces: path.availableInterfaces.map(\.name))
            if fresh {
                Diagnostics.step(message, since: nil, area: "Netz")
            } else {
                Diagnostics.defect(message, since: nil, area: "Netz")
            }
        }
        incoming.start(queue: DispatchQueue(label: "dev.ms-solutions.cinelounge.networkwatch"))
    }

    /// The sentence for a change — **without address**, only interface names (`en0`, `utun3`).
    nonisolated static func logLine(connected: Bool, interfaces: [String]) -> String {
        let list = interfaces.isEmpty ? "none" : interfaces.joined(separator: ", ")
        return (connected ? "Network back" : "Network lost") + " · interfaces: " + list
    }

    /// Stops. **Only for checks** — in the program the guard runs as long as the app runs.
    public func stopListening() {
        lock.lock()
        defer { lock.unlock() }
        watcher?.cancel()
        watcher = nil
    }

    /// Sets the state by hand — **for checks, and only on a guard of one's own.**
    ///
    /// An `NWPathMonitor` cannot be made to lose a network; the rule behind it — what
    /// the app makes of "no network" — should nevertheless be verifiable.
    ///
    /// **Never on ``shared``.** Swift Testing runs checks concurrently; whoever alters
    /// the shared guard alters it for everything running alongside. On 2026-09-11
    /// exactly that knocked over an unrelated playback check, and only in the release
    /// build — different order, different timing. Whoever needs the guard builds one:
    /// `NetworkWatch()` and passes it in.
    public func setForTesting(connected fresh: Bool) {
        lock.lock()
        defer { lock.unlock() }
        reachable = fresh
    }
}
