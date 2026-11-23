import Foundation
import Testing

@testable import JellyfinKit

/// **A found server that this device does not reach** (AP18, 2026-09-02).
///
/// The server answers the broadcast with **its own** idea of how it can be reached. Whether
/// this device can do anything with that is another matter — and until today stood nowhere.
@Suite("Server search: reachable or only found")
struct ServerReachabilityTests {

    private func found(_ id: String, _ address: String) -> ServerDiscovery.Found {
        ServerDiscovery.Found(id: id, name: "Server \(id)", address: URL(string: address)!)
    }

    @Test("Whoever does not answer stays in the list — but marked")
    func unreachableStaysButIsMarked() async {
        let list = [
            found("1", "http://192.0.2.183:8096"),
            found("2", "https://jellyfin.example"),
        ]
        let verified = await ServerDiscovery.verify(list) { url in
            url.host() == "192.0.2.183"
        }

        // **Nothing disappears.** A server that answered is there; only the way to it is wrong.
        // Leaving it out would take away the only trace the viewer has.
        #expect(verified.count == 2)
        #expect(verified.map(\.reachable) == [true, false])
        #expect(verified.map(\.id) == ["1", "2"])
    }

    /// **The order of the search stays.** A list that sorts differently depending on response time
    /// wanders away from under the viewer's focus — they then press on something other than what
    /// they saw.
    @Test("The order does not depend on the response time")
    func orderDoesNotFollowResponseTime() async {
        let list = (1...5).map { found("\($0)", "http://host\($0):8096") }
        let verified = await ServerDiscovery.verify(list) { url in
            // The first answers slowest, the last immediately.
            let number = Int(url.host()?.replacingOccurrences(of: "host", with: "") ?? "0") ?? 0
            try? await Task.sleep(for: .milliseconds((6 - number) * 20))
            return true
        }

        #expect(verified.map(\.id) == ["1", "2", "3", "4", "5"])
        let allReachable = verified.allSatisfy(\.reachable)
        #expect(allReachable)
    }

    @Test("Without a find there is nothing to check")
    func nothingFoundNothingProbed() async {
        let called = TallyCounter()
        let verified = await ServerDiscovery.verify([]) { _ in
            called.increment()
            return true
        }

        #expect(verified.isEmpty)
        let state = called.state
        #expect(state == 0)
    }

    @Test("Every server is asked exactly once")
    func eachServerIsProbedOnce() async {
        let called = TallyCounter()
        let list = (1...4).map { found("\($0)", "http://host\($0):8096") }
        _ = await ServerDiscovery.verify(list) { _ in
            called.increment()
            return false
        }

        let state = called.state
        #expect(state == 4)
    }

    /// Counts calls across threads.
    private final class TallyCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }
        var state: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }
}
