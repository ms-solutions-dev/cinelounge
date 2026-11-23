import Core
import Foundation
import Testing

@testable import PlaylistKit

/// Tests the path from the old data into the position ledger (AP42 · row 5, 2026-09-21).
///
/// **Whatever goes wrong here, the viewer notices immediately and cannot undo it:**
/// "Continue Watching" is empty, the favorites are gone, the TV opens the first channel
/// of the list. So what **must not** happen is also tested — a second run
/// that replaces a grown state with the old one.
@Suite("State takeover")
struct StateTransferTests {

    /// The old data, as a device from 2026-09-20 has it in the Keychain.
    private func oldDevice() -> InMemoryStore {
        let old = InMemoryStore()
        try? old.set(
            """
            {"zufall-1#movie#7":{"position":600,"duration":5400,"watched":false,\
            "favorite":true,"titel":"Stille","art":"movie","bild":"p1"}}
            """, for: VODMemory.oldKey)
        try? old.set("zufall-1#xtream#4711", for: "live.lastChannel.zufall-1")
        try? old.set("zufall-1#xtream#4711", for: "live.lastChannel")
        try? old.set(#"["das erste hd","zinne hd"]"#, for: PlaylistStore.favoritesKey)
        return old
    }

    @Test("All three dictionaries arrive")
    func allThreeArrive() {
        let ledger = InMemoryStore()

        #expect(StateTransfer.fromDevice(listen: ["zufall-1"], from: oldDevice(), in: ledger))

        let state = StillLedger.read(from: ledger).state
        #expect(state.titlePositions["zufall-1#movie#7"]?.location == 600)
        #expect(state.titlePositions["zufall-1#movie#7"]?.favorite == true)
        #expect(state.titlePositions["zufall-1#movie#7"]?.title == "Stille")
        #expect(state.lastChannel["zufall-1"] == "zufall-1#xtream#4711")
        #expect(state.lastChannel[""] == "zufall-1#xtream#4711")
        #expect(state.channelFavorites == ["das erste hd", "zinne hd"])
    }

    /// **What arrives here is no action of the viewer but a move.** Booked as
    /// events, hundreds of them would have gone out at the first sync (AP43) as fresh
    /// messages and overwritten more recent state of another device there.
    @Test("The takeover does not fill the outbox")
    func noOutgoingMail() {
        let ledger = InMemoryStore()
        StateTransfer.fromDevice(listen: ["zufall-1"], from: oldDevice(), in: ledger)

        #expect(StillLedger.read(from: ledger).journal.isEmpty)
    }

    /// **A rollback to the previous version must find everything unchanged** (AP48).
    @Test("The old catalog stays")
    func legacyCatalogStays() {
        let old = oldDevice()
        StateTransfer.fromDevice(listen: ["zufall-1"], from: old, in: InMemoryStore())

        #expect((try? old.value(for: VODMemory.oldKey)) != nil)
        #expect((try? old.value(for: "live.lastChannel.zufall-1")) == "zufall-1#xtream#4711")
        #expect((try? old.value(for: PlaylistStore.favoritesKey)) != nil)
    }

    @Test("A second run does not replace a grown state")
    func secondRunLeavesAlone() {
        let ledger = InMemoryStore()
        StateTransfer.fromDevice(listen: ["zufall-1"], from: oldDevice(), in: ledger)

        var grown = StillLedger.read(from: ledger)
        grown.record(.senderGewaehlt(list: "zufall-1", channels: "zufall-1#xtream#9"))
        grown.write(in: ledger)

        #expect(!StateTransfer.fromDevice(listen: ["zufall-1"], from: oldDevice(), in: ledger))
        #expect(
            StillLedger.read(from: ledger).state.lastChannel["zufall-1"] == "zufall-1#xtream#9")
    }

    @Test("A device without an old catalog gets no empty ledger")
    func emptyDevice() {
        let ledger = InMemoryStore()

        #expect(!StateTransfer.fromDevice(listen: ["a"], from: InMemoryStore(), in: ledger))
        #expect((try? ledger.value(for: StillLedger.key)) == nil)
    }

    /// **A list's channel lay under a key of its own**, and a
    /// Keychain store cannot be paged through. Whoever does not pass the lists along
    /// gets only the general state.
    @Test("Without the list identifiers the channel per list stays put")
    func withoutListsOnlyTheGeneralOne() {
        let ledger = InMemoryStore()
        StateTransfer.fromDevice(listen: [], from: oldDevice(), in: ledger)

        let state = StillLedger.read(from: ledger).state
        #expect(state.lastChannel[""] == "zufall-1#xtream#4711")
        #expect(state.lastChannel["zufall-1"] == nil)
    }

    // MARK: - Clearing (AP48, decision 2 of 2026-09-25)

    @Test("Clearing happens only once the base is in place — and then all three")
    func cleansUpAfterTransfer() {
        let old = oldDevice()
        let ledger = InMemoryStore()
        #expect(StateTransfer.clearLegacyCatalog(listen: ["zufall-1"], from: old, in: ledger).isEmpty)
        #expect((try? old.value(for: VODMemory.oldKey)) != nil)

        StateTransfer.fromDevice(listen: ["zufall-1"], from: old, in: ledger)
        let cleaned = StateTransfer.clearLegacyCatalog(listen: ["zufall-1"], from: old, in: ledger)
        #expect(cleaned.count == 4)
        for key in cleaned { #expect((try? old.value(for: key)) == nil) }
    }

    /// **Finding 7 of the counter-check, strand C.** If something was already in the base,
    /// ``StateTransfer/fromDevice(listen:from:in:)`` wrote nothing — and the clearing took the
    /// non-empty base as proof and deleted the started films that had never
    /// arrived.
    @Test("A base that already carried something else does not vouch for the old movies")
    func evidencePerKey() {
        let old = oldDevice()
        let ledger = InMemoryStore()
        var base = StillLedger()
        base.record(.senderfavorit(key: "zinne hd", true))
        base.write(in: ledger)

        #expect(!StateTransfer.fromDevice(listen: ["zufall-1"], from: old, in: ledger))
        let cleaned = StateTransfer.clearLegacyCatalog(listen: ["zufall-1"], from: old, in: ledger)

        #expect(!cleaned.contains(VODMemory.oldKey), "the movies were never in the base")
        #expect((try? old.value(for: VODMemory.oldKey)) != nil)
        #expect(!cleaned.contains(PlaylistStore.favoritesKey), "“das erste hd” is missing in the base")
        #expect((try? old.value(for: "live.lastChannel.zufall-1")) != nil)
    }

    @Test("An unreadable dictionary stays put — it was never taken over")
    func unreadableStays() {
        let old = oldDevice()
        try? old.set("{kaputt", for: VODMemory.oldKey)
        let ledger = InMemoryStore()
        StateTransfer.fromDevice(listen: ["zufall-1"], from: old, in: ledger)
        let cleaned = StateTransfer.clearLegacyCatalog(listen: ["zufall-1"], from: old, in: ledger)
        #expect(!cleaned.contains(VODMemory.oldKey))
        #expect((try? old.value(for: VODMemory.oldKey)) == "{kaputt")
    }
}
