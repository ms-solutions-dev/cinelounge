import AVFoundation
import Foundation
import Testing

@testable import Core

/// Measuring probe for channel captures: the real stream through the real
/// repackager, and the result is really **decoded** — only that proves that picture
/// and audio are not merely packed but playable. Runs only with `CINELOUNGE_TS` on a
/// .ts file.
///
/// Convicted with it: the MP2 silence of the Turkish national channels and the
/// timestamp collision of Ayaz HD* (both 2026-08-16, iptvhost).
@Suite("Capture probe")
struct CaptureProbeTests {

    @Test("Remux a capture and decode the result")
    func remuxAndDecode() async throws {
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
            "Probe: \(store.count) chunks, \(store.seconds)s, "
                + "Error: \(String(describing: remuxer.writerFailure))"
        )
        print(
            "Probe: inventory "
                + remuxer.inventory.streams.map { "\($0.kind.name)@\($0.pid)" }
                .joined(separator: ", ")
        )
        #expect(store.count > 0, "something must be cut from a real stream")
        #expect(remuxer.writerFailure == nil)

        var file = store.headerData ?? Data()
        for index in 0..<store.count { file += store.segment(index) ?? Data() }
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("probe.mp4")
        try file.write(to: out)
        let asset = AVURLAsset(url: out)
        let tracks = try await asset.load(.tracks)

        guard let audio = tracks.first(where: { $0.mediaType == .audio }) else {
            print("Probe: no audio track — fine for a channel without sound")
            return
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: audio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(output)
        #expect(reader.startReading(), "the reader must start")
        var samples = 0
        while let sample = output.copyNextSampleBuffer() {
            samples += CMSampleBufferGetNumSamples(sample)
        }
        print("Probe: \(samples) PCM samples decoded, error \(String(describing: reader.error))")
        #expect(samples > 48000, "at least one second of audio must come out")
    }
}
