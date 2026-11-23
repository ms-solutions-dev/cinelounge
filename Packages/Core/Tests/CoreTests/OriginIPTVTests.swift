import Testing

@testable import Core

/// **Diagnosis F-025 (2026-09-28):** IPTV titles went to the CL-Server because their identifier
/// looks like a portal identifier.
@Suite("Origin: IPTV is not the CL-Server")
struct OriginIPTVTests {

    @Test("An IPTV title with a computed list belongs to the provider")
    func iptv() {
        let identifier = "xtream|iptvhost.example|konto#movie#123"
        #expect(Origin.forItem(identifier: identifier) == .provider)
        #expect(Origin.portal(fromIdentifier: identifier) == nil)
    }

    @Test("A CL-Server title stays a CL-Server title")
    func portal() {
        let identifier = "animehub|crypt-seeker-lord|/anime/stream/crypt-seeker-lord"
        #expect(Origin.forItem(identifier: identifier) == .portals)
        #expect(Origin.portal(fromIdentifier: identifier) == "animehub")
    }
}
