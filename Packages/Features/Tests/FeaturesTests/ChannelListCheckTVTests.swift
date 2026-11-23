import Foundation
import PlaylistKit
import Testing

@testable import Features

/// How the TV records the shared check of a channel list (AP58 R7, E3).
///
/// **Via the shared interpretation**, so that a change there turns this red: until R7
/// `PlaylistSettings.check` read the answer itself, and a rejected access arrived as "not
/// reachable".
@Suite("Channel list status row on the TV")
@MainActor
struct ChannelListCheckTVTests {

    private func reply(_ json: String) throws -> XtreamPayload.AccountInfo {
        try JSONDecoder().decode(XtreamPayload.AccountInfo.self, from: Data(json.utf8))
    }

    @Test("Rejected and expired each get their own sentence")
    func twoSets() throws {
        #expect(
            PlaylistSettings.row(ChannelListCheck.interpret(try reply(#"{"auth":0}"#)))
                == .failed("settings.playlistRejected"))
        #expect(
            PlaylistSettings.row(
                ChannelListCheck.interpret(try reply(#"{"auth":1,"status":"Expired"}"#)))
                == .failed("settings.playlistExpired"))
        #expect(
            PlaylistSettings.row(ChannelListCheck.interpret(XtreamClient.Failure.unauthorized))
                == .failed("settings.playlistRejected"))
    }

    @Test("A valid login names the connections in use")
    func isValid() throws {
        let row = PlaylistSettings.row(
            ChannelListCheck.interpret(
                try reply(#"{"auth":1,"status":"Active","max_connections":"2","active_cons":"1"}"#)))
        #expect(row == .reachable("Active  ·  1/2"))
    }
}
