import Foundation
import Testing

@testable import JellyfinKit

/// The same server appears only once (on-device test 2026-09-27, T2).
///
/// Setup showed the test server's name and its address twice: the broadcast goes to more
/// than one broadcast address, and the same server answers on each.
@Suite("Merging finds")
struct FindMergeTests {

    private func found(_ id: String, _ address: String) -> ServerDiscovery.Found {
        ServerDiscovery.Found(id: id, name: "livingroom", address: URL(string: address)!)
    }

    @Test("Duplicate answers in the broadcast yield one find")
    func duplicateBroadcast() {
        let combined = NetworkScan.create(
            combined: [found("a", "http://192.0.2.183:8096"), found("a", "http://192.0.2.183:8096")],
            and: [])
        #expect(combined.map(\.id) == ["a"])
    }

    @Test("Broadcast and probing together yield each server once")
    func bothWays() {
        let combined = NetworkScan.create(
            combined: [found("a", "http://192.0.2.183:8096")],
            and: [
                found("a", "http://192.0.2.184:8096"), found("b", "http://192.0.2.20:8096"),
                found("b", "http://192.0.2.20:8096"),
            ])
        #expect(combined.map(\.id) == ["a", "b"])
        #expect(combined.first?.address.host == "192.0.2.183")
    }

    @Test("The same address with a different identifier yields one find")
    func sameAddress() {
        let combined = NetworkScan.create(
            combined: [],
            and: [found("a", "http://192.0.2.183:8096"), found("b", "http://192.0.2.183:8096")])
        #expect(combined.count == 1)
    }
}
