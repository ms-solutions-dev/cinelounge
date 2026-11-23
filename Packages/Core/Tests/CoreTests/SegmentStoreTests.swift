import Foundation
import Testing

@testable import Core

/// The ring buffer from which AVFoundation is served.
@Suite("Segment store")
struct SegmentStoreTests {

    @Test("What was put in comes out")
    func roundTrip() {
        let store = SegmentStore()
        store.setHeader(Data([1, 2, 3]))
        let index = store.append(Data([4, 5]), duration: 2)

        #expect(store.headerData == Data([1, 2, 3]))
        #expect(store.segment(index) == Data([4, 5]))
    }

    /// **A channel runs for hours.** Whoever keeps every segment fills the memory in a
    /// quarter of an hour.
    @Test("The window drops old entries")
    func oldSegmentsAreDropped() {
        let store = SegmentStore()
        for value in 0..<(SegmentStore.windowSize + 5) {
            store.append(Data([UInt8(value % 256)]), duration: 2)
        }

        #expect(store.count == SegmentStore.windowSize)
        // The first five are gone, the numbering runs on anyway.
        #expect(store.segment(0) == nil)
        #expect(store.segment(4) == nil)
        #expect(store.segment(5) != nil)
    }

    /// Without continuous numbering the player would start from the beginning at every
    /// refill — the list must say where it stands.
    @Test("The playlist keeps counting when entries were dropped at the front")
    func playlistKeepsCounting() {
        let store = SegmentStore()
        store.setHeader(Data([0]))
        for _ in 0..<(SegmentStore.windowSize + 3) { store.append(Data([0]), duration: 2) }

        #expect(
            store.playlist(base: "http://127.0.0.1:9").contains("#EXT-X-MEDIA-SEQUENCE:3"))
    }

    /// **Only what has changed is built** (AP73, 2026-10-11): the player asks for the list
    /// at the pace of the target duration, and until then it was rebuilt under the lock
    /// every time.
    @Test("The playlist is only rebuilt on change")
    func listOnlyOnChange() {
        let store = SegmentStore()
        store.setHeader(Data([0]))
        for _ in 0..<3 { store.append(Data([0]), duration: 2) }
        let base = "http://127.0.0.1:9"

        let first = store.playlist(base: base)
        #expect(store.playlist(base: base) == first)
        #expect(store.playlist(base: base) == first)
        #expect(store.listBuilds == 1)

        store.append(Data([0]), duration: 2)
        let second = store.playlist(base: base)
        #expect(second != first)
        #expect(store.listBuilds == 2)

        store.markComplete()
        #expect(store.playlist(base: base).contains("#EXT-X-ENDLIST"))
        #expect(store.listBuilds == 3)
        // A different address is a different list.
        #expect(store.playlist(base: "http://127.0.0.1:10") != store.playlist(base: base))
        #expect(store.listBuilds == 5)
    }

    /// **The head stays.** Without it the decoder cannot start again after every discard.
    @Test("The header is never dropped")
    func headerSurvives() {
        let store = SegmentStore()
        store.setHeader(Data([9, 9, 9]))
        for _ in 0..<(SegmentStore.windowSize * 3) { store.append(Data([0]), duration: 2) }

        #expect(store.headerData == Data([9, 9, 9]))
    }

    /// **The head alone is not enough.** A list without a segment is formally valid, and
    /// the player accepts it — only to wait silently for content that it considers
    /// present.
    @Test("Only a store with header and content is ready")
    func readyNeedsBoth() {
        let store = SegmentStore()
        #expect(!store.isReady)

        store.setHeader(Data([1]))
        #expect(!store.isReady)

        store.append(Data([2]), duration: 2)
        #expect(store.isReady)
    }

    @Test("What never existed does not exist")
    func unknownSegmentIsNil() {
        #expect(SegmentStore().segment(99) == nil)
    }
}
