import Core
import Foundation
import Testing

@testable import PlaylistKit

/// The shared check of a channel list (AP58 R7, finding E3) — interpretation of the response and
/// reading of a typed-in address, the same for TV and phone.
@Suite("Channel list check")
struct ChannelListCheckTests {

    private func reply(_ json: String) throws -> XtreamPayload.AccountInfo {
        try JSONDecoder().decode(XtreamPayload.AccountInfo.self, from: Data(json.utf8))
    }

    @Test("Rejected, expired and valid are three findings")
    func threeFindings() throws {
        #expect(ChannelListCheck.interpret(try reply(#"{"auth":0}"#)) == .rejected)
        #expect(
            ChannelListCheck.interpret(try reply(#"{"auth":1,"status":"Expired"}"#)) == .expired)
        let isValid = ChannelListCheck.interpret(
            try reply(
                #"{"auth":1,"status":"Active","max_connections":"1","active_cons":"0","allowed_output_formats":["ts"]}"#
            ))
        #expect(
            isValid
                == .isValid(.init(status: "Active", until: nil, taken: 0, atMost: 1, rawOnly: true)))
    }

    /// **The gap on both sides:** `verify()` throws on `auth != 1` and on a status
    /// other than "Active" — both ended up as "does not respond" until R7.
    @Test("A thrown error is interpreted and not swallowed")
    func thrown() {
        #expect(ChannelListCheck.interpret(XtreamClient.Failure.unauthorized) == .rejected)
        #expect(ChannelListCheck.interpret(XtreamClient.Failure.accountDisabled) == .expired)
        #expect(ChannelListCheck.interpret(XtreamClient.Failure.unreachable) == .muted)
        #expect(ChannelListCheck.interpret(URLError(.timedOut)) == .muted)
    }

    @Test("Without a password nothing is asked, an M3U list never is")
    func withoutQuestion() async throws {
        let server = try #require(URL(string: "http://anbieter.beispiel:8080"))
        let xtream = Playlist(id: "x", name: "X", kind: .xtream(server: server, username: "u"))
        #expect(await ChannelListCheck.verify(xtream, password: nil) == .withoutPassword)
        #expect(await ChannelListCheck.verify(xtream, password: "") == .withoutPassword)
        let m3u = Playlist(id: "m", name: "M", kind: .m3u(server))
        #expect(await ChannelListCheck.verify(m3u, password: "geheim") == nil)
    }

    /// `URL(string:)` reads `provider.tv:8080` as scheme `provider.tv` without a host — that is how
    /// the phone read it until R7.
    @Test("An address gets its scheme and needs a host")
    func address() {
        let without = ChannelListCheck.address(" anbieter.tv:8080/liste.m3u ")
        #expect(without?.scheme == "http")
        #expect(without?.host() == "anbieter.tv")
        #expect(without?.port == 8080)
        #expect(ChannelListCheck.address("https://a.tv/x/")?.absoluteString == "https://a.tv/x/")
        #expect(ChannelListCheck.address("httpbin.org/liste")?.host() == "httpbin.org")
        #expect(ChannelListCheck.address("   ") == nil)
        #expect(ChannelListCheck.address("http://") == nil)
        #expect(
            ChannelListCheck.serverAddress("anbieter.tv:8080/")?.absoluteString
                == "http://anbieter.tv:8080")
    }
}
