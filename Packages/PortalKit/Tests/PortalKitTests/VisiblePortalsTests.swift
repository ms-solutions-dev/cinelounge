import Core
import Foundation
import Testing

@testable import PortalKit

/// **Finding on the test Apple TV, 2026-09-28:** Titles from a portal switched off on the
/// server appeared in "Continue Watching" — the server delivers state and favorites
/// unfiltered.
@Suite("Continue Watching only from visible portals")
struct VisiblePortalsTests {

    private func title(_ portal: String) -> MediaItem {
        MediaItem(
            id: PortalItemID(portal: portal, key: "k", address: "/a").identifier,
            kind: .movie, title: portal)
    }

    @Test("A disabled portal drops out, a visible one stays")
    func disabled() {
        let filtered = PortalSource.only([title("zinne"), title("versteckt")], from: ["zinne"])
        #expect(filtered.map(\.title) == ["zinne"])
    }

    @Test("An identifier without a readable portal drops out")
    func unreadable() {
        let foreign = MediaItem(id: "ohne-trenner", kind: .movie, title: "x")
        #expect(PortalSource.only([foreign], from: ["zinne"]).isEmpty)
    }

    /// The reader ``PortalBridge`` builds for the CineLounge server.
    private func read(_ json: String) throws -> BridgeReply.Portals {
        let reader = JSONDecoder()
        reader.keyDecodingStrategy = .custom { path in
            DialectKey(PortalDialect.cinelounge.key(path: path))
        }
        return try reader.decode(BridgeReply.Portals.self, from: Data(json.utf8))
    }

    private static let portal = """
        {"id": "zinne", "name": "ZINNE", "kind": "native", "capabilities": [], "state": "ready"}
        """

    /// **AP90, owner 2026-11-16:** a title from a portal with a fault stays in "Continue
    /// Watching"; the fault is said when it is played. The server lists the portal in
    /// `permitted` although it is missing from `portals`.
    @Test("A broken but permitted portal keeps its titles")
    func brokenButPermitted() throws {
        let reply = try read(#"{"portals": [\#(Self.portal)], "permitted": ["zinne", "bs"]}"#)
        #expect(reply.keepsTitles == ["zinne", "bs"])
        let kept = PortalSource.only([title("zinne"), title("bs"), title("off")], from: reply.keepsTitles)
        #expect(kept.map(\.title) == ["zinne", "bs"])
    }

    /// A server before AP90 sends no `permitted`: the portal list decides, as before.
    @Test("Without the field the portal list decides")
    func olderServer() throws {
        let reply = try read(#"{"portals": [\#(Self.portal)]}"#)
        #expect(reply.permitted == nil)
        #expect(reply.keepsTitles == ["zinne"])
    }
}
