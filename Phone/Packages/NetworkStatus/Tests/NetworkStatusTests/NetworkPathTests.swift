import Network
import Testing

@testable import NetworkStatus

@Suite("Network path")
struct NetworkPathTests {

    /// "Expensive" is an indication of its own: A hotspot is Wi-Fi and still expensive.
    @Test("An expensive Wi-Fi is not a home network")
    func expensiveWifi() {
        let hotspot = NetworkPath(kind: .wifi, expensive: true)
        #expect(hotspot.carries)
        #expect(!hotspot.largeVolumesAcceptable)
    }

    /// Low Data Mode is an explicit request and not an assumption about the line. It therefore
    /// weighs more than any measurement of our own.
    @Test("Low Data Mode beats everything")
    func frugal() {
        #expect(!NetworkPath(kind: .wifi, frugal: true).largeVolumesAcceptable)
    }

    @Test("Without a network nothing works")
    func offline() {
        #expect(!NetworkPath.none.carries)
        #expect(!NetworkPath.none.largeVolumesAcceptable)
    }

    @Test("An ordinary Wi-Fi carries large amounts")
    func homeNetwork() {
        #expect(NetworkPath(kind: .wifi).largeVolumesAcceptable)
    }
}

/// The translation from what `Network` reports — **the half that could only be seen on the
/// device** until it took a list of interface types instead of an `NWPath`.
@Suite("Network path from the report")
struct NetworkPathTranslationTests {

    /// The finding of 2026-09-09: airplane mode, WireGuard as a full tunnel, and the offline screen
    /// did not appear. `Network` reported `satisfied` over `utun`.
    @Test("A tunnel with no radio underneath carries nothing")
    func tunnelAlone() {
        let route = NetworkPath(status: .satisfied, interfaces: [.other])
        #expect(!route.carries)
    }

    @Test("A tunnel over Wi-Fi is Wi-Fi")
    func tunnelOverWifi() {
        let route = NetworkPath(status: .satisfied, interfaces: [.other, .wifi])
        #expect(route.kind == .wifi)
        #expect(route.largeVolumesAcceptable)
    }

    @Test("A tunnel over cellular is cellular, and expensive stays expensive")
    func tunnelOverCellular() {
        let route = NetworkPath(status: .satisfied, interfaces: [.other, .cellular], expensive: true)
        #expect(route.kind == .cellular)
        #expect(!route.largeVolumesAcceptable)
    }

    @Test("Without a carrying path every interface list is none")
    func unsatisfied() {
        #expect(!NetworkPath(status: .unsatisfied, interfaces: [.wifi]).carries)
        #expect(!NetworkPath(status: .requiresConnection, interfaces: [.wifi]).carries)
    }

    @Test("Loopback alone is not a network")
    func loopback() {
        #expect(!NetworkPath(status: .satisfied, interfaces: [.loopback]).carries)
    }
}
