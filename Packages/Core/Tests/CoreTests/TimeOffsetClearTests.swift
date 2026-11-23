import Foundation
import Testing

@testable import Core

/// **The ring goes along with the halt of the session** (player check, V2, 2026-09-27).
///
/// Until then only the `deinit` of the ``TimeShiftRing`` cleared the disk. If something held the
/// session after the halt, a few hundred megabytes lay in the
/// cache until the next app launch — yet after the halt nobody requests a chunk anymore.
@Suite("Time offset: clearing on stop")
struct TimeOffsetClearTests {

    @Test("The download ledger clears its ring from disk and has no time offset afterwards")
    func downloadsClears() {
        let root = FileManager.default.temporaryDirectory.appending(path: "ring-\(UUID().uuidString)")
        defer { TimeShiftRing.sweep(root: root) }
        let ring = TimeShiftRing(root: root)
        let store = SegmentStore()
        store.setHeader(Data([1]))
        store.enableTimeShift(ring)
        for i in 0..<60 {
            store.append(Data(repeating: UInt8(i), count: 10), duration: 2, independent: true)
        }
        store.awaitOffload()
        #expect(store.timeShiftBytes > 0)
        #expect(FileManager.default.fileExists(atPath: ring.directory.path))

        store.clearTimeShift()
        store.awaitOffload()

        #expect(!FileManager.default.fileExists(atPath: ring.directory.path))
        #expect(!store.hasTimeShift)
        #expect(store.timeShiftBytes == 0)
    }

    @Test("The session's stop clears the ring — not only its end in memory")
    func holdClears() throws {
        let session = try LiveRemuxSession(
            source: try #require(URL(string: "http://sender.invalid/live/1.ts")), timeOffset: 1_000_000)
        #expect(session.hasTimeShift)
        session.stop()
        #expect(!session.hasTimeShift, "the session is still alive, the ring is gone anyway")
    }
}
