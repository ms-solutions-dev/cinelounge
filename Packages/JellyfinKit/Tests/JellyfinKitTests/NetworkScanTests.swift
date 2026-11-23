import Foundation
import Testing

@testable import JellyfinKit

/// Probing the own network — the second way besides the broadcast.
///
/// **What is checked is the calculation and the merging, not the network.** Whether a
/// request arrives is told only by a real network; that a mask yields the right addresses
/// and that two ways yield **one** list is told by nobody — it would be noticed only when a
/// viewer saw the same server twice in the list or the phone began to probe a network that
/// does not belong to it.
@Suite("Probing the network")
struct NetworkScanTests {

    // MARK: - Which addresses

    @Test("An ordinary home network yields 253 addresses")
    func homeNetworkYields253() {
        let list = NetworkScan.addresses(own: "192.0.2.33", mask: "255.255.255.0")

        #expect(list.count == 253, "254 hosts minus its own")
        #expect(!list.contains("192.0.2.33"), "nobody asks themselves")
        #expect(!list.contains("192.0.2.0"), "the network address is not a host")
        #expect(!list.contains("192.0.2.255"), "neither is the broadcast address")
        #expect(list.first == "192.0.2.1")
        #expect(list.last == "192.0.2.254")
    }

    @Test("A network that is too large is not probed at all")
    func tooLargeNetworkStaysUntouched() {
        // **The case that would otherwise silently become expensive.** A `/16` is 65,534
        // requests; that is no longer searching, and on a phone it would be clearly noticeable in
        // battery and cell.
        #expect(NetworkScan.addresses(own: "10.0.0.5", mask: "255.255.0.0").isEmpty)
        #expect(NetworkScan.addresses(own: "10.0.0.5", mask: "255.0.0.0").isEmpty)
    }

    @Test("A small network yields few addresses")
    func smallNetwork() {
        // /30: four addresses, two of them machines — one is yourself.
        let list = NetworkScan.addresses(own: "192.168.1.1", mask: "255.255.255.252")

        #expect(list == ["192.168.1.2"])
    }

    @Test("What is not a mask yields no list")
    func brokenMaskYieldsNothing() {
        // Gappy mask, empty mask, nonsense: computing a range from it would mean making something
        // up — and then the phone would knock on foreign doors.
        #expect(NetworkScan.addresses(own: "192.168.1.5", mask: "255.0.255.0").isEmpty)
        #expect(NetworkScan.addresses(own: "192.168.1.5", mask: "0.0.0.0").isEmpty)
        #expect(NetworkScan.addresses(own: "no address", mask: "255.255.255.0").isEmpty)
        #expect(NetworkScan.addresses(own: "192.168.1.5", mask: "255.255.255.255").isEmpty)
    }

    @Test("Tunnels and near-field links are out of the question")
    func tunnelIsSkipped() {
        // **The finding that would be expensive on the road:** on the phone WireGuard hangs as
        // `utun`; probing its network would mean sending 253 requests through a line measured at
        // 0.6 Mbit/s.
        #expect(!NetworkScan.isUsable("utun3"))
        #expect(!NetworkScan.isUsable("awdl0"))
        #expect(!NetworkScan.isUsable("bridge100"))
        #expect(NetworkScan.isUsable("en0"))
    }

    // MARK: - What an answer is worth

    @Test("Only identifier and name make an answer a find")
    func onlyRealReplyCounts() {
        let real = Data(
            #"{"Id":"3c37","ServerName":"livingroom","Version":"10.10.7"}"#.utf8)
        let found = NetworkScan.interpret(real, from: "192.0.2.184")

        #expect(found?.id == "3c37")
        #expect(found?.name == "livingroom")
        #expect(found?.address.absoluteString == "http://192.0.2.184:8096")
    }

    @Test("Whoever answers politely is not yet a Jellyfin server")
    func foreignReplyIsNoFinding() {
        // Anything at all can be on 8096 — a printer, a router, another service. Without an
        // identifier it is not a find, and an entry in the list would be an invitation into an
        // error message.
        #expect(NetworkScan.interpret(Data("<html>Hallo</html>".utf8), from: "192.168.1.7") == nil)
        #expect(NetworkScan.interpret(Data(#"{"Id":""}"#.utf8), from: "192.168.1.7") == nil)
        #expect(NetworkScan.interpret(Data(), from: "192.168.1.7") == nil)
    }

    @Test("A server without a name gets its address as name")
    func namelessServerIsNamedByAddress() {
        let found = NetworkScan.interpret(Data(#"{"Id":"abc"}"#.utf8), from: "192.168.1.9")

        #expect(found?.name == "192.168.1.9", "an empty row in the list would not be selectable")
    }

    // MARK: - Merging

    private func found(_ id: String, _ address: String) -> ServerDiscovery.Found {
        ServerDiscovery.Found(id: id, name: "S\(id)", address: URL(string: address)!)
    }

    @Test("The same server appears only once — the broadcast wins")
    func broadcastWins() {
        // Measured on 2026-09-10: the home server answers under **two** addresses with the same
        // identifier. Twice in the list it would be a question nobody can answer.
        let list = NetworkScan.create(
            combined: [found("a", "http://vault.example:8096")],
            and: [found("a", "http://192.0.2.184:8096"), found("a", "http://192.0.2.183:8096")]
        )

        #expect(list.count == 1)
        #expect(
            list.first?.address.absoluteString == "http://vault.example:8096",
            "the address the server itself considers the right one")
    }

    @Test("Whoever was only probed is added")
    func knockedOnesAreAdded() {
        let list = NetworkScan.create(
            combined: [found("a", "http://a.example:8096")],
            and: [found("b", "http://192.0.2.50:8096")])

        #expect(list.map(\.id) == ["a", "b"], "the broadcast comes first and keeps its order")
    }

    // MARK: - The flow

    @Test("Every address is asked exactly once")
    func everyAddressOnce() async {
        let targets = (1...200).map { "10.0.0.\($0)" }
        let ledger = QueryLedger()

        await NetworkScan.knock(
            on: targets, concurrently: 16,
            query: { address in
                await ledger.note(address)
                return address == "10.0.0.42"
                    ? ServerDiscovery.Found(
                        id: "x", name: "found", address: URL(string: "http://\(address)")!)
                    : nil
            },
            fund: { found in Task { await ledger.take(found) } })

        let asked = await ledger.asked
        #expect(asked.count == 200)
        #expect(Set(asked).count == 200, "no address twice")
        // The find is reported via a task; a moment of trailing time belongs to it.
        try? await Task.sleep(for: .milliseconds(50))
        let match = await ledger.match
        #expect(match.count == 1)
    }

    @Test("Without addresses nothing happens")
    func withoutAddressesNothing() async {
        let ledger = QueryLedger()
        await NetworkScan.knock(
            on: [],
            query: {
                await ledger.note($0); return nil
            }, fund: { _ in })
        let asked = await ledger.asked
        #expect(asked.isEmpty)
    }
}

/// Records what was asked and what was found — written from several tasks at once, hence
/// an actor.
private actor QueryLedger {
    var asked: [String] = []
    var match: [ServerDiscovery.Found] = []

    func note(_ address: String) { asked.append(address) }
    func take(_ found: ServerDiscovery.Found) { match.append(found) }
}
