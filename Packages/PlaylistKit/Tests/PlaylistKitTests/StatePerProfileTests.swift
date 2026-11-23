import Core
import Foundation
import Testing

@testable import PlaylistKit

/// **The promise of AP42** (2026-09-21): two profiles on one TV have separate
/// Xtream state, separate favorites and a separate last channel.
///
/// What is tested goes through the three readers and not at ``Core/StillLedger`` itself — exactly
/// there lay the bug: the book could have been kept per person before; nobody
/// read from it. Here therefore stands the path the app takes.
///
/// **Via ``Core/ProfilePointer/als(_:_:)`` and not via the process-wide pointer.** The
/// first draft switched it and switched it back afterwards — and thereby turned a test red
/// in a completely different file that happened to run alongside.
@Suite("State per profile")
@MainActor
struct StatePerProfileTests {

    /// **The finding that triggered AP42**, in one line: whoever watched after the child
    /// carried on where the child had stopped.
    @Test("The last watched channel belongs to the person")
    func lastChannelPerProfile() {
        let ledger = InMemoryStore()

        ProfilePointer.als("eltern") { LiveMemory.remember("l#xtream#1", of: "l", ledger: ledger) }
        ProfilePointer.als("kind") { LiveMemory.remember("l#xtream#9", of: "l", ledger: ledger) }

        ProfilePointer.als("eltern") {
            #expect(LiveMemory.lastChannel(of: "l", ledger: ledger) == "l#xtream#1")
        }
        ProfilePointer.als("kind") {
            #expect(LiveMemory.lastChannel(of: "l", ledger: ledger) == "l#xtream#9")
        }
    }

    @Test("“Continue Watching” shows the person's started movies")
    func startedMoviesPerProfile() async {
        let ledger = InMemoryStore()

        await ProfilePointer.als("eltern") {
            await VODMemory(store: ledger).setPosition(600, of: 5400, for: "l#movie#7")
        }
        await ProfilePointer.als("kind") {
            await VODMemory(store: ledger).setPosition(120, of: 3600, for: "l#movie#9")
        }

        await ProfilePointer.als("eltern") {
            let pending = await VODMemory(store: ledger).resumableWithoutProfile(limit: 10)
            #expect(pending == ["l#movie#7"])
        }
        await ProfilePointer.als("kind") {
            let pending = await VODMemory(store: ledger).resumableWithoutProfile(limit: 10)
            #expect(pending == ["l#movie#9"])
        }
    }

    @Test("The channel favorites belong to the person")
    func favoritesPerProfile() {
        let ledger = InMemoryStore()
        let channels = Channel(
            id: "l#x#1", name: "Das Nordlicht HD", streamURL: URL(string: "http://s/1.ts")!,
            playlistID: "l")

        ProfilePointer.als("eltern") {
            let catalog = PlaylistStore(
                store: InMemoryStore(), secrets: InMemoryStore(), ledger: ledger)
            catalog.setFavorite(true, for: channels)
        }

        ProfilePointer.als("kind") {
            let catalog = PlaylistStore(
                store: InMemoryStore(), secrets: InMemoryStore(), ledger: ledger)
            #expect(!catalog.isFavorite(channels))
        }

        ProfilePointer.als("eltern") {
            let catalog = PlaylistStore(
                store: InMemoryStore(), secrets: InMemoryStore(), ledger: ledger)
            #expect(catalog.isFavorite(channels))
        }
    }

    /// **Without a pointer the device counts** — the rule from AP41. An empty pointer means "not
    /// set up yet" and not "nobody": before the first setup the
    /// TV must still know where it stopped.
    @Test("Without a pointer the device base applies")
    func withoutPointerDeviceApplies() {
        let ledger = InMemoryStore()

        ProfilePointer.als(nil) {
            LiveMemory.remember("l#xtream#1", of: "l", ledger: ledger)
            #expect(LiveMemory.lastChannel(of: "l", ledger: ledger) == "l#xtream#1")
        }

        #expect(StillLedger.read(from: ledger).state.lastChannel["l"] == "l#xtream#1")
        // And a profile's book stays untouched by it.
        #expect(StillLedger.read(from: ledger, forItem: "eltern") == StillLedger())
    }

    /// **The profile switch must reread the favorites.** This catalog lives as long as
    /// the app; without the reread the favorites row would keep showing those of the
    /// previous viewer after the switch — and the next press on a star would write them into the book of the
    /// new one.
    @Test("After the switch the catalog rereads the favorites")
    func switchRereads() {
        let ledger = InMemoryStore()
        let channels = Channel(
            id: "l#x#1", name: "Das Nordlicht HD", streamURL: URL(string: "http://s/1.ts")!,
            playlistID: "l")

        let catalog = PlaylistStore(store: InMemoryStore(), secrets: InMemoryStore(), ledger: ledger)
        ProfilePointer.als("eltern") {
            catalog.setFavorite(true, for: channels)
        }

        ProfilePointer.als("kind") {
            catalog.loadFavorites()
            #expect(!catalog.isFavorite(channels))
        }
    }
}
