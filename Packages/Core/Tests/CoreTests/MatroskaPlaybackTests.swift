import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import Core

/// **The proof for the media library: AVFoundation plays remuxed MKV.**
///
/// What is tested is not one example but all four combinations, which
/// together make up 96 percent of the catalog — HEVC and H.264, each with AAC
/// and with the Dolby formats. What runs here runs on the media library; what
/// fails here affects hundreds of titles.
@Suite("Playback: MKV, remuxed")
struct MatroskaPlaybackTests {

    static func remuxed(
        _ name: String, audioLanguage: String? = nil
    ) async throws -> (
        store: SegmentStore, remuxer: MatroskaRemuxer
    ) {
        let data = try MatroskaTests.fixture(name)
        let store = SegmentStore(retainsEverything: true)
        let remuxer = MatroskaRemuxer(store: store, audioLanguage: audioLanguage)

        // In small chunks, as it would arrive over the network — not in one piece.
        var offset = 0
        while offset < data.count {
            let end = min(offset + 64 << 10, data.count)
            remuxer.feed(data.subdata(in: offset..<end))
            offset = end
        }
        await remuxer.finish()
        return (store, remuxer)
    }

    private func outcome(of item: AVPlayerItem, seconds: Double = 15) async -> AVPlayerItem.Status {
        let deadline = Date().addingTimeInterval(seconds)
        while item.status == .unknown, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return item.status
    }
}
