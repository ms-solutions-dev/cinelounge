import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import Core

/// **The chain from the channel to the finished segment store.**
///
/// The complete stretch on real material from "Telve 1 HEVC":
///
/// Transport stream → extract picture data → pictures with timestamps →
/// `CMSampleBuffer` → fragmented MP4 → segment store and playlist
///
/// That AVFoundation also **plays** the result is checked by
/// ``RemuxPlaybackTests`` — here it is about everything before that.
@Suite("End to end: from the channel into AVFoundation")
struct RemuxEndToEndTests {

    /// Fills a segment store from the test material.
    private func filledStore() async throws -> (SegmentStore, TransportStream.StreamKind) {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/hevc-live-long", withExtension: "ts")
        )
        let data = try Data(contentsOf: url)
        let video = try #require(TransportStream.inventory(from: data).video)

        let stream = TransportStream.elementaryStream(from: data, pid: video.pid)
        let sets = TransportStream.parameterSets(
            in: TransportStream.units(inElementaryStream: stream), kind: video.kind)
        let format = try SampleAssembly.formatDescription(from: sets, kind: video.kind)

        let store = SegmentStore()
        let writer = try FragmentWriter(format: format) { segment in
            if segment.isInitialization {
                store.setHeader(segment.data)
            } else {
                store.append(segment.data, duration: 2)
            }
        }

        for unit in TransportStream.accessUnits(from: data, pid: video.pid) {
            guard
                let sample = try? SampleAssembly.sampleBuffer(
                    for: unit, kind: video.kind, format: format)
            else { continue }
            _ = writer.append(sample)
        }
        await writer.finish()

        return (store, video.kind)
    }

    /// What the segment store does not have must be explicitly rejected. Whoever stays
    /// silent here lets AVFoundation run into the timeout — and the viewer sees an
    /// endless spinner instead of a message.
    @Test("An empty download ledger does not leave AVFoundation hanging")
    func emptyStoreFailsQuickly() async throws {
        let stream = try RemuxStream(store: SegmentStore(), isLive: false)
        try await stream.start()
        defer { stream.stop() }

        let url = try #require(URL(string: stream.base + "/segment0.m4s"))
        let (_, response) = try await URLSession.shared.data(from: url)

        #expect((response as? HTTPURLResponse)?.statusCode == 404)
    }
}
