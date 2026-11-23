import Flows
import Foundation
import Testing

@testable import Features

/// The switches of the setup's sheets (AP88 wave 4) — **which page a state shows and where the
/// focus lands**; the paths themselves are checked at the core in `Flows`.
@Suite("Setup — the TV sheets")
struct SetupSheetsTests {

    @Test("A6: every answer of the request has its own page")
    func clServerPages() {
        #expect(ClServerJoinView.page(.searching) == .searching)
        #expect(ClServerJoinView.page(.notFound) == .notFound)
        #expect(ClServerJoinView.page(.request(.none)) == .ask)
        #expect(
            ClServerJoinView.page(.request(.waiting(remainingSeconds: 60)))
                == .waiting(.waiting(remainingSeconds: 60)))
        #expect(ClServerJoinView.page(.request(.throttled(seconds: 90))) == .waiting(.throttled(seconds: 90)))
        #expect(
            ClServerJoinView.page(.request(.approved(name: "Lea", withTag: true)))
                == .approved(name: "Lea", withTag: true))
        #expect(ClServerJoinView.page(.request(.rejected)) == .ended(.rejected))
        #expect(ClServerJoinView.page(.request(.expired)) == .ended(.expired))
        #expect(ClServerJoinView.page(.request(.failed("x"))) == .ended(.failed("x")))
    }

    @Test("G3 at the screen: a child's state never offers the request")
    func childNeverAsks() {
        #expect(ClServerJoinView.page(.childPairing) == .childPairing)
        #expect(ClServerJoinView.page(.request(.notForChildren)) == .childPairing)
        #expect(ClServerJoinView.focusTarget(.childPairing) == "pairing")
    }

    @Test("A6: \"Continue\" has the focus while waiting, as in design A")
    func clServerFocus() {
        #expect(ClServerJoinView.focusTarget(.waiting(.waiting(remainingSeconds: 1))) == "continue")
        #expect(ClServerJoinView.focusTarget(.ask) == "ask")
        #expect(ClServerJoinView.focusTarget(.searching) == nil)
    }

    @Test("A5: the focus is on a button, never on the code")
    func jellyfinFocus() {
        #expect(JellyfinConfirmView.focusTarget(.noCode(errorKey: nil)) == "password")
        #expect(JellyfinConfirmView.focusTarget(.otherUser(signedIn: "tom", expected: "lea")) == "take-over")
        #expect(JellyfinConfirmView.focusTarget(.unreachable(errorKey: nil)) == "retry")
        #expect(JellyfinConfirmView.focusTarget(.connecting) == nil)
    }

    @Test("IPTV: the row names the provider's host, with or without a scheme")
    func channelListDetail() {
        #expect(
            ChannelListSheet.detail(for: PlaylistAccess(address: " tv.example.com:8080 ")) == "tv.example.com"
        )
        #expect(
            ChannelListSheet.detail(for: PlaylistAccess(kind: .m3u, address: "https://lists.example/a.m3u"))
                == "lists.example")
    }
}
