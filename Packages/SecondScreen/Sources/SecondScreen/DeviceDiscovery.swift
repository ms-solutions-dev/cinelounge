import Diagnose
import Foundation
import Network

/// Which TVs on the home network are waiting for a remote.
///
/// **A service of its own and not the handoff's.** ``HandoffWire/service`` carries
/// a **one-off** process: an encrypted bundle, a receipt, done. The
/// remote holds a connection for hours and speaks a different format.
/// Running both over the same service would mean rebuilding the handoff's tested receiver
/// so that it distinguishes at the first frame what it is about — and thereby touching it at
/// a spot where it is demonstrably correct today.
///
/// **The price is one more entry in both Info files.** That is cheaper than a
/// case distinction in the receiver, which is suspected with every handoff error.
///
/// **Found by name, not by address.** An Apple TV changes its
/// IP when the router restarts; its Bonjour name survives that. Resolution happens only at
/// the moment of connecting.
public enum DeviceDiscovery {

    /// The remote's service type on the home network.
    public static let service = "_cinelounge-fern._tcp"

    /// A found TV.
    ///
    /// **It carries the endpoint and not the address.** `NWEndpoint.service` is exactly
    /// what ``OwnWire`` needs for connecting; turning it into an address
    /// would mean doing the resolution twice — once here and once when connecting.
    public struct Device: Sendable, Equatable, Identifiable {

        /// The name the TV gave itself — "Living Room" or "CineLounge".
        public let name: String
        public let endpoint: NWEndpoint

        public var id: String { name }

        public init(name: String, endpoint: NWEndpoint) {
            self.name = name
            self.endpoint = endpoint
        }
    }

    /// Searches as long as the stream is read.
    ///
    /// **A stream of lists and not of single finds.** A device that disappears
    /// is as much a message as one that appears — reporting only finds would let
    /// the screen offer a TV that no longer exists. Bonjour reports
    /// the whole state anyway.
    ///
    /// **Ended through the stream.** Whoever stops reading it stops searching; a
    /// `halt()` alongside would be a second truth about whether it is still searching.
    public static func search() -> AsyncStream<[Device]> {
        AsyncStream { continuation in
            let browser = NWBrowser(
                for: .bonjour(type: service, domain: nil),
                using: {
                    let parameters = NWParameters.tcp
                    // **Also over a direct connection** — two devices in one room
                    // find each other with it even if the router separates them
                    // (guest network, client isolation). That is exactly the case in which a
                    // remote would otherwise inexplicably not work.
                    parameters.includePeerToPeer = true
                    return parameters
                }())

            browser.browseResultsChangedHandler = { results, _ in
                let found = devices(from: results)
                // **The count into the log** (finding 13) — "found nothing" and "did not
                // search" look the same on screen.
                Diagnose.step(.network, BonjourProtocol.message(discoveries: found.count))
                continuation.yield(found)
            }
            browser.stateUpdateHandler = { state in
                // **Every state into the log** (finding 13) — above all `.waiting` with
                // denied "Local Network", which otherwise went under silently.
                BonjourProtocol.note(BonjourProtocol.message(search: state))
                // **A failed browser reports an empty list and does not stay
                // silent.** Otherwise the screen would say "searching…" until the end of
                // time, and the viewer would wait for something that has already given up.
                if case .failed = state { continuation.yield([]) }
            }
            continuation.onTermination = { _ in browser.cancel() }
            browser.start(queue: .global(qos: .userInitiated))
        }
    }

    /// The conversion of Bonjour results into devices — **without a network and therefore testable.**
    static func devices(from results: Set<NWBrowser.Result>) -> [Device] {
        results.compactMap { result in
            guard case .service(let name, _, _, _) = result.endpoint else { return nil }
            return Device(name: name, endpoint: result.endpoint)
        }
        // **Sorted by name and not in the order of the replies.** Bonjour
        // delivers them in the order the packets arrive; a list that
        // swaps places while you look is a list you cannot hit.
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
