import Core
import Foundation
import Testing

@testable import PortalKit

/// **Several levels, also failures** (AP74, 2026-10-11) — see ``LayerSlot``.
@Suite("The level slot (AP74)")
struct LevelSlotTests {

    struct ServerError: Error {}

    @Test("Several levels coexist, the oldest is dropped when the slot is full")
    func multipleLevels() {
        var slot = LayerSlot()
        let now = Date()
        for n in 0..<(LayerSlot.slots + 2) {
            slot.memorize(PortalTier(items: []), forItem: "ebene-\(n)", now: now)
        }
        #expect(slot.count == LayerSlot.slots)
        #expect(slot.entry(forItem: "ebene-0", now: now) == nil)
        #expect(slot.entry(forItem: "ebene-1", now: now) == nil)
        guard case .level = slot.entry(forItem: "ebene-2", now: now) else {
            Issue.record("level 2 is missing")
            return
        }
        guard case .level = slot.entry(forItem: "ebene-\(LayerSlot.slots + 1)", now: now)
        else {
            Issue.record("youngest level is missing")
            return
        }
    }

    @Test("A level is valid for 20 s, a failure for 5 s")
    func deadlines() {
        var slot = LayerSlot()
        let now = Date()
        slot.memorize(PortalTier(items: []), forItem: "a", now: now)
        slot.memorize(failure: ServerError(), forItem: "b", now: now)

        guard case .level = slot.entry(forItem: "a", now: now + 19) else {
            Issue.record("level gone after 19 s")
            return
        }
        #expect(slot.entry(forItem: "a", now: now + 21) == nil)
        guard case .failure(let error) = slot.entry(forItem: "b", now: now + 4) else {
            Issue.record("failure gone after 4 s")
            return
        }
        #expect(error is ServerError)
        #expect(slot.entry(forItem: "b", now: now + 6) == nil)
    }

    @Test("A success replaces the failure of the same level, forgetting clears everything")
    func replaceAndForget() {
        var slot = LayerSlot()
        let now = Date()
        slot.memorize(failure: ServerError(), forItem: "a", now: now)
        slot.memorize(PortalTier(items: []), forItem: "a", now: now)
        #expect(slot.count == 1)
        guard case .level = slot.entry(forItem: "a", now: now) else {
            Issue.record("failure stayed")
            return
        }
        slot.forget()
        #expect(slot.count == 0)
        #expect(slot.entry(forItem: "a", now: now) == nil)
    }
}
