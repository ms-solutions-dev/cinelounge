import Foundation
import Network
import SourceProbe
import Testing

@testable import SecondScreen

/// **Search and receiver write to the log** — on-device test build 1332, finding 13.
@Suite("Finding 13 · Bonjour in the log")
struct BonjourProtocolTests {

    /// The case that went unnoticed on the device: "Local Network" denied.
    @Test("A waiting search without permission names the setting")
    func localNetworkDenied() throws {
        let entry = try #require(
            BonjourProtocol.message(search: .waiting(.dns(BonjourProtocol.localNetworkDenied))))
        #expect(entry.0 == .hint)
        #expect(entry.1.contains("Local Network not allowed (-65570)"))
    }

    @Test("Every state of the search has its severity, the setup has none")
    func search() {
        #expect(BonjourProtocol.message(search: .setup) == nil)
        #expect(BonjourProtocol.message(search: .ready)?.0 == .step)
        #expect(BonjourProtocol.message(search: .failed(.posix(.ENETDOWN)))?.0 == .error)
        #expect(BonjourProtocol.message(search: .cancelled)?.0 == .step)
        #expect(BonjourProtocol.message(discoveries: 2) == "Remote: 2 TVs found")
    }

    @Test("The receiver reports readiness, waiting, failure and the service registration")
    func receiver() {
        #expect(
            BonjourProtocol.message(receiver: .ready, who: "Remote")?.1
                == "Remote: receiver ready")
        #expect(
            BonjourProtocol.message(receiver: .failed(.posix(.EADDRINUSE)), who: "Handoff")?.0
                == .error)
        #expect(
            BonjourProtocol.message(
                receiver: .waiting(.dns(BonjourProtocol.localNetworkDenied)), who: "Handoff")?
                .1.contains("-65570") == true)
    }

    /// **The counter-check against the old code:** the search, the remote's receiver and the
    /// handoff's receiver wrote their states nowhere until today.
    @Test("Search and both receivers are connected to the log")
    func connected() throws {
        let discoverySource = try SourceText.read("DeviceDiscovery.swift", in: .secondScreen)
        #expect(discoverySource.contains("BonjourProtocol.message(search: state)"))
        #expect(discoverySource.contains("BonjourProtocol.message(discoveries:"))
        let remoteSource = try SourceText.read("RemoteReceiver.swift", in: .secondScreen)
        #expect(remoteSource.contains("BonjourProtocol.observe(new, who: \"Remote\")"))
        let wire = try SourceText.read("HandoffWire.swift", in: .secondScreen)
        #expect(wire.contains("BonjourProtocol.observe(listeners, who: \"Handoff\")"))
    }
}
