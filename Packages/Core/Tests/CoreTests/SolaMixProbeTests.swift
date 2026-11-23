import Foundation
import Testing

@testable import Core

/// Measuring probe for the on-device finding "Sola Sport Mix FHD: 37 MB received, 0
/// segments cut" (2026-08-16) — the real recording through the real remuxer. Runs only
/// with `CINELOUNGE_TS` on a .ts file.
@Suite("Sola mix probe")
struct SolaMixProbeTests {

    @Test("The real capture must yield segments")
    func realCaptureCutsPieces() async throws {
        guard let path = ProcessInfo.processInfo.environment["CINELOUNGE_TS"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))

        let store = SegmentStore(label: "Probe", logsProduction: false)
        let remuxer = TransportRemuxer(store: store)
        var offset = 0
        while offset < data.count {
            let end = min(offset + 65536, data.count)
            remuxer.feed(data.subdata(in: offset..<end))
            offset = end
        }
        await remuxer.finish()

        print(
            "Probe: \(store.count) segments, \(store.seconds)s, error: \(String(describing: remuxer.writerFailure))"
        )
        print(
            "Probe: inventory \(remuxer.inventory.streams.map { "\($0.kind)@\($0.pid)" }.joined(separator: ", "))"
        )
        #expect(store.count > 0, "something must be cut from 3 MB of a real stream")
    }
}
