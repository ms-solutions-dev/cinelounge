import Testing

@testable import NetworkStatus

/// Whether the home network is directly reachable.
///
/// **What can be tested here and what cannot.** Querying this machine's network interfaces
/// tests the machine and not the rule — and a check run that gives a different result in a
/// different place is not a check run. What is tested is therefore the **decision** over
/// given networks, and it carries the whole finding: The question is not whether the server
/// answers but whether it lies in the own network.
///
/// **Measured against the real network on 2026-09-10**, with the WireGuard tunnel running: The
/// machine was on a `/24` home subnet address, the media server in the same subnet, and
/// `utun5` was up. The rule said "at home" — because of the subnet and not because the
/// server answers.
@Suite("Location determination")
struct LocationDeterminationTests {

    private let homeNetwork = LocationDetermination.Network(
        address: 0xC000_0221, mask: 0xFFFF_FF00)  // 192.0.2.33 / 255.255.255.0

    @Test("A dotted address becomes a number")
    func readAddress() {
        #expect(LocationDetermination.address(from: "192.0.2.184") == 0xC000_02B8)
        #expect(LocationDetermination.address(from: "0.0.0.0") == 0)
        #expect(LocationDetermination.address(from: "255.255.255.255") == 0xFFFF_FFFF)
    }

    /// **What is not an address does not become one.** `256` does not fit in a byte, `01` looks
    /// like one and is not — whoever let both through would end up taking a name for an address
    /// and never asking the name service.
    @Test("What is not an address yields nothing")
    func noAddress() {
        #expect(LocationDetermination.address(from: "jellyfin.example") == nil)
        #expect(LocationDetermination.address(from: "192.0.2") == nil)
        #expect(LocationDetermination.address(from: "192.0.2.256") == nil)
        #expect(LocationDetermination.address(from: "192.0.2.01") == nil)
        #expect(LocationDetermination.address(from: "") == nil)
    }

    @Test("In the same subnet means at home")
    func inSameNetwork() {
        let server = LocationDetermination.address(from: "192.0.2.184")
        #expect(LocationDetermination.location(server: server, networks: [homeNetwork]) == .home)
    }

    /// **The case this is about.** Over WireGuard the media server answers from anywhere in the
    /// world; the phone then sits in a different network. Whoever ties "at home" to
    /// reachability gets "at home" on the train.
    @Test("Through the tunnel one is on the go although the server answers")
    func onTheRoadThroughTunnel() {
        // The phone is on cellular, the tunnel leads into the house — but the tunnel's interface
        // does not count as a network of its own, and the cellular network is a different one.
        let cellular = LocationDetermination.Network(address: 0x0A1E_0B0C, mask: 0xFFFF_FF00)
        let server = LocationDetermination.address(from: "192.0.2.184")

        #expect(LocationDetermination.location(server: server, networks: [cellular]) == .inFlight)
    }

    /// **A foreign Wi-Fi is also Wi-Fi** — exactly the sentence that is in ``LocationStatement``.
    /// And if the foreign network happens to use the same numbers (`192.0.2.x` is the
    /// default of every Fritz!Box), the rule says "at home". That is the known limit of this
    /// method and it is here as a check so that nobody takes it for a bug: Two networks with
    /// the same address range cannot be told apart from inside.
    @Test("A foreign network with the same numbers cannot be told apart")
    func sameNumbersForeignNetwork() {
        let foreignFritzbox = LocationDetermination.Network(address: 0xC000_022A, mask: 0xFFFF_FF00)
        let server = LocationDetermination.address(from: "192.0.2.184")

        #expect(LocationDetermination.location(server: server, networks: [foreignFritzbox]) == .home)
    }

    /// **Without an answer nothing is claimed** — the whole purpose of ``Location/unknown``.
    @Test("Without an address or without a network of its own it stays unknown")
    func unknownInsteadOfGuessed() {
        #expect(LocationDetermination.location(server: nil, networks: [homeNetwork]) == .unknown)
        #expect(
            LocationDetermination.location(server: 0xC000_02B8, networks: []) == .unknown,
            "in airplane mode there is no network of its own")
        #expect(LocationDetermination.location(server: nil, networks: []) == .unknown)
    }

    /// Several interfaces at once — Wi-Fi and cellular. One is enough.
    @Test("One matching network among several is enough")
    func multipleNetworks() {
        let cellular = LocationDetermination.Network(address: 0x0A1E_0B0C, mask: 0xFFFF_FF00)
        let server = LocationDetermination.address(from: "192.0.2.184")

        #expect(
            LocationDetermination.location(server: server, networks: [cellular, homeNetwork]) == .home)
    }

    /// **The tunnel does not belong to the own networks** — otherwise one would compare the
    /// answer with the question. The list is in the source and is pinned down here so that
    /// nobody shortens it while tidying up.
    @Test("Tunnel and direct interfaces do not count as a network of their own")
    func foreignPortsExcluded() {
        for name in ["utun", "awdl", "bridge", "ap", "ipsec", "ppp", "llw"] {
            #expect(LocationDetermination.foreignPorts.contains(name))
        }
        #expect(!LocationDetermination.foreignPorts.contains("en"))
        #expect(!LocationDetermination.foreignPorts.contains("pdp_ip"), "cellular counts")
    }

    /// Without a location there is no location line — the connection between this file and
    /// what is on screen.
    @Test("With an unknown location the location statement yields nothing")
    func unknownStaysSilent() {
        for place in LocationStatement.Place.allCases {
            #expect(LocationStatement.forItem(place, location: .unknown) == nil)
            #expect(LocationStatement.forItem(place, location: .home) != nil)
            #expect(LocationStatement.forItem(place, location: .inFlight) != nil)
        }
    }
}
