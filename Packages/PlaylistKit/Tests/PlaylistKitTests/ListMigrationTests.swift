import Core
import Foundation
import Testing

@testable import PlaylistKit

/// Checks that the path from the random number to the computed key **loses nothing**
/// (AP42, 2026-09-21).
///
/// The move touches three stores that know nothing of each other: the entry including account,
/// the most recently watched channel and the started movies. Forgetting one of them goes
/// unnoticed — it looks as if the viewer had never watched TV.
@Suite("List migration")
@MainActor
struct ListMigrationTests {

    private let panel = URL(string: "http://panel.example")!

    private func catalog() -> (PlaylistStore, InMemoryStore, InMemoryStore, InMemoryStore) {
        let listen = InMemoryStore()
        let credentials = InMemoryStore()
        let state = InMemoryStore()
        return (PlaylistStore(store: listen, secrets: credentials, ledger: state), listen, credentials, state)
    }

    private func oldList(_ identifier: String) -> Playlist {
        Playlist(id: identifier, name: "Zuhause", kind: .xtream(server: panel, username: "max"))
    }

    // MARK: - Der ganze Weg

    @Test("The credentials move along — otherwise the list is signed out after the move")
    func accessMovesAlong() {
        let (catalog, _, _, state) = catalog()
        catalog.add(oldList("zufall-1"), password: "geheim")

        ListMigration.perform(in: catalog, ledger: state)

        let fresh = "xtream|panel.example|max"
        #expect(catalog.playlists.map(\.id) == [fresh])
        #expect(catalog.password(for: fresh) == "geheim")
        #expect(catalog.credentials(for: "zufall-1") == nil)
    }

    @Test("The last watched channel moves along — key and value")
    func channelMovesAlong() {
        let (catalog, _, _, state) = catalog()
        catalog.add(oldList("zufall-1"))
        LiveMemory.remember("zufall-1#xtream#4711", of: "zufall-1", ledger: state)

        ListMigration.perform(in: catalog, ledger: state)

        let fresh = "xtream|panel.example|max"
        #expect(LiveMemory.lastChannel(of: fresh, ledger: state) == "\(fresh)#xtream#4711")
        // The general state ("most recent overall") pointed at the same list.
        #expect(LiveMemory.lastChannel(of: nil, ledger: state) == "\(fresh)#xtream#4711")
    }

    @Test("The started movies move along")
    func moviesMoveAlong() async {
        let (catalog, _, _, state) = catalog()
        catalog.add(oldList("zufall-1"))

        let memory = VODMemory(store: state)
        await memory.setPosition(600, of: 5400, for: "zufall-1#movie#88#mkv")

        ListMigration.perform(in: catalog, ledger: state)

        // Freshly read, because the move touches the store and not the actor.
        let after = VODMemory(store: state)
        let pending = await after.resumableWithoutProfile(limit: 10)
        #expect(pending == ["xtream|panel.example|max#movie#88#mkv"])
    }

    // MARK: - The cases in which nothing may happen

    @Test("An identifier that was already computed stays untouched")
    func computedStays() {
        let (catalog, _, _, state) = catalog()
        catalog.add(Playlist(name: "Zuhause", kind: .xtream(server: panel, username: "max")))

        #expect(ListMigration.perform(in: catalog, ledger: state) == 0)
        #expect(catalog.playlists.map(\.id) == ["xtream|panel.example|max"])
    }

    /// **The same provider twice.** Merging would be a decision about
    /// which name and which order wins — and nobody makes that here.
    @Test("An occupied key leaves the second list alone")
    func occupiedKeyIsLeftAlone() {
        let (catalog, _, _, state) = catalog()
        catalog.add(Playlist(name: "Zuhause", kind: .xtream(server: panel, username: "max")))
        catalog.add(oldList("zufall-1"))
        LiveMemory.remember("zufall-1#xtream#4711", of: "zufall-1", ledger: state)

        #expect(ListMigration.perform(in: catalog, ledger: state) == 0)
        #expect(catalog.playlists.map(\.id) == ["xtream|panel.example|max", "zufall-1"])
        // **The state stays with the old one.** Moved, it would sit on top of the other list's.
        #expect(LiveMemory.lastChannel(of: "zufall-1", ledger: state) == "zufall-1#xtream#4711")
    }

    // MARK: - Der Anbieter-Umzug

    @Test("New domain, same user: the state moves along")
    func providerMigration() {
        let (catalog, _, _, state) = catalog()
        catalog.add(Playlist(name: "Zuhause", kind: .xtream(server: panel, username: "max")))
        let old = "xtream|panel.example|max"
        LiveMemory.remember("\(old)#xtream#4711", of: old, ledger: state)

        catalog.update(old, kind: .xtream(server: URL(string: "http://neu.example")!, username: "max"))
        #expect(ListMigration.perform(in: catalog, ledger: state) == 1)

        let fresh = "xtream|neu.example|max"
        #expect(catalog.playlists.map(\.id) == [fresh])
        #expect(LiveMemory.lastChannel(of: fresh, ledger: state) == "\(fresh)#xtream#4711")
    }
}
