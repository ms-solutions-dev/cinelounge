import Foundation
import Testing

@testable import Core

/// Which channel opens when you press "Live".
@Suite("Last watched channel")
struct LiveMemoryTests {

    /// The in-memory store — the test should leave nothing behind.
    typealias Memory = InMemoryStore

    static func channel(_ id: String, playlist: String = "a") -> Channel {
        Channel(
            id: id, name: id, streamURL: URL(string: "http://x/\(id)")!, playlistID: playlist)
    }

    @Test("Remembered per list")
    func remembersPerPlaylist() {
        let store = Memory()
        LiveMemory.remember("k1", of: "tr", ledger: store)
        LiveMemory.remember("k2", of: "de", ledger: store)

        #expect(LiveMemory.lastChannel(of: "tr", ledger: store) == "k1")
        #expect(LiveMemory.lastChannel(of: "de", ledger: store) == "k2")
    }

    /// **Whoever switches between two providers wants to continue in both where
    /// they were.** A shared memory led to the wrong list on every
    /// switch.
    @Test("A list without a memory of its own takes the general one")
    func fallsBackToTheGeneralOne() {
        let store = Memory()
        LiveMemory.remember("k1", of: "tr", ledger: store)

        // "de" has never been on — better yesterday's channel than the first.
        #expect(LiveMemory.lastChannel(of: "de", ledger: store) == "k1")
        // And asked without a list, the same applies.
        #expect(LiveMemory.lastChannel(of: nil, ledger: store) == "k1")
    }

    @Test("Without any memory there is nothing to resume")
    func nothingRemembered() {
        #expect(LiveMemory.lastChannel(of: "tr", ledger: Memory()) == nil)
    }

    /// **Without a memory the first of the catalog** and not "nothing": The
    /// very first time there is nothing to remember, and an empty screen
    /// would be the worst answer to a press on "Live".
    @Test("The first time the first channel opens")
    func opensTheFirstOne() {
        let stock = [Self.channel("a"), Self.channel("b")]
        #expect(LiveMemory.opening(stock, remembered: nil)?.id == "a")
    }

    @Test("The remembered channel opens if it still exists")
    func opensTheRememberedOne() {
        let stock = [Self.channel("a"), Self.channel("b")]
        #expect(LiveMemory.opening(stock, remembered: "b")?.id == "b")
    }

    /// List changed, group hidden — then the channel no longer exists,
    /// and there is nothing to continue.
    @Test("A vanished channel falls back to the first")
    func vanishedChannelFallsBack() {
        let stock = [Self.channel("a"), Self.channel("b")]
        #expect(LiveMemory.opening(stock, remembered: "gone")?.id == "a")
        #expect(LiveMemory.opening([], remembered: "a") == nil)
    }

    // MARK: - Der Wechsel im Player

    /// **The finding of 2026-09-02** (when another channel is opened and then
    /// the user leaves and re-enters, the app does not recognise that another
    /// channel had been opened — it always lands on the last sports channel).
    ///
    /// The path to it: The schedule remembers the channel the player was
    /// opened with. Whoever then opens the overlay **in** the player and
    /// switches there passed none of the four remembering places — all
    /// four lay before the player. Remembering now goes through the running
    /// address, and that is the one place where a switch takes place.
    @Test("The switch in the player carries the memory forward")
    func rememberingWhilePlaying() {
        let store = Memory()
        let stock = [Self.channel("a"), Self.channel("b")]
        LiveMemory.remember("a", of: "a", ledger: store)

        let switched = LiveMemory.remember(playing: stock[1].streamURL, in: stock, ledger: store)

        #expect(switched?.id == "b")
        #expect(LiveMemory.lastChannel(of: "a", ledger: store) == "b")
    }

    /// **Via ``Channel/plays(_:)`` and not via an equality test.**
    /// On fallback to the raw stream the running address differs from the
    /// registered one — an equality test would then not find the channel and
    /// the memory would stay put without anyone noticing.
    @Test("The raw stream is also assigned to the channel")
    func rememberingTheRawStream() {
        let store = Memory()
        let channel = Channel(
            id: "b", name: "b", streamURL: URL(string: "http://x/b.m3u8")!, playlistID: "a")

        let switched = LiveMemory.remember(
            playing: URL(string: "http://x/b.ts")!, in: [channel], ledger: store)

        #expect(switched?.id == "b")
        #expect(LiveMemory.lastChannel(of: "a", ledger: store) == "b")
    }

    /// If the address belongs to no channel of the catalog, **nothing** is
    /// remembered: A memory of something the catalog does not know would lead
    /// nowhere on the next open.
    @Test("A foreign address does not erase the memory")
    func unknownURLKeepsTheMemory() {
        let store = Memory()
        let stock = [Self.channel("a")]
        LiveMemory.remember("a", of: "a", ledger: store)

        let switched = LiveMemory.remember(
            playing: URL(string: "http://elsewhere/x")!, in: stock, ledger: store)

        #expect(switched == nil)
        #expect(LiveMemory.lastChannel(of: "a", ledger: store) == "a")
    }
}
