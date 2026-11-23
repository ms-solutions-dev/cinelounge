import Foundation
import Network

/// Finds Jellyfin servers on the home network.
///
/// Jellyfin listens on a broadcast of its own: whoever sends `who is JellyfinServer?` as
/// a UDP message to everyone gets an answer with address and name from every server on
/// the network. That saves typing an IP address on the on-screen keyboard on the TV — the
/// most common hurdle at first start.
public actor ServerDiscovery {

    public struct Found: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let address: URL

        /// **Public since 2026-09-10**, because a find has since not come only from the broadcast:
        /// ``NetworkScan`` builds the same type, and the phone app's checks create it without
        /// seeing this package from the inside.
        public init(id: String, name: String, address: URL) {
            self.id = id
            self.name = name
            self.address = address
        }
    }

    /// A found server together with the question of whether this device reaches it.
    public struct Reachability: Sendable, Equatable, Identifiable {
        public let found: Found
        public let reachable: Bool

        public var id: String { found.id }

        public init(found: Found, reachable: Bool) {
            self.found = found
            self.reachable = reachable
        }
    }

    /// Checks the found servers before they are up for selection.
    ///
    /// **Why this is necessary** (AP18, 2026-09-02). A server answers the broadcast with **its
    /// own idea** of how it can be reached — and that is not always an address this device
    /// can resolve. On the home server the services are named under a private `*.home`
    /// domain; whoever has given the Apple TV a different name service than the computer gets
    /// offered a name only the computer knows.
    ///
    /// In the list that looked like any other entry until now. Only pressing it led into an
    /// error message — and whoever lands there does not know whether the server is off, the
    /// network is stuck, or the name is not resolved.
    ///
    /// **The entry does not disappear anyway.** A server that answered the broadcast is
    /// there; only the way to it is wrong. Leaving it out would take away the only trace the
    /// viewer has.
    ///
    /// - Parameter probe: How checking is done — from outside, so the check of this rule
    ///   gets by without a network.
    public static func verify(
        _ found: [Found],
        using probe: @Sendable @escaping (URL) async -> Bool
    ) async -> [Reachability] {
        guard !found.isEmpty else { return [] }

        // Side by side and not one after another: with three servers, two of which do not
        // answer, two timeouts would otherwise add up before the list stands.
        return await withTaskGroup(of: (Int, Bool).self) { group in
            for (index, server) in found.enumerated() {
                group.addTask { (index, await probe(server.address)) }
            }
            var answers: [Int: Bool] = [:]
            for await (index, reachable) in group { answers[index] = reachable }
            // **The order of the search stays.** A list that sorts differently depending on response
            // time wanders away from under the viewer's focus.
            return found.enumerated().map {
                Reachability(found: $1, reachable: answers[$0] ?? false)
            }
        }
    }

    /// The port Jellyfin answers search requests on.
    private static let discoveryPort: NWEndpoint.Port = 7359
    private static let probe = "who is JellyfinServer?"

    public init() {}

    /// Asks the network and collects the responses.
    ///
    /// - Parameter timeout: How long to wait. Two seconds suffice on a home network; longer
    ///   feels sluggish at start.
    public func search(timeout: Duration = .seconds(2)) async -> [Found] {
        guard let connection = makeConnection() else { return [] }

        let collector = ResponseCollector()
        connection.start(queue: .global(qos: .userInitiated))

        // Send off the broadcast. Whether it arrives cannot be determined — missing responses
        // simply mean: nothing found.
        connection.send(
            content: Self.probe.data(using: .utf8),
            completion: .idempotent
        )

        let listening = Task {
            while !Task.isCancelled {
                guard let response = await receive(on: connection) else { break }
                await collector.add(response)
            }
        }

        try? await Task.sleep(for: timeout)
        listening.cancel()
        connection.cancel()

        return await collector.results
    }

    private func makeConnection() -> NWConnection? {
        let endpoint = NWEndpoint.hostPort(
            host: .ipv4(.broadcast),
            port: Self.discoveryPort
        )
        let parameters = NWParameters.udp
        // Without this permission the system silently discards the broadcast.
        parameters.allowLocalEndpointReuse = true
        return NWConnection(to: endpoint, using: parameters)
    }

    private func receive(on connection: NWConnection) async -> Found? {
        await withCheckedContinuation { continuation in
            connection.receiveMessage { data, _, _, _ in
                guard let data else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: Self.parse(data))
            }
        }
    }

    /// Evaluates a server's response.
    static func parse(_ data: Data) -> Found? {
        struct Response: Decodable {
            let address: String
            let id: String
            let name: String

            enum CodingKeys: String, CodingKey {
                case address = "Address"
                case id = "Id"
                case name = "Name"
            }
        }

        guard let response = try? JSONDecoder().decode(Response.self, from: data),
            let url = URL(string: response.address)
        else { return nil }

        return Found(id: response.id, name: response.name, address: url)
    }
}

/// Collects the responses. As an actor of its own, because writing happens from the
/// network callback and several servers can answer at the same time.
private actor ResponseCollector {
    private var found: [String: ServerDiscovery.Found] = [:]

    /// Stored by identifier: a server likes to answer a broadcast several times, but should
    /// appear in the list only once.
    func add(_ server: ServerDiscovery.Found) {
        found[server.id] = server
    }

    var results: [ServerDiscovery.Found] {
        found.values.sorted { $0.name < $1.name }
    }
}
