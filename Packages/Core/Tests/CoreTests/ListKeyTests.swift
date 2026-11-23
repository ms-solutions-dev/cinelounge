import Foundation
import Testing

@testable import Core

/// Tests the computed list key — **the condition for a state reaching a
/// second device** (AP42, 2026-09-21).
@Suite("List keys")
struct ListKeyTests {

    @Test("The same provider yields the same key on two devices")
    func sameProviderSameKey() {
        let livingRoom = Playlist(
            name: "Zuhause", kind: .xtream(server: URL(string: "http://panel.example")!, username: "max"))
        let kitchen = Playlist(
            name: "Küche", kind: .xtream(server: URL(string: "http://panel.example")!, username: "max"))

        #expect(livingRoom.id == kitchen.id)
        #expect(livingRoom.id == "xtream|panel.example|max")
    }

    @Test("The port is not part of it — a panel offers the same access on several")
    func suffixDoesNotCount() {
        let eighty = ListKey.forItem(
            .xtream(server: URL(string: "http://panel.example")!, username: "max"))
        let longerKey = ListKey.forItem(
            .xtream(server: URL(string: "http://panel.example:25461")!, username: "max"))

        #expect(eighty == longerKey)
    }

    @Test("Upper case is the same access")
    func spellingDoesNotCount() {
        let lowercased = ListKey.forItem(
            .xtream(server: URL(string: "http://panel.example")!, username: "max"))
        let large = ListKey.forItem(
            .xtream(server: URL(string: "http://PANEL.Example")!, username: "Max"))

        #expect(lowercased == large)
    }

    @Test("A different domain is a move, not a coincidence")
    func otherDomainOtherKey() {
        let old = ListKey.forItem(
            .xtream(server: URL(string: "http://alt.example")!, username: "max"))
        let fresh = ListKey.forItem(
            .xtream(server: URL(string: "http://neu.example")!, username: "max"))

        #expect(old != fresh)
    }

    /// **The reason why the address is not taken raw.** The key ends up in
    /// files, in a backup and later in iCloud.
    @Test("The password of an M3U URL is not in the key")
    func passwordIsNotIncluded() {
        let url = URL(
            string: "http://panel.example/get.php?username=max&password=geheim123&type=m3u_plus")!
        let key = ListKey.forItem(.m3u(url))

        #expect(!key.contains("geheim123"))
        #expect(key == "m3u|panel.example|max")
    }

    @Test("An M3U file without a user is distinguished by its path")
    func m3uWithoutUser() {
        let single = ListKey.forItem(.m3u(URL(string: "http://example.org/liste.m3u")!))
        let other = ListKey.forItem(.m3u(URL(string: "http://example.org/zweite.m3u")!))

        #expect(single == "m3u|example.org|/liste.m3u")
        #expect(single != other)
    }

    @Test("The server's channel management has exactly one key")
    func jellyfinIsOne() {
        #expect(ListKey.forItem(.jellyfinLiveTV) == "jellyfin")
    }

    @Test("A supplied identifier beats the computed one")
    func suppliedIdentifierWins() {
        let list = Playlist(
            id: "alte-zufallszahl", name: "Alt",
            kind: .xtream(server: URL(string: "http://panel.example")!, username: "max"))

        #expect(list.id == "alte-zufallszahl")
        #expect(list.key == "xtream|panel.example|max")
    }

    @Test("A random number is recognizable as legacy data")
    func randomNumberIsNotComputed() {
        #expect(!ListKey.isComputed(UUID().uuidString))
        #expect(ListKey.isComputed("xtream|panel.example|max"))
        #expect(ListKey.isComputed("m3u|example.org|/liste.m3u"))
        #expect(ListKey.isComputed("jellyfin"))
    }
}
