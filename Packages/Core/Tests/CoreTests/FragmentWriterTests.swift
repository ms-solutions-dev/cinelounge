import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import Core

/// **The proof that the packaging holds.**
///
/// Up to here it was shown that Apple's decoder understands our extracted data.
/// Here it is shown that something can be built from it that
/// AVFoundation can **play**: fragmented MP4, as HLS expects it.
///
/// Tested on 400 kilobytes of real material from "Telve 1 HEVC" — 24 frames, enough
/// for a complete segment.
@Suite("Writing fragmented MP4")
struct FragmentWriterTests {

    private func source() throws -> (Data, TransportStream.Elementary) {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/hevc-live-long", withExtension: "ts")
        )
        let data = try Data(contentsOf: url)
        let video = try #require(TransportStream.inventory(from: data).video)
        return (data, video)
    }

    /// Runs the whole path: transport stream in, fMP4 out.
    private func writeSegments() async throws -> [FragmentWriter.Segment] {
        let (data, video) = try source()
        let stream = TransportStream.elementaryStream(from: data, pid: video.pid)
        let sets = TransportStream.parameterSets(
            in: TransportStream.units(inElementaryStream: stream), kind: video.kind)
        let format = try SampleAssembly.formatDescription(from: sets, kind: video.kind)

        let collected = SegmentCollector()
        let writer = try FragmentWriter(format: format) { collected.add($0) }

        for unit in TransportStream.accessUnits(from: data, pid: video.pid) {
            guard
                let sample = try? SampleAssembly.sampleBuffer(
                    for: unit, kind: video.kind, format: format)
            else { continue }
            // Backpressure is not an error — try again on the next frame.
            _ = writer.append(sample)
        }
        await writer.finish()

        if let failure = writer.failure { throw failure }
        return collected.all
    }

    /// **The sync at the hopper** (user requirement 2026-08-15): "If audio
    /// is at second 4 and video at second 6, something is off" — exactly this
    /// calculation, as a pure function.
    @Test("The offset between picture and audio becomes a measurable number")
    func skewIsMeasurable() {
        // As long as both tracks have not delivered, there is no offset —
        // a silent channel is not a sync error.
        #expect(FragmentWriter.skew(video: 6, audio: nil) == nil)
        #expect(FragmentWriter.skew(video: nil, audio: 4) == nil)

        // Positive: the video leads. The Hollowmark case from the report.
        #expect(FragmentWriter.skew(video: 6, audio: 4) == 2)
        // Negative: the audio leads.
        #expect(FragmentWriter.skew(video: 4, audio: 6) == -2)

        // The thresholds with a gap between them, otherwise the message flickers.
        #expect(FragmentWriter.skewAllClear < FragmentWriter.skewThreshold)
    }
}

/// Collects the reported segments. The callback comes from a foreign thread,
/// hence with a lock instead of a bare field.
final class SegmentCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var segments: [FragmentWriter.Segment] = []

    func add(_ segment: FragmentWriter.Segment) {
        lock.lock()
        defer { lock.unlock() }
        segments.append(segment)
    }

    var all: [FragmentWriter.Segment] {
        lock.lock()
        defer { lock.unlock() }
        return segments
    }
}

extension Data {
    /// Whether an MP4 box of this name occurs. Box names are four
    /// ASCII characters directly after their length.
    func contains(boxName: String) -> Bool {
        guard let needle = boxName.data(using: .ascii) else { return false }
        return range(of: needle) != nil
    }
}
