import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import Core

/// **The own piece writer, and whether AVFoundation believes it.**
///
/// Writing the boxes by hand is one half; the other is that Apple's reader accepts
/// them — on an error it says only a number, and the number says nothing about which
/// byte was wrong. That is why it is not just counted here but read: first as a file,
/// then as playback.
@Suite("The custom piece writer")
struct CMAFWriterTests {

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var segments: [CMAFWriter.Segment] = []
        func add(_ segment: CMAFWriter.Segment) {
            lock.lock()
            defer { lock.unlock() }
            segments.append(segment)
        }
        var all: [CMAFWriter.Segment] {
            lock.lock()
            defer { lock.unlock() }
            return segments
        }
    }

    private func fixture() throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/hevc-live-long", withExtension: "ts"))
        return try Data(contentsOf: url)
    }

    /// Runs the test material through repackager and writer.
    private func write(fragment: CMTime = CMAFWriter.fragmentDuration) throws -> [CMAFWriter.Segment] {
        let collector = Collector()
        let remuxer = TransportRemuxer(
            makeSink: { video, audio in
                try CMAFWriter(format: video, audioFormat: audio, fragmentDuration: fragment) {
                    collector.add($0)
                }
            })
        remuxer.feed(try fixture())
        remuxer.flushSegment()
        return collector.all
    }
}
