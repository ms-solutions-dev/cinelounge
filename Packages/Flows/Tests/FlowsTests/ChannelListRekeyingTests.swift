import Core
import Foundation
import PlaylistKit
import ProfileKit
import Testing

@testable import Flows

/// iPad, 2026-09-29: A list entered before AP42 kept its random ID on the phone, and
/// Continue Watching from the other devices matched no list.
@MainActor
@Suite("Channel lists: re-keying on the phone")
struct ChannelListRekeyingTests {

    @Test("Random identifier becomes the list key, the profile points along")
    func rekey() throws {
        let ledgerStore = InMemoryStore()
        let catalog = PlaylistStore(
            store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore())
        let legacy = "35657D19-4FE3-46C7-8A84-91FB84B7EAF9"
        catalog.add(
            Playlist(
                id: legacy, name: "Anbieter",
                kind: .xtream(server: URL(string: "http://iptvhost.example:80")!, username: "AlexUser")),
            password: "secret")
        var ledger = ProfileBook()
        let alex = Profile(name: "Alex", credentials: [.channelList(identifier: legacy)])
        ledger.create(alex)
        ledger.write(in: ledgerStore)

        #expect(ChannelListView.rekey(catalog, ledgerStore: ledgerStore) == 1)

        let fresh = "xtream|iptvhost.example|alexuser"
        #expect(catalog.playlists.map(\.id) == [fresh])
        #expect(catalog.password(for: fresh) == "secret")
        let after = try #require(ProfileBook.read(from: ledgerStore).profile.first)
        #expect(after.channelLists.compactMap(\.channelListID) == [fresh])

        // A second pass finds nothing more.
        #expect(ChannelListView.rekey(catalog, ledgerStore: ledgerStore) == 0)
    }
}
