import Core
import Foundation
import Testing

@testable import ProfileKit

/// **Which channel lists a person sees** (on-device test build 1332, 2026-09-27, findings 1/3) —
/// the one calculation for TV and phone.
@Suite("Channel list window per profile")
struct ChannelListWindowTests {

    @Test("Without a profile all, a new profile none, otherwise exactly its own")
    func window() {
        var ledger = ProfileBook()
        #expect(ledger.channelListWindow(available: ["a", "b"]) == nil)

        var old = Profile(name: "Alt")
        old.create(.channelList(identifier: "a"))
        let fresh = Profile(name: "Neu")
        ledger.create(old)
        ledger.create(fresh)
        #expect(ledger.channelListWindow(available: ["a", "b"]) == ["a"])

        ledger.switchTo(zu: fresh.identifier)
        #expect(ledger.channelListWindow(available: ["a", "b"]) == [], "the new profile saw Y-IPTV")
    }

    /// **The valve:** After a provider move the list carries a new key, and
    /// the profile knows only the old one. Live should not vanish then.
    @Test("If the profile points only at vanished lists, the whole stock applies")
    func valve() {
        var ledger = ProfileBook()
        var max = Profile(name: "Max")
        max.create(.channelList(identifier: "alt-schluessel"))
        ledger.create(max)
        #expect(ledger.channelListWindow(available: ["neu-schluessel"]) == nil)
        #expect(ledger.channelListWindow(available: []) == ["alt-schluessel"])
    }

    /// **Only what the person manages goes upward** — until 2026-09-27 every sync pass wrote all
    /// of the device's lists, including the password, into every profile's zone, even a new or
    /// shared one.
    @Test("Only a profile's own lists go into its zone")
    func uploadOnlyOwn() {
        let all = ["a", "b"].map {
            ChannelListAccess(
                key: $0, name: $0, kind: .xtream, address: URL(string: "http://\($0)")!,
                user: $0, secret: "kennwort")
        }
        var old = Profile(name: "Alt")
        old.create(.channelList(identifier: "a"))
        #expect(ProfileCloud.ownLists(all, forItem: old).map(\.key) == ["a"])
        #expect(
            ProfileCloud.ownLists(all, forItem: Profile(name: "Neu")).isEmpty,
            "the new profile put Y-IPTV with its password into iCloud")
    }
}
