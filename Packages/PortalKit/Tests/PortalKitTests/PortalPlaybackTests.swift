import Foundation
import Testing

@testable import PortalKit

/// What `/play` answers — and when a press plays instead of opening.
///
/// Both belong together: a flat portal plays on press, and what then comes is the answer from `/play`.
/// Until 2026-08-29 both went wrong — the press led to a detail page without content, and the address was the
/// raw one of the portal's local proxy.
@Suite("Playing from a portal")
struct PortalPlaybackTests {

    private func reply(_ raw: String) throws -> BridgeReply.Playback {
        try JSONDecoder().decode(BridgeReply.Playback.self, from: Data(raw.utf8))
    }

    /// **The case this is about.** The bridge has decided that the stream runs through it — the address points
    /// to itself, and the headers are already set there.
    @Test("A passed-through stream names the address of the bridge")
    func passedThrough() throws {
        let a = try reply(
            """
            {"adresse":"http://portale.example:8099/strom?adresse=x&puffer=ab12",
             "art":"datei","kopfzeilen":{},"durchgereicht":true}
            """)

        #expect(a.address.hasPrefix("http://portale.example:8099/strom"))
        #expect(a.passedThrough == true)
        #expect(a.headers?.isEmpty == true)
    }

    /// The other way: directly to the host, and then the app carries the headers. No portal stands like that
    /// today — the answer can say it anyway, and a check that knows only the one case overlooks the day on
    /// which someone sets `direct: true`.
    @Test("A direct stream brings its headers along")
    func direct() throws {
        let a = try reply(
            """
            {"adresse":"https://cdn.beispiel.invalid/1080.mp4","art":"datei",
             "kopfzeilen":{"Referer":"https://beispiel.invalid/"},"durchgereicht":false}
            """)

        #expect(a.passedThrough == false)
        #expect(a.headers?["Referer"] == "https://beispiel.invalid/")
    }

    /// **The server may take a different source than the requested one** (2026-09-16): since every resolution
    /// sends the title's address along, it goes through the other sources if the requested one does not hold
    /// up. The answer says which one is running — in its words (`source`, `switched`), which the dialect
    /// translates.
    @Test("The response names the source that works and whether it switched")
    func switched() throws {
        let reader = JSONDecoder()
        reader.keyDecodingStrategy = .custom { path in
            DialectKey(PortalDialect.cinelounge.key(path: path))
        }
        let a = try reader.decode(
            BridgeReply.Playback.self,
            from: Data(
                """
                {"address":"https://cl.example/stream?address=x","kind":"hls","headers":{},
                 "proxied":true,"source":"f=getHostUrl&hUrl=click","switched":true}
                """.utf8))
        #expect(a.source == "f=getHostUrl&hUrl=click")
        #expect(a.switched == true)

        // The bridge says nothing of this — and the answer stays readable.
        let b = try reply(#"{"adresse":"http://x.invalid/s"}"#)
        #expect(b.source == nil)
        #expect(b.switched == nil)
    }

    /// Older bridges do not know the field. A missing `passedThrough` must not make the answer unreadable —
    /// otherwise nothing plays at all after a partial update.
    @Test("Missing fields do not make the response unreadable")
    func lenient() throws {
        let a = try reply(
            """
            {"adresse":"http://x.invalid/s"}
            """)

        #expect(a.address == "http://x.invalid/s")
        #expect(a.passedThrough == nil)
        #expect(a.headers == nil)
    }

    /// **The rule for the press** (user request 2026-08-29). It names no portal names — it queries the capability,
    /// and that is why it also applies to the next flat portal.
    @Test("Without seasons a portal is flat")
    func flatDetected() throws {
        let portals = try reported(
            ("serieshub", ["suche", "staffeln", "sprachen"]),
            ("flatone", ["blaettern", "suche"]),
            ("flattwo", ["blaettern", "suche"])
        )

        #expect(PortalSource.supportsSeasons(portal: "serieshub", in: portals))
        #expect(!PortalSource.supportsSeasons(portal: "flatone", in: portals))
        #expect(!PortalSource.supportsSeasons(portal: "flattwo", in: portals))
    }

    /// **When in doubt the detail page.** A portal that the bridge has not yet reported must not count as flat:
    /// a press would then play a series instead of showing its seasons.
    @Test("An unknown portal does not count as flat")
    func unknown() throws {
        #expect(PortalSource.supportsSeasons(portal: "kenntKeiner", in: try reported()))
    }

    private func reported(_ portals: (String, [String])...) throws -> [BridgeReply.Portal] {
        try portals.map { id, capabilities in
            let list = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
            let raw = """
                {"id":"\(id)","name":"\(id)","art":"extension","faehigkeiten":[\(list)],
                 "zustand":"bereit","grund":null}
                """
            return try JSONDecoder().decode(BridgeReply.Portal.self, from: Data(raw.utf8))
        }
    }
}
