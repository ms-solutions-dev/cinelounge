import Core
import Foundation
import SourceProbe
import Testing

@testable import PlaylistKit

/// What is tested is the move that AP39 demands: **one** store, and whatever sits in the old
/// default Keychain service comes over exactly once.
///
/// The bug in question was silent for two months — entered lists
/// ended up in a service that the Live area never read from. Nothing threw, nothing
/// reported; all you saw was an empty channel list. That is why this suite does not test the
/// Keychain binding (which belongs to the device) but the rule above it.
@Suite("The channel lists have a store")
@MainActor
struct DeviceStoreTests {

    // MARK: - Hilfen

    private func m3u(_ id: String, _ name: String, address: String) -> Playlist {
        Playlist(id: id, name: name, kind: .m3u(URL(string: address)!))
    }

    private func xtream(_ id: String, _ name: String, user: String) -> Playlist {
        Playlist(
            id: id, name: name,
            kind: .xtream(server: URL(string: "http://anbieter.example")!, username: user))
    }

    /// Ordinary settings that no other checks see.
    private func store(_ name: String) -> UserDefaults {
        let store = UserDefaults(suiteName: "test.\(name).\(UUID().uuidString)")!
        return store
    }

    // MARK: - Bringing across

    @Test("What lies in the old service comes across with its password")
    func transfersWithPassword() {
        let old = PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore())
        old.add(xtream("a1", "Anbieter", user: "max"), password: "geheim")

        let fresh = PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore())
        let added = fresh.adopt(from: old)

        #expect(added == 1)
        #expect(fresh.playlists.map(\.name) == ["Anbieter"])
        // The password is the part a move loses most easily: it sits
        // in the second store and not in the list itself.
        #expect(fresh.password(for: "a1") == "geheim")
    }

    @Test("The same list does not come twice — address and user decide")
    func recognizesSameList() {
        // The same account, entered in both places: different ID, different
        // name, same address and same user.
        let old = PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore())
        old.add(xtream("alt", "Vom Telefon", user: "max"), password: "geheim")

        let fresh = PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore())
        fresh.add(xtream("hier", "Mein Anbieter", user: "max"), password: "geheim")

        #expect(fresh.adopt(from: old) == 0)
        // The visible catalog wins: the name in Settings stays.
        #expect(fresh.playlists.map(\.name) == ["Mein Anbieter"])
    }

    @Test("Another user on the same server is another list")
    func otherUserIsOtherList() {
        let old = PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore())
        old.add(xtream("alt", "Zweiter Zugang", user: "gast"), password: "anders")

        let fresh = PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore())
        fresh.add(xtream("hier", "Mein Anbieter", user: "max"), password: "geheim")

        #expect(fresh.adopt(from: old) == 1)
        #expect(fresh.playlists.count == 2)
        #expect(fresh.password(for: "alt") == "anders")
    }

    @Test("Favorites are merged, not replaced")
    func mergesFavorites() {
        let channels = { (name: String, list: String) in
            Channel(
                id: "\(list)#\(name)#1", name: name,
                streamURL: URL(string: "http://\(list)/1")!, playlistID: list)
        }

        let old = PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore())
        old.add(m3u("alt", "Vom Telefon", address: "http://server/alt.m3u"))
        old.setFavorite(true, for: channels("Das Nordlicht", "alt"))

        let fresh = PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: InMemoryStore())
        fresh.add(m3u("hier", "Meine Liste", address: "http://server/hier.m3u"))
        fresh.setFavorite(true, for: channels("ZINNE", "hier"))

        fresh.adopt(from: old)

        // Favourites apply across all lists — the local one must not be lost in the move,
        // and the one brought along should arrive.
        #expect(fresh.isFavorite(channels("ZINNE", "hier")))
        #expect(fresh.isFavorite(channels("Das Nordlicht", "alt")))
    }

    // MARK: - Genau einmal

    @Test("onDevice fetches the old catalog, but only the first time")
    func fetchesOnlyOnce() {
        let listen = InMemoryStore()
        let credentials = InMemoryStore()
        let oldLists = InMemoryStore()
        let oldCredentials = InMemoryStore()
        let settings = store("einmal")

        let old = PlaylistStore(store: oldLists, secrets: oldCredentials, ledger: InMemoryStore())
        old.add(m3u("alt", "Vom Telefon", address: "http://server/alt.m3u"))

        let first = PlaylistStore.onDevice(
            listen: listen, credentials: credentials,
            oldLists: oldLists, oldCredentials: oldCredentials, store: settings)
        #expect(first.playlists.map(\.name) == ["Vom Telefon"])

        // Whoever deletes it afterwards wants to be rid of it. Without a marker it would be back
        // at the next launch — the bug that a merge inevitably builds in at every
        // launch.
        //
        // **Via the ID from the catalog and not via the one brought along**, since
        // ``ListMigration`` comes along when adopting: the list is no longer called
        // "alt" here but carries its computed key. The UI deletes
        // via what it displays anyway; only this check knew the ID from
        // outside.
        first.remove(first.playlists[0].id)

        let second = PlaylistStore.onDevice(
            listen: listen, credentials: credentials,
            oldLists: oldLists, oldCredentials: oldCredentials, store: settings)
        #expect(second.playlists.isEmpty)
    }

    @Test("Without an old catalog nothing changes")
    func emptyOldService() {
        let listen = InMemoryStore()
        let credentials = InMemoryStore()
        let settings = store("leer")

        let catalog = PlaylistStore(store: listen, secrets: credentials, ledger: InMemoryStore())
        catalog.add(m3u("hier", "Meine Liste", address: "http://server/hier.m3u"))

        let onDevice = PlaylistStore.onDevice(
            listen: listen, credentials: credentials,
            oldLists: InMemoryStore(), oldCredentials: InMemoryStore(), store: settings)

        #expect(onDevice.playlists.map(\.name) == ["Meine Liste"])
    }
}

/// **Only one place opens the channel-list store** — the "done when" commitment of the
/// first AP39 line, as a check.
///
/// **Before, there were three**, and two of them used a different Keychain service than
/// the third: `MainView` read from `…cinelounge.playlists`,
/// `CineLoungeApp` and ``Takeover`` wrote to the default service. The guard is
/// the only form that pins this down permanently — a check on rules does not notice
/// that someone opens a second store elsewhere.
@Test("Outside PlaylistKit nobody builds an own list store")
func onlyOneStore() throws {
    var locations: [String] = []
    for file in try SourceText.files(in: .tvApp) + SourceText.files(in: .packets) {
        // The store itself and everything modelled on it do not count: `PlaylistKit`
        // holds the construction form, the checks hold in-memory stores.
        guard !file.path.contains("/PlaylistKit/"), !file.path.contains("/Tests/") else {
            continue
        }

        let content = file.content
        let withoutComments = content.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: " ")
        // Collapsed, because the construction may also span several lines.
        let compact = withoutComments.split(separator: " ", omittingEmptySubsequences: true)
            .joined()
        if compact.contains("PlaylistStore(store:") {
            locations.append(file.name)
        }
    }

    #expect(
        locations.isEmpty,
        """
        An own channel list store in: \(locations.sorted().joined(separator: ", ")). \
        Whoever needs one calls `PlaylistStore.onDevice()` — otherwise the viewer's lists \
        sit in two Keychain services, and they see only one of them.
        """
    )
}
