import Foundation
import Network
import Testing

@testable import PortalKit

/// From a Bonjour discovery to an address.
///
/// **What is checked is the computable part, not the network.** Whether a service answers
/// in the home network is something no test suite can say; what becomes of its answer, it
/// can — and that is exactly where the decision sits that could be wrong.
@Suite("The server on the home network")
struct ServerDiscoveryTests {

    /// **Plain text, always.** The server serves `https` for the browser, with a certificate
    /// from mkcert — whose root is not on a TV.
    @Test("From host and port a plain-text address is made")
    func plainText() {
        let endpoint = NWEndpoint.hostPort(host: "cinelounge.local", port: 8100)
        #expect(ServerLookup.address(from: endpoint)?.absoluteString == "http://cinelounge.local:8100")
    }

    @Test("An IPv4 address works just the same")
    func quad() {
        let endpoint = NWEndpoint.hostPort(host: "192.0.2.183", port: 8100)
        #expect(ServerLookup.address(from: endpoint)?.absoluteString == "http://192.0.2.183:8100")
    }

    /// **The number is taken over and not set.** 8100 is what the service announces today,
    /// and no promise — guessing it was exactly the mistake this search was built against.
    @Test("Another port is taken over")
    func otherNumber() {
        let endpoint = NWEndpoint.hostPort(host: "cinelounge.local", port: 9000)
        #expect(ServerLookup.address(from: endpoint)?.absoluteString == "http://cinelounge.local:9000")
    }

    /// A service name is not an address — it has to be resolved first.
    @Test("From an unresolved service nothing is made")
    func unresolved() {
        let service = NWEndpoint.service(
            name: "cinelounge", type: ServerLookup.service, domain: "local.", interface: nil)
        #expect(ServerLookup.address(from: service) == nil)
        #expect(ServerLookup.address(from: nil) == nil)
    }

    /// The service name appears in one place — and in two plists that have to carry it.
    @Test("The service name is the one the server announces")
    func serviceName() {
        #expect(ServerLookup.service == "_cinelounge._tcp")
    }
}
