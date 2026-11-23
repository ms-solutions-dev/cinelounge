import Foundation
import Testing

@testable import Core

/// The disk ring and its interplay with the downloads (AP9).
@Suite("The disk ring")
struct TimeShiftRingTests {

    private func freshRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "ring-\(UUID().uuidString)")
    }

    @Test("What goes in comes back — and the oldest is evicted at the limit")
    func storesAndEvicts() {
        let ring = TimeShiftRing(root: freshRoot(), capacity: 250)
        for i in 0..<4 {
            ring.store(
                index: i, data: Data(repeating: UInt8(i), count: 100), duration: 0.5, independent: true,
                period: 0)
        }
        // 400 bytes at a limit of 250: the first two are gone.
        #expect(ring.count == 2)
        #expect(ring.firstIndex == 2)
        #expect(ring.bytes == 200)
        #expect(ring.data(for: 0) == nil)
        #expect(ring.data(for: 3) == Data(repeating: 3, count: 100))
        #expect(ring.seconds == 1.0)
        let folder = ring.directory
        ring.removeAll()
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test("The buffer spills out, the playlist leads with the ring, the segment is readable")
    func storeSpillsIntoRing() {
        let root = freshRoot()
        let store = SegmentStore()
        store.setHeader(Data([1]))
        store.enableTimeShift(TimeShiftRing(root: root))
        // Beyond the window: 20 chunks and 40 s must both trip.
        for i in 0..<60 {
            store.append(Data(repeating: UInt8(i), count: 10), duration: 2, independent: true)
        }
        // The offloading writes on its own queue — see `SegmentStore.inFlight`.
        store.awaitOffload()
        #expect(store.count <= SegmentStore.windowSize + 1)
        #expect(store.timeShiftSeconds > 0)
        #expect(store.segment(0) == Data(repeating: 0, count: 10), "read from the ring")
        let list = store.playlist(base: "http://h")
        #expect(list.contains("#EXT-X-MEDIA-SEQUENCE:0"))
        #expect(list.contains("segment0.m4s"))
        #expect(list.contains("segment59.m4s"))
        TimeShiftRing.sweep(root: root)
        #expect(TimeShiftRing.usage(root: root) == 0)
    }
}
