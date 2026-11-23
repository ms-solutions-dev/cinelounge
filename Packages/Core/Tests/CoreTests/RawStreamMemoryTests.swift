import Foundation
import Testing

@testable import Core

/// The memo list of the channels that cannot cope with the playlist — and its way to
/// heal.
///
/// Until 2026-08-15 this memory could only grow, and that was a sentence for life: Telve 1
/// HEVC was on it once, from then on always went via the raw stream — and when the
/// provider let exactly this path die, the channel was permanently dead, although
/// the remuxer could long since have carried the playlist.
@Suite("The raw-stream memory")
struct RawStreamMemoryTests {

    private let channel = URL(string: "http://provider/live/1234.m3u8")!

    @Test("Forgetting removes the entry — under both extensions")
    func forgetRemovesTheEntry() {
        var memory = RawStreamMemory()
        memory.remember(channel)
        #expect(memory.needsRawStream(channel))

        // The key is the address without extension: remembered via `.m3u8`, forgotten via
        // `.ts` — it is the same channel.
        memory.forget(URL(string: "http://provider/live/1234.ts")!)

        #expect(!memory.needsRawStream(channel))
    }

    @Test("Forgetting an unknown entry leaves the others in place")
    func forgettingAStrangerKeepsTheRest() {
        var memory = RawStreamMemory()
        memory.remember(channel)

        memory.forget(URL(string: "http://provider/live/9999.ts")!)

        #expect(memory.needsRawStream(channel))
        #expect(memory.count == 1)
    }

    @Test("A healed memory also disappears from the store")
    func healedMemoryLeavesTheStore() throws {
        let store = InMemoryStore()
        var memory = RawStreamMemory()
        memory.remember(channel)
        memory.save(to: store)

        memory.forget(channel)
        memory.save(to: store)

        // Empty means removed, not left behind as an empty row — the next session would
        // otherwise load an address made of nothing.
        #expect(RawStreamMemory.load(from: store).count == 0)
    }
}
