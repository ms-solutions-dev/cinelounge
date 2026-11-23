import Foundation
import Synchronization
import Testing

@testable import NetworkStatus

/// **Network path, tunnel and location tell what they decided** — finding 11.
///
/// `.serialized`, because the hook applies to the whole program.
@Suite("Finding 11 · Network log", .serialized)
@MainActor
struct NetworkLogTests {

    /// Collects what comes through the hook.
    final class Collector: Sendable {
        let rows = Mutex<[(NetworkLog.Tier, String)]>([])
        var all: [(NetworkLog.Tier, String)] { rows.withLock { $0 } }
    }

    func withHook(_ bodyContent: (Collector) async throws -> Void) async rethrows {
        let collector = Collector()
        NetworkLog.set { tier, message in collector.rows.withLock { $0.append((tier, message)) } }
        defer { NetworkLog.set(nil) }
        try await bodyContent(collector)
    }

    @Test("A change over a full tunnel without a carrier is a hint with the interfaces")
    func fullTunnelWithoutCarrier() async {
        await withHook { collector in
            let watcher = NetworkWatch()
            watcher.adopt(NetworkPath(kind: .wifi), interfaces: ["utun3", "en0"])
            watcher.adopt(.none, interfaces: ["utun3"])
            let rows = collector.all
            #expect(rows.count == 2)
            #expect(rows.first?.0 == .step)
            #expect(rows.first?.1.contains("Tunnel detected (utun3) over wifi") == true)
            #expect(rows.last?.0 == .hint)
            #expect(rows.last?.1.contains("Full tunnel without carrier (utun3)") == true)
            #expect(rows.last?.1.contains("Interfaces: utun3") == true)
        }
    }

    @Test("The same report again writes nothing")
    func noSwitchNoLine() async {
        await withHook { collector in
            let watcher = NetworkWatch()
            watcher.adopt(NetworkPath(kind: .cellular, expensive: true), interfaces: ["pdp_ip0"])
            watcher.adopt(NetworkPath(kind: .cellular, expensive: true), interfaces: ["pdp_ip0"])
            #expect(
                collector.all.map(\.1) == ["Network path none → cellular expensive · Interfaces: pdp_ip0"])
        }
    }

    /// **Silent is the default** — that is how it stays for StoryShelf, which never sets the
    /// hook.
    @Test("Without a hook nothing is built and nothing is output")
    func withoutHookSilent() {
        NetworkLog.set(nil)
        let watcher = NetworkWatch()
        watcher.adopt(NetworkPath(kind: .wifi), interfaces: ["en0"])
        #expect(watcher.changeCount == 1)
    }

    @Test("The location sentence names no address")
    func locationSentence() {
        let message = LocationDetermination.logLine(
            .unknown, addressResolved: false, name: true, networks: 1)
        #expect(
            message
                == "Location unknown: server address not resolved (name resolved), 1 own network(s) without tunnel"
        )
        #expect(!message.contains("192.168"))
    }

    @Test("Location determination reports its decision — one step without a server")
    func locationWithoutServer() async {
        await withHook { collector in
            let result = await LocationDetermination.location(forItem: nil)
            #expect(result == .unknown)
            #expect(collector.all.map(\.1) == ["Location unknown: no Jellyfin server configured"])
        }
    }
}
