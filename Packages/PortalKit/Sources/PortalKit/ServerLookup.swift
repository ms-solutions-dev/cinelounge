import Foundation
import Network

/// Find the CineLounge server on the home network without typing it in.
///
/// **Why this is necessary here, and it is a finding of 2026-09-12:** the console creates its
/// invitation links with the address one is currently operating it through. Whoever opens it via
/// `https://<home-server>` gets `https://<home-server>/?invite=…` — and an app must not make
/// anything of that address: the certificate is from mkcert, and its root is in the home's
/// browser and not in every device. The invitation is valid, the password usable, and the address
/// is missing all the same.
///
/// **So it is asked instead of guessed.** The server registers itself as `_cinelounge._tcp`;
/// re-measured on 2026-09-12 it answers with `cinelounge.local.:8100` and the addition
/// `path=/.well-known/cinelounge api=1 v=1`. That is no assumption about a foreign home network —
/// it is the service's own statement.
///
/// **And it does not contradict the decision "if nothing is entered, nothing should work".**
/// That one is directed against a silent default that simply applies at start. This search runs
/// only when someone redeems an invitation — that is, on an action, and with a result that then
/// stands in the field and can be read.
///
/// **Without an entry in the plist this finds nothing here, and silently so.** `NSBonjourServices`
/// must list `_cinelounge._tcp`; otherwise iOS does not release the service at all. That is the
/// same mistake that cost half a day on 2026-09-10. (AP24).
public enum ServerLookup {

    /// The service under which the server registers itself.
    public static let service = "_cinelounge._tcp"

    /// The first server that reports — `nil` if none answers within the deadline.
    ///
    /// **The first and not a choice.** A household has one server; offering a list would mean asking a
    /// question that has only one answer. If there are ever two, that is a screen of its own and not a
    /// side branch here.
    ///
    /// **With a deadline, because a network does not always answer.** Without it, redeeming would wait
    /// indefinitely for a packet that never comes in a guest network.
    public static func find(deadline: Duration = .seconds(4)) async -> URL? {
        await withTaskGroup(of: URL?.self) { group in
            group.addTask { await firstService() }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    /// Searches and resolves until one is there.
    private static func firstService() async -> URL? {
        for await found in stream() {
            if let address = await resolve(found) { return address }
        }
        return nil
    }

    /// The service names as Bonjour reports them.
    private static func stream() -> AsyncStream<NWEndpoint> {
        AsyncStream { continuation in
            let browser = NWBrowser(
                for: .bonjour(type: service, domain: nil),
                using: {
                    let parameters = NWParameters.tcp
                    // **Also over a direct connection** — the same reasoning as with ``SecondScreen/DeviceDiscovery``: two
                    // devices in one room thereby find each other even when the router separates them.
                    parameters.includePeerToPeer = true
                    return parameters
                }())
            browser.browseResultsChangedHandler = { results, _ in
                for result in results { continuation.yield(result.endpoint) }
            }
            browser.stateUpdateHandler = { state in
                // A failed browser ends the stream instead of staying silent — otherwise the caller waits for its
                // deadline although it has long been clear that nothing is coming.
                if case .failed = state { continuation.finish() }
            }
            continuation.onTermination = { _ in browser.cancel() }
            browser.start(queue: .global(qos: .userInitiated))
        }
    }

    /// An address from a service name.
    ///
    /// **Bonjour reports a name, not an address.** Host and number are in `currentPath.remoteEndpoint`
    /// of an established connection only — that is why a connection is really made here and hung up
    /// immediately. That costs a handshake and spares the assumption that the service listens on 8100.
    private static func resolve(_ endpoint: NWEndpoint) async -> URL? {
        await withCheckedContinuation { continuation in
            let once = OneShotReply(continuation)
            let connection = NWConnection(to: endpoint, using: .tcp)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let address = Self.address(from: connection.currentPath?.remoteEndpoint)
                    connection.cancel()
                    once.respond(address)
                case .failed, .cancelled:
                    once.respond(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    /// An address from host and number — **plain text, as the devices speak.**
    ///
    /// The app never takes `https`: the server does that for the browser, with a certificate whose
    /// root is not on a TV.
    static func address(from endpoint: NWEndpoint?) -> URL? {
        guard case .hostPort(let calculator, let number) = endpoint else { return nil }
        let name: String
        switch calculator {
        case .ipv4(let v4): name = "\(v4)".split(separator: "%").first.map(String.init) ?? "\(v4)"
        case .ipv6(let v6): name = "[\(v6)]".split(separator: "%").first.map(String.init) ?? "[\(v6)]"
        case .name(let word, _): name = word
        @unknown default: return nil
        }
        var split = URLComponents()
        split.scheme = "http"
        split.host = name
        split.port = Int(number.rawValue)
        return split.url
    }
}

/// A continuation that answers only once.
///
/// `NWConnection` reports its state several times, and a `CheckedContinuation` resumed twice
/// crashes the program. The guard sits here and not at the call site, so that it cannot be
/// forgotten.
private final class OneShotReply: @unchecked Sendable {
    private var continuation: CheckedContinuation<URL?, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<URL?, Never>) { self.continuation = continuation }

    func respond(_ address: URL?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: address)
    }
}
